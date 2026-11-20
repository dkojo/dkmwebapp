# Phase 7: Deploy the app

**Goal:** `dkmwebapp` running in the cluster from the digest CI committed, reachable at
`https://app.danielkojomegbenu.com` through an ALB with your ACM certificate, with its database password coming
from External Secrets, and Argo CD posting "deployed" messages to Slack.

**Time:** about 2 hours · **💰 Adds about $0.03/hour** (the ALB and its public IPs)

---

## 7.1 The Helm chart: `gitops/charts/dkmwebapp/`

```
gitops/charts/dkmwebapp/
├── Chart.yaml
├── values.yaml                 defaults; gitops/envs/prod/values.yaml overrides them
└── templates/
    ├── _pod.tpl                the pod spec, shared by Deployment (now) and Rollout (Phase 10)
    ├── deployment.yaml
    ├── service.yaml
    ├── ingress.yaml
    ├── externalsecret.yaml
    ├── hpa.yaml
    └── pdb.yaml
```

### `Chart.yaml`

```yaml
apiVersion: v2
name: dkmwebapp
description: dkmwebapp on EKS
type: application
version: 0.1.0
```

### `values.yaml`

```yaml
image:
  repository: ""        # set in gitops/envs/prod/values.yaml
  digest: ""            # set by CI
  version: ""           # set by CI

resources:
  requests: { cpu: 250m, memory: 512Mi }
  limits: { memory: 768Mi }   # no CPU limit: avoids throttling; requests drive scheduling

autoscaling:             # the HPA owns the replica count: change minReplicas, never set replicas in Git
  minReplicas: 2
  maxReplicas: 6
  targetCPU: 70

# Connections per pod. RDS db.t4g.micro allows 60; Hikari's default of 10 x 6 pods + RDS's own 3 = 63 is over.
# 5 x (6 pods + a canary) = 35 leaves room.
dbPoolSize: 5

faultErrorRate: "0"     # Phase 10 raises this to prove rollback works

ingress:
  host: app.danielkojomegbenu.com

rollout:
  enabled: false        # Phase 10 switches the Deployment to an Argo Rollouts canary

metrics:
  serviceMonitor: false # Phase 8 turns this on once Prometheus exists
```

### `templates/_pod.tpl`

```yaml
{{- define "dkmwebapp.podTemplate" -}}
metadata:
  labels:
    app: dkmwebapp
spec:
  terminationGracePeriodSeconds: 30
  securityContext:
    runAsNonRoot: true
    seccompProfile: { type: RuntimeDefault }
  topologySpreadConstraints:
    - maxSkew: 1
      topologyKey: topology.kubernetes.io/zone
      whenUnsatisfiable: ScheduleAnyway
      labelSelector: { matchLabels: { app: dkmwebapp } }
  # Only on Karpenter's nodes, never the system nodes: an app scale-out once filled a system node's memory,
  # its kubelet died, and Argo CD, metrics-server and Prometheus went down with it.
  affinity:
    nodeAffinity:
      requiredDuringSchedulingIgnoredDuringExecution:
        nodeSelectorTerms:
          - matchExpressions:
              - { key: karpenter.sh/nodepool, operator: Exists }
  containers:
    - name: dkmwebapp
      image: "{{ .Values.image.repository }}@{{ required "image.digest is set by CI" .Values.image.digest }}"
      ports:
        - { name: http, containerPort: 8080 }
      env:
        - { name: APP_VERSION, value: {{ .Values.image.version | quote }} }
        - { name: FAULT_ERROR_RATE, value: {{ .Values.faultErrorRate | quote }} }
        - { name: SPRING_DATASOURCE_HIKARI_MAXIMUMPOOLSIZE, value: {{ .Values.dbPoolSize | quote }} }
      envFrom:
        - secretRef: { name: dkm-db }       # DB_HOST, DB_PORT, DB_NAME, DB_USERNAME, DB_PASSWORD
      resources: {{- toYaml .Values.resources | nindent 8 }}
      lifecycle:
        # Keep serving while the ALB deregisters this pod. Without it, the ALB keeps sending requests for a few
        # seconds to a pod that is already shutting down (measured: 2 failed requests per rolling update).
        # The native sleep action needs no shell, which the distroless image doesn't have.
        preStop:
          sleep: { seconds: 15 }
      securityContext:
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true
        capabilities: { drop: [ALL] }
      startupProbe:
        httpGet: { path: /actuator/health/liveness, port: http }
        periodSeconds: 5
        failureThreshold: 30                 # up to 150 s for the JVM to start
      livenessProbe:
        httpGet: { path: /actuator/health/liveness, port: http }
        periodSeconds: 10
      readinessProbe:
        httpGet: { path: /actuator/health/readiness, port: http }
        periodSeconds: 5
      volumeMounts:
        - { name: tmp, mountPath: /tmp }     # Spring Boot needs a writable /tmp; the rest is read-only
  volumes:
    - name: tmp
      emptyDir: {}
{{- end }}
```

