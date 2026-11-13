# Phase 10: Canary releases

**Goal:** new versions reach users in steps: **10% → 50% → 100%** of real traffic, split by the ALB. While
that happens, Argo Rollouts asks Prometheus for the new version's success rate. If it drops below 95%, the
release is **aborted and rolled back automatically**. You'll prove it by shipping a deliberately broken release.

**Time:** about 2 hours · **Cost:** $0 (the ALB already exists)

---

## 10.1 How it works

```
                      ┌──────── 90% ────────▶ dkmwebapp-stable  ─▶ old pods
users ─▶ ALB (weights)│
                      └──────── 10% ────────▶ dkmwebapp-canary  ─▶ new pods
                                                     │
                     Prometheus ◀── metrics labelled with the pod-template hash
                          │
             AnalysisRun: success rate of the *new* pods ≥ 95%?  ── no ──▶ abort, all traffic back to stable
                          │ yes
                     next step: 50%, then 100%
```

---

## 10.2 Install Argo Rollouts

```bash
helm search repo argo/argo-rollouts      # → ‹rollouts chart›
```

`gitops/platform/argo-rollouts.yaml`, in the usual shape:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: argo-rollouts
  namespace: argocd
  finalizers: [resources-finalizer.argocd.argoproj.io]
spec:
  project: default
  source:
    repoURL: https://argoproj.github.io/argo-helm
    chart: argo-rollouts
    targetRevision: 2.43.12            # Argo Rollouts v1.10.2
    helm:
      valuesObject:
        controller:
          replicas: 1
          metrics:
            enabled: true
            serviceMonitor: { enabled: true }
  destination:
    server: https://kubernetes.default.svc
    namespace: argo-rollouts
  syncPolicy:
    automated: { prune: true, selfHeal: true }
    syncOptions: [CreateNamespace=true, ServerSideApply=true]
    retry: { limit: 10, backoff: { duration: 15s, factor: 2, maxDuration: 5m } }
```

The `kubectl argo rollouts` plugin shows rollouts live in your terminal. Download
`kubectl-argo-rollouts-windows-amd64` from the
[latest release](https://github.com/argoproj/argo-rollouts/releases/latest), rename it to
`kubectl-argo-rollouts.exe`, and put it in a folder on your `PATH`. Check:
`kubectl argo rollouts version`.

---

## 10.3 Chart changes

### `templates/rollout.yaml` (new)

```yaml
{{- if .Values.rollout.enabled }}
apiVersion: argoproj.io/v1alpha1
kind: Rollout
metadata:
  name: dkmwebapp
spec:
  selector: { matchLabels: { app: dkmwebapp } }
  template:
    {{- include "dkmwebapp.podTemplate" . | nindent 4 }}
  strategy:
    canary:
      stableService: dkmwebapp-stable
      canaryService: dkmwebapp-canary
      trafficRouting:
        alb:
          ingress: dkmwebapp
          rootService: dkmwebapp
          servicePort: 80
      # Runs for the whole rollout, from the first step; any failure aborts the release
      analysis:
        templates:
          - templateName: dkmwebapp-success-rate
        startingStep: 1
        args:
          - name: canary-hash
            valueFrom:
              podTemplateHashValue: Latest
      steps:
        - setWeight: 10
        - pause: { duration: 3m }
        - setWeight: 50
        - pause: { duration: 3m }
        # after the last step, 100% goes to the new version
{{- end }}
```

### `templates/services-canary.yaml` (new)

Argo Rollouts points these two at the old and new pods by adding a pod-template-hash to their selectors:

```yaml
{{- if .Values.rollout.enabled }}
{{- range $role := list "stable" "canary" }}
---
apiVersion: v1
kind: Service
metadata:
  name: dkmwebapp-{{ $role }}
  labels: { app: dkmwebapp }
spec:
  selector: { app: dkmwebapp }
  ports:
    - { name: http, port: 80, targetPort: http }
{{- end }}
{{- end }}
```

### `templates/analysis-template.yaml` (new)

```yaml
{{- if .Values.rollout.enabled }}
apiVersion: argoproj.io/v1alpha1
kind: AnalysisTemplate
metadata:
  name: dkmwebapp-success-rate
