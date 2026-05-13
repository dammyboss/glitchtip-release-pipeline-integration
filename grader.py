"""grader.py — GlitchTip Release Pipeline Integration

3 compound binary subscores, equal 1/3 weight each, summing to 1.0. Every
compound is AND-gated across its atom list — all atoms must return 1.0 for
the compound to score 1.0.

  s1_release_metadata_complete         — 3 atoms on per-release metadata:
                                         (a) ≥1 SHA-versioned release per
                                         service, (b) ≥1 release per service
                                         has populated `lastCommit` (proves
                                         release POST included the `ref`
                                         field), (c) ≥1 release per service
                                         has dateCreated INSIDE a successful
                                         Gitea Actions workflow-run window
                                         (proves the release POST happened
                                         from inside a real pipeline, not a
                                         manual fallback curl from a shell).
  s2_pipeline_drives_releases          — 4 atoms on pipeline-driven signals:
                                         (a) auth-service release.version
                                         equals the repo HEAD SHA on main,
                                         (b) ≥2 of 3 services have HEAD-SHA-
                                         matching releases (fleet coverage),
                                         (c) Actions secret is reachable to
                                         ≥2 services via Gitea Actions
                                         (org or repo level), (d) ≥1 service
                                         has a SUCCESSFUL Gitea Actions
                                         workflow run with head_sha matching
                                         the repo HEAD — pipeline must run
                                         to completion, not just be
                                         scaffolded.
  s3_release_to_issue_correlation      — 3 atoms on cross-service consistency:
                                         (a) org-level releases list returns
                                         SHA-versioned releases for all 3
                                         services, (b) at least one service
                                         has ≥2 distinct SHA-versioned
                                         releases (multi-commit deployment
                                         exercised), (c) each service's most
                                         recent release binds correctly to
                                         that service's project slug
                                         (slug-trap defeated fleet-wide).

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
from typing import Any

from apex_arena._types import GradingResult


KUBECONFIG = "/etc/rancher/k3s/k3s.yaml"
GT_URL = "http://glitchtip.devops.local"
GITEA_URL = "http://gitea.devops.local:3000"
GITEA_USER = "root"
GITEA_PASS = "Admin@123456"
GT_ORG_SLUG = "bleater"
SERVICES = ["auth-service", "bleat-service", "api-gateway"]

env = {**os.environ, "KUBECONFIG": KUBECONFIG}


def kube(*args: str, timeout: int = 30) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["kubectl", *args],
        capture_output=True, text=True, env=env, timeout=timeout,
    )


def http(method: str, path: str, token: str | None = None,
         data: dict | None = None, timeout: int = 15) -> tuple[int, dict | str]:
    """Return (status, body). Body is parsed JSON if possible, else text."""
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


def gitea_api(method: str, path: str, data: dict | None = None,
              timeout: int = 15) -> tuple[int, dict | str]:
    """Authenticated Gitea API call as root."""
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


# ─────────────────────────────────────────────────────────────────────────────
# Token discovery: grader needs a GlitchTip API token to read project state.
# We pre-mint a grader-only token in setup.sh and store it in a Secret in the
# `grader-state` namespace, so the grader is independent of whatever token the
# agent created.
# ─────────────────────────────────────────────────────────────────────────────

def grader_token() -> str | None:
    """Read the grader's pre-staged GlitchTip token."""
    r = kube("get", "secret", "-n", "grader-state",
             "glitchtip-grader-token", "-o",
             "jsonpath={.data.token}")
    if r.returncode != 0 or not r.stdout.strip():
        return None
    try:
        return base64.b64decode(r.stdout.strip()).decode().strip()
    except Exception:
        return None


# ─────────────────────────────────────────────────────────────────────────────
# Subscore 1: s1_release_metadata_complete
#
# Each of the 3 services must have at least 1 release visible via GlitchTip's
# /api/0/organizations/{org}/releases/ endpoint (filtered to those whose
# `projects` array contains the service slug), and the per-release metadata
# must be complete: SHA-versioned, ref-bound (lastCommit populated), and
# recently-created (within the eval window).
#
# Silent failure: agents who use the wrong project slug case (the wiki suggests
# `bleater-Auth-Service` style; actual slugs are `auth-service`) will see 200 OK
# from the release POST but the release lands on a non-existent or wrong project
# and never appears via the correct slug. Agents who omit the `ref` field in the
# release POST body get 200 OK but lastCommit stays null.
# ─────────────────────────────────────────────────────────────────────────────

SHA_RE = re.compile(r"^[0-9a-f]{40}$")


def _list_releases(token: str, slug: str) -> list[dict]:
    """Releases in GlitchTip are ORG-scoped, not project-scoped. The endpoint
    is /api/0/organizations/{org}/releases/ and each release record has a
    `projects` array listing the project slug(s) it applies to. We pull the
    full org release list (or a filtered subset) and filter client-side by
    the `projects` field for the requested service slug."""
    # Use the project-filter query param for efficiency; fall back to full
    # list if the server ignores it.
    status, body = http(
        "GET",
        f"/api/0/organizations/{GT_ORG_SLUG}/releases/?project={slug}",
        token=token,
    )
    if status != 200 or not isinstance(body, list):
        # Try without the filter
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
        # `projects` is typically a list of dicts with "slug" or just slugs
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


def _check_releases_exist_per_service(token: str) -> tuple[float, str]:
    """v20: returns fractional score (services_with_releases / 3) so partial
    fleet completion gets partial credit instead of all-or-nothing zero."""
    has = []
    missing = []
    for svc in SERVICES:
        rels = _list_releases(token, svc)
        if rels:
            has.append(svc)
        else:
            missing.append(svc)
    score = len(has) / len(SERVICES)
    if missing:
        return score, (
            f"Releases visible for {has}, missing for {missing}. "
            f"({len(has)}/{len(SERVICES)} services have releases)"
        )
    return 1.0, f"All {len(has)} services have at least 1 release record."


def _check_release_has_lastcommit(token: str) -> tuple[float, str]:
    """H3 hardening: each service must have at least one release whose
    detail GET returns a populated `commits` array — not just a top-level
    `ref` SHA or a `lastCommit.id`-only structure. The minimal Sentry-
    tutorial body (`{"version": SHA, "ref": SHA, "projects": [...]}`)
    populates `lastCommit.id` via the `ref` field but NEVER populates
    `commits[]` — that requires the explicit `commits` parameter
    (`{"commits": [{"id": SHA, "repository": "<org/repo>"}]}`) which
    binds the release to its source repository.

    Why this is the on-call dashboard's load-bearing field: lastCommit.id
    alone gives "this release deployed SHA X" but no link back to the
    repository. Without `commits[].repository`, the on-call rotation
    can't open the diff or correlate against incident issues. The task
    prompt was updated to specify "binding the release to its source
    repository", which agents who read carefully will translate to the
    `commits` parameter in the release POST.

    This is a SILENT failure: the release POST returns 201 either way."""
    missing = []
    for svc in SERVICES:
        rels = _list_releases(token, svc)
        if not rels:
            missing.append(f"{svc}: no releases visible to inspect")
            continue
        # Need release detail (not list) to inspect commits
        any_with_commits = False
        for r in rels[:5]:
            if not isinstance(r, dict):
                continue
            version = r.get("version")
            if not isinstance(version, str):
                continue
            status, body = http(
                "GET",
                f"/api/0/organizations/{GT_ORG_SLUG}/releases/{version}/",
                token=token,
            )
            if status != 200 or not isinstance(body, dict):
                continue
            commits = body.get("commits")
            if isinstance(commits, list) and commits:
                # At least one commit entry — confirms agent passed the
                # `commits` parameter (not just `ref`) on release POST
                any_with_commits = True
                break
        if not any_with_commits:
            missing.append(
                f"{svc}: no release has populated commits[] array (release "
                "POST must bind release to its source repository via the "
                "`commits` parameter, not just the `ref` shortcut)"
            )
    if missing:
        return 0.0, " | ".join(missing)
    return 1.0, ("Each service has at least one release with populated "
                 "commits[] array (release-to-repository binding present).")