### `templates/deployment.yaml`

```yaml
{{- if not .Values.rollout.enabled }}
apiVersion: apps/v1
kind: Deployment
metadata:
  name: dkmwebapp
spec:
  selector: { matchLabels: { app: dkmwebapp } }
  strategy:
    rollingUpdate: { maxSurge: 1, maxUnavailable: 0 }
  template:
    {{- include "dkmwebapp.podTemplate" . | nindent 4 }}
{{- end }}
```

### `templates/service.yaml`

```yaml
apiVersion: v1
kind: Service
metadata:
  name: dkmwebapp
  labels: { app: dkmwebapp }
spec:
  selector: { app: dkmwebapp }
  ports:
    - { name: http, port: 80, targetPort: http }
```

### `templates/ingress.yaml`

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: dkmwebapp
  annotations:
    alb.ingress.kubernetes.io/scheme: internet-facing
    alb.ingress.kubernetes.io/target-type: ip                 # traffic goes straight to pod IPs
    alb.ingress.kubernetes.io/listen-ports: '[{"HTTP":80},{"HTTPS":443}]'
    alb.ingress.kubernetes.io/ssl-redirect: "443"
    alb.ingress.kubernetes.io/ssl-policy: ELBSecurityPolicy-TLS13-1-2-2021-06
    alb.ingress.kubernetes.io/healthcheck-path: /actuator/health/readiness
    alb.ingress.kubernetes.io/group.name: dkm                # Phase 10's canary shares this ALB
spec:
  ingressClassName: alb
  # The controller finds the ACM certificate for this host by itself (certificate discovery),
  # so no certificate ARN, and no account ID, is needed here
  tls:
    - hosts: [{{ .Values.ingress.host }}]
  rules:
    - host: {{ .Values.ingress.host }}                        # ExternalDNS creates the Route 53 record from this
      http:
        paths:
          # Only the API is public. /actuator (metrics, health) stays inside the cluster: the ALB answers 404 for it.
          # Prometheus scrapes it in-cluster and the ALB health check reaches pods directly, so neither needs this route.
          - path: /api
            pathType: Prefix
            backend:
              service:
                name: dkmwebapp
                port: { name: http }
```

### `templates/externalsecret.yaml`

```yaml
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: dkm-db
spec:
  refreshInterval: 1h
  secretStoreRef: { kind: ClusterSecretStore, name: aws-secrets-manager }
  target:
    name: dkm-db
    template:
      data:
        # {{ "{{" }} … {{ "}}" }} escapes these from Helm, so External Secrets gets its own template syntax
        DB_HOST: '{{ "{{ .host }}" }}'
        DB_PORT: '{{ "{{ .port }}" }}'
        DB_NAME: '{{ "{{ .dbname }}" }}'
        DB_USERNAME: '{{ "{{ .username }}" }}'
        DB_PASSWORD: '{{ "{{ .password }}" }}'
  dataFrom:
    - extract: { key: dkm/db }
```

### `templates/hpa.yaml`

```yaml
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: dkmwebapp
spec:
  scaleTargetRef:
    {{- if .Values.rollout.enabled }}
    apiVersion: argoproj.io/v1alpha1
    kind: Rollout
    {{- else }}
    apiVersion: apps/v1
    kind: Deployment
    {{- end }}
    name: dkmwebapp
  minReplicas: {{ .Values.autoscaling.minReplicas }}
  maxReplicas: {{ .Values.autoscaling.maxReplicas }}
  metrics:
    - type: Resource
      resource:
        name: cpu
        target: { type: Utilization, averageUtilization: {{ .Values.autoscaling.targetCPU }} }
  behavior:
    scaleUp:
      stabilizationWindowSeconds: 60     # a JVM's startup CPU spike lasts ~30 s; don't scale on it
      policies:
        - { type: Pods, value: 1, periodSeconds: 60 }   # at most one new pod a minute