spec:
  args:
    - name: canary-hash
  metrics:
    - name: success-rate
      interval: 30s
      failureLimit: 1          # a second failed reading aborts the release
      # No traffic yet (NaN) counts as a pass; the load generator in 10.4 guarantees traffic
      successCondition: len(result) == 0 || isNaN(result[0]) || result[0] >= 0.95
      provider:
        prometheus:
          address: http://kube-prometheus-stack-prometheus.observability:9090
          query: |
            sum(rate(http_server_requests_seconds_count{application="dkmwebapp", rollouts_pod_template_hash="{{ "{{" }}args.canary-hash{{ "}}" }}", uri!~"/actuator.*", status!~"5.."}[1m]))
            /
            sum(rate(http_server_requests_seconds_count{application="dkmwebapp", rollouts_pod_template_hash="{{ "{{" }}args.canary-hash{{ "}}" }}", uri!~"/actuator.*"}[1m]))
{{- end }}
```

### `templates/ingress.yaml`: point the backend at the Rollouts-managed action

With ALB traffic routing, the Ingress backend uses the special port name `use-annotation`, and Argo Rollouts
writes the weighted action into an annotation. Change the backend block to:

```yaml
            backend:
              service:
                name: dkmwebapp
                port:
                  {{- if .Values.rollout.enabled }}
                  name: use-annotation       # Argo Rollouts manages the weights between stable and canary
                  {{- else }}
                  name: http
                  {{- end }}
```

### `templates/servicemonitor.yaml`: scrape once, keep the hash

Three Services now select the same pods, so scrape only the root one, and copy the pod-template-hash label
onto the metrics. That label is how the analysis tells new pods from old:

```yaml
{{- if .Values.metrics.serviceMonitor }}
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: dkmwebapp
spec:
  selector:
    matchLabels: { app: dkmwebapp, metrics: "true" }
  podTargetLabels: [rollouts-pod-template-hash]
  endpoints:
    - port: http
      path: /actuator/prometheus
      interval: 15s
{{- end }}
```

…and add `metrics: "true"` to the labels of the root Service in `templates/service.yaml`:

```yaml
  labels: { app: dkmwebapp, metrics: "true" }
```

### Turn it on: `gitops/envs/prod/values.yaml`

```yaml
rollout:
  enabled: true
```

```bash
helm template dkm gitops/charts/dkmwebapp -f gitops/envs/prod/values.yaml | grep -E '^kind:' | sort | uniq -c
# AnalysisTemplate, ExternalSecret, HorizontalPodAutoscaler, Ingress, PodDisruptionBudget,
# PrometheusRule, Rollout, 3 × Service, ServiceMonitor   (no Deployment)
git add gitops && git commit -m "Release dkmwebapp with Argo Rollouts canary and Prometheus analysis" && git push
```

The switch from Deployment to Rollout is a one-time event: the first Rollout revision has no previous version
to compare against, so it scales up fully without steps.

⚠️ **This switch is not zero-downtime.** Measured on the first run: **50 of 516 requests got 503 over ~38
seconds**. The Ingress moved to the new `dkmwebapp-stable`/`dkmwebapp-canary` target groups straight away, while
the Rollout's pods were still starting and registering in them. For a demo, accept it once. For a real service,
migrate in two steps: first a Rollout with `workloadRef` pointing at the existing Deployment and
`scaleDown: progressively` (it starts its own pods next to the Deployment's, which keeps serving), and only
when that Rollout is Healthy, switch the Ingress and remove the Deployment.

`PruneLast=true` in `gitops/apps/dkmwebapp.yaml` makes Argo CD delete the old Deployment after everything
else is applied and healthy, not first.

---

## 10.4 Steady traffic, so the analysis has something to measure

The `dkm` namespace only runs signed `dkmwebapp` images (Phase 9), so the load generator lives in its own
namespace and goes through the public URL. That way it exercises the ALB's weights too.
`gitops/apps/loadgen.yaml`: an Application for `gitops/loadgen/`, and in that folder:

```yaml
# Steady traffic through the public URL, so the canary analysis always has requests to measure (and the ALB's
# weights are exercised). It lives outside dkm: that namespace only admits signed dkmwebapp images (Phase 9).
apiVersion: v1
kind: Namespace
metadata:
  name: loadgen
  labels:
    pod-security.kubernetes.io/enforce: restricted
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: loadgen
  namespace: loadgen
spec:
  replicas: 1
  selector: { matchLabels: { app: loadgen } }
  template:
    metadata:
      labels: { app: loadgen }
    spec:
      securityContext: { runAsNonRoot: true, runAsUser: 100, seccompProfile: { type: RuntimeDefault } }
      containers:
        - name: curl
          image: curlimages/curl:8.23.0@sha256:3fb7e13e5d179a845c97d78204f3f1064d1907037f26a3ebf91710571151fd93
          command: ["sh", "-c"]
          args:
            - while true; do curl -s -o /dev/null https://app.danielkojomegbenu.com/api/products; sleep 0.2; done
          resources:
            requests: { cpu: 10m, memory: 16Mi }
            limits: { memory: 32Mi }
          securityContext: { allowPrivilegeEscalation: false, readOnlyRootFilesystem: true, capabilities: { drop: [ALL] } }
