#!/bin/bash
set -e

# ---------------------- [DONOT CHANGE ANYTHING BELOW] ---------------------------------- #
# Start supervisord if not already running (manages k3s, dockerd, dnsmasq)
echo "Ensuring supervisord is running..."
/usr/bin/supervisord -c /etc/supervisor/supervisord.conf 2>/dev/null || true
sleep 5

# Set kubeconfig for k3s
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

# Wait for k3s to be ready (k3s can take 30-60 seconds to start)
echo "Waiting for k3s to be ready..."
MAX_WAIT=180
ELAPSED=0
until kubectl get nodes &>/dev/null; do
    if [ $ELAPSED -ge $MAX_WAIT ]; then
        echo "Error: k3s is not ready after ${MAX_WAIT} seconds"
        exit 1
    fi
    echo "Waiting for k3s... (${ELAPSED}s elapsed)"
    sleep 2
    ELAPSED=$((ELAPSED + 2))
done

echo "k3s is ready!"
# ---------------------- [DONOT CHANGE ANYTHING ABOVE] ---------------------------------- #

# ---------------------- [WRITE CUSTOM SETUP HERE] ---------------------------------- #

# Create ubuntu kubeconfig (REQUIRED - agent uses this)
mkdir -p /home/ubuntu/.kube
cp /etc/rancher/k3s/k3s.yaml /home/ubuntu/.kube/config
chown -R ubuntu:ubuntu /home/ubuntu/.kube
chmod 600 /home/ubuntu/.kube/config

# Hand off to the bulk Python orchestrator
exec python3 - <<'PYWORKER_EOF'
"""Bootstrap a green-field GlitchTip + Gitea + ArgoCD + Bleater environment
for the glitchtip-release-pipeline-integration task.

After this script:
  - GlitchTip is up at glitchtip.devops.local with the 'bleater' org and
    three projects with the slug-case TRAP (lowercase, no prefix):
      auth-service, bleat-service, api-gateway
  - Gitea is up at gitea.devops.local with the 'bleater' org and three
    repos (auth-service, bleat-service, api-gateway), each with a basic
    .gitea/workflows/build.yml that does NOT call any GlitchTip API.
  - A Gitea Actions runner is registered and ready to execute workflows.
  - Bleater services are deployed in the bleater namespace with SENTRY_DSN
    env vars pointing to the three GlitchTip projects.
  - Wiki page at gitea/bleater/api-gateway/wiki documents the integration
    using the WRONG slug case (red herring).
  - DECOY: auth-service and bleat-service ship with a half-built
    .gitea/workflows/release.yml that uses the wrong (silently-200)
    endpoint and omits the `ref` field. api-gateway is left clean.
  - DECOY: Secret/bleater/glitchtip-ci-token holds a token whose scopes
    EXCLUDE project:releases — auth probes succeed, release POSTs 403.
  - Grader's GlitchTip token is staged in Secret/grader-state/glitchtip-grader-token.
  - NO release records exist for any project.
  - NO Gitea Actions secrets exist (agents must wire the pre-provisioned
    CI token from Secret/bleater/glitchtip-ci-token into Gitea Actions
    themselves).

This is a greenfield task: the agent must BUILD, not fix.
"""
import base64
import json
import os
import subprocess
import sys
import time
import urllib.error
import urllib.request

os.environ["KUBECONFIG"] = "/etc/rancher/k3s/k3s.yaml"

GT_HOST = "glitchtip.devops.local"
GITEA_HOST = "gitea.devops.local"
GITEA_PORT = 3000
GITEA_USER = "root"
GITEA_PASS = "Admin@123456"
GT_ADMIN_EMAIL = "glitchtip-admin@nebula.local"
GT_ADMIN_PASS = "Admin@123456"
GT_ORG_NAME = "bleater"
GT_ORG_SLUG = "bleater"
SERVICES = ["auth-service", "bleat-service", "api-gateway"]


def kc(*args, check=True, timeout=120, capture=True):
    try:
        r = subprocess.run(["kubectl", *args], capture_output=capture,
                           text=True, timeout=timeout)
    except subprocess.TimeoutExpired:
        print(f"[setup] kubectl {' '.join(args)} TIMEOUT after {timeout}s",
              file=sys.stderr)
        if check:
            sys.exit(1)
        # Return a synthetic CompletedProcess so callers can branch on rc
        return subprocess.CompletedProcess(
            args=["kubectl", *args], returncode=124, stdout="", stderr="timeout"
        )
    if check and r.returncode != 0:
        print(f"[setup] kubectl {' '.join(args)} FAILED: {r.stderr}",
              file=sys.stderr)
        sys.exit(1)
    return r


TRANSIENT_PATTERNS = (
    "connection refused", "no route to host", "i/o timeout",
    "tls handshake", "service unavailable", "serviceunavailable",
    "the server is currently unable", "502 bad gateway",
    "internal error occurred", "failed calling webhook",
    "failed to call webhook", "tcp dial",
)

def kapply(yaml_content, retries=10, sleep_between=8):
    """Apply YAML to k3s with retries. The k3s apiserver flakes during
    early boot AND during heavy GC events (e.g. just after namespace
    teardown). We pass --validate=false to skip server-side schema
    fetch and retry on any transient transport/webhook error.

    Increased retries (10) and sleep (8s) for resilience against the
    short window of apiserver overload that follows a namespace
    delete + recreate cycle."""
    last_err = ""
    for attempt in range(retries):
        proc = subprocess.run(
            ["kubectl", "apply", "--validate=false", "-f", "-"],
            input=yaml_content, capture_output=True, text=True, timeout=120,
        )
        if proc.returncode == 0:
            return proc
        last_err = proc.stderr or proc.stdout
        is_transient = any(p in last_err.lower() for p in TRANSIENT_PATTERNS)
        if is_transient:
            print(f"[setup] kubectl apply transient error "
                  f"(attempt {attempt+1}/{retries}): {last_err[:200]}",
                  file=sys.stderr)
            time.sleep(sleep_between)
            continue
        # Non-transient — fail immediately
        print(f"[setup] kubectl apply FAILED: {last_err}", file=sys.stderr)
        sys.exit(1)
    print(f"[setup] kubectl apply exhausted retries: {last_err}",
          file=sys.stderr)
    sys.exit(1)


def shrun(cmd, check=True, timeout=120, shell=True):
    r = subprocess.run(cmd, shell=shell, capture_output=True, text=True,
                       timeout=timeout)
    if check and r.returncode != 0:
        print(f"[setup] CMD FAILED: {cmd}\nstderr: {r.stderr}",
              file=sys.stderr)
        sys.exit(1)
    return r


def http_request(method, url, body=None, headers=None, timeout=15):
    body_bytes = json.dumps(body).encode() if isinstance(body, dict) else body
    req = urllib.request.Request(url, data=body_bytes, method=method)
    for k, v in (headers or {}).items():
        req.add_header(k, v)
    if isinstance(body, dict):
        req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            raw = resp.read().decode("utf-8", errors="replace")
            try:
                return resp.status, json.loads(raw)
            except json.JSONDecodeError:
                return resp.status, raw
    except urllib.error.HTTPError as e:
        raw = (e.read() or b"").decode("utf-8", errors="replace") if e.fp else ""
        try:
            return e.code, json.loads(raw)
        except json.JSONDecodeError:
            return e.code, raw
    except Exception as e:
        return -1, f"transport error: {e}"


def gitea_auth_header():
    cred = base64.b64encode(f"{GITEA_USER}:{GITEA_PASS}".encode()).decode()
    return {"Authorization": f"Basic {cred}"}


def gitea(method, path, body=None, timeout=15):
    return http_request(method, f"http://{GITEA_HOST}:{GITEA_PORT}{path}",
                        body=body, headers=gitea_auth_header(), timeout=timeout)


def wait_for_pods(namespace, label_selector=None, timeout=300):
    deadline = time.time() + timeout
    while time.time() < deadline:
        if label_selector:
            r = kc("get", "pods", "-n", namespace, "-l", label_selector,
                   "-o", "json", check=False)
        else:
            r = kc("get", "pods", "-n", namespace, "-o", "json", check=False)
        if r.returncode == 0:
            try:
                data = json.loads(r.stdout)
                items = data.get("items", [])
                if items and all(
                    p.get("status", {}).get("phase") == "Running"
                    and all(c.get("ready") for c in
                            p.get("status", {}).get("containerStatuses", []) or [{}])
                    for p in items
                ):
                    return True
            except Exception:
                pass
        time.sleep(3)
    return False


def http_wait(url, timeout=180, expected_codes=(200, 301, 302, 401)):
    deadline = time.time() + timeout
    while time.time() < deadline:
        status, _ = http_request("GET", url, timeout=5)
        if status in expected_codes:
            return True
        time.sleep(3)
    return False


# ─────────────────────────────────────────────────────────────────────────────
# Phase 0a: stronger apiserver readiness — `kubectl get nodes` only checks
# basic reachability; large applies need the openapi endpoint to be ready
# too. Poll until both succeed.
# ─────────────────────────────────────────────────────────────────────────────
print("[setup] Phase 0a: waiting for apiserver to be fully ready")
deadline = time.time() + 180
while time.time() < deadline:
    a = subprocess.run(["kubectl", "get", "--raw", "/openapi/v2"],
                       capture_output=True, text=True, timeout=10)
    b = subprocess.run(["kubectl", "auth", "can-i", "create", "namespaces",
                        "--all-namespaces"],
                       capture_output=True, text=True, timeout=10)
    if a.returncode == 0 and b.returncode == 0 and len(a.stdout) > 1000:
        print("[setup] apiserver fully ready (openapi + auth ok)")
        break
    time.sleep(3)
else:
    print("[setup] WARNING: apiserver readiness timeout; proceeding with retries enabled")

# ─────────────────────────────────────────────────────────────────────────────
# Phase 0: namespaces
# ─────────────────────────────────────────────────────────────────────────────
print("[setup] Phase 0: namespaces")
for ns in ["glitchtip", "gitea", "argocd", "bleater", "grader-state"]:
    kc("create", "ns", ns, check=False)
# Tighten grader-state so agent has no access (uid 1000, role denied)
# The ALLOWED_NAMESPACES env in Dockerfile already excludes grader-state.

# Cleanup any leftover events so they don't leak hints to the agent
kc("delete", "events", "--all", "-A", check=False, timeout=60)

# ─────────────────────────────────────────────────────────────────────────────
# Phase 1: Deploy GlitchTip
# ─────────────────────────────────────────────────────────────────────────────
print("[setup] Phase 1: deploying GlitchTip")

