"""grader.py — GlitchTip Release Pipeline Integration (v30)

3 functional binary subscores, equal 1/3 weight each, summing to 1.0. Every
subscore returns strictly 0.0 or 1.0. The three subscores are genuinely
ORTHOGONAL — they require progressively MORE DISTINCT agent actions, so an
agent's score reflects how far up the action-ladder they climbed:

  s1_schema_correctness_fleet_wide
        For each of the 3 services: a GlitchTip release exists whose
        version equals the repo's HEAD SHA and satisfies the platform
        release schema — bare 40-char hex version, ref == version,
        projects[] contains the lowercase service slug, dateCreated set.
        This is gated by the P2 admission proxy at POST time: a malformed
        release body is rejected with 422 and never lands. Passing s1 =
        "the agent discovered the correct schema + auth + routing."

  s2_lifecycle_completeness_fleet_wide
        For each service's HEAD-SHA release, the FULL Sentry release
        lifecycle is present — beyond just CREATE:
          * dateReleased > dateCreated  (a finalize step happened)
          * commits[] populated         (a separate POST /commits/ call)
          * >=1 deploy, environment=production  (a separate POST /deploys/)
        The /commits/ and /deploys/ endpoints are served by the P2 shim
        (GlitchTip v5.1.1 stripped them). An agent who writes a minimal
        "POST a release" workflow passes s1 but fails s2 entirely — the
        lifecycle calls are three additional, independent actions.

  s3_durability_under_rotation
        The grader pushes 2 synthetic commits per service (60s apart),
        waits 150s, then verifies each service produced >= baseline+2
        SHA-versioned releases that are EACH lifecycle-complete (s1 + s2
        criteria per release). This catches agents whose pipeline ran
        once at validation but isn't idempotent, and agents who didn't
        suppress BOTH retention CronJobs (glitchtip-release-retention-
        enforcer AND glitchtip-storage-compliance) — releases get swept
        within the 150s window.

Orthogonality: (1,0,0) basic-pipeline agent · (1,1,0) full-lifecycle agent
who didn't handle retention · (1,1,1) complete agent. The axes move
independently.

Every check is functional — live HTTP against the GlitchTip API (via the
P2 proxy/shim) and the Gitea API (via P1). No regex/substring matching on
agent-authored files. Polling/retry with deadlines for state propagation.

Runs as root with KUBECONFIG=/etc/rancher/k3s/k3s.yaml.
"""
import base64
import datetime as dt
import json
import os
import re
import subprocess
import time
import urllib.error
import urllib.parse
import urllib.request

from apex_arena._types import GradingResult


KUBECONFIG = "/etc/rancher/k3s/k3s.yaml"
# The grader talks to GlitchTip and Gitea through their Services. After the
# v30 Service-rename, glitchtip-web -> P2 proxy+shim, gitea -> P1 proxy.
# Going through P2 is REQUIRED so the grader can read the shimmed
# /commits/ and /deploys/ endpoints.
GT_URL = "http://glitchtip-web.glitchtip.svc.cluster.local:8080"
GITEA_URL = "http://gitea.gitea.svc.cluster.local:3000"
GITEA_USER = "root"
GITEA_PASS = "Admin@123456"
GT_ORG_SLUG = "bleater"
SERVICES = ["auth-service", "bleat-service", "api-gateway"]

env = {**os.environ, "KUBECONFIG": KUBECONFIG}
SHA_RE = re.compile(r"^[0-9a-f]{40}$")


def kube(*args, timeout=30):
    return subprocess.run(
        ["kubectl", *args],
        capture_output=True, text=True, env=env, timeout=timeout,
    )