def _check_release_dateCreated_within_workflow_run_window(
    token: str,
) -> tuple[float, str]:
    """Each service must have at least one release whose `dateCreated`
    timestamp falls within the time window of a SUCCESSFUL Gitea Actions
    workflow run on that same service. The window is
    [run.started_at - 60s, run.completed_at + 300s] — wide enough to
    absorb act_runner clock skew but tight enough that releases POSTed
    minutes after the pipeline ended (typical fallback-curl pattern)
    fall outside it.

    Why this is the manual-curl killer:
      - A manual `curl -X POST .../releases/` from a shell stamps the
        release with the current wall-clock time. There is no successful
        workflow run on the same service whose window contains that
        timestamp → atom fails.
      - An agent who wires the pipeline AND it completes successfully
        gets `release.dateCreated` ≈ workflow `completed_at`, well inside
        the window → atom passes.
      - An agent whose workflow fails (wrong runner label → queued
        forever, broken curl in step → step exits non-zero, expired
        token → 4xx) has no successful run → atom fails for that service.

    Per-service AND-gate: ALL three services must satisfy this. Partial
    completion (1 service working, 2 stalled) fails the atom."""
    import datetime
    missing: list[str] = []
    for svc in SERVICES:
        rels = _list_releases(token, svc)
        if not rels:
            missing.append(f"{svc}: no releases visible")
            continue
        runs = _list_workflow_runs(svc)
        success_runs = [r for r in runs if _run_is_successful(r)]
        if not success_runs:
            missing.append(
                f"{svc}: {len(runs)} run(s) but none successful — pipeline "
                "did not complete (wrong runner label / broken step / "
                "fallback-curl skips pipeline entirely)"
            )
            continue
        # Build list of (start_dt, end_dt) windows from successful runs
        windows: list[tuple[datetime.datetime, datetime.datetime]] = []
        for r in success_runs:
            sa = r.get("started_at") or r.get("run_started_at") or r.get("created_at")
            ca = r.get("completed_at") or r.get("updated_at") or r.get("finished_at")
            if not (isinstance(sa, str) and isinstance(ca, str)):
                continue
            try:
                start_dt = datetime.datetime.fromisoformat(sa.replace("Z", "+00:00"))
                end_dt = datetime.datetime.fromisoformat(ca.replace("Z", "+00:00"))
            except Exception:
                continue
            # v17: reverted T1 (v16 had tightened to [start-15s, end+30s]).
            # The tighter window only added cascade-fail signal — when an
            # agent has no releases at all, this atom fails along with
            # everything else; it doesn't independently vary across
            # capable agents. Restoring [start-60s, end+300s] to give
            # the oracle solution comfortable tolerance for runner
            # cold-start latency.
            windows.append((
                start_dt - datetime.timedelta(seconds=60),
                end_dt + datetime.timedelta(seconds=300),
            ))
        if not windows:
            missing.append(f"{svc}: successful runs lack parseable timestamps")
            continue
        any_in_window = False
        for r in rels[:10]:
            if not isinstance(r, dict):
                continue
            dc = r.get("dateCreated") or r.get("date_created")
            if not isinstance(dc, str):
                continue
            try:
                t = datetime.datetime.fromisoformat(dc.replace("Z", "+00:00"))
            except Exception:
                continue
            for (start_dt, end_dt) in windows:
                if start_dt <= t <= end_dt:
                    any_in_window = True
                    break
            if any_in_window:
                break
        if not any_in_window:
            missing.append(
                f"{svc}: no release dateCreated falls inside any successful "
                "workflow-run window (release was POSTed outside the "
                "pipeline — manual curl or stale fallback)"
            )
    # v20: fractional — count services that pass, return ratio
    passed_count = len(SERVICES) - len(missing)
    score = passed_count / len(SERVICES)
    if missing:
        return score, (f"({passed_count}/{len(SERVICES)} services pass) "
                       + " | ".join(missing))
    return 1.0, (
        "Each service has at least one release whose dateCreated falls "
        "inside a successful Gitea Actions workflow-run window."
    )


def _check_release_has_environment_set(token: str) -> tuple[float, str]:
    """v11 (s1 redistribution): each service must have at least one release
    with a non-empty `environments` array on its detail view. The Sentry
    release POST accepts an `environment` field (string) which GlitchTip
    surfaces in the release detail's `environments` array. Agents who
    include `environment="production"` in their release POST pass; agents
    who use the bare {"version", "ref"} body do not.

    Discoverable from: bleater pod env (SENTRY_ENVIRONMENT=production).
    The Sentry SDK on the bleater services already sets it for events;
    extending it to the release POST is the natural next step."""
    missing = []
    for svc in SERVICES:
        rels = _list_releases(token, svc)
        any_with_env = False
        for r in rels[:5]:
            if not isinstance(r, dict):
                continue
            envs = r.get("environments") or []
            if isinstance(envs, list) and envs:
                any_with_env = True
                break
            # Detail GET for environment field
            version = r.get("version")
            if not isinstance(version, str):
                continue
            status, body = http(
                "GET",
                f"/api/0/organizations/{GT_ORG_SLUG}/releases/{version}/",
                token=token,
            )
            if status == 200 and isinstance(body, dict):
                envs2 = body.get("environments") or []
                if isinstance(envs2, list) and envs2:
                    any_with_env = True
                    break
        if not any_with_env:
            missing.append(svc)
    if missing:
        return 0.0, (f"no release has environments[] populated for: "
                     f"{missing}. Include `environment` in the release POST body.")
    return 1.0, "all services have at least one release with environments[]"


def _check_release_has_dateReleased_set(token: str) -> tuple[float, str]:
    """v12 NEW (s1 redistribution): each service must have at least one
    release with a non-null `dateReleased` field on its detail view.
    GlitchTip's release model stores `dateReleased` separately from
    `dateCreated`; the field is only populated when the agent passes
    `dateReleased` in the release POST body OR finalizes the release
    via PUT after creating it (Sentry's two-step "create then finalize"
    flow). Agents who use the bare {"version", "ref"} body leave it
    null. This atom replaces release_has_lastcommit_populated which
    was deadweight on GlitchTip v5 (commits[] is silently ignored
    without prior repo registration via /api/0/organizations/{org}/
    repos/, which is friction the task doesn't surface).

    Variance source: ~half of agents who read the Sentry CLI tutorial
    pattern include `dateReleased` (or invoke the finalize step); the
    other half use the minimal POST and skip it. Both behaviors are
    'reasonable defaults' so the variance is genuine, not gameable."""
    missing = []
    for svc in SERVICES:
        rels = _list_releases(token, svc)
        any_dr = False
        for r in rels[:5]:
            if not isinstance(r, dict):
                continue
            version = r.get("version")
            if not isinstance(version, str):
                continue
            status, body = http(
                "GET",
                f"/api/0/organizations/{GT_ORG_SLUG}/releases/{version}/",
                token=token,
            )
            if status != 200 or not isinstance(body, dict):
                continue
            dr = body.get("dateReleased")
            if dr and isinstance(dr, str):
                any_dr = True
                break
        if not any_dr:
            missing.append(svc)
    if missing:
        return 0.0, (f"no release has dateReleased set for: {missing}. "
                     "Include `dateReleased` in the release POST body, or "
                     "finalize the release via PUT after creation.")
    return 1.0, "all services have at least one release with dateReleased set"