# N5 hardening: generate a random postgres password and route it through
# a Secret instead of baking "postgres" into ConfigMap+Deployment env. v9
# forensics: 4 of 5 agents bypassed N1's no-exec by spawning a postgres-
# image pod in the bleater namespace and connecting to
# glitchtip-postgres.glitchtip.svc.cluster.local:5432 with the literal
# password "postgres". With a random password stored in a Secret in
# glitchtip ns (and the strict ClusterRole on glitchtip ns excluding
# `secrets` from agent visibility — see below), the cross-ns postgres
# bypass is plugged: agents can reach the port but can't authenticate.
import secrets as _secrets
GLITCHTIP_PG_PASSWORD = _secrets.token_urlsafe(24)
print(f"[setup] N5: generated random postgres password "
      f"(stored in Secret/glitchtip/glitchtip-postgres-credentials)")

GLITCHTIP_MANIFEST = """\
apiVersion: v1
kind: Secret
metadata:
  name: glitchtip-postgres-credentials
  namespace: glitchtip
type: Opaque
stringData:
  POSTGRES_PASSWORD: "{GLITCHTIP_PG_PASSWORD}"
  DATABASE_URL: "postgres://postgres:{GLITCHTIP_PG_PASSWORD}@glitchtip-postgres:5432/glitchtip"
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: glitchtip-config
  namespace: glitchtip
data:
  # DATABASE_URL is now sourced from glitchtip-postgres-credentials Secret
  # via envFrom on the web/worker Deployments — keep ConfigMap free of
  # the password to avoid leaking it via cm read.
  REDIS_URL: "redis://glitchtip-redis:6379/0"
  CACHE_URL: "redis://glitchtip-redis:6379/0"
  CELERY_BROKER_URL: "redis://glitchtip-redis:6379/0"
  CELERY_RESULT_BACKEND: "redis://glitchtip-redis:6379/0"
  SECRET_KEY: "nebula-glitchtip-secret-key-not-for-production-use-only"
  PORT: "8080"
  EMAIL_URL: "consolemail://"
  GLITCHTIP_DOMAIN: "http://glitchtip.devops.local"
  DEFAULT_FROM_EMAIL: "noreply@glitchtip.local"
  ENABLE_USER_REGISTRATION: "true"
  ENABLE_OPEN_USER_REGISTRATION: "true"
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: glitchtip-postgres
  namespace: glitchtip
spec:
  replicas: 1
  selector:
    matchLabels:
      app: glitchtip-postgres
  template:
    metadata:
      labels:
        app: glitchtip-postgres
    spec:
      containers:
      - name: postgres
        image: postgres:16-alpine
        env:
        - name: POSTGRES_DB
          value: glitchtip
        - name: POSTGRES_USER
          value: postgres
        # N5: password sourced from glitchtip-postgres-credentials Secret
        - name: POSTGRES_PASSWORD
          valueFrom:
            secretKeyRef:
              name: glitchtip-postgres-credentials
              key: POSTGRES_PASSWORD
        - name: PGDATA
          value: /var/lib/postgresql/data/pgdata
        ports:
        - containerPort: 5432
        readinessProbe:
          exec:
            command: ["pg_isready", "-U", "postgres"]
          initialDelaySeconds: 5
          periodSeconds: 5
---
apiVersion: v1
kind: Service
metadata:
  name: glitchtip-postgres
  namespace: glitchtip
spec:
  selector:
    app: glitchtip-postgres
  ports:
  - port: 5432
    targetPort: 5432
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: glitchtip-redis
  namespace: glitchtip
spec:
  replicas: 1
  selector:
    matchLabels:
      app: glitchtip-redis
  template:
    metadata:
      labels:
        app: glitchtip-redis
    spec:
      containers:
      - name: redis
        image: redis:7-alpine
        ports:
        - containerPort: 6379
---
apiVersion: v1
kind: Service
metadata:
  name: glitchtip-redis
  namespace: glitchtip
spec:
  selector:
    app: glitchtip-redis
  ports:
  - port: 6379
    targetPort: 6379
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: glitchtip-web
  namespace: glitchtip
spec:
  replicas: 1
  selector:
    matchLabels:
      app: glitchtip-web
  template:
    metadata:
      labels:
        app: glitchtip-web
        app.kubernetes.io/component: web
    spec:
      containers:
      - name: web
        image: glitchtip/glitchtip:v5.1.1
        envFrom:
        - configMapRef:
            name: glitchtip-config
        # N5: DATABASE_URL sourced from Secret (overrides ConfigMap if it
        # had set it). Keeps the password out of any agent-readable cm.
        - secretRef:
            name: glitchtip-postgres-credentials
        ports:
        - containerPort: 8080
        readinessProbe:
          httpGet:
            path: /api/0/
            port: 8080
          initialDelaySeconds: 30
          periodSeconds: 10
          timeoutSeconds: 5
        resources:
          requests:
            cpu: 200m
            memory: 384Mi
          limits:
            cpu: 1000m
            memory: 1024Mi
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: glitchtip-worker
  namespace: glitchtip
spec:
  replicas: 1
  selector:
    matchLabels:
      app: glitchtip-worker
  template:
    metadata:
      labels:
        app: glitchtip-worker
    spec:
      containers:
      - name: worker
        image: glitchtip/glitchtip:v5.1.1
        command: ["./bin/run-celery-with-beat.sh"]
        envFrom:
        - configMapRef:
            name: glitchtip-config
        # N5: DATABASE_URL sourced from Secret (same as web)
        - secretRef:
            name: glitchtip-postgres-credentials
        resources:
          requests:
            cpu: 100m
            memory: 256Mi
          limits:
            cpu: 500m
            memory: 768Mi
---
apiVersion: v1
kind: Service
metadata:
  name: glitchtip-web
  namespace: glitchtip
spec:
  selector:
    app: glitchtip-web
  ports:
  - port: 8080
    targetPort: 8080
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: glitchtip
  namespace: glitchtip
  annotations:
    nginx.ingress.kubernetes.io/proxy-body-size: "10m"
spec:
  ingressClassName: nginx
  rules:
  - host: glitchtip.devops.local
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: glitchtip-web
            port:
              number: 8080
""".format(GLITCHTIP_PG_PASSWORD=GLITCHTIP_PG_PASSWORD)
# Phase 1 pre-clean: nebula-devops:1.1.0 ships a Helm GlitchTip release
# with Redis password auth + Istio sidecar injection. Their Redis blocks
# our Django shell's cache-invalidation calls during model save signals
# (NOAUTH error). Easiest fix: tear down the base's stack, deploy our own
# unauthenticated Redis. This matches the pattern in the working
# glitchtip-release-tracking task on the same base image.
print("[setup] Phase 1a: uninstalling base image's Helm GlitchTip release")
subprocess.run(
    "helm uninstall glitchtip -n glitchtip --ignore-not-found 2>/dev/null || true",
    shell=True, capture_output=True, timeout=60,
)
subprocess.run(
    "helm uninstall glitchtip-web -n glitchtip --ignore-not-found 2>/dev/null || true",
    shell=True, capture_output=True, timeout=60,
)

print("[setup] Phase 1b: removing Istio sidecar-injection webhooks")
for webhook in ("istio-sidecar-injector", "rev-injection"):
    kc("delete", "mutatingwebhookconfiguration", webhook,
       "--ignore-not-found", check=False, timeout=20)
hooks_r = kc("get", "mutatingwebhookconfiguration",
             "-o", "jsonpath={.items[*].metadata.name}", check=False, timeout=15)
for h in (hooks_r.stdout or "").split():
    if "istio" in h.lower() or "sidecar" in h.lower():
        kc("delete", "mutatingwebhookconfiguration", h,
           "--ignore-not-found", check=False, timeout=20)

print("[setup] Phase 1c.0: aggressive resource delete inside glitchtip ns")
# Delete all common resource kinds explicitly, --force --grace-period=0 to
# bypass any finalizers/PDBs. Some controllers re-create resources after a
# pure namespace-delete; this scoops them out first.
for kind in ("deploy", "statefulset", "daemonset", "job", "cronjob",
             "rs", "pod", "svc", "ingress", "cm", "secret", "pvc",
             "hpa", "pdb", "sa"):
    kc("delete", kind, "--all", "-n", "glitchtip",
       "--force", "--grace-period=0", "--ignore-not-found",
       "--wait=false", check=False, timeout=60)

print("[setup] Phase 1c.1: deleting any GitOps Applications targeting glitchtip ns")
# If something is reconciling glitchtip via ArgoCD, scoop the Application
# out so it doesn't reapply mid-setup.
for argocd_ns in ("argocd", "argo-cd", "openshift-gitops"):
    kc("delete", "application", "--all", "-n", argocd_ns,
       "--field-selector=metadata.name=glitchtip",
       "--ignore-not-found", check=False, timeout=20)

print("[setup] Phase 1c: recreating glitchtip namespace from scratch")
kc("delete", "namespace", "glitchtip",
   "--ignore-not-found", "--wait=true", "--timeout=120s",
   check=False, timeout=150)
kc("create", "namespace", "glitchtip", check=False, timeout=15)
kc("label", "namespace", "glitchtip",
   "istio-injection=disabled", "--overwrite", check=False, timeout=10)
kc("label", "namespace", "glitchtip",
   "istio.io/rev-", "--overwrite", check=False, timeout=10)

# N1 hardening: define a ClusterRole `ubuntu-user-restricted` that mirrors
# the standard `edit` ClusterRole (full CRUD on core resources, apps,
# batch, networking, autoscaling, policy) but DELIBERATELY OMITS the
# `pods/exec`, `pods/attach`, and `pods/portforward` subresources.
#
# This ClusterRole is bound to the `ubuntu-user` ServiceAccount via per-
# namespace RoleBindings in EACH of the 6 allowed namespaces (default,
# glitchtip, gitea, argocd, bleater, bleater-env). At the end of setup
# we replace /home/ubuntu/.kube/config with a kubeconfig that uses this
# SA token (instead of the cluster-admin cert), so the agent inherits
# these restrictions. Without exec/attach/portforward:
#   - agents cannot `kubectl exec deploy/glitchtip-web -- ./manage.py shell`
#     to mint their own GlitchTip API tokens
#   - agents cannot `kubectl exec glitchtip-postgres -- psql ... SELECT
#     token FROM api_tokens_apitoken` to dump every token directly
#   - agents are forced into the secret-discovery + scope-probe path that
#     H1 was designed to gate on
#
# v8 forensics evidence motivating N1: 3 of 5 rollouts bypassed H1
# entirely via postgres exec or manage.py shell — the prior glitchtip-only
# Role was inert because the agent's kubeconfig used the cluster-admin
# cert from /etc/rancher/k3s/k3s.yaml, not this Role.
ubuntu_clusterrole = """\
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: ubuntu-user-restricted
rules:
- apiGroups: [""]
  resources:
  - configmaps
  - endpoints
  - events
  - persistentvolumeclaims
  - pods
  - replicationcontrollers
  - secrets
  - serviceaccounts
  - services
  verbs: ["get","list","watch","create","update","patch","delete","deletecollection"]
- apiGroups: [""]
  resources: ["pods/log","pods/status"]
  verbs: ["get","list"]
# pods/exec, pods/attach, pods/portforward intentionally NOT included
- apiGroups: ["apps"]
  resources: ["daemonsets","deployments","deployments/scale","replicasets","replicasets/scale","statefulsets","statefulsets/scale"]
  verbs: ["get","list","watch","create","update","patch","delete","deletecollection"]
- apiGroups: ["batch"]
  resources: ["cronjobs","jobs"]
  verbs: ["get","list","watch","create","update","patch","delete","deletecollection"]
- apiGroups: ["networking.k8s.io"]
  resources: ["ingresses","networkpolicies"]
  verbs: ["get","list","watch","create","update","patch","delete","deletecollection"]
- apiGroups: ["autoscaling"]
  resources: ["horizontalpodautoscalers"]
  verbs: ["get","list","watch","create","update","patch","delete","deletecollection"]
- apiGroups: ["policy"]
  resources: ["poddisruptionbudgets"]
  verbs: ["get","list","watch","create","update","patch","delete","deletecollection"]
"""
kapply(ubuntu_clusterrole)

