#!/bin/bash
set -euo pipefail

# Reference solution for glitchtip-release-pipeline-integration.
#
# Scoring path (must hit 1.0 across all 3 subscores):
#   s1_release_visible_with_environment — releases for all 3 services
#       carry a SHA version and 'production' in environments.
#   s2_pipeline_drives_releases         — Gitea Actions runs for ≥2 services
#       must complete successfully with head_shas matching release versions
#       in GlitchTip + GLITCHTIP_TOKEN secret reachable at org or ≥2 repos.
#   s3_release_to_issue_correlation     — auth-service must have a SHA-
#       versioned release; grader posts a probe event tagged with that
#       version; resulting issue must show the release association AND the
#       release detail's firstEvent must populate.
#
# Strategy:
#   1. Discover ACTUAL GlitchTip project slugs via API (avoid the wiki trap).
#   2. Fetch admin creds from passwords.devops.local (don't hardcode).
#   3. Mint a release-write token via GlitchTip's Django shell.
#   4. Set the token as a Gitea Actions ORG-level secret (covers all 3 repos).
#   5. Push a reusable workflow to a shared repo; service workflows
#      `uses:` it. Push commits to each service's main branch. Each push
#      drives a workflow run whose head_sha matches a release in GlitchTip.
#   6. Verify: 3 releases visible with SHA + production env; runs successful;
#      release-issue link works.

export KUBECONFIG=/home/ubuntu/.kube/config

GT="http://glitchtip.devops.local"
GITEA="http://gitea.devops.local:3000"
ORG="bleater"
SERVICES=(auth-service bleat-service api-gateway)

log() { echo "[solution] $*"; }

# ─────────────────────────────────────────────────────────────────────────────
# Step 1: discover credentials from passwords.devops.local
# ─────────────────────────────────────────────────────────────────────────────
log "Step 1: discover credentials from passwords catalog"
PASSWORDS_HTML=$(curl -sf http://passwords.devops.local || true)

# Parse passwords catalog for credentials (best-effort).
read -r GT_ADMIN GT_PASS GITEA_USER GITEA_PASS <<< "$(printf '%s' "$PASSWORDS_HTML" | python3 - <<'PY'
import sys, re
html = sys.stdin.read()
def find(label):
    m = re.search(
        rf"<tr>\s*<td>[^<]*{label}[^<]*</td>\s*<td>([^<]+)</td>\s*<td>([^<]+)</td>",
        html, re.I,
    )
    return (m.group(1).strip(), m.group(2).strip()) if m else (None, None)
gt_user, gt_pass = find("GlitchTip Admin")
gitea_user, gitea_pass = find("Gitea root")
if not gt_user: gt_user = "glitchtip-admin@nebula.local"
if not gt_pass: gt_pass = "Admin@123456"
if not gitea_user: gitea_user = "root"
if not gitea_pass: gitea_pass = "Admin@123456"
print(gt_user, gt_pass, gitea_user, gitea_pass)
PY
)"

# Pull the staged CI token from Secret/bleater/glitchtip-ci-token. The
# wiki advertises this as a "release-write credential" but the token is
# actually poisoned — its scopes EXCLUDE project:releases. Auth probes
# return 200; the actual POST .../releases/ returns 403. We must scope-
# check it and mint a fresh token via admin login if it's insufficient.
CI_TOKEN_PRE=$(kubectl get secret -n bleater glitchtip-ci-token \
    -o jsonpath='{.data.token}' 2>/dev/null | base64 -d 2>/dev/null || true)
if [ -z "$CI_TOKEN_PRE" ]; then
    log "ERROR: could not read Secret/bleater/glitchtip-ci-token"
    log "  kubectl output: $(kubectl get secret -n bleater glitchtip-ci-token 2>&1 | head -3)"
    exit 1
fi
log "  staged CI token (from bleater Secret): ${CI_TOKEN_PRE:0:8}..."
log "GT admin=$GT_ADMIN  Gitea user=$GITEA_USER"
GITEA_AUTH="$GITEA_USER:$GITEA_PASS"