def http(method, path, token=None, data=None, timeout=20):
    """GlitchTip API call through the P2 proxy/shim.

    The grader-side token is a plain GlitchTip token (no gt_ prefix). P2
    does not 403 GET requests for a missing prefix — it forwards them — so
    read paths work with the plain token. P2's shim serves /commits/ and
    /deploys/ from its own store; everything else proxies to upstream.
    """
    url = path if path.startswith("http") else f"{GT_URL}{path}"
    body_bytes = json.dumps(data).encode() if data is not None else None
    req = urllib.request.Request(url, data=body_bytes, method=method)
    if token:
        req.add_header("Authorization", f"Bearer {token}")
    if data is not None:
        req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            raw = resp.read().decode("utf-8", errors="replace")
            try:
                return resp.status, json.loads(raw)
            except json.JSONDecodeError:
                return resp.status, raw
    except urllib.error.HTTPError as e:
        raw = e.read().decode("utf-8", errors="replace") if e.fp else ""
        try:
            return e.code, json.loads(raw)
        except json.JSONDecodeError:
            return e.code, raw
    except Exception as e:  # noqa: BLE001
        return -1, f"transport error: {e}"


def gitea_api(method, path, data=None, timeout=20):
    url = f"{GITEA_URL}{path}"
    body_bytes = json.dumps(data).encode() if data is not None else None
    req = urllib.request.Request(url, data=body_bytes, method=method)
    cred = base64.b64encode(f"{GITEA_USER}:{GITEA_PASS}".encode()).decode()
    req.add_header("Authorization", f"Basic {cred}")
    if data is not None:
        req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            raw = resp.read().decode("utf-8", errors="replace")
            try:
                return resp.status, json.loads(raw)
            except json.JSONDecodeError:
                return resp.status, raw
    except urllib.error.HTTPError as e:
        raw = e.read().decode("utf-8", errors="replace") if e.fp else ""
        try:
            return e.code, json.loads(raw)
        except json.JSONDecodeError:
            return e.code, raw
    except Exception as e:  # noqa: BLE001
        return -1, f"transport error: {e}"


def grader_token():
    """Read the grader-side GlitchTip token staged by setup.sh in the
    grader-state namespace (agent has no access to that namespace)."""
    r = kube("get", "secret", "-n", "grader-state",
             "glitchtip-grader-token", "-o", "jsonpath={.data.token}")
    if r.returncode != 0 or not r.stdout.strip():
        return None
    try:
        tok = base64.b64decode(r.stdout.strip()).decode().strip()
        # If it carries the platform gt_ prefix, strip it — the raw token is
        # what upstream GlitchTip expects, and P2 would strip it anyway.
        return tok[3:] if tok.startswith("gt_") else tok
    except Exception:
        return None


def _list_releases(token, slug):
    """Releases are ORG-scoped. Pull the org list and filter client-side by
    the projects[] field for the requested service slug."""
    status, body = http(
        "GET",
        f"/api/0/organizations/{GT_ORG_SLUG}/releases/?project={slug}&per_page=200",
        token=token,
    )
    if status != 200 or not isinstance(body, list):
        status, body = http(
            "GET",
            f"/api/0/organizations/{GT_ORG_SLUG}/releases/?per_page=200",
            token=token,
        )
        if status != 200 or not isinstance(body, list):
            return []
    out = []
    for r in body:
        if not isinstance(r, dict):
            continue
        proj_slugs = []
        for p in (r.get("projects") or []):
            if isinstance(p, dict) and p.get("slug"):
                proj_slugs.append(p["slug"])
            elif isinstance(p, str):
                proj_slugs.append(p)
        if slug in proj_slugs:
            out.append(r)
    return out


def _get_release_detail(token, version):
    status, body = http(
        "GET",
        f"/api/0/organizations/{GT_ORG_SLUG}/releases/"
        f"{urllib.parse.quote(version, safe='')}/",
        token=token,
    )
    return body if status == 200 and isinstance(body, dict) else None


def _list_commits(token, version):
    """Served by the P2 shim — GlitchTip v5.1.1 has no /commits/ endpoint."""
    status, body = http(
        "GET",
        f"/api/0/organizations/{GT_ORG_SLUG}/releases/"
        f"{urllib.parse.quote(version, safe='')}/commits/",
        token=token,
    )
    return body if status == 200 and isinstance(body, list) else []


def _list_deploys(token, version):
    """Served by the P2 shim — GlitchTip v5.1.1 has no /deploys/ endpoint."""
    status, body = http(
        "GET",
        f"/api/0/organizations/{GT_ORG_SLUG}/releases/"
        f"{urllib.parse.quote(version, safe='')}/deploys/",
        token=token,
    )
    return body if status == 200 and isinstance(body, list) else []


