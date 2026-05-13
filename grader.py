"""grader.py — GlitchTip Release Pipeline Integration (v21)

4 functional binary subscores, equal 0.25 weight each, summing to 1.0. Every
subscore returns strictly 0.0 or 1.0 (no partial credit, no fractional
aggregation). Each subscore tests ONE distinct functional outcome via live
HTTP/API calls against GlitchTip and Gitea.

  s1_workflow_succeeds_fleet_wide      All 3 services must have a successful
                                       Gitea Actions workflow run whose
                                       head_sha matches the repo's current
                                       HEAD on main. Proves the pipeline
                                       actually ran to completion against
                                       the latest commit on each service.

  s2_sha_releases_match_head           All 3 services must have a GlitchTip
                                       release whose `version` is the bare
                                       40-char hex HEAD SHA of that service
                                       repo. Proves the release-announce
                                       step ran from inside the pipeline
                                       and used the correct version format.

  s3_release_slug_binding_correct      For each of the 3 services, the most
                                       recent SHA-versioned release's
                                       `projects[]` array must contain the
                                       lowercase service slug. Defeats the
                                       slug-trap (PascalCase vs lowercase)
                                       fleet-wide.

  s4_multi_commit_cycle                Each of the 3 services must have at
                                       least 2 distinct SHA-versioned
                                       releases. Proves the pipeline
                                       survives a second push cycle (which
                                       exercises the rotator pressure path
                                       for org-level secrets).

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
import urllib.request

from apex_arena._types import GradingResult


KUBECONFIG = "/etc/rancher/k3s/k3s.yaml"
GT_URL = "http://glitchtip.devops.local"
GITEA_URL = "http://gitea.devops.local:3000"
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
    """Read the grader's pre-staged GlitchTip token from grader-state ns."""
    r = kube("get", "secret", "-n", "grader-state",
             "glitchtip-grader-token", "-o",
             "jsonpath={.data.token}")
    if r.returncode != 0 or not r.stdout.strip():
        return None
    try:
        return base64.b64decode(r.stdout.strip()).decode().strip()
    except Exception:
        return None


def _list_releases(token, slug):
    """Releases in GlitchTip are ORG-scoped. Pull the org release list and
    filter client-side by the `projects` field for the requested slug."""
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


def _list_workflow_runs(svc):
    """Return Gitea Actions workflow runs for a service repo."""
    status, body = gitea_api(
        "GET",
        f"/api/v1/repos/{GT_ORG_SLUG}/{svc}/actions/runs?limit=50",
    )
    if status == 200:
        if isinstance(body, dict):
            return body.get("workflow_runs") or body.get("runs") or []
        if isinstance(body, list):
            return body
    return []


def _get_repo_head_sha(svc):
    """Return the current HEAD commit SHA of the service repo's main branch."""
    status, body = gitea_api(
        "GET", f"/api/v1/repos/{GT_ORG_SLUG}/{svc}/commits?limit=1",
    )
    if status != 200 or not isinstance(body, list) or not body:
        return None
    sha = body[0].get("sha") if isinstance(body[0], dict) else None
    return sha if isinstance(sha, str) and SHA_RE.match(sha) else None


def _run_is_successful(run):
    if not isinstance(run, dict):
        return False
    status = (run.get("status") or "").lower()
    conclusion = (run.get("conclusion") or "").lower()
    if status in ("success", "succeeded", "completed_success"):
        return True
    if conclusion in ("success", "succeeded"):
        return True
    return False


def _run_head_sha(run):
    if not isinstance(run, dict):
        return None
    for key in ("head_sha", "head_commit_sha", "head_commit", "sha"):
        v = run.get(key)
        if isinstance(v, str) and SHA_RE.match(v):
            return v
        if isinstance(v, dict):
            inner = v.get("sha") or v.get("id")
            if isinstance(inner, str) and SHA_RE.match(inner):
                return inner
    return None


# ─────────────────────────────────────────────────────────────────────────────
# Subscore 1: workflow succeeds fleet-wide
# ─────────────────────────────────────────────────────────────────────────────

