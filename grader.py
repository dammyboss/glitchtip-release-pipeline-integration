"""grader.py — GlitchTip Release Pipeline Integration (v29.1)

3 functional binary subscores, equal 1/3 weight each, summing to 1.0. Each
subscore returns strictly 0.0 or 1.0 (no partial credit, no fractional
aggregation). The subscores test three ORTHOGONAL dimensions on the
release-API surface GlitchTip v5.1.1 actually implements (commits[] and
deploys[] subendpoints are stripped from this build — see PROBE NOTES
in the README).

  s1_schema_correctness_fleet_wide
        For each of the 3 services: a GlitchTip release exists whose
        version equals the repo's HEAD SHA, satisfying all 4 strict
        schema rules (bare 40-char hex; ref == version; projects[]
        contains the lowercase slug; dateCreated populated).

        Note: the `ref == version` check is load-bearing. GlitchTip's
        PUT /releases/{v}/ silently clears `ref` to null when the
        request body lacks an explicit `ref` field. Agents who PUT
        only `{"dateReleased": ...}` lose ref and fail this subscore;
        agents who PUT `{"dateReleased": ..., "ref": <sha>}` preserve
        it.

  s2_finalize_evidence_fleet_wide
        For each service's HEAD-SHA release, dateReleased must be
        strictly later than dateCreated + 30s. This proves a separate
        finalize step happened (GlitchTip's auto-set dateReleased at
        CREATE is within milliseconds of dateCreated). Agents who only
        POST and never PUT will have dateReleased ≈ dateCreated and
        fail this subscore.

  s3_durability_under_rotation
        The grader pushes 2 synthetic commits per service (60s apart),
        waits 150s, then verifies each service produced ≥ baseline+2
        SHA-versioned releases that are also schema-correct AND
        finalized (s1 + s2 criteria, per release). Catches agents
        whose pipeline only ran once at validation, whose pipeline
        isn't idempotent, or who didn't suspend the retention CronJob
        sweeping releases every 3 min.

Every check is functional — live HTTP against the GlitchTip API or live
Gitea API metadata. No regex/substring matching on agent-authored files.
Polling/retry with deadlines for state-propagation atoms.

Runs as root with KUBECONFIG=/etc/rancher/k3s/k3s.yaml.
"""
import base64
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