def _get_repo_head_sha(svc):
    status, body = gitea_api(
        "GET", f"/api/v1/repos/{GT_ORG_SLUG}/{svc}/commits?limit=1",
    )
    if status != 200 or not isinstance(body, list) or not body:
        return None
    sha = body[0].get("sha") if isinstance(body[0], dict) else None
    return sha if isinstance(sha, str) and SHA_RE.match(sha) else None


def _trigger_grader_push(svc, label):
    """Push a synthetic commit to a service repo via the grader-pusher pod
    in the grader-state namespace. Returns True on success. The pod reaches
    Gitea through the P1 proxy (a plain content POST — P1 passes it through).
    """
    timestamp = int(time.time())
    inline = (
        "import urllib.request, urllib.error, json, base64\n"
        f"auth = base64.b64encode(b'{GITEA_USER}:{GITEA_PASS}').decode()\n"
        "h = {'Authorization': 'Basic ' + auth, 'Content-Type': 'application/json'}\n"
        f"url = '{GITEA_URL}/api/v1/repos/{GT_ORG_SLUG}/{svc}/contents/"
        f".grader-probes/{label}-{timestamp}.txt'\n"
        "payload = {\n"
        f"    'message': 'grader-probe {label} {timestamp}',\n"
        f"    'content': base64.b64encode(b'probe {timestamp}').decode(),\n"
        "    'branch': 'main',\n"
        "}\n"
        "req = urllib.request.Request(url, data=json.dumps(payload).encode(), "
        "method='POST', headers=h)\n"
        "try:\n"
        "    with urllib.request.urlopen(req, timeout=20) as r:\n"
        "        print('OK', r.status)\n"
        "except urllib.error.HTTPError as e:\n"
        "    print('HTTPError', e.code, e.read().decode()[:200])\n"
    )
    r = subprocess.run(
        ["kubectl", "exec", "-n", "grader-state", "deploy/grader-pusher",
         "--", "python3", "-c", inline],
        capture_output=True, text=True, env=env, timeout=40,
    )
    return r.returncode == 0 and "OK" in r.stdout


# ─────────────────────────────────────────────────────────────────────────────
# Shared per-release predicates
# ─────────────────────────────────────────────────────────────────────────────

def _schema_reason(rel, svc, expected_version):
    """None if the release record satisfies the platform schema for svc at
    expected_version, else a short failure reason."""
    v = rel.get("version", "")
    if not (isinstance(v, str) and SHA_RE.match(v)):
        return "version not 40-char lowercase hex"
    if v != expected_version:
        return f"version {v[:12]} != expected {expected_version[:12]}"
    ref = rel.get("ref", "")
    if not isinstance(ref, str) or not SHA_RE.match(ref) or ref != v:
        ref_disp = (ref[:12] if isinstance(ref, str) and ref
                    else type(ref).__name__)
        return f"ref={ref_disp} != version (finalize PUT must preserve ref)"
    proj_slugs = []
    for p in (rel.get("projects") or []):
        if isinstance(p, dict) and p.get("slug"):
            proj_slugs.append(p["slug"])
        elif isinstance(p, str):
            proj_slugs.append(p)
    if svc not in proj_slugs:
        return f"projects[]={proj_slugs} missing '{svc}'"
    if not rel.get("dateCreated"):
        return "dateCreated missing"
    return None


def _finalized(rel):
    """True if dateReleased is strictly later than dateCreated — proof a
    finalize step ran (GlitchTip auto-stamps dateReleased ~7ms BEFORE
    dateCreated at create time, so a naive create alone never satisfies
    this; an explicit dateReleased — via create body or finalize PUT —
    set to a real ship time does)."""
    dr = rel.get("dateReleased")
    dc = rel.get("dateCreated")
    if not isinstance(dr, str) or not isinstance(dc, str):
        return False
    try:
        dr_dt = dt.datetime.fromisoformat(dr.replace("Z", "+00:00"))
        dc_dt = dt.datetime.fromisoformat(dc.replace("Z", "+00:00"))
    except Exception:
        return False
    return dr_dt > dc_dt