```

About three requests a second (each `curl` takes ~0.1 s): enough for a meaningful success rate at 10% weight.
The namespace enforces Pod Security `restricted` like `dkm`, so the pod runs as a non-root user with a read-only
filesystem. All of it comes from one IP (the NAT gateway): Phase 11's WAF rate limit has to allow for it.

---

## ✅ Phase 10 checkpoint

### A good release goes all the way

Make a harmless change in the app (for example a new product in a `V3__…sql` migration) and push:

```bash
git push && gh run watch
kubectl argo rollouts get rollout dkmwebapp -n dkm --watch
```

You'll see: `SetWeight 10` → `Paused` (3 min) → `SetWeight 50` → `Paused` → **✔ Healthy**, with an
**AnalysisRun Successful**. In the AWS console (EC2 → Load Balancers → the dkm ALB → Listeners → HTTPS rule),
the forward action shows the two target groups with weights 90/10, then 50/50.

The first run: 10% at +2 min (after the canary pod started), 50% at +5 min, 100% at +8.5 min; 14 of 14 analysis
readings passed; the new product appeared in `/api/products`. A probe sending 2 requests a second saw 2 of 636
fail, both at the moment of promotion (see "If something goes wrong").

### A bad release is caught and rolled back

Make 30% of requests fail, using the fault switch you built in Phase 1:

```bash
# gitops/envs/prod/values.yaml
faultErrorRate: "0.3"
git commit -am "Test: ship a release that fails 30% of requests" && git push
kubectl argo rollouts get rollout dkmwebapp -n dkm --watch
```

Within about 2 minutes of reaching 10%: the AnalysisRun shows **Failed**, the rollout shows **✖ Degraded,
RolloutAborted**, traffic goes back to 100% stable, and the canary pods scale down. `DkmwebappHighErrorRate`
may also fire in Slack.

The first run, measured:

```
Status:   ✖ Degraded
Message:  RolloutAborted: Rollout aborted update to revision 3: Background analysis phase error/failed:
          Metric "success-rate" assessed Failed due to failed (2) > failureLimit (1)
readings: (no canary traffic yet) → 1.0 → 0.80 → 0.78
```

Aborted **87 seconds** after reaching 10%. The probe saw 4 of 106 requests fail in that window (3.8%, close to
the expected 10% × 30% = 3%), and none after. Why 1.0 first: the analysis starts when the weight changes, and
the first 1-minute window holds almost no canary requests.

Then fix forward, the GitOps way, through Git:

```bash
git revert --no-edit HEAD && git push
kubectl argo rollouts get rollout dkmwebapp -n dkm --watch     # back to ✔ Healthy
```

The revert makes the pod template identical to the stable ReplicaSet's, so Argo Rollouts goes straight back to
Healthy with no new pods and no canary steps: 7 seconds after the push on the first run.

📸 **Screenshot the aborted rollout** (terminal and the AnalysisRun in the Argo CD UI). It's the best single
proof of the whole platform working.

### If something goes wrong

| Symptom | Fix |
|---|---|
| Rollout stuck at `SetWeight 10`, Ingress unchanged | The Ingress backend must use port name `use-annotation`, and `rootService` must name the Service in that backend. `kubectl -n argo-rollouts logs deploy/argo-rollouts` names the problem. |
| AnalysisRun errors `no data` / always NaN | The metrics have no `rollouts_pod_template_hash` label. Check `podTargetLabels` in the ServiceMonitor and that only the root Service has `metrics: "true"`. |
| Bad release is **not** aborted | No traffic reaches the canary: check the loadgen pod is running and that `curl` succeeds from it. |
| HPA shows `<unknown>` targets | Its `scaleTargetRef` must be the Rollout now (`templates/hpa.yaml` handles it when `rollout.enabled`). |
| Rollout stays at step 0 with the canary pod Ready; `kubectl -n dkm get rollout dkmwebapp -o yaml` shows `ReplicaFailure … failed calling webhook "ivpol…kyverno"` | Kyverno was down at some point (its webhook **fails closed**), and the stable ReplicaSet is now in the controller's exponential back-off. Check `kubectl -n kyverno get pods`, then nudge it: `kubectl -n dkm annotate rs <stable-rs> resync=$(date +%s) --overwrite`. Seen on the first run when a system node briefly stopped reporting. |
| A few 503s at the very end of a good release | The final step points the stable Service at the new pods; they must pass the ALB health check in the stable target group while it still carries 50% of traffic. Measured: 2 of 636 requests. Argo Rollouts' ALB **ping-pong** mode (`canary.pingPong`) avoids it: the target group serving traffic never has its pods swapped. |

> ### 🛑 End of session
> Same as Phase 8. Also delete `loadgen` along with `apps`, or it keeps calling a host that's about to vanish.

**Next:** [Phase 11: Optional CloudFront and WAF](11-edge-optional.md), or go straight to
[Phase 12](12-portfolio-and-teardown.md)
