# Phase 8: Observability

**Goal:** metrics (Prometheus), logs (Loki) and traces (Tempo), all visible in Grafana, collected by an
OpenTelemetry Collector on every node; alert rules for `dkmwebapp`; and alerts posted to Slack by Alertmanager.

**Time:** 2–3 hours · **💰 Adds about $0.01/hour** (three small EBS volumes), plus perhaps one more Karpenter node

---

## 8.1 How data flows

```
dkmwebapp pods ──/actuator/prometheus (scrape)──────────────▶ Prometheus ─▶ Alertmanager ─▶ Slack
      │  OpenTelemetry Java agent (traces, OTLP)                  ▲
      ▼                                                           │ ServiceMonitor
OTel Collector (DaemonSet, one per node) ──traces──▶ Tempo        │
      └── reads every pod's log files ──logs──────▶ Loki          │
                                                      └──────▶ Grafana ◀──┘
```

Everything goes in a new namespace, `observability`.

---

## 8.2 A gp3 storage class (default)

EKS's default storage class is the older `gp2`. gp3 is cheaper and faster.
`gitops/platform-config/storage/gp3.yaml`:

```yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: gp3
  annotations:
    storageclass.kubernetes.io/is-default-class: "true"
provisioner: ebs.csi.aws.com
parameters:
  type: gp3
  encrypted: "true"
reclaimPolicy: Delete                  # deleting the PVC deletes the EBS volume
volumeBindingMode: WaitForFirstConsumer
allowVolumeExpansion: true
```

Remove the default flag from gp2, so there's only one default:

```bash
kubectl annotate storageclass gp2 storageclass.kubernetes.io/is-default-class=false --overwrite
```

(Add this line to `session-up.sh` after `update-kubeconfig`, since the cluster is new each session.)

`gitops/platform/storage.yaml`: an Application for the folder, in the same shape as `karpenter-nodes`
(path `gitops/platform-config/storage`, no namespace needed).

⚠️ **Volumes outlive the cluster.** An EBS volume is deleted only when its PVC is deleted. If you destroy the
cluster with PVCs still present, the volumes stay in your account, billing about $0.08/GB-month, until you
delete them by hand. The teardown in Phase 12 deletes the `observability` namespace first for exactly this reason.

---

## 8.3 Chart versions

```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo add grafana https://grafana.github.io/helm-charts
helm repo add open-telemetry https://open-telemetry.github.io/opentelemetry-helm-charts
helm repo update
helm search repo prometheus-community/kube-prometheus-stack   # → ‹kps chart›
helm search repo grafana/loki                                  # → ‹loki chart› (the "loki" chart, not loki-stack)
helm search repo grafana/tempo                                 # → ‹tempo chart› (single binary)
helm search repo open-telemetry/opentelemetry-collector        # → ‹otel chart›
```

These charts change their values layout between major versions more than most. If a sync fails with an
unknown field, compare your values against `helm show values ‹repo/chart› --version ‹v›`.

---

## 8.4 The Applications: `gitops/platform/`

### `kube-prometheus-stack.yaml`

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: kube-prometheus-stack
  namespace: argocd
  finalizers: [resources-finalizer.argocd.argoproj.io]
spec:
  project: default
  source:
    repoURL: https://prometheus-community.github.io/helm-charts
    chart: kube-prometheus-stack
    targetRevision: ‹kps chart›
    helm:
      valuesObject:
        prometheus:
          prometheusSpec:
            retention: 2d                                  # sessions are short; keep the volume small
            # Pick up ServiceMonitors and rules from every namespace, not only ones with the chart's label
            serviceMonitorSelectorNilUsesHelmValues: false
            ruleSelectorNilUsesHelmValues: false
            podMonitorSelectorNilUsesHelmValues: false
            resources:
              requests: { cpu: 200m, memory: 1Gi }
            storageSpec:
              volumeClaimTemplate:
                spec:
                  storageClassName: gp3
                  accessModes: [ReadWriteOnce]
                  resources: { requests: { storage: 10Gi } }
        alertmanager:
          alertmanagerSpec:
            secrets: [alertmanager-slack]                  # mounted at /etc/alertmanager/secrets/alertmanager-slack/
          config:
            route:
              receiver: slack
              group_by: [alertname, namespace]
              group_wait: 30s
              repeat_interval: 4h
              routes:
                - receiver: "null"
                  matchers: ['alertname =~ "Watchdog|InfoInhibitor"']   # always-firing heartbeat alerts
            receivers:
              - name: "null"
              - name: slack
                slack_configs:
                  - api_url_file: /etc/alertmanager/secrets/alertmanager-slack/url
                    send_resolved: true
                    title: '{{ if eq .Status "firing" }}🔥{{ else }}✅{{ end }} {{ .CommonLabels.alertname }}'
                    text: '{{ range .Alerts }}{{ .Annotations.summary }}{{ "\n" }}{{ end }}'
        grafana:
          adminPassword: ""                                # chart generates one; read it from the secret (8.7)
          additionalDataSources:
            - name: Loki
              type: loki
              uid: loki
              url: http://loki.observability:3100
            - name: Tempo
              type: tempo
              uid: tempo
              url: http://tempo.observability:3200
              jsonData:
                tracesToLogsV2: { datasourceUid: loki, filterByTraceID: true }   # jump from a trace to its logs
          dashboardProviders:
            dashboardproviders.yaml:
              apiVersion: 1
              providers:
                - { name: community, folder: Community, type: file, options: { path: /var/lib/grafana/dashboards/community } }
          dashboards:
            community:
              jvm-micrometer: { gnetId: 4701, revision: 10, datasource: Prometheus }       # JVM (Micrometer)
              spring-boot:    { gnetId: 19004, revision: 1, datasource: Prometheus }       # Spring Boot statistics
  destination:
    server: https://kubernetes.default.svc
    namespace: observability
  syncPolicy:
    automated: { prune: true, selfHeal: true }
    syncOptions: [CreateNamespace=true, ServerSideApply=true]   # its CRDs are too large for client-side apply
    retry: { limit: 10, backoff: { duration: 15s, factor: 2, maxDuration: 5m } }