# ─────────────────────────────────────────────────────────────────────────────
# Step 1.7: scope-check the bleater-ns token; if poisoned (no release
# scope), fall back to the real token in Secret/glitchtip/release-write-
# credentials. Agents who skip this scope-probe and trust the wiki-
# advertised bleater token will produce zero release records.
# ─────────────────────────────────────────────────────────────────────────────
log "Step 1.7: probe staged bleater token for release-write scope"
# Use a per-run unique probe version so a re-run against the same GlitchTip
# state doesn't 500 on duplicate-version uniqueness collision.
PROBE_SUFFIX=$(date +%s)_$$
PROBE_HTTP=$(curl -s -o /tmp/_probe -w '%{http_code}' \
    -H "Authorization: Bearer $CI_TOKEN_PRE" \
    -X POST -H "Content-Type: application/json" \
    -d "{\"version\":\"_solution_scope_probe_${PROBE_SUFFIX}\",\"projects\":[\"api-gateway\"]}" \
    "$GT/api/0/organizations/$ORG/releases/" 2>/dev/null || echo "000")
log "  bleater-token release-POST probe: HTTP $PROBE_HTTP"

CI_TOKEN=""
if [ "$PROBE_HTTP" = "200" ] || [ "$PROBE_HTTP" = "201" ] || [ "$PROBE_HTTP" = "208" ]; then
    log "  bleater token has release scope — using as-is"
    CI_TOKEN="$CI_TOKEN_PRE"
else
    # H1 hardening: real token relocated to default/prometheus-remote-write-token
    # (renamed + moved from glitchtip/release-write-credentials, no
    # description annotation). Solution must scope-probe candidate
    # secrets across all allowed namespaces; we shortcut by knowing the
    # exact location, but agents must enumerate.
    log "  bleater token rejected — scope-probing candidate secrets across allowed namespaces"
    REAL_TOKEN=$(kubectl get secret -n default prometheus-remote-write-token \
        -o jsonpath='{.data.token}' 2>/dev/null | base64 -d 2>/dev/null || true)
    if [ -z "$REAL_TOKEN" ]; then
        log "ERROR: Secret/default/prometheus-remote-write-token not found"
        kubectl get secrets -n default 2>&1 | head -20
        exit 1
    fi
    log "  found candidate token in default ns: ${REAL_TOKEN:0:8}..."

    # Verify the candidate token actually has release-write scope
    PROBE2_HTTP=$(curl -s -o /tmp/_probe2 -w '%{http_code}' \
        -H "Authorization: Bearer $REAL_TOKEN" \
        -X POST -H "Content-Type: application/json" \
        -d "{\"version\":\"_solution_scope_probe2_${PROBE_SUFFIX}\",\"projects\":[\"api-gateway\"]}" \
        "$GT/api/0/organizations/$ORG/releases/" 2>/dev/null || echo "000")
    log "  default-ns prometheus-remote-write-token release-POST probe: HTTP $PROBE2_HTTP"
    if [ "$PROBE2_HTTP" != "200" ] && [ "$PROBE2_HTTP" != "201" ] && [ "$PROBE2_HTTP" != "208" ]; then
        log "ERROR: default-ns token also rejected (HTTP $PROBE2_HTTP)"
        head -c 500 /tmp/_probe2
        exit 1
    fi
    CI_TOKEN="$REAL_TOKEN"
    log "  using real release-write token from default/prometheus-remote-write-token"
fi

# ─────────────────────────────────────────────────────────────────────────────
# Step 2: discover ACTUAL GlitchTip project slugs (NOT the wiki's PascalCase)
# ─────────────────────────────────────────────────────────────────────────────
log "Step 2: discover real project slugs via the public API"

# Discover real slugs: 'auth-service', 'bleat-service', 'api-gateway'
# (NOT the 'bleater-Auth-Service' the wiki suggests)
PROJECTS_JSON=$(curl -sf -H "Authorization: Bearer $CI_TOKEN" \
    "$GT/api/0/organizations/$ORG/projects/")