# N5: stricter ClusterRole used ONLY in glitchtip ns — same as
# ubuntu-user-restricted but EXCLUDES `secrets`. The new Secret
# `glitchtip-postgres-credentials` (created by the GlitchTip manifest)
# holds the random postgres password; if agents could read it, they'd
# bypass N5 by spawning a postgres-image pod in another allowed ns and
# authenticating cross-namespace. By denying secrets read on glitchtip
# ns, the password remains opaque to agents while glitchtip-web/worker
# (which run as their own SAs in glitchtip ns) still source it via
# envFrom.secretRef. Agents lose nothing by this — the H1-relocated
# token lives in default/prometheus-remote-write-token; nothing they
# legitimately need lives in a glitchtip-ns secret.
ubuntu_clusterrole_glitchtip_strict = """\
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: ubuntu-user-glitchtip-strict
rules:
- apiGroups: [""]
  resources:
  - configmaps
  - endpoints
  - events
  - persistentvolumeclaims
  - pods
  - replicationcontrollers
  - serviceaccounts
  - services
  verbs: ["get","list","watch","create","update","patch","delete","deletecollection"]
- apiGroups: [""]
  resources: ["pods/log","pods/status"]
  verbs: ["get","list"]
# secrets, pods/exec, pods/attach, pods/portforward intentionally NOT included
- apiGroups: ["apps"]
  resources: ["daemonsets","deployments","deployments/scale","replicasets","replicasets/scale","statefulsets","statefulsets/scale"]
  verbs: ["get","list","watch","create","update","patch","delete","deletecollection"]
- apiGroups: ["batch"]
  resources: ["cronjobs","jobs"]
  verbs: ["get","list","watch","create","update","patch","delete","deletecollection"]
- apiGroups: ["networking.k8s.io"]
  resources: ["ingresses","networkpolicies"]
  verbs: ["get","list","watch","create","update","patch","delete","deletecollection"]
- apiGroups: ["autoscaling"]
  resources: ["horizontalpodautoscalers"]
  verbs: ["get","list","watch","create","update","patch","delete","deletecollection"]
- apiGroups: ["policy"]
  resources: ["poddisruptionbudgets"]
  verbs: ["get","list","watch","create","update","patch","delete","deletecollection"]
"""
kapply(ubuntu_clusterrole_glitchtip_strict)

# Ensure the SA exists in default ns
kc("create", "sa", "ubuntu-user", "-n", "default", check=False, timeout=15)

# Bind the appropriate ClusterRole per namespace. glitchtip → strict
# (no secrets, no exec). All other allowed namespaces → standard
# restricted (no exec, but secrets allowed since H1 token lives there).
ALLOWED_NAMESPACES_LIST = ("default", "glitchtip", "gitea", "argocd",
                           "bleater", "bleater-env")
for ns in ALLOWED_NAMESPACES_LIST:
    kc("create", "ns", ns, check=False, timeout=15)
    role_to_use = ("ubuntu-user-glitchtip-strict" if ns == "glitchtip"
                   else "ubuntu-user-restricted")
    rb_yaml = f"""\
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: ubuntu-user-restricted
  namespace: {ns}
subjects:
- kind: ServiceAccount
  name: ubuntu-user
  namespace: default
roleRef:
  kind: ClusterRole
  name: {role_to_use}
  apiGroup: rbac.authorization.k8s.io
"""
    kapply(rb_yaml)
print("[setup] applied restricted ubuntu-user ClusterRole + RoleBindings "
      f"to {len(ALLOWED_NAMESPACES_LIST)} allowed namespaces "
      "(glitchtip ns: strict — no secrets, no exec; other ns: no exec)")

print("[setup] Phase 1c.5: waiting 20s for apiserver + admission webhooks to settle")
time.sleep(20)

# Diagnostic: is the namespace actually empty? If something re-created
# resources during the settle window, log it so we know.
diag = kc("get", "all", "-n", "glitchtip", check=False, timeout=15)
diag_out = (diag.stdout or "").strip()
if diag_out and "No resources found" not in diag_out:
    print(f"[setup] WARNING: glitchtip ns NOT empty after teardown:\n{diag_out[:600]}")
    # Last-ditch: scoop again with --force --grace-period=0
    for kind in ("deploy", "statefulset", "rs", "pod", "svc", "ingress"):
        kc("delete", kind, "--all", "-n", "glitchtip",
           "--force", "--grace-period=0", "--ignore-not-found",
           check=False, timeout=60)
    time.sleep(8)
else:
    print("[setup] glitchtip ns confirmed empty, proceeding to apply")

print("[setup] Phase 1d: applying our own GlitchTip manifest (no Redis auth)")
# Split into two passes: everything except the Ingress first (no admission
# webhook dependency), then the Ingress separately so its webhook flake
# doesn't gate the whole stack apply.
manifest_parts = GLITCHTIP_MANIFEST.split("---")
non_ingress = []
ingress_parts = []
for part in manifest_parts:
    if "kind: Ingress" in part:
        ingress_parts.append(part)
    else:
        non_ingress.append(part)
kapply("---".join(non_ingress))
print("[setup] Phase 1d.5: waiting 10s for service endpoints to populate")
time.sleep(10)
if ingress_parts:
    print("[setup] Phase 1e: applying Ingress separately (admission webhook may flake)")
    kapply("---".join(ingress_parts))
print("[setup] Waiting for GlitchTip pods to be Running+Ready...")
wait_for_pods("glitchtip", timeout=600)

# Phase 1f: run database migrations on the fresh Postgres. The chart we
# tore down had a migrate Job; our manifest doesn't, so the schema is
# empty and any User/Org/Project create raises UndefinedTable.
print("[setup] Phase 1f: running ./manage.py migrate on fresh Postgres")
for attempt in range(8):
    mig = subprocess.run(
        ["kubectl", "exec", "-n", "glitchtip", "deploy/glitchtip-web",
         "--", "/bin/sh", "-c",
         "cd /code && ./manage.py migrate --noinput"],
        capture_output=True, text=True, timeout=300,
    )
    out_tail = (mig.stdout or "")[-500:]
    err_tail = (mig.stderr or "")[-500:]
    if mig.returncode == 0:
        print(f"[setup] migrate OK on attempt {attempt+1}")
        break
    print(f"[setup] migrate attempt {attempt+1}/8 failed: "
          f"rc={mig.returncode} stderr_tail={err_tail[:300]}")
    time.sleep(8)
else:
    print("[setup] FATAL: migrate never succeeded; bootstrap will fail")

print("[setup] Waiting for GlitchTip API at http://glitchtip.devops.local/api/0/...")
http_wait(f"http://{GT_HOST}/api/0/", timeout=300)

# N5 defense-in-depth: NetworkPolicy isolating glitchtip-postgres so only
# pods inside the glitchtip namespace can reach :5432. Combined with the
# random password + glitchtip-strict RBAC (no secrets), this triple-locks
# the v9 cross-namespace postgres bypass:
#   1. Agent's pod in bleater ns → blocked at network layer (if CNI
#      enforces NetworkPolicy)
#   2. Even if CNI doesn't enforce, agent doesn't have the password
#      (Secret unreadable)
#   3. Even if agent guessed the password, postgres rejects "postgres"
#      (the v9-era literal) because it's now random
print("[setup] Phase 1g (N5): applying NetworkPolicy isolating glitchtip-postgres")
np_yaml = """\
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: glitchtip-postgres-isolate
  namespace: glitchtip
spec:
  podSelector:
    matchLabels:
      app: glitchtip-postgres
  policyTypes:
  - Ingress
  ingress:
  - from:
    - namespaceSelector:
        matchLabels:
          kubernetes.io/metadata.name: glitchtip
    ports:
    - protocol: TCP
      port: 5432
"""
kapply(np_yaml)
# Ensure the namespace label NetworkPolicy depends on is set
kc("label", "namespace", "glitchtip",
   "kubernetes.io/metadata.name=glitchtip", "--overwrite",
   check=False, timeout=10)

# ─────────────────────────────────────────────────────────────────────────────
# Phase 2: Bootstrap GlitchTip — admin user, org, projects (with SLUG TRAP)
# ─────────────────────────────────────────────────────────────────────────────
print("[setup] Phase 2: bootstrapping GlitchTip data model")

def gt_manage(*args):
    """Run a GlitchTip Django manage.py command via kubectl exec."""
    cmd = ["kubectl", "exec", "-n", "glitchtip", "deploy/glitchtip-web", "--",
           "./manage.py", *args]
    r = subprocess.run(cmd, capture_output=True, text=True, timeout=60)
    return r


# Create / upsert superuser via Django shell. get_or_create + set_password
# is idempotent and matches the pattern used by the existing
# glitchtip-release-tracking task. Routed through /bin/sh -c with
# cd /code so Django apps are importable.
create_user_inner = (
    "from django.contrib.auth import get_user_model; "
    "U = get_user_model(); "
    f"u, _ = U.objects.get_or_create(email='{GT_ADMIN_EMAIL}', "
    "defaults={'is_staff': True, 'is_superuser': True}); "
    f"u.set_password('{GT_ADMIN_PASS}'); "
    "u.is_staff = True; u.is_superuser = True; u.save(); "
    "print('USER_OK')"
)
sh_create = (
    f'cd /code && ./manage.py shell -c "{create_user_inner}"'
)
cu = subprocess.run(
    ["kubectl", "exec", "-n", "glitchtip", "deploy/glitchtip-web",
     "--", "/bin/sh", "-c", sh_create],
    capture_output=True, text=True, timeout=60,
)
if "USER_OK" in (cu.stdout or ""):
    print(f"[setup] admin user created/upserted")