```

If a dashboard ID fails to import, search grafana.com/grafana/dashboards for "JVM Micrometer" and use the
current ID and revision.

### `loki.yaml`: single binary, filesystem storage

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: loki
  namespace: argocd
  finalizers: [resources-finalizer.argocd.argoproj.io]
spec:
  project: default
  source:
    repoURL: https://grafana.github.io/helm-charts
    chart: loki
    targetRevision: ‹loki chart›
    helm:
      valuesObject:
        deploymentMode: SingleBinary
        loki:
          auth_enabled: false
          commonConfig: { replication_factor: 1 }
          storage: { type: filesystem }
          schemaConfig:
            configs:
              - from: "2024-04-01"
                store: tsdb
                object_store: filesystem
                schema: v13
                index: { prefix: loki_index_, period: 24h }
          limits_config:
            allow_structured_metadata: true      # needed for OTLP ingestion
            retention_period: 48h
        singleBinary:
          replicas: 1
          persistence: { enabled: true, size: 10Gi, storageClass: gp3 }
        # Single-binary mode: turn off the scalable components and caches
        read: { replicas: 0 }
        write: { replicas: 0 }
        backend: { replicas: 0 }
        chunksCache: { enabled: false }
        resultsCache: { enabled: false }
        gateway: { enabled: false }
        lokiCanary: { enabled: false }
        test: { enabled: false }
  destination:
    server: https://kubernetes.default.svc
    namespace: observability
  syncPolicy:
    automated: { prune: true, selfHeal: true }
    syncOptions: [CreateNamespace=true, ServerSideApply=true]
    retry: { limit: 10, backoff: { duration: 15s, factor: 2, maxDuration: 5m } }
```

### `tempo.yaml`

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: tempo
  namespace: argocd
  finalizers: [resources-finalizer.argocd.argoproj.io]
spec:
  project: default
  source:
    repoURL: https://grafana.github.io/helm-charts
    chart: tempo
    targetRevision: ‹tempo chart›
    helm:
      valuesObject:
        tempo:
          retention: 48h
          receivers:
            otlp:
              protocols:
                grpc: { endpoint: "0.0.0.0:4317" }
                http: { endpoint: "0.0.0.0:4318" }
        persistence: { enabled: true, size: 5Gi, storageClassName: gp3 }
  destination:
    server: https://kubernetes.default.svc
    namespace: observability
  syncPolicy:
    automated: { prune: true, selfHeal: true }
    syncOptions: [CreateNamespace=true]
    retry: { limit: 10, backoff: { duration: 15s, factor: 2, maxDuration: 5m } }