def _lifecycle_reason(token, rel, svc, expected_version):
    """None if the release is FULLY lifecycle-complete (schema + finalized +
    commits + production deploy), else a short failure reason. Used by both
    s2 (HEAD release) and s3 (each grader-pushed release)."""
    schema = _schema_reason(rel, svc, expected_version)
    if schema:
        return f"schema: {schema}"
    if not _finalized(rel):
        return "not finalized (dateReleased not > dateCreated)"
    version = rel["version"]
    commits = _list_commits(token, version)
    valid_commit = any(
        isinstance(c, dict)
        and SHA_RE.match(str(c.get("id", "")))
        and isinstance(c.get("repository"), str) and c.get("repository").strip()
        and isinstance(c.get("author_email"), str) and c.get("author_email").strip()
        for c in commits
    )
    if not valid_commit:
        return f"no valid commit record (have {len(commits)})"
    deploys = _list_deploys(token, version)
    prod_deploy = any(
        isinstance(d, dict) and d.get("environment") == "production"
        for d in deploys
    )
    if not prod_deploy:
        return f"no production deploy (have {len(deploys)})"
    return None


# ─────────────────────────────────────────────────────────────────────────────
# Subscore 1: schema correctness fleet-wide
# ─────────────────────────────────────────────────────────────────────────────

def check_s1_schema_correctness_fleet_wide():
    token = grader_token()
    if not token:
        return 0.0, "s1: grader token missing — setup defect, not agent fault."

    deadline = time.time() + 45
    final_failures = {}
    while time.time() < deadline:
        failures = {}
        successes = []
        for svc in SERVICES:
            head_sha = _get_repo_head_sha(svc)
            if not head_sha:
                failures[svc] = "cannot read repo HEAD SHA"
                continue
            rel = _get_release_detail(token, head_sha)
            if not rel:
                failures[svc] = f"no release at /releases/{head_sha[:12]}/"
                continue
            reason = _schema_reason(rel, svc, head_sha)
            if reason:
                failures[svc] = reason
                continue
            successes.append(svc)
        if len(successes) == len(SERVICES):
            return 1.0, (f"All 3 services have schema-correct releases on "
                         f"HEAD SHA: {successes}")
        final_failures = failures
        time.sleep(5)

    return 0.0, ("Schema correctness failed: "
                 + " | ".join(f"{s}: {m}" for s, m in final_failures.items()))


# ─────────────────────────────────────────────────────────────────────────────
# Subscore 2: lifecycle completeness fleet-wide
# ─────────────────────────────────────────────────────────────────────────────

def check_s2_lifecycle_completeness_fleet_wide():
    token = grader_token()
    if not token:
        return 0.0, "s2: grader token missing — setup defect."

    failures = []
    for svc in SERVICES:
        head_sha = _get_repo_head_sha(svc)
        if not head_sha:
            failures.append(f"{svc}: cannot read repo HEAD SHA")
            continue
        rel = _get_release_detail(token, head_sha)
        if not rel:
            failures.append(f"{svc}: release {head_sha[:12]} not found")
            continue
        reason = _lifecycle_reason(token, rel, svc, head_sha)
        if reason:
            failures.append(f"{svc}: {reason}")
            continue

    if failures:
        return 0.0, "Lifecycle completeness failed: " + " | ".join(failures[:5])
    return 1.0, ("All 3 services have lifecycle-complete releases on HEAD SHA: "
                 "finalized + commits[] + production deploy")


# ─────────────────────────────────────────────────────────────────────────────
# Subscore 3: durability under rotation
# ─────────────────────────────────────────────────────────────────────────────

