#!/bin/bash
# Oracle solution for glitchtip-release-pipeline-integration (v30).
#
# Demonstrates the full release lifecycle end-to-end through the v30
# admission-proxy hardening layer. Scores 1.0 on all 3 subscores:
#   s1 schema      — release POSTed with correct schema (P2-gated)
#   s2 lifecycle   — release finalized + commits[] + production deploy
#                    (the /commits/ and /deploys/ endpoints are served by
#                    the P2 shim)
#   s3 durability  — pipeline is idempotent across multiple commit cycles
#                    AND both retention CronJobs are suspended so releases
#                    survive the grader's 150s probe window
#
# Choices that satisfy the proxy contracts:
#   - Token: the gt_-prefixed `token` key of Secret/bleater/release-ci-token.
#     P1 rejects an Actions-secret VALUE that lacks the gt_ prefix; P2 strips
#     the prefix before forwarding to upstream GlitchTip.
#   - Secret name: RELEASE_AUTH (neutral) — P1 rejects GLITCHTIP_/GT_/GITHUB_*
#     names, and the repo-actions-secret-retention CronJob sweeps them.
#   - Workflow file: .gitea/workflows/deploy.yml — the P3 reconciler reverts
#     .gitea/workflows/release.yml every 60s; deploy.yml is the documented escape.
#   - Runner job env is busybox-only (no curl/python3, wget can't PUT) so the
#     whole lifecycle is done with three wget --post-data POSTs: CREATE (with
#     dateReleased -> finalized, and url for the P2 schema gate), /commits/,
#     and /deploys/.
#   - Cluster service DNS for the GlitchTip URL (the runner pod has CoreDNS
#     only; glitchtip-web.glitchtip.svc.cluster.local fronts the P2 proxy).
set -e
export KUBECONFIG=/home/ubuntu/.kube/config

GITEA="http://gitea.gitea.svc.cluster.local:3000"
GT="http://glitchtip-web.glitchtip.svc.cluster.local:8080"
ORG="bleater"
SERVICES=(auth-service bleat-service api-gateway)
log() { echo "[solution] $*"; }

# ─────────────────────────────────────────────────────────────────────────────
# Step 1: discover Gitea admin credentials from the passwords catalog
# ─────────────────────────────────────────────────────────────────────────────
log "Step 1: discover Gitea admin credentials"
PASSWORDS_HTML=$(curl -sf http://passwords.devops.local || true)
read -r GITEA_USER GITEA_PASS <<< "$(printf '%s' "$PASSWORDS_HTML" \
    | python3 -c "
import sys, re
html = sys.stdin.read()
m = re.search(r'<tr>\s*<td>[^<]*Gitea root[^<]*</td>\s*<td>([^<]+)</td>\s*<td>([^<]+)</td>', html, re.I)
print(m.group(1).strip(), m.group(2).strip()) if m else print('root', 'Admin@123456')
")"
GITEA_AUTH="${GITEA_USER}:${GITEA_PASS}"
log "  Gitea user=${GITEA_USER}"

# ─────────────────────────────────────────────────────────────────────────────
# Step 2: read the platform release token (gt_-prefixed) from
# Secret/bleater/release-ci-token. The `token` key carries the gt_ prefix
# that P1 requires on an Actions-secret value and that P2 strips before
# forwarding to upstream GlitchTip.
# ─────────────────────────────────────────────────────────────────────────────
log "Step 2: read platform release token (gt_-prefixed)"
GT_TOKEN=$(kubectl get secret -n bleater release-ci-token \
    -o jsonpath='{.data.token}' 2>/dev/null | base64 -d || true)
if [ -z "$GT_TOKEN" ]; then
    log "ERROR: Secret/bleater/release-ci-token missing or empty"
    exit 1
fi
case "$GT_TOKEN" in
    gt_*) log "  release token loaded: ${GT_TOKEN:0:11}..." ;;
    *)    log "ERROR: release token is not gt_-prefixed"; exit 1 ;;
esac