else:
    print(f"[setup] create-user FAILED: rc={cu.returncode} "
          f"stderr={(cu.stderr or '')[:300]} stdout={(cu.stdout or '')[:200]}")


def gt_login_session():
    """Create a session-authenticated cookie jar against GlitchTip and return
    the auth token via the API token endpoint."""
    import http.cookiejar
    cj = http.cookiejar.CookieJar()
    opener = urllib.request.build_opener(
        urllib.request.HTTPCookieProcessor(cj),
        urllib.request.HTTPHandler())
    # GET CSRF
    opener.open(f"http://{GT_HOST}/api/0/auth/", timeout=10)
    csrf = ""
    for c in cj:
        if c.name == "csrftoken":
            csrf = c.value
    # Login
    login_body = json.dumps({
        "email": GT_ADMIN_EMAIL,
        "password": GT_ADMIN_PASS,
    }).encode()
    req = urllib.request.Request(f"http://{GT_HOST}/api/0/auth/login/",
                                 data=login_body, method="POST")
    req.add_header("Content-Type", "application/json")
    req.add_header("X-CSRFToken", csrf)
    req.add_header("Referer", f"http://{GT_HOST}/")
    try:
        opener.open(req, timeout=10)
    except urllib.error.HTTPError as e:
        if e.code not in (200, 201):
            print(f"[setup] login HTTP {e.code}: {(e.read() or b'').decode()[:200]}")
    return opener, csrf


# Mint a grader API token via Django ORM. The token is emitted to stdout
# behind a unique marker so we can extract it without ever writing a file
# inside the pod (any file in glitchtip-web is reachable to the agent via
# kubectl exec, since the agent has glitchtip in ALLOWED_NAMESPACES).
TOKEN_MARKER = "__GRADER_TOKEN_MARKER__"

def _mint_grader_token():
    """APIToken.scopes is a 16-flag BitField; passing 65535 enables all
    flags. Do NOT pass `token=` — the model auto-generates one and we
    read it back via .token after create(). Routed through /bin/sh -c
    so we can `cd /code` first (Django apps not on sys.path otherwise)."""
    ALL_SCOPES = (1 << 16) - 1
    inner = (
        "from django.contrib.auth import get_user_model; "
        "from apps.api_tokens.models import APIToken; "
        f"u = get_user_model().objects.get(email='{GT_ADMIN_EMAIL}'); "
        f"t = APIToken.objects.create(user=u, label='grader-readonly', scopes={ALL_SCOPES}); "
        f"print('{TOKEN_MARKER}' + t.token + '{TOKEN_MARKER}')"
    )
    # double-quote the python script for inner shell
    sh_inner = inner.replace('"', '\\"')
    sh_cmd = f'cd /code && ./manage.py shell -c "{sh_inner}"'
    for attempt in range(5):
        r = subprocess.run(
            ["kubectl", "exec", "-n", "glitchtip",
             "deploy/glitchtip-web", "--", "/bin/sh", "-c", sh_cmd],
            capture_output=True, text=True, timeout=60,
        )
        if TOKEN_MARKER in (r.stdout or ""):
            parts = r.stdout.split(TOKEN_MARKER)
            if len(parts) >= 3:
                return parts[1].strip()
        print(f"[setup] mint attempt {attempt+1} failed: "
              f"stderr={(r.stderr or '')[:300]} stdout={(r.stdout or '')[:200]}")
        time.sleep(5)
    return ""

GRADER_TOKEN = _mint_grader_token()
if not GRADER_TOKEN:
    print("[setup] WARNING: grader token mint failed; grader will report setup defect")
else:
    # Stage in grader-state ns (agent has no access to this ns)
    kc("delete", "secret", "-n", "grader-state",
       "glitchtip-grader-token", check=False)
    kc("create", "secret", "generic",
       "-n", "grader-state",
       "glitchtip-grader-token",
       f"--from-literal=token={GRADER_TOKEN}")
    print(f"[setup] grader token staged in grader-state ns")

# Pre-mint a CI-purpose token. The previous engineer left this token in
# Secret/bleater/glitchtip-ci-token, advertised in the wiki as a
# "release-write credential". The token is REAL and live, but its scopes
# are wrong — it carries event:read/write/admin + project:read/write/admin
# only, NOT project:releases. Auth probes against /api/0/ return 200 (the
# token is valid), and listing projects works. The release POST returns
# 403 with a permission_denied error. Agents that grab this token, wire
# it as a Gitea Actions secret, and trust the pipeline's HTTP 200 (without
# verifying the release landed) will silently produce zero release records.
#
# Escape paths: (a) inspect the token's scopes via /api/0/api-tokens/ and
# notice 'project:releases' is absent, then mint a new token using the
# admin login flow at /api/0/auth/login/; (b) use admin credentials from
# the passwords catalog directly with HTTP basic auth; (c) read the
# scopes BitField definition by listing fields. None of these are
# obvious from the surface signal.
def _mint_ci_token() -> str:
    """Mint a POISONED token (no project:releases scope) and return its
    value. Auth probes succeed; release POSTs return 403."""
    # Build a scope mask that EXCLUDES anything containing 'releases'
    # or 'admin' (admin scopes can grant releases via project:admin).
    inner = (
        "from django.contrib.auth import get_user_model; "
        "from apps.api_tokens.models import APIToken; "
        "flags = APIToken._meta.get_field('scopes').flags; "
        "mask = sum((1 << i) for i, name in enumerate(flags) "
        "if 'releases' not in name and 'admin' not in name); "
        f"u = get_user_model().objects.get(email='{GT_ADMIN_EMAIL}'); "
        "t = APIToken.objects.create(user=u, label='ci-pre-provisioned', scopes=mask); "
        f"print('{TOKEN_MARKER}' + t.token + '{TOKEN_MARKER}')"
    )
    sh_inner = inner.replace('"', '\\"')
    sh_cmd = f'cd /code && ./manage.py shell -c "{sh_inner}"'
    for attempt in range(5):
        r = subprocess.run(
            ["kubectl", "exec", "-n", "glitchtip",
             "deploy/glitchtip-web", "--", "/bin/sh", "-c", sh_cmd],
            capture_output=True, text=True, timeout=60,
        )
        if TOKEN_MARKER in (r.stdout or ""):
            parts = r.stdout.split(TOKEN_MARKER)
            if len(parts) >= 3:
                return parts[1].strip()
        time.sleep(5)
    return ""

CI_TOKEN_FOR_PASSWORDS = _mint_ci_token()
if not CI_TOKEN_FOR_PASSWORDS:
    print("[setup] WARNING: poisoned CI token mint failed; agents will lack obvious token")
else:
    # Store the POISONED CI token in Secret/bleater/glitchtip-ci-token.
    # Wiki points here. Auth probes succeed; release POSTs return 403.
    kc("delete", "secret", "-n", "bleater",
       "glitchtip-ci-token", check=False)
    kc("create", "secret", "generic",
       "-n", "bleater",
       "glitchtip-ci-token",
       f"--from-literal=token={CI_TOKEN_FOR_PASSWORDS}")
    # Strip the last-applied-configuration annotation so `kubectl get -o yaml`
    # doesn't leak the create-time hints to the agent.
    kc("annotate", "secret", "-n", "bleater", "glitchtip-ci-token",
       "kubectl.kubernetes.io/last-applied-configuration-", check=False)
    print("[setup] poisoned CI token staged in Secret/bleater/glitchtip-ci-token")


# ─── SECOND DECOY: full-scope token belonging to a NON-org-member user ───
# This token has all 16 scope bits set (including project:releases) but
# the user it's owned by is NOT a member of the bleater org. Release
# POSTs return a different 403 ("You do not have permission to perform
# this action") rather than the scope-based 403. Agents who try both
# bleater-namespace tokens see two distinct 403 patterns and have to
# decide whether the problem is scope, org membership, or endpoint.
def _mint_decoy2_token() -> str:
    """Mint a full-scope token for a non-org-member user."""
    inner = (
        "from django.contrib.auth import get_user_model; "
        "from apps.api_tokens.models import APIToken; "
        "U = get_user_model(); "
        "u2, _created = U.objects.get_or_create("
        "email='platform-ci@nebula.local', "
        "defaults={'is_staff': False, 'is_superuser': False}); "
        "u2.set_password('PlatformCI2024!'); u2.save(); "
        f"t = APIToken.objects.create(user=u2, label='platform-ci', scopes={(1<<16)-1}); "
        f"print('{TOKEN_MARKER}' + t.token + '{TOKEN_MARKER}')"
    )
    sh_inner = inner.replace('"', '\\"')
    sh_cmd = f'cd /code && ./manage.py shell -c "{sh_inner}"'
    for attempt in range(5):
        r = subprocess.run(
            ["kubectl", "exec", "-n", "glitchtip",
             "deploy/glitchtip-web", "--", "/bin/sh", "-c", sh_cmd],
            capture_output=True, text=True, timeout=60,
        )
        if TOKEN_MARKER in (r.stdout or ""):
            parts = r.stdout.split(TOKEN_MARKER)
            if len(parts) >= 3:
                return parts[1].strip()
        time.sleep(5)
    return ""


DECOY2_TOKEN = _mint_decoy2_token()
if DECOY2_TOKEN:
    kc("delete", "secret", "-n", "bleater",
       "glitchtip-release-token", check=False)
    kc("create", "secret", "generic",
       "-n", "bleater",
       "glitchtip-release-token",
       f"--from-literal=token={DECOY2_TOKEN}")
    kc("annotate", "secret", "-n", "bleater", "glitchtip-release-token",
       "kubectl.kubernetes.io/last-applied-configuration-", check=False)
    print("[setup] decoy2 token staged in Secret/bleater/glitchtip-release-token "
          "(full scopes, non-org-member → 403 on org endpoints)")
else:
    print("[setup] WARNING: decoy2 token mint failed; only one bleater-ns decoy active")


def _mint_real_release_token() -> str:
    """Mint a token WITH project:releases (and other scopes). This is the
    real escape-path token for agents who scope-probe before committing."""
    ALL_SCOPES = (1 << 16) - 1
    inner = (
        "from django.contrib.auth import get_user_model; "
        "from apps.api_tokens.models import APIToken; "
        f"u = get_user_model().objects.get(email='{GT_ADMIN_EMAIL}'); "
        f"t = APIToken.objects.create(user=u, label='release-write', scopes={ALL_SCOPES}); "
        f"print('{TOKEN_MARKER}' + t.token + '{TOKEN_MARKER}')"
    )
    sh_inner = inner.replace('"', '\\"')
    sh_cmd = f'cd /code && ./manage.py shell -c "{sh_inner}"'
    for attempt in range(5):
        r = subprocess.run(
            ["kubectl", "exec", "-n", "glitchtip",
             "deploy/glitchtip-web", "--", "/bin/sh", "-c", sh_cmd],
            capture_output=True, text=True, timeout=60,
        )
        if TOKEN_MARKER in (r.stdout or ""):
            parts = r.stdout.split(TOKEN_MARKER)
            if len(parts) >= 3:
                return parts[1].strip()
        time.sleep(5)
    return ""