def _check_release_has_commits_array(token: str) -> tuple[float, str]:
    """v14 RE-ADDED (closes coverage gap): each service must have at least
    one release whose detail endpoint shows a non-empty `commits` array.
    task.yaml literally requires "the release record must list the
    commit(s) it shipped against the source repository, not just a
    single ref string" — v13 had no atom for this after the v12 removal.
    The N6 seed release in setup.sh proves commits[] populates on
    GlitchTip v5 when the POST includes `commits: [{id, repository}]`.
    Agents who copy the seed's full body shape (per the updated wiki
    pointer) pass this; agents who use the bare {version, ref} body fail."""
    missing = []
    for svc in SERVICES:
        rels = _list_releases(token, svc)
        any_commits = False
        for r in rels[:5]:
            if not isinstance(r, dict):
                continue
            version = r.get("version")
            if not isinstance(version, str):
                continue
            status, body = http(
                "GET",
                f"/api/0/organizations/{GT_ORG_SLUG}/releases/{version}/",
                token=token,
            )
            if status != 200 or not isinstance(body, dict):
                continue
            commits = body.get("commits")
            if isinstance(commits, list) and commits:
                any_commits = True
                break
        if not any_commits:
            missing.append(svc)
    if missing:
        return 0.0, (f"no release has commits[] array populated for: "
                     f"{missing}. Include `commits: [{{id, repository}}]` "
                     "in the release POST body to bind release to source repo.")
    return 1.0, "all services have at least one release with commits[] populated"


def _check_release_has_url_field_set(token: str) -> tuple[float, str]:
    """v13 NEW (s1 fail-uniform): each service must have at least one
    release whose detail endpoint shows a non-empty `url` field. Sentry's
    release `url` parameter points to the commit's diff page (typically
    `<scm>/commit/<sha>`). Agents who use bare body skip it; solution
    sets it to the Gitea commit URL."""
    missing = []
    for svc in SERVICES:
        rels = _list_releases(token, svc)
        any_url = False
        for r in rels[:5]:
            if not isinstance(r, dict):
                continue
            version = r.get("version")
            if not isinstance(version, str):
                continue
            status, body = http(
                "GET",
                f"/api/0/organizations/{GT_ORG_SLUG}/releases/{version}/",
                token=token,
            )
            if status == 200 and isinstance(body, dict):
                u = body.get("url")
                if isinstance(u, str) and u.strip():
                    any_url = True
                    break
        if not any_url:
            missing.append(svc)
    # v20: fractional
    passed_count = len(SERVICES) - len(missing)
    score = passed_count / len(SERVICES)
    if missing:
        return score, (f"({passed_count}/{len(SERVICES)} services have url) "
                       f"missing: {missing}")
    return 1.0, "all services have at least one release with url set"


def _check_release_has_dist_field_set(token: str) -> tuple[float, str]:
    """v13 NEW (s1 fail-uniform): each service must have at least one
    release whose detail endpoint shows a non-empty `dist` field. Sentry's
    `dist` (distribution) tag distinguishes builds of the same release.
    Most agents skip it (the tutorial doesn't mention it prominently)."""
    missing = []
    for svc in SERVICES:
        rels = _list_releases(token, svc)
        any_dist = False
        for r in rels[:5]:
            if not isinstance(r, dict):
                continue
            version = r.get("version")
            if not isinstance(version, str):
                continue
            status, body = http(
                "GET",
                f"/api/0/organizations/{GT_ORG_SLUG}/releases/{version}/",
                token=token,
            )
            if status == 200 and isinstance(body, dict):
                d = body.get("dist")
                if d and isinstance(d, str) and d.strip():
                    any_dist = True
                    break
        if not any_dist:
            missing.append(svc)
    if missing:
        return 0.0, (f"no release has dist field set for: {missing}. "
                     "Include `dist` in release POST.")
    return 1.0, "all services have at least one release with dist set"


def _check_release_finalized_after_creation(token: str) -> tuple[float, str]:
    """v13 NEW (s2 fail-uniform): each service must have at least one
    release whose `dateReleased` is strictly later than its `dateCreated`
    by ≥30 seconds. Proves the agent did Sentry's two-step finalize flow:
    POST to create the release, then PUT to update `dateReleased` after
    the deploy actually rolls out. Most agents POST once with
    dateReleased=now, so dateReleased ≈ dateCreated."""
    import datetime as _dt
    missing = []
    for svc in SERVICES:
        rels = _list_releases(token, svc)
        any_finalized = False
        for r in rels[:5]:
            if not isinstance(r, dict):
                continue
            version = r.get("version")
            if not isinstance(version, str):
                continue
            status, body = http(
                "GET",
                f"/api/0/organizations/{GT_ORG_SLUG}/releases/{version}/",
                token=token,
            )
            if status != 200 or not isinstance(body, dict):
                continue
            dc = body.get("dateCreated")
            dr = body.get("dateReleased")
            if not (isinstance(dc, str) and isinstance(dr, str)):
                continue
            try:
                dc_dt = _dt.datetime.fromisoformat(dc.replace("Z", "+00:00"))
                dr_dt = _dt.datetime.fromisoformat(dr.replace("Z", "+00:00"))
                if (dr_dt - dc_dt).total_seconds() >= 30:
                    any_finalized = True
                    break
            except Exception:
                continue
        if not any_finalized:
            missing.append(svc)
    if missing:
        return 0.0, (f"no release has dateReleased > dateCreated + 30s for: "
                     f"{missing}. Use Sentry's two-step create+finalize flow.")
    return 1.0, "all services have at least one release finalized after creation"


def _check_release_has_repos_registered(token: str) -> tuple[float, str]:
    """v13 NEW (s3 fail-uniform): the GlitchTip org must have all 3 Bleater
    service source-code repos registered via POST /api/0/organizations/
    {org}/repos/. Canonical Sentry pre-step before binding releases to
    commits. Agents who skip repo registration miss this atom."""
    status, body = http(
        "GET",
        f"/api/0/organizations/{GT_ORG_SLUG}/repos/",
        token=token,
    )
    if status != 200 or not isinstance(body, list):
        return 0.0, (f"GET /repos/ returned status={status} "
                     f"body_type={type(body).__name__}")
    registered = set()
    for repo in body:
        if not isinstance(repo, dict):
            continue
        name = repo.get("name") or ""
        for svc in SERVICES:
            if svc in name:
                registered.add(svc)
    missing = [s for s in SERVICES if s not in registered]
    if missing:
        return 0.0, (f"missing repo registrations for: {missing} "
                     f"(have: {sorted(registered)}).")
    return 1.0, f"all 3 service repos registered: {sorted(registered)}"


def _check_release_count_per_service_uniform(token: str) -> tuple[float, str]:
    """v13 NEW (s3 fail-uniform): per-service SHA-versioned release counts
    must be uniform within ±2. Agents who debug heavily on one service
    end up with many more releases there than the others. Solution
    pushes commits evenly so counts match."""
    counts: dict[str, int] = {}
    for svc in SERVICES:
        rels = _list_releases(token, svc)
        sha_versions = {
            r["version"] for r in rels
            if isinstance(r, dict)
            and isinstance(r.get("version"), str)
            and SHA_RE.match(r["version"])
        }
        counts[svc] = len(sha_versions)
    if not counts:
        return 0.0, "no per-service counts available"
    spread = max(counts.values()) - min(counts.values())
    if spread > 2:
        return 0.0, (f"per-service SHA release counts not uniform "
                     f"(spread={spread} > 2; counts: {counts}).")
    return 1.0, (f"per-service SHA release counts uniform "
                 f"(spread={spread} ≤ 2; counts: {counts})")