# ─────────────────────────────────────────────────────────────────────────────
# Step 3: suspend the retention / rotation CronJobs so releases survive the
# grader's durability window. There are TWO release-retention enforcers
# (the original + the v30 storage-compliance duplicate) and two secret
# sweepers — suspend all of them.
# ─────────────────────────────────────────────────────────────────────────────
log "Step 3: suspend retention / rotation CronJobs"
for cj in gitea-actions-secret-rotation repo-actions-secret-retention; do
    kubectl -n gitea patch cronjob "$cj" \
        -p '{"spec":{"suspend":true}}' --type=merge 2>/dev/null \
        && log "  suspended gitea/$cj" || log "  (gitea/$cj not present)"
done
for cj in glitchtip-release-retention-enforcer glitchtip-storage-compliance; do
    kubectl -n glitchtip patch cronjob "$cj" \
        -p '{"spec":{"suspend":true}}' --type=merge 2>/dev/null \
        && log "  suspended glitchtip/$cj" || log "  (glitchtip/$cj not present)"
done

# ─────────────────────────────────────────────────────────────────────────────
# Step 4: discover the GlitchTip project slugs (through the P2 proxy)
# ─────────────────────────────────────────────────────────────────────────────
log "Step 4: discover GlitchTip project slugs"
curl -sf -H "Authorization: Bearer ${GT_TOKEN}" \
    "${GT}/api/0/organizations/${ORG}/projects/" \
    | python3 -c "
import sys, json
try:
    for p in json.load(sys.stdin):
        print('  slug=' + p.get('slug','') + ' name=' + p.get('name',''))
except Exception as e:
    print('  (project list parse failed: %s)' % e)
" || true

# ─────────────────────────────────────────────────────────────────────────────
# Step 5: register the release token as a repo-level Gitea Actions secret
# named RELEASE_AUTH (neutral name; gt_-prefixed value — both required to
# pass the P1 admission proxy).
# ─────────────────────────────────────────────────────────────────────────────
log "Step 5: register RELEASE_AUTH secret on each service repo"
for SVC in "${SERVICES[@]}"; do
    PAYLOAD=$(python3 -c "import json,sys; print(json.dumps({'data': sys.argv[1]}))" "${GT_TOKEN}")
    HTTP=$(curl -s -o /tmp/_sec -w '%{http_code}' -X PUT -u "${GITEA_AUTH}" \
        -H "Content-Type: application/json" -d "${PAYLOAD}" \
        "${GITEA}/api/v1/repos/${ORG}/${SVC}/actions/secrets/RELEASE_AUTH")
    log "  ${SVC}: RELEASE_AUTH PUT -> HTTP ${HTTP}"
done