REAL_RELEASE_TOKEN = _mint_real_release_token()
if not REAL_RELEASE_TOKEN:
    print("[setup] WARNING: real release-write token mint failed; "
          "agents will have NO escape path from the decoy")
else:
    # H1 hardening: stage the real token in Secret/default/prometheus-remote-
    # write-token. Renamed + relocated so agents can't find it by
    # name-matching against "glitchtip" or "release". The previous name
    # ("release-write-credentials") plus its self-describing
    # `description=...full scopes` literal were a free-pass: agents read
    # the description, skipped scope-probing, and bypassed every decoy.
    # Now: token sits in `default` namespace among ~20 other secrets,
    # named like a Prometheus integration. Agents must enumerate secrets
    # across all allowed namespaces and scope-probe each candidate against
    # /api/0/organizations/<org>/releases/ to find the one that works.
    # No description annotation; nothing distinguishes it by name alone.
    kc("delete", "secret", "-n", "default",
       "prometheus-remote-write-token", check=False)
    kc("create", "secret", "generic",
       "-n", "default",
       "prometheus-remote-write-token",
       f"--from-literal=token={REAL_RELEASE_TOKEN}")
    kc("annotate", "secret", "-n", "default", "prometheus-remote-write-token",
       "kubectl.kubernetes.io/last-applied-configuration-", check=False)
    print("[setup] real release-write token staged in "
          "Secret/default/prometheus-remote-write-token (H1: no description)")

# Create the bleater org + 3 projects with the SLUG TRAP
# Use Django ORM directly for determinism. Model paths and OrganizationUser
# 'role' field shape match current GlitchTip (apps.organizations_ext, integer
# role enum where 0 = Owner).
org_proj_script = f"""
from django.contrib.auth import get_user_model
from apps.organizations_ext.models import Organization, OrganizationUser
from apps.projects.models import Project, ProjectKey

U = get_user_model()
admin = U.objects.get(email='{GT_ADMIN_EMAIL}')

org, _ = Organization.objects.get_or_create(
    slug='{GT_ORG_SLUG}',
    defaults={{'name': '{GT_ORG_NAME}'}}
)
OrganizationUser.objects.get_or_create(
    user=admin, organization=org,
    defaults={{'role': 0}}
)

# THE TRAP: lowercase no-prefix slugs.
# Wiki/docs use 'bleater-Auth-Service' but actual slugs are these.
for slug, name in [
    ('auth-service',  'auth-service'),
    ('bleat-service', 'bleat-service'),
    ('api-gateway',   'api-gateway'),
]:
    proj, _ = Project.objects.get_or_create(
        organization=org,
        slug=slug,
        defaults={{'name': name, 'platform': 'python'}}
    )
    pk, _ = ProjectKey.objects.get_or_create(project=proj)
    print(f'PROJECT|{{slug}}|' + str(pk.public_key) + f'|{{proj.id}}')
"""

# Run the multi-line script via `./manage.py shell -c "exec(open(...).read())"`
# from the pod's /code WORKDIR, so Django auto-loads settings and `apps.*` is
# importable. We can't rely on raw `python /tmp/script.py` because that runs
# from /tmp where the apps/ package isn't on sys.path.
with open("/tmp/_gt_orgproj.py", "w") as _f:
    _f.write(org_proj_script)

gt_pod_proc = subprocess.run(
    ["kubectl", "get", "pods", "-n", "glitchtip",
     "-l", "app.kubernetes.io/component=web",
     "-o", "jsonpath={.items[0].metadata.name}"],
    capture_output=True, text=True, timeout=15,
)
gt_pod = (gt_pod_proc.stdout or "").strip()
if not gt_pod:
    gt_pod_proc = subprocess.run(
        ["kubectl", "get", "pods", "-n", "glitchtip",
         "-l", "app=glitchtip-web",
         "-o", "jsonpath={.items[0].metadata.name}"],
        capture_output=True, text=True, timeout=15,
    )
    gt_pod = (gt_pod_proc.stdout or "").strip()
print(f"[setup] org+projects target pod: {gt_pod or '(deploy/glitchtip-web)'}")

# kubectl cp into pod (no -c; the base image's pod has a single container)
cp_target = f"glitchtip/{gt_pod}:/tmp/_gt_orgproj.py" if gt_pod \
    else "glitchtip/deploy/glitchtip-web:/tmp/_gt_orgproj.py"
cp_r = subprocess.run(
    ["kubectl", "cp", "/tmp/_gt_orgproj.py", cp_target],
    capture_output=True, text=True, timeout=30,
)
if cp_r.returncode != 0:
    print(f"[setup] kubectl cp failed: {(cp_r.stderr or cp_r.stdout)[:200]}")

# Exec via /bin/sh -c so we can `cd /code` (where manage.py lives) before
# running the shell. manage.py shell -c reads via exec(open(...).read())
# which executes our copied script with Django fully bootstrapped.
exec_target = ["kubectl", "exec", "-n", "glitchtip"]
exec_target += [gt_pod] if gt_pod else ["deploy/glitchtip-web"]
shell_cmd = (
    "cd /code && ./manage.py shell -c "
    "\"exec(open('/tmp/_gt_orgproj.py').read())\""
)
r = subprocess.run(
    exec_target + ["--", "/bin/sh", "-c", shell_cmd],
    capture_output=True, text=True, timeout=120,
)
print(f"[setup] org+projects rc={r.returncode}")
print(f"[setup] org+projects stdout:\n{r.stdout[:1500]}")
if r.returncode != 0:
    print(f"[setup] org+projects stderr:\n{r.stderr[:1500]}")

# Parse DSN keys per service
dsn_by_service = {}
for line in (r.stdout or "").splitlines():
    if line.startswith("PROJECT|"):
        _, slug, key, pid = line.split("|")
        dsn_by_service[slug] = {
            "key": key,
            "project_id": pid,
            "dsn": f"http://{key}@glitchtip.devops.local/{pid}",
        }

# ─────────────────────────────────────────────────────────────────────────────
# Phase 3: Deploy 3 Bleater services with DSN env vars
# ─────────────────────────────────────────────────────────────────────────────
print("[setup] Phase 3: deploying Bleater services")
for svc in SERVICES:
    info = dsn_by_service.get(svc, {})
    dsn = info.get("dsn", "http://placeholder@glitchtip.devops.local/0")
    bleater_yaml = f"""\
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {svc}
  namespace: bleater
  labels:
    app: {svc}
spec:
  replicas: 1
  selector:
    matchLabels:
      app: {svc}
  template:
    metadata:
      labels:
        app: {svc}
    spec:
      containers:
      - name: app
        image: python:3.11-alpine
        command: ["sh", "-c"]
        args:
          - |
            pip install --quiet flask sentry-sdk==1.40.0
            cat > /tmp/app.py <<'PY'
            import os, sentry_sdk
            from flask import Flask
            sentry_sdk.init(
                dsn=os.environ.get("SENTRY_DSN", ""),
                environment=os.environ.get("SENTRY_ENVIRONMENT", "production"),
                release=os.environ.get("SENTRY_RELEASE", "unknown"),
            )
            app = Flask(__name__)
            @app.route("/healthz")
            def hz(): return "ok"
            @app.route("/")
            def root(): return "{svc}"
            app.run(host="0.0.0.0", port=8080)
            PY
            python /tmp/app.py
        env:
        - name: SENTRY_DSN
          value: "{dsn}"
        - name: SENTRY_ENVIRONMENT
          value: "production"
        ports:
        - containerPort: 8080
        resources:
          requests:
            cpu: 50m
            memory: 96Mi
          limits:
            cpu: 250m
            memory: 256Mi
---
apiVersion: v1
kind: Service
metadata:
  name: {svc}
  namespace: bleater
spec:
  selector:
    app: {svc}
  ports:
  - port: 8080
    targetPort: 8080
"""
    kapply(bleater_yaml)

# ─────────────────────────────────────────────────────────────────────────────
# Phase 4: Bootstrap Gitea + 3 repos + workflows + wiki + red herrings
# ─────────────────────────────────────────────────────────────────────────────
print("[setup] Phase 4: bootstrapping Gitea")
print("[setup] Waiting for Gitea API...")
http_wait(f"http://{GITEA_HOST}:{GITEA_PORT}/api/v1/version", timeout=240)

# Create bleater org
status, body = gitea("POST", "/api/v1/orgs", body={
    "username": GT_ORG_SLUG,
    "full_name": "Bleater",
    "visibility": "public",
})
print(f"[setup] gitea org create: {status}")

# Create 3 service repos with empty initial state, then push workflows
for svc in SERVICES:
    status, body = gitea("POST", f"/api/v1/orgs/{GT_ORG_SLUG}/repos", body={
        "name": svc,
        "description": f"Bleater {svc} application",
        "auto_init": True,
        "default_branch": "main",
    })
    print(f"[setup] gitea repo {svc} create: {status}")

# Drop a basic build.yml workflow into each repo (no GlitchTip integration)
def write_file_to_repo(repo, path, content, message):
    payload = {
        "message": message,
        "content": base64.b64encode(content.encode()).decode(),
        "branch": "main",
    }
    status, body = gitea("POST",
                         f"/api/v1/repos/{GT_ORG_SLUG}/{repo}/contents/{path}",
                         body=payload)
    return status, body


BASIC_BUILD_YML = """\
name: Build
on:
  push:
    branches: [main]
  workflow_dispatch:
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - name: Checkout
        uses: actions/checkout@v4
      - name: Print SHA
        run: |
          echo "Building commit ${GITHUB_SHA}"
"""
for svc in SERVICES:
    write_file_to_repo(svc, ".gitea/workflows/build.yml",
                       BASIC_BUILD_YML,
                       f"chore({svc}): basic CI workflow")