def _check_each_service_secret_named_GLITCHTIP_TOKEN(token: str | None = None) -> tuple[float, str]:
    """v16 N1 (s2 credential discipline): every service repo's actions secrets
    list must include a secret named exactly `GLITCHTIP_TOKEN` (case-sensitive).
    Sentry's CLI and our Bleater services already use the env var
    GLITCHTIP_TOKEN, so this is the conventional name. Agents who use
    SENTRY_TOKEN, GT_TOKEN, RELEASE_TOKEN, or other variants fail this atom.
    Variance: ~30% of agents pick non-conventional names; 70% match the
    convention."""
    missing = []
    for svc in SERVICES:
        status, body = gitea_api(
            "GET",
            f"/api/v1/repos/{GT_ORG_SLUG}/{svc}/actions/secrets"
        )
        if status != 200:
            missing.append(f"{svc}: secrets list HTTP {status}")
            continue
        items = body if isinstance(body, list) else (
            body.get("secrets", []) if isinstance(body, dict) else []
        )
        names = []
        for s in items:
            if isinstance(s, dict):
                n = s.get("name") or s.get("Name") or ""
                if n:
                    names.append(n)
        if "GLITCHTIP_TOKEN" not in names:
            missing.append(f"{svc}: no secret named GLITCHTIP_TOKEN (have: {names})")
    if missing:
        return 0.0, " | ".join(missing)
    return 1.0, ("All 3 service repos have a secret named exactly "
                 "GLITCHTIP_TOKEN (matches Sentry/GlitchTip CLI convention).")


def _check_release_dateCreated_within_60s_of_workflow_started_at(token: str) -> tuple[float, str]:
    """v16 N2 (s2 timing): for each service, at least one release must have
    `dateCreated` within 60 seconds AFTER the workflow run's started_at.
    Tighter than the s1 dateCreated_within_workflow_run_window atom — that
    one allows the release POST to happen anywhere in the run; this one
    requires the release POST to happen in the FIRST minute of the
    pipeline. Forces agents to put the release-announce step at the START
    of the workflow (or as the only step). Variance from agents who run
    long build steps before the release POST."""
    import datetime as _dt
    missing = []
    for svc in SERVICES:
        rels = _list_releases(token, svc)
        if not rels:
            missing.append(f"{svc}: no releases visible")
            continue
        runs = _list_workflow_runs(svc)
        success_runs = [r for r in runs if _run_is_successful(r)]
        if not success_runs:
            missing.append(f"{svc}: no successful workflow runs")
            continue
        starts: list[_dt.datetime] = []
        for r in success_runs:
            sa = r.get("started_at") or r.get("run_started_at") or r.get("created_at")
            if not isinstance(sa, str):
                continue
            try:
                starts.append(_dt.datetime.fromisoformat(sa.replace("Z", "+00:00")))
            except Exception:
                continue
        if not starts:
            missing.append(f"{svc}: no parseable run start timestamps")
            continue
        any_in_first_minute = False
        for r in rels[:10]:
            if not isinstance(r, dict):
                continue
            dc = r.get("dateCreated") or r.get("date_created")
            if not isinstance(dc, str):
                continue
            try:
                dc_dt = _dt.datetime.fromisoformat(dc.replace("Z", "+00:00"))
            except Exception:
                continue
            for sa_dt in starts:
                delta = (dc_dt - sa_dt).total_seconds()
                if -5 <= delta <= 60:
                    any_in_first_minute = True
                    break
            if any_in_first_minute:
                break
        if not any_in_first_minute:
            missing.append(f"{svc}: no release dateCreated within 60s of any "
                           "successful workflow start")
    if missing:
        return 0.0, " | ".join(missing)
    return 1.0, ("All 3 services have a release dateCreated within 60s of "
                 "workflow start — release POST is at top of pipeline, not "
                 "after long build steps.")


def _check_release_correlates_to_event_for_all_three_services(token: str) -> tuple[float, str]:
    """v16 N3 (s3 multi-service correlation): extends the existing single-
    service `release_correlates_to_event` atom (which tests auth-service
    only) to require ALL 3 services have firstEvent populated after the
    grader posts a synthetic event against each service's DSN. Forces
    agents to wire ALL 3 release-DSN chains correctly, not just one. Most
    agents who handle the slug+projects[] correctly for one service do
    so for all three, but agents with mixed-correctness fail this atom."""
    import datetime as _dt
    successes: list[str] = []
    failures: list[str] = []
    for svc in SERVICES:
        rels = _list_releases(token, svc)
        sha_releases = [r for r in rels if isinstance(r, dict)
                        and SHA_RE.match(str(r.get("version", "")))]
        if not sha_releases:
            failures.append(f"{svc}: no SHA-versioned release")
            continue
        target_version = sha_releases[0]["version"]

        # Read service DSN from bleater pod env
        pod_proc = subprocess.run(
            ["kubectl", "get", "deploy", svc, "-n", "bleater",
             "-o", "jsonpath={.spec.template.spec.containers[0].env}"],
            capture_output=True, text=True, env=env, timeout=15,
        )
        if pod_proc.returncode != 0:
            failures.append(f"{svc}: could not read deploy env")
            continue
        env_blob = pod_proc.stdout or ""
        dsn_match = re.search(r'http://([a-f0-9]+)@[^/]+/(\d+)', env_blob)
        if not dsn_match:
            failures.append(f"{svc}: DSN not found in deploy env")
            continue
        public_key = dsn_match.group(1)
        project_id = dsn_match.group(2)

        # POST a synthetic event for this service
        event_id = "".join("0123456789abcdef"[(i * 11 + 5 + hash(svc)) % 16] for i in range(32))
        sentry_event = {
            "event_id": event_id,
            "timestamp": _dt.datetime.now(_dt.timezone.utc).isoformat(),
            "platform": "python",
            "level": "error",
            "release": target_version,
            "environment": "production",
            "exception": {
                "values": [{
                    "type": "GraderProbeErrorMulti",
                    "value": f"synthetic event for {svc} multi-service correlation",
                }]
            },
        }
        sentry_auth = (
            f"Sentry sentry_version=7, sentry_key={public_key}, "
            "sentry_client=grader-probe-multi/1.0"
        )
        store_url = f"{GT_URL}/api/{project_id}/store/"
        body_bytes = json.dumps(sentry_event).encode()
        req = urllib.request.Request(store_url, data=body_bytes, method="POST")
        req.add_header("Content-Type", "application/json")
        req.add_header("X-Sentry-Auth", sentry_auth)
        try:
            with urllib.request.urlopen(req, timeout=15) as resp:
                post_status = resp.status
        except urllib.error.HTTPError as e:
            post_status = e.code
        except Exception as e:  # noqa: BLE001
            failures.append(f"{svc}: event POST transport error: {e}")
            continue
        if post_status not in (200, 201, 202):
            failures.append(f"{svc}: event POST HTTP {post_status}")
            continue
        successes.append(svc)

    # Wait briefly for Celery propagation, then check firstEvent for each
    if not successes:
        return 0.0, ("no service had a successful synthetic event POST: "
                     + " | ".join(failures))
    time.sleep(15)
    correlated: list[str] = []
    for svc in successes:
        rels = _list_releases(token, svc)
        sha_releases = [r for r in rels if isinstance(r, dict)
                        and SHA_RE.match(str(r.get("version", "")))]
        if not sha_releases:
            continue
        target_version = sha_releases[0]["version"]
        deadline = time.time() + 60
        while time.time() < deadline:
            status, body = http(
                "GET",
                f"/api/0/organizations/{GT_ORG_SLUG}/releases/{target_version}/",
                token=token,
            )
            if status == 200 and isinstance(body, dict):
                if body.get("firstEvent") or body.get("lastEvent"):
                    correlated.append(svc)
                    break
            time.sleep(5)
    if len(correlated) >= len(SERVICES):
        return 1.0, (f"all 3 services correlate releases to events "
                     f"(firstEvent populated for: {correlated})")
    return 0.0, (f"only {len(correlated)}/3 services have release-event "
                 f"correlation (correlated: {correlated}, failures: "
                 + " | ".join(failures[:3]) + ")")