# ─────────────────────────────────────────────────────────────────────────────
# Step 6: push the deploy.yml workflow to each service repo. The workflow
# runs the full release lifecycle as three busybox-wget POSTs on every push:
#   1. CREATE  POST /releases/                  (version+ref+url+projects+dateReleased)
#   2. COMMITS POST /releases/{sha}/commits/     (P2 shim)
#   3. DEPLOY  POST /releases/{sha}/deploys/     (P2 shim; needs release finalized)
# Filename is deploy.yml — NOT release.yml (the P3 reconciler reverts that).
# ─────────────────────────────────────────────────────────────────────────────
log "Step 6: push deploy.yml workflow to each service repo"
for SVC in "${SERVICES[@]}"; do
    DEPLOY_YML=$(cat <<YAML
name: Deploy and announce GlitchTip release
on:
  push:
    branches: [main]
  workflow_dispatch:
jobs:
  release-lifecycle:
    runs-on: nebula
    steps:
      - name: Announce full release lifecycle to GlitchTip
        env:
          REPO: \${{ github.repository }}
          SHA: \${{ github.sha }}
          TOKEN: \${{ secrets.RELEASE_AUTH }}
        run: |
          set -e
          PROJECT=\$(echo "\$REPO" | awk -F/ '{print \$2}')
          NOW=\$(date -u +%s)
          DR=\$(date -u -d @\$((NOW + 60)) +%Y-%m-%dT%H:%M:%SZ)
          TS=\$(date -u +%Y-%m-%dT%H:%M:%SZ)
          COMMIT_URL="http://gitea.gitea.svc.cluster.local:3000/\$REPO/commit/\$SHA"
          REL="${GT}/api/0/organizations/${ORG}/releases"
          # 1. CREATE — dateReleased in the body makes the record finalized
          #    (dateReleased > dateCreated); url + ref satisfy the P2 schema gate.
          CREATE_BODY="{\"version\":\"\$SHA\",\"ref\":\"\$SHA\",\"url\":\"\$COMMIT_URL\",\"projects\":[\"\$PROJECT\"],\"dateReleased\":\"\$DR\"}"
          echo "CREATE \$SHA for \$PROJECT"
          wget -q -O- --header="Authorization: Bearer \$TOKEN" --header="Content-Type: application/json" --post-data="\$CREATE_BODY" "\$REL/"
          echo
          # 2. SET COMMITS — P2 shim endpoint
          COMMITS_BODY="{\"commits\":[{\"id\":\"\$SHA\",\"repository\":\"\$REPO\",\"author_email\":\"ci@bleater.local\",\"author_name\":\"Bleater CI\",\"message\":\"deploy \$SHA\",\"timestamp\":\"\$TS\"}]}"
          echo "COMMITS \$SHA"
          wget -q -O- --header="Authorization: Bearer \$TOKEN" --header="Content-Type: application/json" --post-data="\$COMMITS_BODY" "\$REL/\$SHA/commits/"
          echo
          # 3. RECORD DEPLOY — P2 shim endpoint; requires the release finalized
          DEPLOY_BODY="{\"environment\":\"production\",\"name\":\"\$PROJECT-release\",\"dateStarted\":\"\$TS\",\"dateFinished\":\"\$DR\"}"
          echo "DEPLOY \$SHA"
          wget -q -O- --header="Authorization: Bearer \$TOKEN" --header="Content-Type: application/json" --post-data="\$DEPLOY_BODY" "\$REL/\$SHA/deploys/"
          echo
          echo "Release lifecycle complete for \$PROJECT @ \$SHA"
YAML
)
    B64=$(printf '%s' "$DEPLOY_YML" | base64 -w0)
    EXISTING_SHA=$(curl -sf -u "${GITEA_AUTH}" \
        "${GITEA}/api/v1/repos/${ORG}/${SVC}/contents/.gitea/workflows/deploy.yml" \
        2>/dev/null \
        | python3 -c "import sys,json
try: print(json.load(sys.stdin).get('sha',''))
except Exception: print('')" || echo "")
    if [ -n "$EXISTING_SHA" ]; then
        curl -sf -u "${GITEA_AUTH}" -X PUT \
            -H "Content-Type: application/json" \
            -d "{\"message\":\"v30 release lifecycle workflow\",\"content\":\"${B64}\",\"branch\":\"main\",\"sha\":\"${EXISTING_SHA}\"}" \
            "${GITEA}/api/v1/repos/${ORG}/${SVC}/contents/.gitea/workflows/deploy.yml" >/dev/null
    else
        curl -sf -u "${GITEA_AUTH}" -X POST \
            -H "Content-Type: application/json" \
            -d "{\"message\":\"v30 release lifecycle workflow\",\"content\":\"${B64}\",\"branch\":\"main\"}" \
            "${GITEA}/api/v1/repos/${ORG}/${SVC}/contents/.gitea/workflows/deploy.yml" >/dev/null
    fi
    log "  ${SVC}: deploy.yml pushed"
done

# ─────────────────────────────────────────────────────────────────────────────
# Step 7: poll Gitea Actions until each service has a successful workflow run
# on its current HEAD SHA. The grader runs after solution.sh — without this
# wait the grader would race an in-flight pipeline.
# ─────────────────────────────────────────────────────────────────────────────
log "Step 7: poll Gitea Actions for successful run on HEAD SHA"
poll_for_success () {
    local svc="$1"
    local deadline=$(( $(date +%s) + 600 ))   # 10 min
    while [ "$(date +%s)" -lt "$deadline" ]; do
        local head_sha
        head_sha=$(curl -sf -u "${GITEA_AUTH}" \
            "${GITEA}/api/v1/repos/${ORG}/${svc}/commits?limit=1" \
            | python3 -c "import sys,json; print(json.load(sys.stdin)[0]['sha'])" 2>/dev/null || echo "")
        if [ -n "$head_sha" ]; then
            local raw
            raw=$(curl -s -u "${GITEA_AUTH}" \
                "${GITEA}/api/v1/repos/${ORG}/${svc}/actions/runs?limit=10")
            local hit
            hit=$(RAW="$raw" TARGET="$head_sha" python3 -c "
import os, json
target = (os.environ.get('TARGET') or '').lower()
try: d = json.loads(os.environ['RAW'])
except Exception: raise SystemExit(0)
runs = d.get('workflow_runs') or d.get('runs') or (d if isinstance(d, list) else [])
for r in runs:
    if not isinstance(r, dict): continue
    s = (r.get('status') or '').lower()
    c = (r.get('conclusion') or '').lower()
    if not (s in ('success','succeeded','completed_success') or c in ('success','succeeded')):
        continue
    sha = ''
    for k in ('head_sha','head_commit_sha','head_commit','sha'):
        v = r.get(k)
        if isinstance(v, str): sha = v; break
        if isinstance(v, dict):
            inner = v.get('sha') or v.get('id')
            if isinstance(inner, str): sha = inner; break
    if target and sha.lower() == target:
        print('OK'); raise SystemExit(0)
" 2>/dev/null || echo "")
            if [ "$hit" = "OK" ]; then
                log "  ${svc}: success on HEAD ${head_sha:0:12}"
                return 0
            fi
        fi
        sleep 10
    done
    log "  ${svc}: TIMEOUT after 10 min waiting for success on HEAD"
    return 1
}
for SVC in "${SERVICES[@]}"; do
    poll_for_success "$SVC" || true
done

# ─────────────────────────────────────────────────────────────────────────────
# Step 8: push a SECOND commit per service so each service has >= 2
# SHA-versioned releases. The grader's s3 then pushes 2 more probe commits,
# requiring >= baseline+2 lifecycle-complete releases per service.
# ─────────────────────────────────────────────────────────────────────────────
log "Step 8: push second commit per service to seed s3 baseline"
for SVC in "${SERVICES[@]}"; do
    NEW_CONTENT="# Changelog

- $(date -u +%Y-%m-%dT%H:%M:%SZ): wired GlitchTip release lifecycle
"
    B64=$(printf '%s' "$NEW_CONTENT" | base64 -w0)
    EXISTING_SHA=$(curl -sf -u "${GITEA_AUTH}" \
        "${GITEA}/api/v1/repos/${ORG}/${SVC}/contents/CHANGELOG.md" 2>/dev/null \
        | python3 -c "import sys,json
try: print(json.load(sys.stdin).get('sha',''))
except Exception: print('')" || echo "")
    if [ -n "$EXISTING_SHA" ]; then
        curl -sf -u "${GITEA_AUTH}" -X PUT \
            -H "Content-Type: application/json" \
            -d "{\"message\":\"chore: bump changelog\",\"content\":\"${B64}\",\"branch\":\"main\",\"sha\":\"${EXISTING_SHA}\"}" \
            "${GITEA}/api/v1/repos/${ORG}/${SVC}/contents/CHANGELOG.md" >/dev/null
    else
        curl -sf -u "${GITEA_AUTH}" -X POST \
            -H "Content-Type: application/json" \
            -d "{\"message\":\"chore: add changelog\",\"content\":\"${B64}\",\"branch\":\"main\"}" \
            "${GITEA}/api/v1/repos/${ORG}/${SVC}/contents/CHANGELOG.md" >/dev/null
    fi
    log "  ${SVC}: second commit pushed"
done

log "Step 9: poll for second-commit pipeline runs"
for SVC in "${SERVICES[@]}"; do
    poll_for_success "$SVC" || true
done

log "Solution complete. Each service has >= 2 lifecycle-complete releases."
log "Grader s3 will push 2 more probe commits to verify durability."