```

### `templates/pdb.yaml`

```yaml
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: dkmwebapp
spec:
  minAvailable: 1      # Karpenter consolidation never takes the last pod down
  selector: { matchLabels: { app: dkmwebapp } }
```

Check the chart renders before pushing:

```bash
helm template dkm gitops/charts/dkmwebapp -f gitops/envs/prod/values.yaml | head -50
helm lint gitops/charts/dkmwebapp -f gitops/envs/prod/values.yaml       # 0 chart(s) failed
```

---

## 7.2 The Application, and a second root for apps

`gitops/apps/dkmwebapp.yaml`:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: dkmwebapp
  namespace: argocd
  finalizers: [resources-finalizer.argocd.argoproj.io]
  annotations:
    notifications.argoproj.io/subscribe.on-deployed.slack: deployments   # the channel; the bot must be invited to it
spec:
  project: default
  sources:
    - repoURL: https://github.com/dkojo/dkmwebapp.git
      targetRevision: remodelled
      path: gitops/charts/dkmwebapp
      helm:
        valueFiles: [$values/gitops/envs/prod/values.yaml]
    - repoURL: https://github.com/dkojo/dkmwebapp.git
      targetRevision: remodelled
      ref: values
  destination:
    server: https://kubernetes.default.svc
    namespace: dkm
  syncPolicy:
    automated: { prune: true, selfHeal: true }
    syncOptions: [CreateNamespace=true]
    managedNamespaceMetadata:
      labels:
        # The Load Balancer Controller adds a readiness gate to each pod: a pod only counts as Ready once the ALB
        # reports its target healthy, so a rolling update never removes old pods before new ones take traffic.
        elbv2.k8s.aws/pod-readiness-gate-inject: enabled
    retry: { limit: 5, backoff: { duration: 15s, factor: 2, maxDuration: 3m } }
```

`gitops/bootstrap/apps-root.yaml`, which watches `gitops/apps/` the same way `platform` watches add-ons:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: apps
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/dkojo/dkmwebapp.git
    targetRevision: remodelled
    path: gitops/apps
  destination:
    server: https://kubernetes.default.svc
    namespace: argocd
  syncPolicy:
    automated: { prune: true, selfHeal: true }
```

Add it to the `kubectl apply` line in `scripts/session-up.sh`, so future sessions bring the app back by themselves:

```bash
kubectl apply -f gitops/bootstrap/karpenter-oci-repo.yaml -f gitops/bootstrap/root.yaml -f gitops/bootstrap/apps-root.yaml
```

---

## 7.3 Deploy

The cluster must be running (`scripts/session-up.sh` if you destroyed it), and CI must have committed a digest
(Phase 6):

```bash
git pull                                          # get the bot's latest digest commit
git add gitops
git commit -m "Add dkmwebapp Helm chart and Argo CD Application"
git push
kubectl apply -f gitops/bootstrap/apps-root.yaml

kubectl -n argocd get application dkmwebapp -w     # Synced / Healthy in 2–4 minutes
```

What happens in those minutes: Argo CD applies the chart → External Secrets creates `dkm-db` → pods start,
Flyway creates the schema in RDS → the Load Balancer Controller creates an ALB (1–2 min) → ExternalDNS adds
`app.danielkojomegbenu.com` to Route 53 → DNS propagates (usually under a minute).

---

## 7.4 "Deployed" messages from Argo CD to Slack

CI already tells Slack when an image is published. This adds the message when it's actually **running**: the
dashed "deploy notice" line in your diagram.

⚠️ **Use a Slack bot token here, not an incoming webhook.** Argo CD's webhook notifier logs every request URL,
and an incoming webhook's URL *is* its credential. The first run of this guide used a webhook and found it in the
notifications controller's logs (and Phase 8 would have shipped those logs to Loki). A bot token travels in a
request header, which isn't logged. CI can keep its webhook: GitHub masks secrets in Actions logs.

**Create the bot token** in the same Slack app as the CI webhook (https://api.slack.com/apps → your app):

1. **OAuth & Permissions → Bot Token Scopes → Add an OAuth Scope → `chat:write`** (only this one).
2. **Install to Workspace** (or Reinstall) → **Allow**. Don't opt into token rotation: rotated tokens expire every
   12 hours and Argo CD can't refresh them.
3. Copy the **Bot User OAuth Token** (`xoxb-…`). In `#deployments`, type `/invite @‹your app›`.