```

### `otel-collector.yaml`: one collector per node

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: otel-collector
  namespace: argocd
  finalizers: [resources-finalizer.argocd.argoproj.io]
spec:
  project: default
  source:
    repoURL: https://open-telemetry.github.io/opentelemetry-helm-charts
    chart: opentelemetry-collector
    targetRevision: ‹otel chart›
    helm:
      valuesObject:
        mode: daemonset
        image:
          repository: otel/opentelemetry-collector-k8s
        presets:
          logsCollection: { enabled: true }        # tails /var/log/pods on each node
          kubernetesAttributes: { enabled: true }  # adds namespace, pod and app labels to everything
        ports:
          otlp: { enabled: true, hostPort: 4317 }        # pods send traces to their own node's collector
          otlp-http: { enabled: true, hostPort: 4318 }
        config:
          exporters:
            otlphttp/loki:
              endpoint: http://loki.observability:3100/otlp
            otlp/tempo:
              endpoint: tempo.observability:4317
              tls: { insecure: true }              # in-cluster traffic
          service:
            pipelines:
              logs:
                receivers: [filelog]
                processors: [k8sattributes, memory_limiter, batch]
                exporters: [otlphttp/loki]
              traces:
                receivers: [otlp]
                processors: [k8sattributes, memory_limiter, batch]
                exporters: [otlp/tempo]
  destination:
    server: https://kubernetes.default.svc
    namespace: observability
  syncPolicy:
    automated: { prune: true, selfHeal: true }
    syncOptions: [CreateNamespace=true]
    retry: { limit: 10, backoff: { duration: 15s, factor: 2, maxDuration: 5m } }
```

### The Slack webhook for Alertmanager

Reuse `dkm/slack-webhook` from Phase 7. Add
`gitops/platform-config/external-secrets/alertmanager-slack.yaml`:

```yaml
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: alertmanager-slack
  namespace: observability
spec:
  refreshInterval: 1h
  secretStoreRef: { kind: ClusterSecretStore, name: aws-secrets-manager }
  target: { name: alertmanager-slack }
  data:
    - secretKey: url
      remoteRef: { key: dkm/slack-webhook, property: url }
```

---

## 8.5 Instrument dkmwebapp

### Traces: add the OpenTelemetry Java agent to the image

Find the latest agent version and its checksum:

```bash
V=$(gh api repos/open-telemetry/opentelemetry-java-instrumentation/releases/latest --jq .tag_name)   # e.g. v2.21.0
echo "$V"
curl -sL "https://github.com/open-telemetry/opentelemetry-java-instrumentation/releases/download/$V/opentelemetry-javaagent.jar" | sha256sum
```

In `app/Dockerfile`, in the **runtime** stage, after the `COPY --from=build` line:

```dockerfile
# OpenTelemetry Java agent: traces every HTTP request and JDBC query with no code changes.
# --checksum makes the build fail if the downloaded file isn't exactly this release.
ADD --checksum=sha256:‹checksum› \
    https://github.com/open-telemetry/opentelemetry-java-instrumentation/releases/download/‹version›/opentelemetry-javaagent.jar \
    /app/otel.jar
```

The agent is only loaded when `JAVA_TOOL_OPTIONS` says so, so local `docker compose` runs are unaffected.

### Chart: tell the agent where to send traces

In `templates/_pod.tpl`, add to the container's `env:` list:

```yaml
        - name: NODE_IP
          valueFrom: { fieldRef: { fieldPath: status.hostIP } }
        - { name: JAVA_TOOL_OPTIONS, value: "-javaagent:/app/otel.jar" }
        - { name: OTEL_SERVICE_NAME, value: dkmwebapp }
        - { name: OTEL_EXPORTER_OTLP_ENDPOINT, value: "http://$(NODE_IP):4318" }   # this node's collector
        - { name: OTEL_TRACES_EXPORTER, value: otlp }
        - { name: OTEL_METRICS_EXPORTER, value: none }   # metrics come from Micrometer → Prometheus
        - { name: OTEL_LOGS_EXPORTER, value: none }      # logs come from the collector reading pod logs
        - { name: OTEL_RESOURCE_ATTRIBUTES, value: "service.version={{ .Values.image.version }}" }
```

### Chart: a ServiceMonitor and alert rules

`templates/servicemonitor.yaml`:

```yaml
{{- if .Values.metrics.serviceMonitor }}
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: dkmwebapp
spec:
  selector: { matchLabels: { app: dkmwebapp } }   # matches the stable and (Phase 10) canary Services
  endpoints:
    - port: http
      path: /actuator/prometheus
      interval: 15s
{{- end }}
```

`templates/prometheusrule.yaml`:

```yaml
{{- if .Values.metrics.serviceMonitor }}
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: dkmwebapp
spec:
  groups:
    - name: dkmwebapp
      rules:
        - alert: DkmwebappHighErrorRate
          expr: |
            sum(rate(http_server_requests_seconds_count{application="dkmwebapp",status=~"5.."}[5m]))
              / sum(rate(http_server_requests_seconds_count{application="dkmwebapp"}[5m])) > 0.05
          for: 5m
          labels: { severity: critical }
          annotations:
            summary: "dkmwebapp: more than 5% of requests are failing"
        - alert: DkmwebappSlow
          expr: |
            histogram_quantile(0.95, sum by (le) (rate(http_server_requests_seconds_bucket{application="dkmwebapp",uri!~"/actuator.*"}[5m]))) > 0.5
          for: 10m
          labels: { severity: warning }
          annotations:
            summary: "dkmwebapp: p95 latency above 500 ms"
        - alert: DkmwebappPodRestarting
          expr: increase(kube_pod_container_status_restarts_total{namespace="dkm"}[15m]) > 2
          labels: { severity: warning }
          annotations:
            summary: "dkmwebapp: a pod restarted more than twice in 15 minutes"
{{- end }}
```