def check_s1_workflow_succeeds_fleet_wide():
    """Functional outcome: each of the 3 service repos has a Gitea Actions
    workflow run that BOTH (a) succeeded AND (b) has head_sha matching the
    repo's current HEAD SHA on main. Catches:
      - Pipelines that never ran (no run records)
      - Pipelines that ran but failed (wrong runner label, broken step, bad token)
      - Manual-curl fallback (bypasses Gitea Actions; no run record at all)
    """
    deadline = time.time() + 30
    successes, failures = [], []
    while time.time() < deadline:
        successes, failures = [], []
        for svc in SERVICES:
            head_sha = _get_repo_head_sha(svc)
            if not head_sha:
                failures.append(f"{svc}: cannot read repo HEAD SHA")
                continue
            runs = _list_workflow_runs(svc)
            if not runs:
                failures.append(f"{svc}: no run records (pipeline never invoked)")
                continue
            success_for_head = [
                r for r in runs
                if _run_is_successful(r)
                and (_run_head_sha(r) or "") == head_sha
            ]
            if success_for_head:
                successes.append(svc)
            else:
                any_success = sum(1 for r in runs if _run_is_successful(r))
                failures.append(
                    f"{svc}: {len(runs)} run(s), {any_success} successful, "
                    f"none match HEAD SHA {head_sha[:12]}"
                )
        if len(successes) == len(SERVICES):
            break
        time.sleep(5)
    if len(successes) == len(SERVICES):
        return 1.0, (f"All 3 services have a successful workflow run on "
                     f"HEAD SHA: {successes}")
    return 0.0, (f"Only {len(successes)}/3 services have a successful workflow "
                 f"run matching their repo HEAD SHA (need all 3). "
                 + " | ".join(failures[:3]))


# ─────────────────────────────────────────────────────────────────────────────
# Subscore 2: SHA-versioned releases match repo HEAD fleet-wide
# ─────────────────────────────────────────────────────────────────────────────

def check_s2_sha_releases_match_head():
    """Functional outcome: each of the 3 services has a GlitchTip release
    whose `version` is the bare 40-char hex HEAD SHA. Catches:
      - Releases POSTed with composite version like '${PROJECT}@${SHA}'
        (version regex fails)
      - Releases POSTed with a stale or wrong SHA (HEAD-match fails)
      - Releases that never reach GlitchTip at all (no match)
    """
    token = grader_token()
    if not token:
        return 0.0, "s2: grader token missing — setup defect, not agent fault."

    deadline = time.time() + 30
    successes, failures = [], []
    while time.time() < deadline:
        successes, failures = [], []
        for svc in SERVICES:
            head_sha = _get_repo_head_sha(svc)
            if not head_sha:
                failures.append(f"{svc}: cannot read repo HEAD SHA")
                continue
            rels = _list_releases(token, svc)
            rel_versions = {r.get("version") for r in rels if isinstance(r, dict)}
            if head_sha in rel_versions:
                successes.append(svc)
            else:
                sample = [str(v)[:20] for v in list(rel_versions)[:3]]
                failures.append(
                    f"{svc}: HEAD SHA {head_sha[:12]} not in releases "
                    f"(have: {sample})"
                )
        if len(successes) == len(SERVICES):
            break
        time.sleep(5)

    if len(successes) == len(SERVICES):
        return 1.0, (f"All 3 services have a release matching their repo "
                     f"HEAD SHA: {successes}")
    return 0.0, (f"Only {len(successes)}/3 services have a release whose "
                 "version equals their HEAD SHA — version must be the bare "
                 "40-char hex SHA. "
                 + " | ".join(failures[:3]))


# ─────────────────────────────────────────────────────────────────────────────
# Subscore 3: release projects[] binds to correct lowercase slug fleet-wide
# ─────────────────────────────────────────────────────────────────────────────