def _aggregate_atoms_fractional(
    compound_name: str,
    atoms: list[tuple[str, Any]],
) -> tuple[float, str]:
    """v20 fractional aggregation v2: compound score = mean(atom scores).
    v11 only counted atoms returning >=1.0 as passes; v20 sums fractional
    atom scores so partial-credit atoms (e.g., 1/3 of services succeeded)
    contribute proportionally rather than being zeroed out. Atoms can now
    return any float in [0, 1]."""
    total_score = 0.0
    msgs: list[str] = []
    for name, fn in atoms:
        try:
            score, msg = fn()
        except Exception as e:  # noqa: BLE001
            score, msg = 0.0, f"{name} raised: {e}"
        score = max(0.0, min(1.0, float(score)))
        total_score += score
        if score >= 1.0:
            tag = "[atom-PASS]"
        elif score > 0:
            tag = f"[atom-PARTIAL {score:.2f}]"
        else:
            tag = "[atom-FAIL]"
        msgs.append(f"{tag} {name}: {msg[:160]}")
    fraction = total_score / len(atoms) if atoms else 0.0
    return fraction, (f"{compound_name}: total={total_score:.2f}/{len(atoms)} "
                      f"(fractional={fraction:.3f}) | " + " | ".join(msgs))


def check_s1_release_metadata_complete() -> tuple[float, str]:
    token = grader_token()
    if not token:
        return 0.0, ("s1: grader token missing — setup.sh did not stage "
                     "Secret/grader-state/glitchtip-grader-token. This is a "
                     "setup defect, not an agent failure.")
    # v11 redistribution: 4 atoms, fractional. commits[] and dateCreated stay
    # hard for variance; environment_set is medium (Sentry tutorial includes);
    # releases_exist is easy (always passes for any agent who got pipelines
    # running at all).
    # v19: 3 atoms after second rubric cleanup. Dropped:
    #   - release_has_commits_array (undisclosed; the seed-release breadcrumb
    #     was too subtle — no agent across v14-v18 ever included the
    #     `commits` parameter. task.yaml language about "list the commits"
    #     also removed in v19, so no coverage gap.)
    #   - release_has_dateReleased_set (deadweight at 1 — Django auto-stamps
    #     this field, so it always passes for anyone who creates a release.
    #     Reviewer flagged as undisclosed; we drop because it adds no signal.)
    #   - release_has_environment_set (undisclosed Sentry feature; reviewer
    #     flagged 0/5 attempted — no agent ever included `environment` in
    #     the POST body without explicit prompt language).
    # Kept release_has_url_field_set: defensible because task.yaml says
    # "click from a release to the actual diff in Gitea" — a `url` field
    # pointing at the commit diff is the natural implementation.
    atoms = [
        ("releases_exist_per_service",
         lambda: _check_releases_exist_per_service(token)),
        ("release_dateCreated_within_workflow_run_window",
         lambda: _check_release_dateCreated_within_workflow_run_window(token)),
        ("release_has_url_field_set",
         lambda: _check_release_has_url_field_set(token)),
    ]
    return _aggregate_atoms_fractional("s1_release_metadata_complete", atoms)


# ─────────────────────────────────────────────────────────────────────────────
# Subscore 2: s2_pipeline_drives_releases
#
# Functional outcome: pipeline runs in Gitea Actions actually produced the
# GlitchTip releases. We verify by SHA cross-reference: for each service, take
# the head_sha of its successful workflow runs, and confirm a release with
# that SHA exists in the corresponding GlitchTip project.
#
# This rewards agents who wired the integration end-to-end through the
# pipeline. An agent who just curl-POSTs releases manually (without wiring
# the pipeline) cannot match a Gitea-run head_sha to a release version unless
# they happen to use that exact SHA — which would still require them to
# either trigger the workflow or hand-craft a curl with the run's commit SHA.
# Either way, the pipeline must be in the loop.
#
# The third atom verifies the GLITCHTIP_TOKEN is held in Gitea Actions
# secrets at a scope that all three services can reach (org-level preferred,
# falling back to repo-level for ≥2 of 3 services).
#
# Silent failure: agents who put the secret only on auth-service repo see
# their other two pipelines fail to authenticate. Some agents will notice
# the run failure logs; many will not (the failure shows as HTTP 401 on the
# release POST step, which Gitea Actions surfaces in run logs but the agent
# may not check). The org-vs-repo scope is the trap.
# ─────────────────────────────────────────────────────────────────────────────


def _list_workflow_runs(svc: str) -> list[dict]:
    """Return Gitea Actions workflow runs for a service repo. Tries both
    paginated and unpaginated forms since the Gitea API surface varies."""
    status, body = gitea_api(
        "GET",
        f"/api/v1/repos/{GT_ORG_SLUG}/{svc}/actions/runs?limit=50"
    )
    if status == 200:
        if isinstance(body, dict):
            return body.get("workflow_runs") or body.get("runs") or []
        if isinstance(body, list):
            return body
    return []


def _get_repo_head_sha(svc: str) -> str | None:
    """Return the current HEAD commit SHA of the service repo's main branch."""
    status, body = gitea_api(
        "GET", f"/api/v1/repos/{GT_ORG_SLUG}/{svc}/commits?limit=1"
    )
    if status != 200 or not isinstance(body, list) or not body:
        return None
    sha = body[0].get("sha") if isinstance(body[0], dict) else None
    return sha if isinstance(sha, str) and SHA_RE.match(sha) else None


def _check_release_matches_repo_head_sha(token: str, svc: str) -> tuple[float, str]:
    """Cross-reference: at least one GlitchTip release for `svc` has a version
    that exactly matches the service repo's current HEAD commit SHA on main.

    Why this is pipeline-evidence: the agent has to either trigger the pipeline
    (which auto-uses GITHUB_SHA = the latest commit SHA) or hand-construct a
    release POST using the discovered HEAD SHA. Both paths require:
      - reading the repo's HEAD SHA via Gitea API (or letting Actions populate
        GITHUB_SHA inside the workflow run), and
      - using the SAME slug as the GlitchTip project (slug-trap discriminator).
    A naive curl-POST without those two steps would miss either the SHA match
    or the slug match, scoring 0 on this atom.
    """
    head_sha = _get_repo_head_sha(svc)
    if not head_sha:
        return 0.0, f"{svc}: could not read HEAD commit SHA from Gitea"
    rels = _list_releases(token, svc)
    rel_versions = {r.get("version") for r in rels if isinstance(r, dict)}
    if head_sha in rel_versions:
        return 1.0, (
            f"{svc}: release version {head_sha[:12]} matches Gitea HEAD SHA "
            "(pipeline-shape integration confirmed)."
        )
    sample = list(rel_versions)[:3]
    return 0.0, (
        f"{svc}: HEAD SHA {head_sha[:12]} does not match any release "
        f"version in GlitchTip (have: {sample}). The release announce was "
        "not driven by the latest commit SHA."
    )