Turn them on in `gitops/envs/prod/values.yaml`:

```yaml
metrics:
  serviceMonitor: true
```

### Ship it

```bash
git add app gitops
git commit -m "Add observability stack and instrument dkmwebapp"
git push        # CI builds the image with the agent, then Argo CD rolls it out
gh run watch
```

---

## 8.6 A DORA panel: deployment frequency

Argo CD already counts its syncs. Add one panel to any Grafana dashboard:

```promql
sum(increase(argocd_app_sync_total{name="dkmwebapp", phase="Succeeded"}[7d]))
```

For this, Argo CD's metrics must be scraped. Add to `gitops/bootstrap/argocd-values.yaml`:

```yaml
controller:
  metrics:
    enabled: true
    serviceMonitor: { enabled: true }
```

…and run the `helm upgrade argocd …` command from Phase 7 again.

---

## ✅ Phase 8 checkpoint

```bash
kubectl -n argocd get applications | grep -E 'prometheus|loki|tempo|otel|storage'   # all Synced / Healthy
kubectl -n observability get pods       # prometheus, alertmanager, grafana, loki-0, tempo-0, otel-collector (one per node)
kubectl -n observability get pvc        # 3 Bound volumes on gp3

# Grafana
kubectl -n observability get secret kube-prometheus-stack-grafana -o jsonpath='{.data.admin-password}' | base64 -d; echo
kubectl -n observability port-forward svc/kube-prometheus-stack-grafana 3000:80
# http://localhost:3000  user: admin
```

Make some traffic, then check each signal in Grafana:

```bash
for i in $(seq 1 200); do curl -s -o /dev/null https://app.danielkojomegbenu.com/api/products; done
```

| In Grafana | Look for |
|---|---|
| **Explore → Prometheus** | `sum(rate(http_server_requests_seconds_count{application="dkmwebapp"}[1m]))` shows a line |
| **Explore → Loki** | `{k8s_namespace_name="dkm"}` shows dkmwebapp's log lines |
| **Explore → Tempo → Search** | traces for `dkmwebapp`, each with an HTTP span and a child JDBC span to MySQL |
| **Dashboards → Community** | JVM dashboard with heap and GC for the dkmwebapp pods |
| **Alerting → Alert rules** | `DkmwebappHighErrorRate`, `DkmwebappSlow`, `DkmwebappPodRestarting`, all Normal |

**Prove alerting reaches Slack:**

```bash
kubectl -n observability port-forward svc/kube-prometheus-stack-alertmanager 9093 &
curl -s -XPOST localhost:9093/api/v2/alerts -H 'Content-Type: application/json' \
  -d '[{"labels":{"alertname":"GuideTestAlert"},"annotations":{"summary":"Test alert from the build guide"}}]'
# #deployments gets "🔥 GuideTestAlert" within about 30 seconds
kill %1
```

### If something goes wrong

| Symptom | Fix |
|---|---|
| kube-prometheus-stack sync error `metadata.annotations: Too long` | `ServerSideApply=true` is missing from its `syncOptions`. |
| PVCs stuck `Pending` | `kubectl describe pvc`. Usually the EBS CSI driver's Pod Identity association is missing (Phase 3), or no default storage class. |
| No dkmwebapp targets in Prometheus (Status → Targets) | The ServiceMonitor's label selector must match the Service's labels (`app: dkmwebapp`), and `serviceMonitorSelectorNilUsesHelmValues: false` must be set. |
| No traces | `kubectl -n dkm exec deploy/dkmwebapp -- printenv JAVA_TOOL_OPTIONS`. Then check the collector logs for `otlp` errors and that its pods expose host port 4318. |
| No logs in Loki | `kubectl -n observability logs ds/otel-collector-agent`. Look for `otlphttp/loki` errors (often the `/otlp` path or `allow_structured_metadata`). |

> ### 🛑 End of session
> Phase 7's steps **plus**, before `terraform destroy`:
> ```bash
> kubectl -n argocd delete application kube-prometheus-stack loki tempo otel-collector
> kubectl delete namespace observability    # deletes the PVCs → deletes the EBS volumes
> ```
> Then check nothing is left behind:
> `aws ec2 describe-volumes --filters Name=status,Values=available --query 'Volumes[].VolumeId'` → `[]`.

**Next:** [Phase 9: Policies with Kyverno](09-policies.md)