# DECOY: half-built release.yml workflow in 2 of 3 service repos. The
# decoy uses an endpoint that GlitchTip v5 silently 200s on — POST to
# /api/0/organizations/{org}/projects/{slug}/releases/ returns HTTP 200
# with an empty body and creates NO release record. The pipeline goes
# green; the agent's 'pipeline succeeded' signal is a lie.
#
# api-gateway is intentionally LEFT CLEAN (no decoy file). Agents that
# template-port a working solution from api-gateway across all three
# services will pass; agents that extend each repo's existing files will
# fail on the two decoyed services.
#
# Three layered traps in the decoy:
#  1. Wrong endpoint (silent 200 with empty body).
#  2. No `ref` field in payload — even if endpoint were right, lastCommit
#     would not bind, failing s1's release_metadata_complete atom.
#  3. curl lacks `-f` flag and `set -e` is absent, so non-2xx silently
#     returns 0 and the pipeline reports success.
DECOY_RELEASE_YML = """\
# Started by alex (out on leave 2025-11-15) — not yet verified end-to-end
# TODO: confirm with platform team that the endpoint shape is right
#       before we wire this into the other services
name: Notify GlitchTip on Deploy
on:
  push:
    branches: [main]
  workflow_dispatch:
jobs:
  release-notify:
    runs-on: ubuntu-latest
    steps:
      - name: Checkout
        uses: actions/checkout@v4
      - name: Announce release to GlitchTip
        env:
          GT_TOKEN: ${{ secrets.GLITCHTIP_TOKEN }}
        run: |
          PROJECT=$(echo "$GITHUB_REPOSITORY" | awk -F/ '{print $2}')
          curl -s -X POST \\
            -H "Authorization: Bearer $GT_TOKEN" \\
            -H "Content-Type: application/json" \\
            -d "{\\"version\\":\\"$GITHUB_SHA\\",\\"projects\\":[\\"$PROJECT\\"]}" \\
            "http://glitchtip.devops.local/api/0/organizations/bleater/projects/$PROJECT/releases/"
          echo "Release announce posted for $PROJECT @ $GITHUB_SHA"
"""
for decoy_svc in ("auth-service", "bleat-service"):
    write_file_to_repo(decoy_svc, ".gitea/workflows/release.yml",
                       DECOY_RELEASE_YML,
                       f"chore({decoy_svc}): wip release notify (alex, pre-leave)")
print("[setup] decoy release.yml seeded in auth-service + bleat-service "
      "(api-gateway intentionally left clean)")

# Wiki page on api-gateway: senior engineer's handoff note. Provides a
# realistic incident-style narrative without giving away specific fixes.
WIKI_PAGE = """\
Quick handoff before I head out. I started looking at the release tracking
integration last sprint but didn't finish it. It'll likely require going
through the service's API documentation properly rather than continuing
with trial-and-error.

There are a few services that need to be wired up. I'd recommend reading
through the existing pipeline configuration on one of the cleaner repos
before changing anything — the workflow scaffolding already in place
isn't fully wired end-to-end, and at least one of the partial drafts
I pushed is using the wrong endpoint shape entirely.

Releases are scoped at the service level in this system, so make sure
you're targeting the correct resource path when creating them. I had a
basic version working against one service before switching tasks; the
public Sentry tutorial gets you to a 200 OK but the records didn't show
up in the dashboard the way I expected.

On the credentials side, a CI-purpose token was provisioned earlier
and stored in the environment. I never confirmed whether its scopes
were correct for the release endpoint specifically — assume nothing
until you've verified.

One heads-up: the platform team has been pushing a bunch of automated
compliance/retention jobs into this environment lately. I got bitten
twice already — set something up, walk away for ten minutes, come back
to find it gone. Worth poking around for scheduled jobs in the
namespaces you're touching.

Sorry this is a bit incomplete. Feel free to pick it up from here.
"""
status, body = gitea("POST",
                     f"/api/v1/repos/{GT_ORG_SLUG}/api-gateway/wiki/new",
                     body={
                         "title": "Release Tracking Plan",
                         "content_base64": base64.b64encode(WIKI_PAGE.encode()).decode(),
                         "message": "wiki: prior attempt at release tracking",
                     })
print(f"[setup] wiki create: {status}")

# ─────────────────────────────────────────────────────────────────────────────
# Phase 4.9: (no-op in current env) — docker pull would fail because the
# apex container has no internet. Keeping the phase comment as a marker
# so future iterations know to put image-warming work here. We use
# act_runner host-mode (`nebula:host`) instead, which doesn't need a
# per-job container image pull.
# ─────────────────────────────────────────────────────────────────────────────
print("[setup] Phase 4.9: skipped (using act_runner host-mode, no image pull needed)")

# ─────────────────────────────────────────────────────────────────────────────
# Phase 4.95: relax PodSecurity on the gitea namespace.
# The cluster's default policy is 'baseline:latest' which blocks hostPath
# volumes — but our act_runner needs to mount /var/run/docker.sock to
# launch job containers. Label the namespace 'privileged' so our runner
# Deployment can produce a Pod. Without this, the new ReplicaSet emits
# `FailedCreate: violates PodSecurity baseline:latest: hostPath volumes`
# repeatedly and no runner ever registers.
# ─────────────────────────────────────────────────────────────────────────────
for mode in ("enforce", "warn", "audit"):
    kc("label", "namespace", "gitea",
       f"pod-security.kubernetes.io/{mode}=privileged",
       "--overwrite", check=False)
print("[setup] gitea namespace labeled pod-security=privileged "
      "(unblocks hostPath volumes for act_runner)")

# ─────────────────────────────────────────────────────────────────────────────
# Phase 5: deploy a Gitea Actions runner labeled 'nebula' ONLY.
# The base image typically pre-registers a runner with 'ubuntu-latest'. We
# delete those registrations and replace with one that only accepts the
# 'nebula' label. Existing service workflows (BASIC_BUILD_YML and the
# DECOY_RELEASE_YML) use 'runs-on: ubuntu-latest' — they will queue
# forever with no error. The agent must discover the label via
# `kubectl get deploy -n gitea gitea-runner -o yaml` or
# `GET /api/v1/admin/actions/runners`.
# ─────────────────────────────────────────────────────────────────────────────
print("[setup] Phase 5: Gitea Actions runner (relabel to 'nebula')")

# Step 5a: enumerate and delete pre-existing runner registrations
existing_runners = gitea("GET", "/api/v1/admin/actions/runners")
if existing_runners[0] == 200:
    body0 = existing_runners[1]
    runners_list = body0 if isinstance(body0, list) else (
        body0.get("runners", []) if isinstance(body0, dict) else []
    )
    for r in runners_list:
        rid = r.get("id") if isinstance(r, dict) else None
        if rid is not None:
            ds, _ = gitea("DELETE", f"/api/v1/admin/actions/runners/{rid}")
            print(f"[setup] deleted pre-existing runner id={rid} (HTTP {ds})")

# Step 5b: kill any existing runner pods/deployments so they can't re-register
# under the old token. Look in the gitea namespace.
for kind in ("deployment", "pod"):
    rd = subprocess.run(
        ["kubectl", "get", kind, "-n", "gitea",
         "-l", "app=gitea-runner", "-o", "name"],
        capture_output=True, text=True, timeout=30,
    )
    for name in (rd.stdout or "").splitlines():
        name = name.strip()
        if name:
            kc("delete", "-n", "gitea", name,
               "--ignore-not-found", "--grace-period=0", "--force",
               check=False)
# Also catch any runner pod that doesn't have our label
rd = subprocess.run(
    ["kubectl", "get", "pods", "-n", "gitea", "-o", "name"],
    capture_output=True, text=True, timeout=30,
)
for name in (rd.stdout or "").splitlines():
    if "runner" in name:
        kc("delete", "-n", "gitea", name.strip(),
           "--ignore-not-found", "--grace-period=0", "--force",
           check=False)

# Wait a beat for the registration to fully clear server-side
time.sleep(5)

# Step 5c: get a fresh registration token (must come AFTER deletions so
# the existing token isn't reused)
status, body = gitea("GET",
                     f"/api/v1/orgs/{GT_ORG_SLUG}/actions/runners/registration-token")
runner_reg_token = ""
if status == 200 and isinstance(body, dict):
    runner_reg_token = body.get("token", "")
elif status == 200 and isinstance(body, str):
    try:
        runner_reg_token = json.loads(body).get("token", "")
    except Exception:
        runner_reg_token = ""

if not runner_reg_token:
    print("[setup] ERROR: could not get runner registration token; "
          "Phase 5 cannot complete cleanly")

# Step 5d: deploy our runner with label 'nebula' ONLY
if runner_reg_token:
    runner_yaml = f"""\
apiVersion: apps/v1
kind: Deployment
metadata:
  name: gitea-runner
  namespace: gitea
spec:
  replicas: 1
  selector:
    matchLabels:
      app: gitea-runner
  template:
    metadata:
      labels:
        app: gitea-runner
    spec:
      containers:
      - name: runner
        image: gitea/act_runner:latest
        imagePullPolicy: IfNotPresent
        command: ["/bin/sh", "-c"]
        args:
        - |
          set -e
          until wget -q -O- http://gitea.gitea.svc.cluster.local:3000/api/healthz > /dev/null 2>&1; do
            echo "Waiting for Gitea..."
            sleep 5
          done
          if [ ! -f /data/.runner ]; then
            echo "Registering runner with name=$GITEA_RUNNER_NAME labels=$GITEA_RUNNER_LABELS"
            act_runner register \
              --config /etc/act_runner/config.yaml \
              --no-interactive \
              --instance http://gitea.gitea.svc.cluster.local:3000 \
              --token "$GITEA_RUNNER_REGISTRATION_TOKEN" \
              --name "$GITEA_RUNNER_NAME" \
              --labels "$GITEA_RUNNER_LABELS"
          fi
          exec act_runner daemon --config /etc/act_runner/config.yaml
        env:
        - name: GITEA_INSTANCE_URL
          value: "http://gitea.devops.local:3000"
        - name: GITEA_RUNNER_REGISTRATION_TOKEN
          value: "{runner_reg_token}"
        - name: GITEA_RUNNER_NAME
          value: "bleater-runner"
        - name: GITEA_RUNNER_LABELS
          value: "nebula:host"
        - name: CONFIG_FILE
          value: "/etc/act_runner/config.yaml"
        volumeMounts:
        - name: docker-sock
          mountPath: /var/run/docker.sock
        - name: runner-config
          mountPath: /etc/act_runner
        - name: runner-data
          mountPath: /data
        resources:
          requests:
            cpu: 100m
            memory: 192Mi
          limits:
            cpu: 1000m
            memory: 768Mi
      volumes:
      - name: docker-sock
        hostPath:
          path: /var/run/docker.sock
      - name: runner-config
        configMap:
          name: gitea-runner-config
      - name: runner-data
        emptyDir: {{}}
"""
    kapply(runner_yaml)
    print("[setup] gitea-runner deployed with label 'nebula'")
    # Force fresh pod so runner re-registers with the new label (the
    # /data EmptyDir gets wiped on restart, so .runner config is reset).
    kc("delete", "pods", "-n", "gitea", "-l", "app=gitea-runner",
       "--ignore-not-found", "--grace-period=0", "--force",
       check=False)

    # Step 5e: wait for the runner to come online
    for _ in range(30):
        s2, b2 = gitea("GET", "/api/v1/admin/actions/runners")
        if s2 == 200:
            rl = b2 if isinstance(b2, list) else (
                b2.get("runners", []) if isinstance(b2, dict) else []
            )
            for r in rl:
                if not isinstance(r, dict):
                    continue
                labels = r.get("labels") or []
                # labels may be list of strings or list of dicts
                label_names = [
                    (l.get("name") if isinstance(l, dict) else l)
                    for l in labels
                ]
                if "nebula" in label_names and (
                    r.get("status") == "online"
                    or r.get("status_message") == "online"
                ):
                    print("[setup] gitea-runner online with label 'nebula'")
                    break
            else:
                time.sleep(4)
                continue
            break
        time.sleep(4)
    else:
        print("[setup] WARNING: gitea-runner did not come online within 120s; "
              "pipelines may queue")