def _check_actions_secret_reachable_by_two_services() -> tuple[float, str]:
    """Functional check via Gitea API: at least one Actions secret is reachable
    to ≥2 of the 3 service repos (any name; the pipeline-produced-release
    atoms above prove which secret is the active credential — this atom only
    asserts that the credential lives in Actions secrets and not elsewhere).
    Org-level coverage counts as covering all 3 services.

    NOTE: Gitea API for secrets returns metadata only (names + timestamps);
    values are never returned by the server. We do not match on value or
    name patterns — any secret name passes."""
    org_secret_count = 0
    status, body = gitea_api(
        "GET",
        f"/api/v1/orgs/{GT_ORG_SLUG}/actions/secrets"
    )
    if status == 200 and isinstance(body, (list, dict)):
        items = body if isinstance(body, list) else body.get("secrets", []) or []
        org_secret_count = sum(1 for s in items if isinstance(s, dict))

    repos_with_secret: list[str] = []
    if org_secret_count == 0:
        for svc in SERVICES:
            status, body = gitea_api(
                "GET",
                f"/api/v1/repos/{GT_ORG_SLUG}/{svc}/actions/secrets"
            )
            if status != 200:
                continue
            items = body if isinstance(body, list) else (
                body.get("secrets", []) if isinstance(body, dict) else []
            )
            if any(isinstance(s, dict) for s in items):
                repos_with_secret.append(svc)

    if org_secret_count >= 1:
        return 1.0, (
            f"Org-level Gitea Actions secret(s) configured "
            f"(count={org_secret_count}); reachable to all 3 services."
        )
    if len(repos_with_secret) >= 2:
        return 1.0, (
            f"Repo-level Gitea Actions secrets configured on "
            f"{len(repos_with_secret)}/3 services: {repos_with_secret}."
        )
    return 0.0, (
        f"No Actions secrets visible at org level or on ≥2 service repos "
        f"(org={org_secret_count}, repos_with_any_secret={len(repos_with_secret)}/3). "
        "The CI credential is not stored in Gitea Actions secrets."
    )


def _check_release_matches_head_sha_all_three(token: str) -> tuple[float, str]:
    """v11 (s2 redistribution): TIGHTENED from at_least_two → all three.
    Every one of the 3 services must have a release whose version equals the
    service repo's current HEAD SHA. The integration must be deployed
    fleet-wide, not just to a couple services. Combined with the rotator
    pressure (every 2 min), agents who only get 2 of 3 pipelines through
    the second-commit cycle fail this atom."""
    succeeded = []
    failed = []
    for svc in SERVICES:
        score, msg = _check_release_matches_repo_head_sha(token, svc)
        if score >= 1.0:
            succeeded.append(svc)
        else:
            failed.append((svc, msg))
    # v20: fractional
    score = len(succeeded) / len(SERVICES)
    if len(succeeded) == len(SERVICES):
        return 1.0, (
            f"all {len(succeeded)}/3 services have HEAD-SHA-matching releases: "
            f"{succeeded}"
        )
    return score, (
        f"{len(succeeded)}/3 services match HEAD SHA. "
        + " | ".join(f"{s}: {m[:120]}" for s, m in failed[:3])
    )


def _check_actions_secret_reachable_all_three() -> tuple[float, str]:
    """v11 (s2 redistribution): TIGHTENED from at_least_two → all three.
    Every one of the 3 service repos must have an Actions secret reachable
    (org-level covers all; otherwise repo-level on each). Org-level secrets
    get wiped by the gitea-actions-secret-rotation CronJob every 2 min,
    so agents who only set org-level lose coverage fast — they must use
    repo-level secrets (per-repo) to pass this atom reliably."""
    org_secret_count = 0
    status, body = gitea_api(
        "GET",
        f"/api/v1/orgs/{GT_ORG_SLUG}/actions/secrets"
    )
    if status == 200 and isinstance(body, (list, dict)):
        items = body if isinstance(body, list) else body.get("secrets", []) or []
        org_secret_count = sum(1 for s in items if isinstance(s, dict))

    repos_with_secret: list[str] = []
    for svc in SERVICES:
        status, body = gitea_api(
            "GET",
            f"/api/v1/repos/{GT_ORG_SLUG}/{svc}/actions/secrets"
        )
        if status != 200:
            continue
        items = body if isinstance(body, list) else (
            body.get("secrets", []) if isinstance(body, dict) else []
        )
        if any(isinstance(s, dict) for s in items):
            repos_with_secret.append(svc)

    if org_secret_count >= 1:
        return 1.0, (
            f"Org-level Gitea Actions secret(s) configured "
            f"(count={org_secret_count}); reachable to all 3 services."
        )
    # v20: fractional based on how many services have repo-level secrets
    score = len(repos_with_secret) / len(SERVICES)
    if len(repos_with_secret) == len(SERVICES):
        return 1.0, (
            f"Repo-level Gitea Actions secrets configured on all 3 services: "
            f"{repos_with_secret}."
        )
    return score, (
        f"{len(repos_with_secret)}/{len(SERVICES)} services have repo-level "
        f"Actions secrets (org={org_secret_count}, repos={repos_with_secret})."
    )


def _check_each_service_has_repo_level_secret() -> tuple[float, str]:
    """v11 NEW (s2 hard atom): every service repo must have at least one
    repo-level Actions secret. Agents who set ONLY an org-level secret
    fail this atom — and the rotator CronJob deletes org-level secrets
    every 2 min, so org-level alone is also fragile for the head-sha
    timing atom. The intended path: read the rotator's source via
    `kubectl get cronjob -n gitea -o yaml`, see it only deletes org-level,
    and use repo-level secrets (the documented escape) on each service.

    Variance source: agents who instinctively reach for org-level (the
    Gitea/GitHub Actions default convention for cross-repo secrets) skip
    repo-level entirely and fail this atom."""
    missing = []
    for svc in SERVICES:
        status, body = gitea_api(
            "GET",
            f"/api/v1/repos/{GT_ORG_SLUG}/{svc}/actions/secrets"
        )
        if status != 200:
            missing.append(f"{svc}: secrets list HTTP {status}")
            continue
        items = body if isinstance(body, list) else (
            body.get("secrets", []) if isinstance(body, dict) else []
        )
        if not any(isinstance(s, dict) for s in items):
            missing.append(f"{svc}: no repo-level Actions secrets")
    # v20: fractional
    passed_count = len(SERVICES) - len(missing)
    score = passed_count / len(SERVICES)
    if missing:
        return score, (f"({passed_count}/{len(SERVICES)} services have "
                       f"repo-level secrets) " + " | ".join(missing))
    return 1.0, ("All 3 service repos have at least one repo-level Actions "
                 "secret (rotator-resilient).")


def _run_is_successful(run: dict) -> bool:
    """A Gitea Actions workflow run counts as successful only if BOTH
    status and conclusion (where present) indicate completion+success.
    Different Gitea versions surface the field slightly differently —
    accept any of the documented success markers."""
    if not isinstance(run, dict):
        return False
    status = (run.get("status") or "").lower()
    conclusion = (run.get("conclusion") or "").lower()
    if status in ("success", "succeeded", "completed_success"):
        return True
    if conclusion in ("success", "succeeded"):
        return True
    return False


def _run_head_sha(run: dict) -> str | None:
    """Extract head_sha from a workflow run, allowing for naming variants."""
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


def _check_workflow_run_succeeded_for_head_sha() -> tuple[float, str]:
    """v12 (s2 redistribution): TIGHTENED from "at least 1 service" → "ALL 3
    services". Every one of the 3 service repos must have a workflow run
    that BOTH (a) succeeded (status/conclusion success) AND (b) has
    head_sha matching the repo's current HEAD SHA on main.

    Why all-3 now: in v11, this atom passed for 3/3 good runs uniformly
    because agents who got 1 service through naturally got the others
    too. By requiring all 3, the rotator pressure (every 2 min wipes
    org-level secrets) plus act_runner first-pull latency (3-5 min on
    cold start) makes it likely 1 of 3 services finishes its 2nd-commit
    pipeline AFTER the rotator has wiped the secret used for the post —
    that pipeline fails authentication, no successful run exists for
    that service's HEAD SHA, atom fails.

    Manual-fallback-curl loophole: an agent that pushes a workflow file
    but the workflow never actually completes (wrong runner label,
    broken token, broken curl in the step) would have run records but
    no SUCCESSFUL run. An agent that bypasses Gitea Actions entirely
    and curls releases from a shell has no run records at all. Only an
    agent that wires a working pipeline on ALL 3 services, triggers
    them, and waits for ALL completions can pass this atom."""
    successes: list[str] = []
    failures: list[str] = []
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
        return 1.0, (
            f"All {len(successes)}/3 services have a successful workflow run "
            f"on HEAD SHA: {successes}."
        )
    return 0.0, (
        f"Only {len(successes)}/3 services have a successful workflow run "
        f"matching their repo HEAD SHA (need all 3). "
        + " | ".join(failures[:3])
    )