def check_s3_durability_under_rotation():
    token = grader_token()
    if not token:
        return 0.0, "s3: grader token missing — setup defect."

    # Baseline: SHA-versioned release counts per service before grader pushes.
    baseline_heads = {svc: _get_repo_head_sha(svc) for svc in SERVICES}
    baseline_counts = {}
    for svc in SERVICES:
        rels = _list_releases(token, svc)
        sha_rels = [r for r in rels if isinstance(r, dict)
                    and isinstance(r.get("version"), str)
                    and SHA_RE.match(r["version"])]
        baseline_counts[svc] = len(sha_rels)
    if not all(baseline_heads.values()):
        return 0.0, (f"baseline HEAD capture failed: "
                     f"{ {k: (v[:12] if v else None) for k, v in baseline_heads.items()} }")

    # Two grader-triggered push cycles, 60s apart.
    pushed1 = {svc: _trigger_grader_push(svc, "probe1") for svc in SERVICES}
    if not all(pushed1.values()):
        return 0.0, (f"first grader push failed: {pushed1} "
                     "(grader-pusher pod or Gitea API unreachable)")
    time.sleep(60)
    pushed2 = {svc: _trigger_grader_push(svc, "probe2") for svc in SERVICES}
    if not all(pushed2.values()):
        return 0.0, f"second grader push failed: {pushed2}"
    time.sleep(90)

    failures = []
    for svc in SERVICES:
        new_head = _get_repo_head_sha(svc)
        if new_head == baseline_heads[svc]:
            failures.append(f"{svc}: HEAD SHA did not advance after grader pushes")
            continue

        rels = _list_releases(token, svc)
        sha_rels = [r for r in rels if isinstance(r, dict)
                    and isinstance(r.get("version"), str)
                    and SHA_RE.match(r["version"])]
        need = baseline_counts[svc] + 2
        if len(sha_rels) < need:
            failures.append(
                f"{svc}: {len(sha_rels)} SHA releases, need >={need} "
                f"(baseline {baseline_counts[svc]} + 2 grader-pushed) — "
                "retention sweeping them, or pipeline not idempotent")
            continue

        # The most recent 3 releases must each be fully lifecycle-complete.
        # Releases come back newest-first from the org-releases endpoint.
        incomplete = []
        for r in sha_rels[:3]:
            v = r.get("version")
            if not isinstance(v, str):
                continue
            detail = _get_release_detail(token, v)
            if not detail:
                incomplete.append(f"{v[:12]}:no-detail")
                continue
            reason = _lifecycle_reason(token, detail, svc, v)
            if reason:
                incomplete.append(f"{v[:12]}:{reason[:40]}")
        if incomplete:
            failures.append(f"{svc}: incomplete recent releases: {incomplete}")

    if failures:
        return 0.0, "Durability failed: " + " | ".join(failures[:3])
    return 1.0, ("All 3 services produced >=baseline+2 lifecycle-complete "
                 "releases across 2 grader-triggered push cycles (150s window)")


# ─────────────────────────────────────────────────────────────────────────────
# Entry point
# ─────────────────────────────────────────────────────────────────────────────

CHECKS = {
    "s1_schema_correctness_fleet_wide":     check_s1_schema_correctness_fleet_wide,
    "s2_lifecycle_completeness_fleet_wide": check_s2_lifecycle_completeness_fleet_wide,
    "s3_durability_under_rotation":         check_s3_durability_under_rotation,
}


def _wait_for_glitchtip_api_ready(timeout_s=90):
    """Poll the GlitchTip API (through P2) until it responds, so the grader
    doesn't race against proxy/upstream cold-start."""
    deadline = time.time() + timeout_s
    while time.time() < deadline:
        status, _ = http("GET", "/api/0/")
        if status in (200, 401, 403):
            return
        time.sleep(3)


def grade(transcript):
    _wait_for_glitchtip_api_ready()

    subscores = {}
    feedback_lines = []
    for name, fn in CHECKS.items():
        try:
            score, msg = fn()
        except Exception as e:  # noqa: BLE001
            score, msg = 0.0, f"{name} raised: {e}"
        score = 1.0 if float(score) >= 1.0 else 0.0
        subscores[name] = score
        marker = "✅" if score >= 1.0 else "❌"
        feedback_lines.append(f"{marker} {name}: {msg}")

    n = len(subscores)
    weights = {k: 1.0 / n for k in subscores}
    total = sum(subscores[k] * weights[k] for k in subscores)
    feedback = "\n".join(feedback_lines)
    return GradingResult(
        score=round(total, 4),
        subscores=subscores,
        weights=weights,
        feedback=feedback,
    )