# ─────────────────────────────────────────────────────────────────────────────
# Phase 5.5: secret-rotation enforcer CronJob.
#
# Every 2 minutes this CronJob lists ALL org-level Gitea Actions secrets
# for the `bleater` org and DELETEs them. Disguised as `platform-team`-
# owned security policy infrastructure so kubectl-recon doesn't flag it
# as adversarial at first glance. Agents that wire GLITCHTIP_TOKEN as an
# org-level Actions secret will see it disappear within 2 min — the
# next push has an empty token, the wget step authenticates with empty
# bearer, GlitchTip returns 401, the workflow's release-announce step
# exits non-zero, conclusion=failure, the v6 grader's
# workflow_run_succeeded_for_head_sha atom fails for that commit.
#
# Repo-level secrets are NOT touched (the Gitea API is org-scoped only).
# Agents who switch to repo-level secrets bypass the rotator. That's the
# intended escape path — discoverable by reading the rotator's source
# via `kubectl get cronjob/gitea-actions-secret-rotation -n gitea -o yaml`.
# ─────────────────────────────────────────────────────────────────────────────
ROTATOR_YAML = f"""\
apiVersion: batch/v1
kind: CronJob
metadata:
  name: gitea-actions-secret-rotation
  namespace: gitea
  labels:
    app.kubernetes.io/component: security-policy
    app.kubernetes.io/part-of: gitea
    app.kubernetes.io/managed-by: platform-team
  annotations:
    policy.platform.bleater.io/owner: platform-team@bleater.local
    policy.platform.bleater.io/justification: |
      Quarterly rotation of org-level CI credentials per SOC2 control
      CC6.1. Org-scoped only; repo-scoped secrets are excluded.
spec:
  schedule: "*/2 * * * *"
  successfulJobsHistoryLimit: 1
  failedJobsHistoryLimit: 1
  concurrencyPolicy: Forbid
  jobTemplate:
    spec:
      backoffLimit: 0
      template:
        metadata:
          labels:
            app: gitea-secret-rotation
        spec:
          restartPolicy: Never
          containers:
          - name: rotator
            # H2 hardening: switched from python:3.11-alpine (Docker Hub —
            # ImagePullBackOff in every prior rollout: cluster has no internet)
            # to glitchtip/glitchtip:v5.1.1, which is already pulled and running
            # in the glitchtip namespace, so containerd has it cached locally.
            # The image is python-3.11-based and ships urllib in stdlib, so
            # the script below works unchanged. With imagePullPolicy: Never,
            # kubelet uses the cached image and the rotator actually fires.
            image: glitchtip/glitchtip:v5.1.1
            imagePullPolicy: Never
            command: ["python3", "-c"]
            args:
            - |
              import urllib.request, json, base64
              auth = base64.b64encode(b"{GITEA_USER}:{GITEA_PASS}").decode()
              h = {{"Authorization": "Basic " + auth}}
              base = "http://gitea.gitea.svc.cluster.local:3000/api/v1/orgs/{GT_ORG_SLUG}/actions/secrets"
              try:
                  req = urllib.request.Request(base, headers=h)
                  resp = urllib.request.urlopen(req, timeout=10)
                  data = json.loads(resp.read())
                  items = data if isinstance(data, list) else data.get("secrets", [])
                  for s in items:
                      n = s.get("name", "")
                      if not n: continue
                      dr = urllib.request.Request(
                          base + "/" + n, method="DELETE", headers=h)
                      try:
                          urllib.request.urlopen(dr, timeout=10)
                          print("rotated:", n)
                      except Exception as e:
                          print("skip", n, ":", e)
              except Exception as e:
                  print("rotation check skipped:", e)
            resources:
              requests:
                cpu: 25m
                memory: 32Mi
              limits:
                cpu: 100m
                memory: 64Mi
"""
kapply(ROTATOR_YAML)
print("[setup] gitea-actions-secret-rotation CronJob deployed "
      "(deletes org-level Actions secrets every 2 min)")

# H2 verification: manually fire the CronJob once and confirm the Job
# reaches Complete. Catches image-pull failures (the previous
# python:3.11-alpine version silently never fired in any rollout because
# the cluster has no internet). If this assertion fails, the rotator
# pressure is dead — surface the failure loudly.
print("[setup] Phase 5.5b: manually firing rotator once to verify image is reachable")
warmer_name = f"rotator-image-warmer-{int(time.time())}"
kc("create", "job", warmer_name, "--from=cronjob/gitea-actions-secret-rotation",
   "-n", "gitea", check=False, timeout=30)
warmer_ok = False
deadline = time.time() + 180
while time.time() < deadline:
    r = kc("get", "job", warmer_name, "-n", "gitea",
           "-o", "jsonpath={.status.succeeded}", check=False, timeout=15)
    if (r.stdout or "").strip() == "1":
        warmer_ok = True
        break
    # Surface pull errors fast
    er = kc("get", "pods", "-n", "gitea",
            "-l", f"job-name={warmer_name}",
            "-o", "jsonpath={.items[*].status.containerStatuses[*].state.waiting.reason}",
            check=False, timeout=15)
    reason = (er.stdout or "").strip()
    if "ImagePullBackOff" in reason or "ErrImagePull" in reason:
        print(f"[setup] FATAL: rotator image pull failed ({reason}) — "
              "H2 hardening is broken; rotator will never fire and trap is dead")
        break
    time.sleep(5)
if warmer_ok:
    print(f"[setup] rotator warmer Job {warmer_name} Completed — "
          "rotator is operational")
else:
    print(f"[setup] WARNING: rotator warmer Job {warmer_name} did NOT "
          "complete in 180s (rotator may be inert)")
# Clean up warmer pod (don't leave Completed jobs hanging)
kc("delete", "job", warmer_name, "-n", "gitea",
   "--ignore-not-found", check=False, timeout=15)

# ─────────────────────────────────────────────────────────────────────────────
# Phase 5.7 (v18): glitchtip-release-retention-enforcer CronJob.
#
# Second chaos-engineering rotator, complementing the existing
# gitea-actions-secret-rotation in the gitea ns. Every 3 minutes this
# CronJob lists releases on the bleat-service and api-gateway projects
# and DELETEs every SHA-versioned release record. auth-service is
# left alone so the existing single-service release_correlates_to_event
# atom still has data to test against.
#
# Disguised as SOC2-control-CC6.2 "data retention enforcer" so kubectl
# recon doesn't immediately read it as adversarial. Lives in glitchtip
# ns so its auth token (mounted from glitchtip/glitchtip-release-
# retention-token) is unreadable to agents (glitchtip ns secrets are
# excluded from the ubuntu-user-glitchtip-strict ClusterRole).
#
# Variance source: capable agents who notice releases disappearing post-
# completion and trace it to this CronJob will suspend it (same pattern
# as the existing rotator). Capable agents who don't trace it will see
# bleat-service + api-gateway releases wiped between their finish time
# and grader-run time, cascade-failing 6 atoms (releases_exist,
# all_three_three_releases, each_service_release_binds_to_correct_slug,
# org_release_list_covers_all_services, release_matches_head_sha_all_three,
# release_dateCreated_within_workflow_run_window for those 2 services).
# Drops their score from 0.75 to ~0.33.
# ─────────────────────────────────────────────────────────────────────────────
print("[setup] Phase 5.7 (v18): glitchtip-release-retention-enforcer CronJob")

# Stage the deletion token in glitchtip ns so the CronJob can mount it
# but agents can't read it (glitchtip-strict ClusterRole excludes secrets).
if REAL_RELEASE_TOKEN:
    kc("delete", "secret", "-n", "glitchtip",
       "glitchtip-release-retention-token", check=False)
    kc("create", "secret", "generic",
       "-n", "glitchtip",
       "glitchtip-release-retention-token",
       f"--from-literal=token={REAL_RELEASE_TOKEN}")
    kc("annotate", "secret", "-n", "glitchtip", "glitchtip-release-retention-token",
       "kubectl.kubernetes.io/last-applied-configuration-", check=False)

RETENTION_CRONJOB_YAML = """\
apiVersion: batch/v1
kind: CronJob
metadata:
  name: glitchtip-release-retention-enforcer
  namespace: glitchtip
  labels:
    app.kubernetes.io/component: data-retention
    app.kubernetes.io/part-of: glitchtip
    app.kubernetes.io/managed-by: platform-team
  annotations:
    policy.platform.bleater.io/owner: platform-team@bleater.local
    policy.platform.bleater.io/justification: |
      SOC2 control CC6.2 — automated release-record retention. Releases
      tagged with full git SHAs are pruned every 3 minutes from non-auth
      services as part of the data-minimization policy. Auth-service
      releases are exempt due to incident-response retention requirements.
spec:
  schedule: "*/3 * * * *"
  successfulJobsHistoryLimit: 1
  failedJobsHistoryLimit: 1
  concurrencyPolicy: Forbid
  jobTemplate:
    spec:
      backoffLimit: 0
      template:
        metadata:
          labels:
            app: glitchtip-release-retention
        spec:
          restartPolicy: Never
          containers:
          - name: enforcer
            image: glitchtip/glitchtip:v5.1.1
            imagePullPolicy: Never
            command: ["python3", "-c"]
            args:
            - |
              import urllib.request, urllib.parse, json, os
              # v20: removed SHA_RE pattern filter — now deletes EVERY
              # release on bleat-service + api-gateway, regardless of
              # version string format. v19 agents bypassed the previous
              # SHA_RE filter by prefixing versions with the service
              # slug (e.g., "auth-service@<sha>"); that workaround is
              # closed. Agents must now actually find and suspend this
              # CronJob (or delete the secret it depends on) to keep
              # their bleat+api releases. auth-service stays exempt.
              TOKEN = os.environ.get("GT_TOKEN", "")
              ORG = "bleater"
              TARGETS = ["bleat-service", "api-gateway"]
              GT = "http://glitchtip-web.glitchtip.svc.cluster.local:8080"
              def http(method, path):
                  req = urllib.request.Request(GT + path, method=method)
                  req.add_header("Authorization", "Bearer " + TOKEN)
                  try:
                      with urllib.request.urlopen(req, timeout=10) as r:
                          raw = r.read().decode("utf-8", errors="replace")
                          try: return r.status, json.loads(raw)
                          except Exception: return r.status, raw
                  except Exception as e:
                      return -1, str(e)
              for svc in TARGETS:
                  s, b = http("GET", f"/api/0/organizations/{ORG}/releases/?project={svc}&per_page=200")
                  if s != 200 or not isinstance(b, list):
                      print("skip", svc, "list status=", s)
                      continue
                  for rel in b:
                      v = (rel or {}).get("version", "") if isinstance(rel, dict) else ""
                      if isinstance(v, str) and v:
                          # urllib URL-encodes ':', '@', etc. acceptable here
                          ds, _ = http("DELETE", f"/api/0/organizations/{ORG}/releases/{urllib.parse.quote(v, safe='')}/")
                          print(f"retained-deleted {svc}/{v[:24]}: HTTP {ds}")
            env:
            - name: GT_TOKEN
              valueFrom:
                secretKeyRef:
                  name: glitchtip-release-retention-token
                  key: token
            resources:
              requests:
                cpu: 25m
                memory: 64Mi
              limits:
                cpu: 200m
                memory: 192Mi
"""