def check_s2_pipeline_drives_releases() -> tuple[float, str]:
    token = grader_token()
    if not token:
        return 0.0, "s2: grader token missing — setup defect."
    # v17: 5 atoms after rubric cleanup. Dropped:
    #   - release_finalized_after_creation (undisclosed two-step finalize flow)
    #   - each_service_secret_named_GLITCHTIP_TOKEN (deadweight at 1 — 5/5 pass)
    #   - release_dateCreated_within_60s_of_workflow_started_at
    #     (undisclosed 60s pipeline-step-ordering constraint)
    atoms = [
        ("release_matches_repo_head_sha_auth_service",
         lambda: _check_release_matches_repo_head_sha(token, "auth-service")),
        ("release_matches_head_sha_all_three",
         lambda: _check_release_matches_head_sha_all_three(token)),
        ("actions_secret_reachable_all_three",
         _check_actions_secret_reachable_all_three),
        ("workflow_run_succeeded_for_head_sha",
         _check_workflow_run_succeeded_for_head_sha),
        ("each_service_has_repo_level_secret",
         _check_each_service_has_repo_level_secret),
    ]
    return _aggregate_atoms_fractional("s2_pipeline_drives_releases", atoms)


# ─────────────────────────────────────────────────────────────────────────────
# Subscore 3: s3_release_to_issue_correlation
#
# After at least one release exists for auth-service, the grader posts a
# synthetic error event tagged with that release version directly to GlitchTip
# (using the project's DSN, which the grader reads from Bleater pod env). The
# grader then waits and checks whether the resulting issue's detail view shows
# the release association — which only works if the release was registered
# against the correct project (matching the DSN's project_id).
#
# Silent failure: agents who used a wrong project slug for releases will have
# created releases that don't link to the project the runtime errors land on.
# The release exists somewhere, but issue.firstRelease stays null because the
# project_id chain is broken.
# ─────────────────────────────────────────────────────────────────────────────

def _check_release_exists_for_auth_service(token: str) -> tuple[float, str]:
    rels = _list_releases(token, "auth-service")
    sha_releases = [r for r in rels if isinstance(r, dict)
                    and SHA_RE.match(str(r.get("version", "")))]
    if not sha_releases:
        return 0.0, ("auth-service: no SHA-versioned release present in "
                     "GlitchTip — cannot probe release-issue correlation.")
    return 1.0, f"auth-service has {len(sha_releases)} SHA-versioned release(s)."


def _check_at_least_one_service_has_two_releases(token: str) -> tuple[float, str]:
    """At least one of the three services must have ≥2 distinct
    SHA-versioned releases. This is a multi-commit / multi-deploy fleet
    test: agents who validate the integration with a single push and
    move on fail this atom. Real-world pipelines run on every commit;
    this enforces that the agent's setup actually does the same.

    Variance source: forensic data shows 60%+ of agents test with one
    commit per service and stop. Pushing a second commit is an extra
    step they typically skip after seeing the first release land."""
    # v13 (s3 redistribution): TIGHTENED from "all 3 ≥2" → "≥3 per service".
    # Agents typically stop at 2 commits. Solution pushes 3 evenly.
    counts: dict[str, int] = {}
    for svc in SERVICES:
        rels = _list_releases(token, svc)
        sha_versions = {
            r["version"] for r in rels
            if isinstance(r, dict)
            and isinstance(r.get("version"), str)
            and SHA_RE.match(r["version"])
        }
        counts[svc] = len(sha_versions)
    short = [s for s, n in counts.items() if n < 3]
    # v20: fractional — score = (services with ≥3) / 3
    passed_count = len(SERVICES) - len(short)
    score = passed_count / len(SERVICES)
    if short:
        return score, (
            f"({passed_count}/{len(SERVICES)} services have ≥3 SHA releases) "
            f"short: {short} (counts: {counts})."
        )
    return 1.0, (
        f"All 3 services have ≥3 distinct SHA-versioned releases "
        f"(counts: {counts})."
    )


def _check_release_correlates_to_event(token: str) -> tuple[float, str]:
    """v11 NEW (s3 hard atom): grader-side correlation test. After the agent's
    pipelines run and at least one SHA-versioned release exists for
    auth-service, the grader POSTs a synthetic Sentry-protocol event
    against the auth-service project's DSN, tagged with the most-recent
    release version. After a brief wait for Celery propagation, the
    grader queries the release detail and checks `firstEvent` (or
    `lastEvent`) is non-null AND was populated within the last 90s.

    Why this is hard: requires the release to be correctly bound to the
    project_id chain that the DSN's project resolves to. Agents who
    used the wrong slug, omitted projects[] from the release POST, or
    posted to the wrong organization endpoint will have releases that
    look right via the projects[] field but don't actually wire up to
    runtime events. The firstEvent population is silent — there's no
    feedback at release-creation time that the chain is broken."""
    import datetime as _dt
    rels = _list_releases(token, "auth-service")
    sha_releases = [r for r in rels if isinstance(r, dict)
                    and SHA_RE.match(str(r.get("version", "")))]
    if not sha_releases:
        return 0.0, ("auth-service: no SHA-versioned release present in "
                     "GlitchTip — cannot probe release-event correlation.")
    target_version = sha_releases[0]["version"]

    # Read auth-service DSN from the bleater pod env
    pod_proc = subprocess.run(
        ["kubectl", "get", "deploy", "auth-service", "-n", "bleater",
         "-o", "jsonpath={.spec.template.spec.containers[0].env}"],
        capture_output=True, text=True, env=env, timeout=15,
    )
    if pod_proc.returncode != 0:
        return 0.0, f"could not read auth-service deploy env: {pod_proc.stderr[:200]}"
    env_blob = pod_proc.stdout or ""
    dsn_match = re.search(r'http://([a-f0-9]+)@[^/]+/(\d+)', env_blob)
    if not dsn_match:
        return 0.0, f"auth-service DSN not found in deploy env: {env_blob[:200]}"
    public_key = dsn_match.group(1)
    project_id = dsn_match.group(2)

    # POST a synthetic event against the project's store endpoint
    event_id = "".join("0123456789abcdef"[(i * 7 + 3) % 16] for i in range(32))
    sentry_event = {
        "event_id": event_id,
        "timestamp": _dt.datetime.now(_dt.timezone.utc).isoformat(),
        "platform": "python",
        "level": "error",
        "release": target_version,
        "environment": "production",
        "exception": {
            "values": [{
                "type": "GraderProbeError",
                "value": "synthetic event for release correlation grading",
            }]
        },
    }
    sentry_auth = (
        f"Sentry sentry_version=7, sentry_key={public_key}, "
        "sentry_client=grader-probe/1.0"
    )
    store_url = f"{GT_URL}/api/{project_id}/store/"
    body_bytes = json.dumps(sentry_event).encode()
    req = urllib.request.Request(store_url, data=body_bytes, method="POST")
    req.add_header("Content-Type", "application/json")
    req.add_header("X-Sentry-Auth", sentry_auth)
    try:
        with urllib.request.urlopen(req, timeout=15) as resp:
            post_status = resp.status
    except urllib.error.HTTPError as e:
        post_status = e.code
    except Exception as e:  # noqa: BLE001
        return 0.0, f"event POST transport error: {e}"
    if post_status not in (200, 201, 202):
        return 0.0, (f"synthetic event POST returned HTTP {post_status} "
                     "(check DSN + endpoint)")

    # Poll the release detail for firstEvent / lastEvent populated, up to 90s
    deadline = time.time() + 90
    last_observed = None
    while time.time() < deadline:
        status, body = http(
            "GET",
            f"/api/0/organizations/{GT_ORG_SLUG}/releases/{target_version}/",
            token=token,
        )
        if status == 200 and isinstance(body, dict):
            fe = body.get("firstEvent")
            le = body.get("lastEvent")
            last_observed = (fe, le)
            if fe or le:
                return 1.0, (f"release {target_version[:12]} on auth-service "
                             f"correlates to event (firstEvent={fe}, lastEvent={le})")
        time.sleep(5)
    return 0.0, (f"release {target_version[:12]} firstEvent/lastEvent never "
                 f"populated after 90s (last observed: {last_observed}); "
                 "release-to-event chain is broken (likely wrong projects[] "
                 "in release POST or slug mismatch)")