**Store it in Secrets Manager**, outside the platform stack so it survives teardown (about $0.40/month).
Console → Secrets Manager → **Store a new secret → Other type of secret**: key `token`, value the `xoxb-…`
token, name `dkm/slack-bot1`. (Check the key really is `token`: the name easily ends up in the key box.)

**Sync it into Argo CD** with External Secrets, which can already read `dkm/*`.
`gitops/platform-config/external-secrets/argocd-notifications-secret.yaml`:

```yaml
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: argocd-notifications-secret
  namespace: argocd
spec:
  refreshInterval: 1h
  secretStoreRef: { kind: ClusterSecretStore, name: aws-secrets-manager }
  target:
    name: argocd-notifications-secret
    # Owner: External Secrets creates this Secret. The Argo CD chart is told not to (notifications.secret.create:
    # false), so "Merge" would wait forever for a Secret nobody creates.
    creationPolicy: Owner
  data:
    # A Slack bot token (chat:write only). Not an incoming webhook: Argo CD's webhook notifier logs request URLs,
    # and a webhook's URL is its secret. The bot token travels in a header, which isn't logged.
    - secretKey: slack-token
      remoteRef: { key: dkm/slack-bot1, property: token }
```

**Teach Argo CD the trigger and message.** Replace the `notifications:` block in
`gitops/bootstrap/argocd-values.yaml`:

```yaml
notifications:
  enabled: true
  secret:
    create: false                       # External Secrets creates argocd-notifications-secret (Phase 7)
  notifiers:
    # Bot token in a header (see argocd-notifications-secret.yaml for why not a webhook)
    service.slack: |
      token: $slack-token
  templates:
    template.app-deployed: |
      message: ":rocket: *{{.app.metadata.name}}* is live at Git revision {{ index .app.status.sync.revisions 0 | trunc 7 }} and Healthy"
  triggers:
    # Multi-source apps (chart + values) record their commits in .revisions (a list); .revision stays empty.
    trigger.on-deployed: |
      - description: Synced and healthy after a new revision
        oncePer: app.status.operationState.syncResult.revisions
        send: [app-deployed]
        when: app.status.operationState != nil and app.status.operationState.phase in ['Succeeded'] and app.status.health.status == 'Healthy'
```

Two details that fail silently if you get them wrong:

- **`creationPolicy: Owner`**, not `Merge`: with `secret.create: false` the chart no longer creates the Secret, and
  `Merge` only ever adds to an existing one.
- **`syncResult.revisions` and `sync.revisions`**, not `.revision`: an Application with two sources (chart + values)
  leaves `.status.sync.revision` empty. Check with
  `kubectl -n argocd get application dkmwebapp -o jsonpath='{.status.sync}'`.

The Application subscribes by channel name (`subscribe.on-deployed.slack: deployments`, in 7.2).

Order matters: push first, so External Secrets has created the token Secret, **then** upgrade Argo CD (the one
thing installed by Helm, not by Argo CD):

```bash
git add gitops && git commit -m "Send Argo CD deploy notifications to Slack" && git push
kubectl -n argocd get secret argocd-notifications-secret -o jsonpath='{.data}' | jq 'keys'   # ["slack-token"]
helm upgrade argocd argo/argo-cd -n argocd --version ‹argocd chart› -f gitops/bootstrap/argocd-values.yaml --wait
kubectl -n argocd rollout restart deploy/argocd-notifications-controller

# Prove no credential reaches the logs: count matches, never print them
kubectl -n argocd logs deploy/argocd-notifications-controller | grep -cE 'hooks.slack.com|xox[bp]-'   # 0
```