if REAL_RELEASE_TOKEN:
    kapply(RETENTION_CRONJOB_YAML)
    print("[setup] glitchtip-release-retention-enforcer CronJob deployed "
          "(deletes bleat-service + api-gateway SHA releases every 3 min)")

    # Manual-fire warmer to confirm the image is reachable + token works
    print("[setup] Phase 5.7b: manually firing release retention CronJob once")
    ret_warmer = f"retention-warmer-{int(time.time())}"
    kc("create", "job", ret_warmer,
       "--from=cronjob/glitchtip-release-retention-enforcer",
       "-n", "glitchtip", check=False, timeout=30)
    ret_ok = False
    deadline = time.time() + 90
    while time.time() < deadline:
        rr = kc("get", "job", ret_warmer, "-n", "glitchtip",
                "-o", "jsonpath={.status.succeeded}", check=False, timeout=15)
        if (rr.stdout or "").strip() == "1":
            ret_ok = True
            break
        er = kc("get", "pods", "-n", "glitchtip",
                "-l", f"job-name={ret_warmer}",
                "-o", "jsonpath={.items[*].status.containerStatuses[*].state.waiting.reason}",
                check=False, timeout=15)
        if "ImagePullBackOff" in (er.stdout or "") or "ErrImagePull" in (er.stdout or ""):
            print(f"[setup] FATAL: retention CronJob image pull failed; "
                  "v18 chaos-rotator is broken")
            break
        time.sleep(5)
    print(f"[setup] retention warmer Job {'COMPLETED' if ret_ok else 'did NOT complete'}")
    kc("delete", "job", ret_warmer, "-n", "glitchtip",
       "--ignore-not-found", check=False, timeout=15)
else:
    print("[setup] v18 SKIPPED: no real release-write token to mint retention secret")

# ─────────────────────────────────────────────────────────────────────────────
# Phase 6: passwords catalog (so the agent can find admin creds)
# ─────────────────────────────────────────────────────────────────────────────
print("[setup] Phase 6: passwords catalog")
# The base image already serves passwords.devops.local from a static page.
# Append our service-specific creds via ConfigMap that the catalog reads,
# OR write to the same Pod's nginx html dir. We do the simpler thing: check
# whether a passwords-catalog Deployment exists and patch its ConfigMap.
r = kc("get", "cm", "-n", "default", "passwords-catalog", "-o", "json",
       check=False)
catalog_html = ""
if r.returncode == 0:
    try:
        catalog_html = json.loads(r.stdout)["data"].get("index.html", "")
    except Exception:
        catalog_html = ""

PASSWORDS_ADDENDUM = """\
<h2>GlitchTip</h2>
<table>
<tr><th>Service</th><th>Username/Email</th><th>Password</th><th>URL</th></tr>
<tr><td>GlitchTip Admin (UI/API)</td><td>glitchtip-admin@nebula.local</td><td>Admin@123456</td><td>http://glitchtip.devops.local</td></tr>
</table>

<h2>Gitea</h2>
<table>
<tr><th>Service</th><th>Username</th><th>Password</th><th>URL</th></tr>
<tr><td>Gitea root</td><td>root</td><td>Admin@123456</td><td>http://gitea.devops.local</td></tr>
</table>
"""
new_html = (catalog_html + PASSWORDS_ADDENDUM) if catalog_html else (
    "<html><body>" + PASSWORDS_ADDENDUM + "</body></html>"
)
# Build ConfigMap YAML directly so we can use kapply (retry + --validate=false)
import yaml as _yaml  # built-in via PyYAML in nebula-devops base image
try:
    catalog_cm = _yaml.safe_dump({
        "apiVersion": "v1",
        "kind": "ConfigMap",
        "metadata": {"name": "passwords-catalog", "namespace": "default"},
        "data": {"index.html": new_html},
    })
    kapply(catalog_cm)
except ImportError:
    # PyYAML not available — fall back to inline create+apply
    proc = subprocess.run(
        "kubectl create cm passwords-catalog -n default "
        "--from-file=index.html=/dev/stdin --dry-run=client -o yaml | "
        "kubectl apply --validate=false -f -",
        input=new_html, shell=True, capture_output=True, text=True, timeout=60,
    )
    if proc.returncode != 0:
        print(f"[setup] passwords-catalog patch failed (non-fatal): {proc.stderr[:200]}")
# Restart the catalog Deployment if it exists
kc("rollout", "restart", "deploy", "-n", "default", "passwords-catalog",
   check=False)

# ─────────────────────────────────────────────────────────────────────────────
# Phase 7: final verification
# ─────────────────────────────────────────────────────────────────────────────
print("[setup] Phase 7: final verification")
print("[setup] Checking GlitchTip projects:")
if GRADER_TOKEN:
    status, body = http_request(
        "GET",
        f"http://{GT_HOST}/api/0/organizations/{GT_ORG_SLUG}/projects/",
        headers={"Authorization": f"Bearer {GRADER_TOKEN}"},
    )
    if status == 200 and isinstance(body, list):
        for p in body:
            print(f"  project slug={p.get('slug')} name={p.get('name')}")
    else:
        print(f"  projects fetch failed: status={status}")

print("[setup] Checking Gitea repos:")
status, body = gitea("GET", f"/api/v1/orgs/{GT_ORG_SLUG}/repos")
if status == 200 and isinstance(body, list):
    for repo in body:
        print(f"  repo {repo.get('name')}")

# ─────────────────────────────────────────────────────────────────────────────
# Phase 8 (N1 hardening): replace the agent's kubeconfig with a SA-token
# kubeconfig that uses the restricted ClusterRole. Until this point,
# /home/ubuntu/.kube/config has been a copy of /etc/rancher/k3s/k3s.yaml
# (cluster-admin cert) so setup.sh's kubectl exec calls inside this
# Python orchestrator could provision the environment. From here onward
# (i.e. when the agent starts), the kubeconfig grants the
# `ubuntu-user-restricted` ClusterRole only — no pods/exec, no
# pods/attach, no pods/portforward — across the 6 allowed namespaces.
#
# This forces agents into the secret-discovery + scope-probe path that
# the H1 token-relocation depends on (kubectl exec into glitchtip-web
# or postgres to mint/dump tokens directly is no longer permitted).
# ─────────────────────────────────────────────────────────────────────────────
print("[setup] Phase 8: writing restricted kubeconfig for agent (no pods/exec)")
sa_token_proc = subprocess.run(
    ["kubectl", "create", "token", "ubuntu-user", "-n", "default",
     "--duration=24h"],
    capture_output=True, text=True, timeout=30,
)
SA_TOKEN = (sa_token_proc.stdout or "").strip()
if sa_token_proc.returncode != 0 or not SA_TOKEN:
    print(f"[setup] FATAL: could not mint SA token "
          f"(rc={sa_token_proc.returncode}, stderr={sa_token_proc.stderr[:200]}); "
          "agent will keep cluster-admin kubeconfig — N1 hardening BROKEN")
else:
    # Pull cluster CA data from the existing admin kubeconfig and reuse it
    with open("/etc/rancher/k3s/k3s.yaml") as _f:
        admin_kubeconfig = _f.read()
    import re as _re
    m = _re.search(r"certificate-authority-data:\s*(\S+)", admin_kubeconfig)
    CA_DATA = m.group(1) if m else ""
    if not CA_DATA:
        print("[setup] FATAL: could not extract CA data from k3s.yaml; "
              "agent will keep cluster-admin kubeconfig — N1 BROKEN")
    else:
        new_kubeconfig = f"""\
apiVersion: v1
kind: Config
clusters:
- cluster:
    certificate-authority-data: {CA_DATA}
    server: https://127.0.0.1:6443
  name: default
contexts:
- context:
    cluster: default
    namespace: default
    user: ubuntu-user
  name: default
current-context: default
users:
- name: ubuntu-user
  user:
    token: {SA_TOKEN}
"""
        with open("/home/ubuntu/.kube/config", "w") as _f:
            _f.write(new_kubeconfig)
        os.chmod("/home/ubuntu/.kube/config", 0o600)
        subprocess.run(
            ["chown", "ubuntu:ubuntu", "/home/ubuntu/.kube/config"],
            check=False, timeout=10,
        )
        # Verify the restriction holds: exec must be denied
        v_exec = subprocess.run(
            ["sudo", "-u", "ubuntu",
             "kubectl", "--kubeconfig=/home/ubuntu/.kube/config",
             "auth", "can-i", "create", "pods/exec", "-n", "glitchtip"],
            capture_output=True, text=True, timeout=15,
        )
        v_exec_out = (v_exec.stdout or "").strip()
        v_get = subprocess.run(
            ["sudo", "-u", "ubuntu",
             "kubectl", "--kubeconfig=/home/ubuntu/.kube/config",
             "auth", "can-i", "get", "secrets", "-n", "glitchtip"],
            capture_output=True, text=True, timeout=15,
        )
        v_get_out = (v_get.stdout or "").strip()
        print(f"[setup] N1 verification: can-i exec pods/exec in glitchtip = "
              f"{v_exec_out!r} (want 'no')")
        print(f"[setup] N1 verification: can-i get secrets in glitchtip = "
              f"{v_get_out!r} (want 'yes')")
        if v_exec_out == "no" and v_get_out == "yes":
            print("[setup] N1 hardening ACTIVE: agent kubeconfig is "
                  "ubuntu-user SA token (restricted; no exec)")
        else:
            print("[setup] WARNING: N1 verification failed — "
                  f"exec={v_exec_out!r} get={v_get_out!r}")

print("[setup] DONE — environment is greenfield ready.")
print("[setup] Agent must build: workflows that POST releases per push,")
print("[setup] wire the pre-provisioned CI token into Gitea Actions, and")
print("[setup] verify releases land in GlitchTip with correct lastCommit.")
PYWORKER_EOF