def check_s3_release_slug_binding_correct():
    """Functional outcome: for each of the 3 services, the most recent
    SHA-versioned release's detail-endpoint `projects[]` array contains
    the lowercase service slug. Catches the slug-trap: agents who used
    PascalCase ("bleater-Auth-Service") or otherwise mis-cased slugs in
    the release POST get releases that don't bind to the correct project.
    """
    token = grader_token()
    if not token:
        return 0.0, "s3: grader token missing — setup defect."

    bad = []
    for svc in SERVICES:
        rels = _list_releases(token, svc)
        sha_releases = [r for r in rels if isinstance(r, dict)
                        and SHA_RE.match(str(r.get("version", "")))]
        if not sha_releases:
            bad.append(f"{svc}: no SHA-versioned release visible")
            continue
        version = sha_releases[0]["version"]
        status, body = http(
            "GET",
            f"/api/0/organizations/{GT_ORG_SLUG}/releases/{version}/",
            token=token,
        )
        if status != 200 or not isinstance(body, dict):
            bad.append(f"{svc}: release detail GET status={status}")
            continue
        projs = body.get("projects") or []
        slugs = []
        for p in projs:
            if isinstance(p, dict):
                s = p.get("slug")
                if s:
                    slugs.append(s)
            elif isinstance(p, str):
                slugs.append(p)
        if svc not in slugs:
            bad.append(f"{svc}: projects[]={slugs} missing '{svc}'")

    if bad:
        return 0.0, ("Slug-binding failed: " + " | ".join(bad))
    return 1.0, ("Each service's most recent SHA-versioned release binds to "
                 "the correct lowercase project slug (slug-trap defeated "
                 "fleet-wide).")


# ─────────────────────────────────────────────────────────────────────────────
# Subscore 4: multi-commit cycle — ≥2 distinct SHA releases per service
# ─────────────────────────────────────────────────────────────────────────────

def check_s4_multi_commit_cycle():
    """Functional outcome: each of the 3 services has at least 2 distinct
    SHA-versioned releases. Proves the pipeline keeps working across
    multiple commits — surviving the gitea-actions-secret-rotation
    CronJob's org-level wipe pressure if the agent used org-level secrets.
    Catches agents who validate once and stop.
    """
    token = grader_token()
    if not token:
        return 0.0, "s4: grader token missing — setup defect."

    counts = {}
    for svc in SERVICES:
        rels = _list_releases(token, svc)
        sha_versions = {
            r["version"] for r in rels
            if isinstance(r, dict)
            and isinstance(r.get("version"), str)
            and SHA_RE.match(r["version"])
        }
        counts[svc] = len(sha_versions)

    short = [s for s, n in counts.items() if n < 2]
    if short:
        return 0.0, (f"Multi-commit cycle failed for: {short} "
                     f"(need ≥ 2 distinct SHA-versioned releases per service; "
                     f"counts: {counts})")
    return 1.0, (f"All 3 services have ≥ 2 distinct SHA-versioned releases "
                 f"(counts: {counts}).")


# ─────────────────────────────────────────────────────────────────────────────
# Entry point
# ─────────────────────────────────────────────────────────────────────────────

CHECKS = {
    "s1_workflow_succeeds_fleet_wide":  check_s1_workflow_succeeds_fleet_wide,
    "s2_sha_releases_match_head":       check_s2_sha_releases_match_head,
    "s3_release_slug_binding_correct":  check_s3_release_slug_binding_correct,
    "s4_multi_commit_cycle":            check_s4_multi_commit_cycle,
}


def _wait_for_glitchtip_api_ready(timeout_s=60):
    """Poll GlitchTip /api/0/ until it responds, so the grader doesn't race
    against in-flight Celery propagation right after a pipeline-driven
    release POST."""
    deadline = time.time() + timeout_s
    while time.time() < deadline:
        status, _ = http("GET", "/api/0/")
        if status in (200, 401, 403):
            return
        time.sleep(2)


def grade(transcript):
    _wait_for_glitchtip_api_ready()

    subscores = {}
    feedback_lines = []
    for name, fn in CHECKS.items():
        try:
            score, msg = fn()
        except Exception as e:  # noqa: BLE001
            score, msg = 0.0, f"{name} raised: {e}"
        # Strict binary: any non-1.0 score is treated as 0.0
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