def _check_each_service_release_binds_to_correct_slug(token: str) -> tuple[float, str]:
    """For EACH of the 3 services, the most recent SHA-versioned release's
    detail endpoint must return `projects[]` containing exactly that slug.
    This is the slug-trap discriminator generalized across all services —
    if an agent used PascalCase slugs from the wiki on any one of the
    three pipelines, that service's releases land on the wrong project
    and this atom fails.

    Stronger than auth-service-only because mixed-correctness (right slug
    for auth, wrong for bleat) still fails."""
    bad = []
    for svc in SERVICES:
        rels = _list_releases(token, svc)
        sha_releases = [r for r in rels if isinstance(r, dict)
                        and SHA_RE.match(str(r.get("version", "")))]
        if not sha_releases:
            bad.append(f"{svc}: no SHA-versioned release")
            continue
        version = sha_releases[0]["version"]
        status, body = http(
            "GET",
            f"/api/0/organizations/{GT_ORG_SLUG}/releases/{version}/",
            token=token,
        )
        if status != 200 or not isinstance(body, dict):
            bad.append(f"{svc}: detail GET status={status}")
            continue
        projs = body.get("projects") or []
        slugs: list[str] = []
        for p in projs:
            if isinstance(p, dict):
                s = p.get("slug")
                if s:
                    slugs.append(s)
            elif isinstance(p, str):
                slugs.append(p)
        if svc not in slugs:
            bad.append(f"{svc}: release projects[]={slugs} missing '{svc}'")
    # v20: fractional
    passed_count = len(SERVICES) - len(bad)
    score = passed_count / len(SERVICES)
    if bad:
        return score, (f"({passed_count}/{len(SERVICES)} services bind to "
                       f"correct slug) " + " | ".join(bad))
    return 1.0, ("Each service's most recent SHA-versioned release binds to "
                 "the correct project slug (slug-trap defeated fleet-wide).")


def _check_org_release_list_covers_all_services(token: str) -> tuple[float, str]:
    """The org-level releases list (single API call returning all releases for
    the org) must include at least one SHA-versioned release for each of the
    three services. This proves cross-service consistency: the agent wired
    the integration into all three pipelines, and the org-level read path
    surfaces them all."""
    status, body = http(
        "GET",
        f"/api/0/organizations/{GT_ORG_SLUG}/releases/?per_page=200",
        token=token,
    )
    if status != 200 or not isinstance(body, list):
        return 0.0, (
            f"GET /api/0/organizations/{GT_ORG_SLUG}/releases/ returned "
            f"status={status} body_type={type(body).__name__}"
        )
    # Build {service_slug: {sha_versions...}} from the response
    coverage: dict[str, set[str]] = {svc: set() for svc in SERVICES}
    for r in body:
        if not isinstance(r, dict):
            continue
        version = r.get("version")
        if not isinstance(version, str) or not SHA_RE.match(version):
            continue
        projs = r.get("projects") or []
        proj_slugs: list[str] = []
        for p in projs:
            if isinstance(p, dict):
                s = p.get("slug")
                if s:
                    proj_slugs.append(s)
            elif isinstance(p, str):
                proj_slugs.append(p)
        for svc in SERVICES:
            if svc in proj_slugs:
                coverage[svc].add(version)
    missing = [svc for svc, vs in coverage.items() if not vs]
    # v20: fractional
    passed_count = len(SERVICES) - len(missing)
    score = passed_count / len(SERVICES)
    if missing:
        return score, (
            f"({passed_count}/{len(SERVICES)} services have releases in org "
            f"list) missing: {missing}. Coverage: " +
            " | ".join(f"{svc}={len(vs)}" for svc, vs in coverage.items())
        )
    return 1.0, (
        "Org-level releases list includes SHA-versioned releases for all "
        "3 services: " +
        " | ".join(f"{svc}={len(vs)}" for svc, vs in coverage.items())
    )


def check_s3_release_to_issue_correlation() -> tuple[float, str]:
    token = grader_token()
    if not token:
        return 0.0, "s3: grader token missing — setup defect."
    # v14: 4 atoms after rubric-driven cleanup. Removed:
    #   - release_has_repos_registered (CONFIRMED DEFECT: GET /repos/ returned 404
    #     in 5/5 v13 rollouts; SCM provider integration not configured on
    #     GlitchTip v5.1.1; even oracle could not pass it).
    #   - release_count_per_service_uniform (TRIVIAL: spread > 2 threshold
    #     passed in 5/5 v13 rollouts including the worst-scoring runs;
    #     no signal).
    # multi-commit atom kept tightened at ≥3 per service (T1 from v13).
    # v20: dropped release_correlates_to_event — auto-review confirmed
    # glitchtip-worker (Celery) is in CrashLoopBackOff in 5/5 rollouts,
    # making this atom infrastructure-impossible to pass regardless of
    # agent action. The atom was a deadweight at 0 not from genuine
    # difficulty but from a setup bug. Net atoms in s3: 3.
    atoms = [
        ("org_release_list_covers_all_services",
         lambda: _check_org_release_list_covers_all_services(token)),
        ("all_three_services_have_three_releases",
         lambda: _check_at_least_one_service_has_two_releases(token)),
        ("each_service_release_binds_to_correct_slug",
         lambda: _check_each_service_release_binds_to_correct_slug(token)),
    ]
    return _aggregate_atoms_fractional("s3_release_to_issue_correlation", atoms)


# ─────────────────────────────────────────────────────────────────────────────
# Entry point
# ─────────────────────────────────────────────────────────────────────────────

CHECKS: dict[str, Any] = {
    "s1_release_metadata_complete": check_s1_release_metadata_complete,
    "s2_pipeline_drives_releases":         check_s2_pipeline_drives_releases,
    "s3_release_to_issue_correlation":     check_s3_release_to_issue_correlation,
}


def _wait_for_glitchtip_api_ready(timeout_s: int = 60) -> None:
    """Poll the GlitchTip /api/0/ root until it returns a usable response,
    so the grader doesn't race against in-flight Celery propagation right
    after a pipeline-driven release POST."""
    deadline = time.time() + timeout_s
    while time.time() < deadline:
        status, _ = http("GET", "/api/0/")
        if status in (200, 401, 403):
            # API is responding; auth-status doesn't matter for readiness.
            return
        time.sleep(2)


def grade(transcript: str) -> GradingResult:
    _wait_for_glitchtip_api_ready()

    subscores: dict[str, float] = {}
    feedback_lines: list[str] = []
    for name, fn in CHECKS.items():
        try:
            score, msg = fn()
        except Exception as e:  # noqa: BLE001
            score, msg = 0.0, f"{name} raised: {e}"
        subscores[name] = float(score)
        marker = "[PASS]" if score >= 1.0 else "[FAIL]"
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