def http(method, path, token=None, data=None, timeout=15):
    """Authenticated GlitchTip API call.

    The grader's token may carry the platform-issued `gt_` prefix as stored
    in the release-ci-token Secret. GlitchTip itself doesn't enforce that
    prefix — strip it before forming the Bearer header. The grader-side
    grader_token() reader strips the prefix at the source.
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


def gitea_api(method, path, data=None, timeout=15):
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
    """Read the grader-side admin token from grader-state ns.

    setup.sh stages a long-lived org admin token in
    Secret/grader-state/glitchtip-grader-token. The grader needs full read
    access to inspect any release the agent created — admin scope covers
    that, no scope-probe needed.
    """
    r = kube("get", "secret", "-n", "grader-state",
             "glitchtip-grader-token", "-o",
             "jsonpath={.data.token}")
    if r.returncode != 0 or not r.stdout.strip():
        return None
    try:
        tok = base64.b64decode(r.stdout.strip()).decode().strip()
        # Strip platform prefix if present
        return tok[3:] if tok.startswith("gt_") else tok
    except Exception:
        return None


def _list_releases(token, slug):
    """Releases are ORG-scoped — pull the org list and filter client-side."""
    status, body = http(
        "GET",
        f"/api/0/organizations/{GT_ORG_SLUG}/releases/?project={slug}",
        token=token,
    )
    if status != 200 or not isinstance(body, list):
        status, body = http(
            "GET",
            f"/api/0/organizations/{GT_ORG_SLUG}/releases/",
            token=token,
        )
        if status != 200 or not isinstance(body, list):
            return []
    out = []
    for r in body:
        if not isinstance(r, dict):
            continue
        projects = r.get("projects") or []
        proj_slugs = []
        for p in projects:
            if isinstance(p, dict):
                s = p.get("slug")
                if s:
                    proj_slugs.append(s)
            elif isinstance(p, str):
                proj_slugs.append(p)
        if slug in proj_slugs:
            out.append(r)
    return out


def _get_release_detail(token, version):
    status, body = http(
        "GET",
        f"/api/0/organizations/{GT_ORG_SLUG}/releases/{urllib.parse.quote(version, safe='')}/",
        token=token,
    )
    return body if status == 200 and isinstance(body, dict) else None


def _get_repo_head_sha(svc):
    status, body = gitea_api(
        "GET", f"/api/v1/repos/{GT_ORG_SLUG}/{svc}/commits?limit=1",
    )
    if status != 200 or not isinstance(body, list) or not body:
        return None
    sha = body[0].get("sha") if isinstance(body[0], dict) else None
    return sha if isinstance(sha, str) and SHA_RE.match(sha) else None


def _trigger_grader_push(svc, label):
    """Push a synthetic commit to a service repo via the grader-pusher pod.

    Returns True if the push succeeded. The pod must have network access
    to Gitea (gitea.gitea.svc.cluster.local:3000).
    """
    timestamp = int(time.time())
    inline = (
        "import urllib.request, urllib.error, json, base64\n"
        f"auth = base64.b64encode(b'{GITEA_USER}:{GITEA_PASS}').decode()\n"
        "h = {'Authorization': 'Basic ' + auth, 'Content-Type': 'application/json'}\n"
        f"url = '{GITEA_URL}/api/v1/repos/{GT_ORG_SLUG}/{svc}/contents/.grader-probes/{label}-{timestamp}.txt'\n"
        "payload = {\n"
        f"    'message': 'grader-probe push {label} {timestamp}',\n"
        f"    'content': base64.b64encode(b'probe at {timestamp}').decode(),\n"
        "    'branch': 'main',\n"
        "}\n"
        "req = urllib.request.Request(url, data=json.dumps(payload).encode(), "
        "method='POST', headers=h)\n"
        "try:\n"
        "    with urllib.request.urlopen(req, timeout=15) as r:\n"
        "        print('OK', r.status)\n"
        "except urllib.error.HTTPError as e:\n"
        "    print('HTTPError', e.code, e.read().decode()[:200])\n"
    )
    r = subprocess.run(
        ["kubectl", "exec", "-n", "grader-state", "deploy/grader-pusher",
         "--", "python3", "-c", inline],
        capture_output=True, text=True, env=env, timeout=30,
    )
    return r.returncode == 0 and "OK" in r.stdout


# ─────────────────────────────────────────────────────────────────────────────
# Subscore 1: schema correctness fleet-wide
# ─────────────────────────────────────────────────────────────────────────────

def _check_schema_correct(rel: dict, svc: str, head_sha: str) -> str | None:
    """Returns None if the release record satisfies all 4 schema rules for svc,
    or a short failure reason string otherwise."""
    v = rel.get("version", "")
    if not (isinstance(v, str) and SHA_RE.match(v)):
        return "version not 40-char lowercase hex"
    if v != head_sha:
        return f"version {v[:12]} != HEAD {head_sha[:12]}"
    ref = rel.get("ref", "")
    if not isinstance(ref, str) or not SHA_RE.match(ref) or ref != v:
        # ref None or empty means PUT cleared it — the load-bearing skill check.
        ref_disp = (ref[:12] if isinstance(ref, str) and ref else
                    type(ref).__name__)
        return (f"ref={ref_disp} != version "
                "(naive PUT clears ref; PUT body must include `ref` too)")
    proj_slugs: list[str] = []
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


def _check_finalized(rel: dict, threshold_s: int = 30) -> str | None:
    """Returns None if dateReleased > dateCreated + threshold_s (proves a
    separate finalize PUT), or a short failure reason string otherwise."""
    import datetime as _dt
    dr = rel.get("dateReleased")
    dc = rel.get("dateCreated")
    if not isinstance(dr, str) or not isinstance(dc, str):
        return f"missing timestamps (dateReleased={dr!r}, dateCreated={dc!r})"
    try:
        dr_dt = _dt.datetime.fromisoformat(dr.replace("Z", "+00:00"))
        dc_dt = _dt.datetime.fromisoformat(dc.replace("Z", "+00:00"))
    except Exception as e:  # noqa: BLE001
        return f"unparseable timestamp: {e}"
    delta = (dr_dt - dc_dt).total_seconds()
    if delta <= threshold_s:
        return (f"dateReleased - dateCreated = {delta:.1f}s, need > "
                f"{threshold_s}s (run an explicit PUT to finalize)")
    return None


def check_s1_schema_correctness_fleet_wide():
    token = grader_token()
    if not token:
        return 0.0, "s1: grader token missing — setup defect, not agent fault."

    # Poll for up to 45s — releases may still be propagating after a
    # just-finished pipeline run.
    deadline = time.time() + 45
    final_failures: dict[str, str] = {}
    while time.time() < deadline:
        failures: dict[str, str] = {}
        successes: list[str] = []
        for svc in SERVICES:
            head_sha = _get_repo_head_sha(svc)
            if not head_sha:
                failures[svc] = "cannot read HEAD SHA"
                continue
            # Use detail endpoint (not list) — detail reflects the
            # latest PUT state including any ref-clearing.
            rel = _get_release_detail(token, head_sha)
            if not rel:
                failures[svc] = f"no release at /releases/{head_sha[:12]}/"
                continue
            reason = _check_schema_correct(rel, svc, head_sha)
            if reason:
                failures[svc] = reason
                continue
            successes.append(svc)

        if len(successes) == len(SERVICES):
            return 1.0, (
                f"All 3 services have schema-correct releases on HEAD SHA: "
                f"{successes}"
            )
        final_failures = failures
        time.sleep(5)

    return 0.0, (
        "Schema correctness failed: "
        + " | ".join(f"{s}: {m}" for s, m in final_failures.items())
    )


# ─────────────────────────────────────────────────────────────────────────────
# Subscore 2: finalize evidence fleet-wide
# ─────────────────────────────────────────────────────────────────────────────

def check_s2_finalize_evidence_fleet_wide():
    token = grader_token()
    if not token:
        return 0.0, "s2: grader token missing — setup defect."

    failures: list[str] = []
    for svc in SERVICES:
        head_sha = _get_repo_head_sha(svc)
        if not head_sha:
            failures.append(f"{svc}: cannot read HEAD SHA")
            continue
        rel = _get_release_detail(token, head_sha)
        if not rel:
            failures.append(
                f"{svc}: release {head_sha[:12]} not found at detail endpoint"
            )
            continue
        reason = _check_finalized(rel)
        if reason:
            failures.append(f"{svc}: {reason}")
            continue

    if failures:
        return 0.0, "Finalize evidence missing: " + " | ".join(failures[:5])
    return 1.0, (
        "All 3 services have finalize evidence: dateReleased > "
        "dateCreated + 30s on the HEAD-SHA release"
    )


# ─────────────────────────────────────────────────────────────────────────────
# Subscore 3: durability under rotation
# ─────────────────────────────────────────────────────────────────────────────

def check_s3_durability_under_rotation():
    token = grader_token()
    if not token:
        return 0.0, "s3: grader token missing — setup defect."

    # Capture baseline state.
    baseline_heads: dict[str, str | None] = {
        svc: _get_repo_head_sha(svc) for svc in SERVICES
    }
    baseline_counts: dict[str, int] = {}
    for svc in SERVICES:
        rels = _list_releases(token, svc)
        sha_rels = [
            r for r in rels
            if isinstance(r, dict)
            and isinstance(r.get("version"), str)
            and SHA_RE.match(r["version"])
        ]
        baseline_counts[svc] = len(sha_rels)
    if not all(baseline_heads.values()):
        return 0.0, (
            f"baseline HEAD capture failed: "
            f"{ {k: (v[:12] if v else None) for k, v in baseline_heads.items()} }"
        )

    # First grader push.
    pushed1 = {svc: _trigger_grader_push(svc, "probe1") for svc in SERVICES}
    if not all(pushed1.values()):
        return 0.0, (
            f"first grader push failed: {pushed1} "
            "(grader-pusher pod or Gitea API unreachable)"
        )
    time.sleep(60)

    # Second grader push.
    pushed2 = {svc: _trigger_grader_push(svc, "probe2") for svc in SERVICES}
    if not all(pushed2.values()):
        return 0.0, f"second grader push failed: {pushed2}"
    time.sleep(90)

    failures: list[str] = []
    for svc in SERVICES:
        new_head = _get_repo_head_sha(svc)
        if new_head == baseline_heads[svc]:
            failures.append(
                f"{svc}: HEAD SHA did not advance after grader pushes "
                f"(stuck at {baseline_heads[svc][:12] if baseline_heads[svc] else 'None'})"
            )
            continue

        rels = _list_releases(token, svc)
        sha_rels = [
            r for r in rels
            if isinstance(r, dict)
            and isinstance(r.get("version"), str)
            and SHA_RE.match(r["version"])
        ]
        need = baseline_counts[svc] + 2
        if len(sha_rels) < need:
            failures.append(
                f"{svc}: {len(sha_rels)} SHA releases, need ≥{need} "
                f"(baseline {baseline_counts[svc]} + 2 grader-pushed); "
                "retention may be deleting them, or workflow didn't run"
            )
            continue

        # Verify the most recent 3 releases are lifecycle-complete on this
        # GlitchTip build: schema-correct (s1 criteria) + finalized (s2
        # criteria). The commits[]/deploys[] subendpoints don't exist on
        # v5.1.1 (probe-verified), so "lifecycle" here is the achievable
        # 2-step Create + Finalize chain with ref preserved through PUT.
        incomplete: list[str] = []
        for r in sha_rels[:3]:
            v = r.get("version")
            if not isinstance(v, str):
                continue
            detail = _get_release_detail(token, v)
            if not detail:
                incomplete.append(f"{v[:12]}:no-detail")
                continue
            # Use the release's own version as the "HEAD" reference for
            # schema check (each grader-pushed commit has its own SHA).
            schema_reason = _check_schema_correct(detail, svc, v)
            if schema_reason:
                incomplete.append(f"{v[:12]}:schema-{schema_reason[:30]}")
                continue
            final_reason = _check_finalized(detail)
            if final_reason:
                incomplete.append(f"{v[:12]}:not-finalized")
                continue
        if incomplete:
            failures.append(f"{svc}: incomplete recent releases: {incomplete}")

    if failures:
        return 0.0, "Durability failed: " + " | ".join(failures[:3])
    return 1.0, (
        "All 3 services produced ≥baseline+2 schema-correct + finalized "
        "releases across 2 grader-triggered push cycles (150s window)"
    )


# ─────────────────────────────────────────────────────────────────────────────
# Entry point
# ─────────────────────────────────────────────────────────────────────────────

CHECKS = {
    "s1_schema_correctness_fleet_wide":   check_s1_schema_correctness_fleet_wide,
    "s2_finalize_evidence_fleet_wide":    check_s2_finalize_evidence_fleet_wide,
    "s3_durability_under_rotation":       check_s3_durability_under_rotation,
}


def _wait_for_glitchtip_api_ready(timeout_s=60):
    deadline = time.time() + timeout_s
    while time.time() < deadline:
        status, _ = http("GET", "/api/0/")
        if status in (200, 401, 403):
            return
        time.sleep(2)


def grade(transcript):
    _wait_for_glitchtip_api_ready()

    subscores: dict[str, float] = {}
    feedback_lines: list[str] = []
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