---

## ✅ Phase 7 checkpoint

```bash
kubectl -n dkm get pods,svc,ingress,externalsecret,hpa
# 2 pods Running 1/1 · Service · Ingress with an ADDRESS (k8s-dkm-….elb.amazonaws.com) · SecretSynced · HPA 2/6

curl -s https://app.danielkojomegbenu.com/api/version          # {"version":"‹short sha from CI›"}
curl -s https://app.danielkojomegbenu.com/api/products | jq length    # 3, served from RDS
curl -sI http://app.danielkojomegbenu.com | head -3             # 301 → https
curl -s -o /dev/null -w '%{http_code}\n' https://app.danielkojomegbenu.com/actuator/prometheus   # 404: not exposed publicly

aws route53 list-resource-record-sets --hosted-zone-id "$(scripts/tf.sh foundation output -raw route53_zone_id)" \
  --query "ResourceRecordSets[?contains(Name,'app.')].[Name,Type]" --output text
# app.danielkojomegbenu.com. A   (plus ExternalDNS ownership TXT records)
```

**The full loop, end to end:** change something visible in the app (for example add a fourth product to
`V1__products.sql` as a **new** migration `V2__more_products.sql`), push, and watch it happen:

```bash
gh run watch                               # CI builds, signs, pushes, bumps the digest
kubectl -n dkm get pods -w                # new pods roll in, old ones drain
curl -s https://app.danielkojomegbenu.com/api/products | jq length    # 4
```

…and `#deployments` gets two messages: ✅ from CI, then 🚀 from Argo CD when it's live.
The first run of this guide took about 5 minutes from `git push` to the new version answering.

**Prove rolling updates drop nothing.** Send requests continuously while the pods are replaced:

```bash
U=https://app.danielkojomegbenu.com/api/version
( end=$((SECONDS+150)); while [ $SECONDS -lt $end ]; do curl -s -o /dev/null -w '%{http_code}\n' --max-time 5 $U; sleep 0.2; done ) > codes.txt &
kubectl -n dkm rollout restart deploy/dkmwebapp && kubectl -n dkm rollout status deploy/dkmwebapp
wait; sort codes.txt | uniq -c        # only 200s
```

Without the `preStop` sleep and the readiness-gate label (7.1, 7.2), this lost 2 of 308 requests: the ALB kept
routing to pods that were already stopping. With them: 371 of 371 succeeded.

### If something goes wrong

| Symptom | Fix |
|---|---|
| Pods `CreateContainerConfigError: secret "dkm-db" not found` | `kubectl -n dkm describe externalsecret dkm-db`. Usually the ClusterSecretStore isn't Ready (Phase 5). |
| Ingress has no ADDRESS after 5 min | `kubectl -n kube-system logs deploy/aws-load-balancer-controller`. "no certificate found for host" means the ACM certificate isn't `ISSUED` or the host doesn't match it exactly. |
| `curl` can't resolve the host | `kubectl -n external-dns logs deploy/external-dns`. Look for the record it created, or for `AccessDenied`. |
| 502/503 from the ALB | Pods aren't ready yet (JVM start), or the readiness probe fails: `kubectl -n dkm logs deploy/dkmwebapp`. |
| Pods crash with `Access denied for user` | The secret didn't refresh after a new session's database. `kubectl -n dkm annotate externalsecret dkm-db force-sync=$(date +%s) --overwrite`. |

> ### 🛑 End of session: ⚠️ the ALB must go before Terraform
> The ALB was created by the Load Balancer Controller, not Terraform. If the VPC is destroyed first, the ALB and
> its network interfaces are left behind, still billing, and `terraform destroy` hangs on the subnets.
> ```bash
> kubectl -n argocd delete application apps        # stop it recreating dkmwebapp
> kubectl -n argocd delete application dkmwebapp    # finalizer deletes the Ingress → controller deletes the ALB
> kubectl -n dkm get ingress                      # wait until gone (~1 min)
> # then the Phase 4 steps: delete "platform", then "karpenter-nodes", wait for nodes, terraform destroy
> ```
> Phase 12 wraps all of this into `scripts/session-down.sh`.

**Next:** [Phase 8: Observability](08-observability.md)