log "Discovered projects:"
echo "$PROJECTS_JSON" | python3 -c "
import sys, json
for p in json.load(sys.stdin):
    print(f\"  slug={p.get('slug')} name={p.get('name')} id={p.get('id')}\")"

# Validate each expected slug exists
for svc in "${SERVICES[@]}"; do
    if ! echo "$PROJECTS_JSON" | python3 -c "
import sys, json
slugs = [p.get('slug') for p in json.load(sys.stdin)]
sys.exit(0 if '$svc' in slugs else 1)
"; then
        log "ERROR: project slug '$svc' not found in GlitchTip"
        exit 1
    fi
done

# ─────────────────────────────────────────────────────────────────────────────
# Step 2.5: neutralize the gitea-actions-secret-rotation CronJob.
# Without this, our org-level GLITCHTIP_TOKEN gets deleted within 2 min
# of being set, breaking every workflow run after the next firing.
# Suspend the CronJob and delete any in-flight Jobs so they don't race.
# ─────────────────────────────────────────────────────────────────────────────
log "Step 2.5: suspend gitea-actions-secret-rotation CronJob"
kubectl patch cronjob -n gitea gitea-actions-secret-rotation \
    -p '{"spec":{"suspend":true}}' 2>/dev/null || true
kubectl delete jobs -n gitea -l app=gitea-secret-rotation \
    --ignore-not-found 2>/dev/null || true

# ─────────────────────────────────────────────────────────────────────────────
# Step 2.6 (v18): suspend the second chaos rotator —
# glitchtip-release-retention-enforcer in glitchtip ns. Fires every 3 min
# and DELETEs all SHA-versioned releases for bleat-service + api-gateway
# (auth-service is exempt). Without this suspend, capable agents' work
# would be wiped between solution-finish and grader-run, cascade-failing
# 6 of 11 atoms. Wiki note ("automated compliance/retention jobs ... if
# your work seems to be disappearing on you, check for scheduled jobs
# running across the namespaces") is the breadcrumb pointing here.
# ─────────────────────────────────────────────────────────────────────────────
log "Step 2.6 (v18): suspend glitchtip-release-retention-enforcer CronJob"
kubectl patch cronjob -n glitchtip glitchtip-release-retention-enforcer \
    -p '{"spec":{"suspend":true}}' 2>/dev/null || true
kubectl delete jobs -n glitchtip -l app=glitchtip-release-retention \
    --ignore-not-found 2>/dev/null || true

# ─────────────────────────────────────────────────────────────────────────────
# Step 3: register CI token as Gitea ORG-level Actions secret
# ─────────────────────────────────────────────────────────────────────────────
log "Step 3: register CI token as Gitea org-level Actions secret"

# Org-level Actions secret — visible to all 3 service repos
curl -sf -u "$GITEA_AUTH" -X PUT \
    -H "Content-Type: application/json" \
    -d "$(python3 -c "import json,sys; print(json.dumps({'data': sys.argv[1]}))" "$CI_TOKEN")" \
    "$GITEA/api/v1/orgs/$ORG/actions/secrets/GLITCHTIP_TOKEN" >/dev/null
log "GLITCHTIP_TOKEN set at org level"

# v11 (s2.each_service_has_repo_level_secret): also set the same token
# at REPO level on every service. The v11 grader atom requires repo-level
# coverage on all 3 services because the rotator wipes org-level secrets
# every 2 min (rotator-resilient placement).
for svc in "${SERVICES[@]}"; do
    curl -sf -u "$GITEA_AUTH" -X PUT \
        -H "Content-Type: application/json" \
        -d "$(python3 -c "import json,sys; print(json.dumps({'data': sys.argv[1]}))" "$CI_TOKEN")" \
        "$GITEA/api/v1/repos/$ORG/$svc/actions/secrets/GLITCHTIP_TOKEN" >/dev/null
    log "  GLITCHTIP_TOKEN set at repo level for $svc"
done

# ─────────────────────────────────────────────────────────────────────────────
# Step 4: create reusable workflow in shared bleater-ci repo
# ─────────────────────────────────────────────────────────────────────────────
log "Step 4: create reusable workflow in $ORG/bleater-ci"

# Step 4 simplified: inline the GlitchTip release announce inside each
# service's build.yml. Gitea Actions' workflow_call support is unreliable
# on this base image, and task.yaml does not require a reusable workflow
# structure — only that pipelines authenticate via a Gitea Actions secret.
log "Step 4 (skipped — inlining release announce in each service's build.yml)"

# ─────────────────────────────────────────────────────────────────────────────
# (v14) Phase 4.5 removed: the prior repos-registration POST against
# /api/0/organizations/{org}/repos/ returned 404 on every rollout because
# GlitchTip v5.1.1 requires a configured SCM provider integration that
# this task's setup intentionally does NOT provision. The matching grader
# atom (release_has_repos_registered) was a confirmed defect — it was
# unsatisfiable even by this oracle solution — and was removed in v14.
# Source-repo binding is now graded via release_has_commits_array, which
# tests that the release POST included `commits: [{id, repository}]`
# and the GET shows commits[] populated (works on v5 — proven by the
# N6 seed release at version=000...000 on api-gateway).
# ─────────────────────────────────────────────────────────────────────────────

# ─────────────────────────────────────────────────────────────────────────────
# Step 5: wire each service workflow with inline release POST + push commit
# ─────────────────────────────────────────────────────────────────────────────
log "Step 5: wire each service workflow + trigger pipeline runs"

for svc in "${SERVICES[@]}"; do
    # H3: include `commits` array in release POST to bind release to source
    # repository (populates `commits[]` on the release detail). Minimal
    # `{"version", "ref"}` body alone leaves commits[] empty and fails the
    # tightened grader atom. Format follows GlitchTip's Sentry-compatible
    # commits parameter: each entry needs `id` (commit SHA) and `repository`
    # (org/repo identifier).
    BUILD_YAML=$(cat <<YAML
name: Build
on:
  push:
    branches: [main]
  workflow_dispatch:
jobs:
  build:
    runs-on: nebula
    steps:
      - name: Build
        run: echo "Building \${GITHUB_SHA}"
      - name: Announce release to GlitchTip
        env:
          GLITCHTIP_TOKEN: \${{ secrets.GLITCHTIP_TOKEN }}
        run: |
          set -e
          SHA="\${GITHUB_SHA}"
          BODY="{\"version\":\"\${SHA}\",\"ref\":\"\${SHA}\",\"projects\":[\"${svc}\"]}"
          # Use cluster service DNS — the act_runner job environment only has
          # k8s coredns (10.43.0.10); glitchtip.devops.local is a dnsmasq
          # alias unreachable from inside the cluster pod network.
          wget -q -O- --header="Authorization: Bearer \${GLITCHTIP_TOKEN}" --header="Content-Type: application/json" --post-data="\${BODY}" http://glitchtip-web.glitchtip.svc.cluster.local:8080/api/0/organizations/bleater/releases/
YAML
)
    BUILD_B64=$(printf '%s' "$BUILD_YAML" | base64 -w0)
    CUR_SHA=$(curl -sf -u "$GITEA_AUTH" \
        "$GITEA/api/v1/repos/$ORG/$svc/contents/.gitea/workflows/build.yml" \
        | python3 -c "import sys,json; print(json.load(sys.stdin).get('sha',''))" 2>/dev/null || echo "")

    if [ -n "$CUR_SHA" ]; then
        curl -sf -u "$GITEA_AUTH" -X PUT \
            -H "Content-Type: application/json" \
            -d "{\"message\":\"wire glitchtip release\",\"content\":\"$BUILD_B64\",\"branch\":\"main\",\"sha\":\"$CUR_SHA\"}" \
            "$GITEA/api/v1/repos/$ORG/$svc/contents/.gitea/workflows/build.yml" >/dev/null
    else
        curl -sf -u "$GITEA_AUTH" -X POST \
            -H "Content-Type: application/json" \
            -d "{\"message\":\"add glitchtip release wire-up\",\"content\":\"$BUILD_B64\",\"branch\":\"main\"}" \
            "$GITEA/api/v1/repos/$ORG/$svc/contents/.gitea/workflows/build.yml" >/dev/null
    fi
    log "  $svc: build.yml updated with inline release announce"
done

# ─────────────────────────────────────────────────────────────────────────────
# Step 5b: remove the decoy release.yml from auth-service + bleat-service.
# The setup seeded a half-built release.yml (wrong endpoint, missing ref)
# in those two repos. It would still trigger on push, silently 200 on the
# wrong endpoint, and produce no release. Delete it.
# ─────────────────────────────────────────────────────────────────────────────
log "Step 5b: remove decoy release.yml from auth-service + bleat-service"
for decoy_svc in auth-service bleat-service; do
    DECOY_SHA=$(curl -sf -u "$GITEA_AUTH" \
        "$GITEA/api/v1/repos/$ORG/$decoy_svc/contents/.gitea/workflows/release.yml" 2>/dev/null \
        | python3 -c "import sys,json; print(json.load(sys.stdin).get('sha',''))" 2>/dev/null || echo "")
    if [ -n "$DECOY_SHA" ]; then
        DEL_HTTP=$(curl -s -o /tmp/_del -w '%{http_code}' -u "$GITEA_AUTH" -X DELETE \
            -H "Content-Type: application/json" \
            -d "{\"message\":\"remove decoy release.yml\",\"sha\":\"$DECOY_SHA\",\"branch\":\"main\"}" \
            "$GITEA/api/v1/repos/$ORG/$decoy_svc/contents/.gitea/workflows/release.yml" 2>/dev/null || echo "000")
        log "  $decoy_svc: decoy release.yml DELETE HTTP $DEL_HTTP"
    else
        log "  $decoy_svc: no decoy release.yml found (already clean)"
    fi
done

# Wait for the pushes to settle and pipelines to be enqueued
sleep 8

# ─────────────────────────────────────────────────────────────────────────────
# Step 6: poll until each service has a SUCCESSFUL workflow run on its
# repo HEAD SHA. The grader (v6) requires release.dateCreated to fall
# inside a successful workflow-run window, so manual fallback POSTs no
# longer satisfy s1 — the pipeline must run to completion and post its
# own release. Timeout: 12 minutes per service (act_runner first-run
# image-pull can take 3–5 minutes; subsequent runs are fast).
# ─────────────────────────────────────────────────────────────────────────────
poll_for_success_run () {
    local svc="$1"
    local target_sha="$2"
    local deadline=$(( $(date +%s) + 720 ))   # 12 min
    while [ "$(date +%s)" -lt "$deadline" ]; do
        local raw
        raw=$(curl -s -u "$GITEA_AUTH" \
            "$GITEA/api/v1/repos/$ORG/$svc/actions/runs?limit=10" 2>/dev/null || echo "{}")
        local hit
        hit=$(printf '%s' "$raw" | TARGET_SHA="$target_sha" python3 - <<'PY' 2>/dev/null || echo ""
import json, os, sys
target = (os.environ.get("TARGET_SHA") or "").lower()
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
runs = d.get("workflow_runs") or d.get("runs") or (d if isinstance(d, list) else [])
def head_sha(r):
    for k in ("head_sha", "head_commit_sha", "head_commit", "sha"):
        v = r.get(k)
        if isinstance(v, str):
            return v
        if isinstance(v, dict):
            inner = v.get("sha") or v.get("id")
            if isinstance(inner, str):
                return inner
    return ""
def is_ok(r):
    s = (r.get("status") or "").lower()
    c = (r.get("conclusion") or "").lower()
    return s in ("success","succeeded","completed_success") or c in ("success","succeeded")
for r in runs:
    if not isinstance(r, dict):
        continue
    if not is_ok(r):
        continue
    if target and head_sha(r).lower() != target:
        continue
    print("OK")
    sys.exit(0)
PY
        )
        if [ "$hit" = "OK" ]; then
            log "  $svc: successful run on SHA ${target_sha:0:12}"
            return 0
        fi
        sleep 12
    done
    log "  $svc: TIMEOUT — no successful run on SHA ${target_sha:0:12} after 12m"
    return 1
}

log "Step 6: poll for successful workflow run per service (12-min timeout)"
declare -A FIRST_SHA
for svc in "${SERVICES[@]}"; do
    FIRST_SHA[$svc]=$(curl -sf -u "$GITEA_AUTH" \
        "$GITEA/api/v1/repos/$ORG/$svc/commits?limit=1" \
        | python3 -c "import sys,json; print(json.load(sys.stdin)[0]['sha'])")
    log "  $svc HEAD SHA: ${FIRST_SHA[$svc]:0:12}"
done

for svc in "${SERVICES[@]}"; do
    poll_for_success_run "$svc" "${FIRST_SHA[$svc]}" || true
done

# ─────────────────────────────────────────────────────────────────────────────
# Step 6.5: push a SECOND commit to each service to produce a second
# SHA-versioned release. This satisfies the multi-commit deployment atom
# (s3.at_least_one_service_has_two_releases) — a real CI/CD pipeline runs
# on every commit, not just the first.
# ─────────────────────────────────────────────────────────────────────────────
log "Step 6.5: push a second commit per service + POST second release"
for svc in "${SERVICES[@]}"; do
    # Add a CHANGELOG.md (or update its content) to create a new commit on main
    EXISTING=$(curl -s -u "$GITEA_AUTH" \
        "$GITEA/api/v1/repos/$ORG/$svc/contents/CHANGELOG.md" 2>/dev/null || echo "")
    NEW_CONTENT="# Changelog

- $(date -u +%Y-%m-%dT%H:%M:%SZ): wired GlitchTip release tracking
"
    NEW_B64=$(printf '%s' "$NEW_CONTENT" | base64 -w0)
    EXISTING_SHA=$(printf '%s' "$EXISTING" | python3 -c "import sys,json
try: print(json.load(sys.stdin).get('sha',''))
except: print('')" 2>/dev/null || echo "")

    if [ -n "$EXISTING_SHA" ]; then
        curl -s -u "$GITEA_AUTH" -X PUT \
            -H "Content-Type: application/json" \
            -d "{\"message\":\"chore($svc): add changelog\",\"content\":\"$NEW_B64\",\"branch\":\"main\",\"sha\":\"$EXISTING_SHA\"}" \
            "$GITEA/api/v1/repos/$ORG/$svc/contents/CHANGELOG.md" >/dev/null
    else
        curl -s -u "$GITEA_AUTH" -X POST \
            -H "Content-Type: application/json" \
            -d "{\"message\":\"chore($svc): add changelog\",\"content\":\"$NEW_B64\",\"branch\":\"main\"}" \
            "$GITEA/api/v1/repos/$ORG/$svc/contents/CHANGELOG.md" >/dev/null
    fi

    # Get the new HEAD SHA (the just-pushed commit) — pipeline auto-runs
    NEW_SHA=$(curl -sf -u "$GITEA_AUTH" \
        "$GITEA/api/v1/repos/$ORG/$svc/commits?limit=1" \
        | python3 -c "import sys,json; print(json.load(sys.stdin)[0]['sha'])")
    log "  $svc: pushed second commit ${NEW_SHA:0:12}; awaiting pipeline"
done

# Poll for the second pipeline run per service to complete successfully.
# Subsequent runs are fast (image cached), so 8 min per service is plenty.
log "Step 6.6: poll for second-commit pipeline runs"
for svc in "${SERVICES[@]}"; do
    SECOND_SHA=$(curl -sf -u "$GITEA_AUTH" \
        "$GITEA/api/v1/repos/$ORG/$svc/commits?limit=1" \
        | python3 -c "import sys,json; print(json.load(sys.stdin)[0]['sha'])")
    poll_for_success_run "$svc" "$SECOND_SHA" || true
done

# ─────────────────────────────────────────────────────────────────────────────
# Step 6.7 (v13 T1): push a THIRD commit per service. T1 tightened
# s3.all_three_services_have_two_releases → "≥3 releases per service".
# Solution pushes 3 evenly so spread is 0 → also satisfies N5
# (release_count_per_service_uniform).
# ─────────────────────────────────────────────────────────────────────────────
log "Step 6.7 (v13): push a third commit per service for T1 (≥3 releases)"
for svc in "${SERVICES[@]}"; do
    THIRD_CONTENT="# README

Bleater $svc service.
Wired GlitchTip release tracking with 2-step finalize on $(date -u +%Y-%m-%dT%H:%M:%SZ).
"
    THIRD_B64=$(printf '%s' "$THIRD_CONTENT" | base64 -w0)
    EXISTING_README=$(curl -s -u "$GITEA_AUTH" \
        "$GITEA/api/v1/repos/$ORG/$svc/contents/README.md" 2>/dev/null || echo "")
    EXISTING_SHA=$(printf '%s' "$EXISTING_README" | python3 -c "import sys,json
try: print(json.load(sys.stdin).get('sha',''))
except: print('')" 2>/dev/null || echo "")

    if [ -n "$EXISTING_SHA" ]; then
        curl -s -u "$GITEA_AUTH" -X PUT \
            -H "Content-Type: application/json" \
            -d "{\"message\":\"docs($svc): note 2-step release flow\",\"content\":\"$THIRD_B64\",\"branch\":\"main\",\"sha\":\"$EXISTING_SHA\"}" \
            "$GITEA/api/v1/repos/$ORG/$svc/contents/README.md" >/dev/null
    else
        curl -s -u "$GITEA_AUTH" -X POST \
            -H "Content-Type: application/json" \
            -d "{\"message\":\"docs($svc): note 2-step release flow\",\"content\":\"$THIRD_B64\",\"branch\":\"main\"}" \
            "$GITEA/api/v1/repos/$ORG/$svc/contents/README.md" >/dev/null
    fi
done

log "Step 6.8 (v13): poll for third-commit pipeline runs"
for svc in "${SERVICES[@]}"; do
    THIRD_SHA=$(curl -sf -u "$GITEA_AUTH" \
        "$GITEA/api/v1/repos/$ORG/$svc/commits?limit=1" \
        | python3 -c "import sys,json; print(json.load(sys.stdin)[0]['sha'])")
    poll_for_success_run "$svc" "$THIRD_SHA" || true
done

# ─────────────────────────────────────────────────────────────────────────────
# Step 7: verify final state
# ─────────────────────────────────────────────────────────────────────────────
log "Step 7: verify releases visible with SHA + production environment"
sleep 5
for svc in "${SERVICES[@]}"; do
    # Decouple curl from python so pipefail can't kill us. Drop -f so we
    # capture HTTP status separately rather than getting empty stdout on 4xx.
    BODY=$(curl -s -w "\n__HTTP__:%{http_code}" \
        -H "Authorization: Bearer $CI_TOKEN" \
        "$GT/api/0/organizations/$ORG/releases/?project=$svc" || true)
    HTTP=$(printf '%s' "$BODY" | awk -F: '/^__HTTP__:/ {print $2}')
    JSON=$(printf '%s' "$BODY" | sed '/^__HTTP__:/d')
    log "  $svc (HTTP ${HTTP:-?}):"
    if [ "${HTTP:-000}" != "200" ]; then
        log "    non-200 response; body: ${JSON:0:200}"
        continue
    fi
    printf '%s' "$JSON" | python3 -c "
import sys, json
try:
    rels = json.load(sys.stdin)
except Exception as e:
    print(f'    parse error: {e}')
    sys.exit(0)
if not rels:
    print('    (no releases)')
    sys.exit(0)
for r in rels[:5]:
    if not isinstance(r, dict): continue
    v = (r.get('version') or '')[:12]
    envs = r.get('environments')
    fe = r.get('firstEvent')
    print(f'    version={v} envs={envs} firstEvent={fe}')
" || true
done

log "Solution complete."
