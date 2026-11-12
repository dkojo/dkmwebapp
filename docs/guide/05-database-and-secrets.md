# Phase 5: Database and secrets

**Goal:** an RDS MySQL database in private subnets, its connection details in AWS Secrets Manager, and External
Secrets Operator copying them into a Kubernetes Secret, so the password never appears in Git, in a Helm value
or in a CI log.

**Time:** 1–2 hours (RDS takes about 10 minutes to create) · **💰 Adds about $0.02/hour**

---

## 5.1 How the password travels

```
Terraform ──creates──▶ Secrets Manager "dkm/db"  {host, port, dbname, username, password}
                              │
          External Secrets (Pod Identity, can read only dkm/*)
                              │
                              ▼
               Kubernetes Secret "dkm-db" in namespace dkm
                              │  envFrom
                              ▼
                        dkmwebapp pods
```

**Why a fixed secret name instead of RDS-managed passwords:** RDS can manage and rotate the master password
itself, but it names that secret `rds!db-‹random›`, and the name changes every time the database is recreated.
Because you recreate the platform each session, the GitOps files would need editing every time. A fixed name
(`dkm/db`) written by Terraform keeps Git unchanged. **In production** you'd keep the database running and
turn on RDS-managed rotation. Phase 12 has this in its "what I'd do differently" list.

---

## 5.2 Terraform: `infra/platform/database.tf`

```hcl
resource "aws_security_group" "db" {
  name        = "${var.cluster_name}-db"
  description = "MySQL from EKS nodes only"
  vpc_id      = module.vpc.vpc_id

  ingress {
    description     = "MySQL from cluster nodes (system and Karpenter nodes share this group)"
    from_port       = 3306
    to_port         = 3306
    protocol        = "tcp"
    security_groups = [module.eks.node_security_group_id]
  }
}

resource "random_password" "db" {
  length           = 32
  special          = true
  override_special = "!#%*-_=+" # avoids characters that need escaping in JDBC URLs and shells
}

resource "aws_db_instance" "dkm" {
  identifier     = "${var.cluster_name}-mysql"
  engine         = "mysql"
  engine_version = var.db_engine_version
  instance_class = var.db_instance_class

  allocated_storage = var.db_allocated_storage_gb
  storage_type      = "gp3"
  storage_encrypted = true

  db_name  = "dkm"
  username = "shop_admin"
  password = random_password.db.result

  db_subnet_group_name   = module.vpc.database_subnet_group_name
  vpc_security_group_ids = [aws_security_group.db.id]
  publicly_accessible    = false

  multi_az                = var.db_multi_az # demo: false; production: true
  backup_retention_period = 1
  # Demo: no final snapshot, because Flyway recreates the schema and sample data every session
  deletion_protection       = var.db_deletion_protection
  skip_final_snapshot       = !var.db_deletion_protection
  final_snapshot_identifier = var.db_deletion_protection ? "${var.cluster_name}-mysql-final" : null
  apply_immediately         = true
}

resource "aws_secretsmanager_secret" "db" {
  name        = "${var.cluster_name}/db"
  description = "dkmwebapp database connection, synced into the cluster by External Secrets"
  # Delete immediately on destroy, so next session can create the same name again without a clash
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret_version" "db" {
  secret_id = aws_secretsmanager_secret.db.id
  secret_string = jsonencode({
    host     = aws_db_instance.dkm.address
    port     = tostring(aws_db_instance.dkm.port)
    dbname   = aws_db_instance.dkm.db_name
    username = aws_db_instance.dkm.username
    password = random_password.db.result
  })
}
```

Add the `random` provider to `infra/platform/versions.tf`:

```hcl
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
```

⚠️ **The password is in the Terraform state.** That's why the state bucket is private, encrypted and versioned,
and why `*.tfstate` is in `.gitignore`. Never copy state files anywhere else.

Also update the External Secrets permission you wrote in Phase 3, if you wrote it before this change:
in `pod-identity.tf`, the ARN must end in `secret:${var.cluster_name}/*`.

### 💰 Apply

```bash
scripts/tf.sh platform init -upgrade        # picks up the random provider
scripts/tf.sh platform plan -out=db.tfplan  # expect: 5 to add (SG, password, DB, secret, secret version); 1 change only if you fixed the ESO ARN
scripts/tf.sh platform apply db.tfplan && rm infra/platform/db.tfplan
```

Size, Multi-AZ and deletion protection are variables (`db_*` in `variables.tf`). Change them in
`envs/prod.tfvars`, not in this file.

---

## 5.3 Tell External Secrets where to look

A `ClusterSecretStore` points External Secrets at Secrets Manager. It has no credentials of its own: it uses
the controller's Pod Identity role.

`gitops/platform-config/external-secrets/cluster-secret-store.yaml`:

```yaml
apiVersion: external-secrets.io/v1
kind: ClusterSecretStore
metadata:
  name: aws-secrets-manager
spec:
  provider:
    aws:
      service: SecretsManager
      region: us-east-1
      # No "auth" block: the controller uses its Pod Identity credentials (read-only, dkm/* only)
```

> If `external-secrets.io/v1` is rejected, your chart version still serves `v1beta1`. Check with
> `kubectl api-resources | grep clustersecretstore`.

`gitops/platform/external-secrets-config.yaml`:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: external-secrets-config
  namespace: argocd
  finalizers: [resources-finalizer.argocd.argoproj.io]
spec:
  project: default
  source:
    repoURL: https://github.com/dkojo/dkmwebapp.git
    targetRevision: remodelled
    path: gitops/platform-config/external-secrets
  destination:
    server: https://kubernetes.default.svc
  syncPolicy:
    automated: { prune: true, selfHeal: true }
    syncOptions: [SkipDryRunOnMissingResource=true]
    retry: { limit: 10, backoff: { duration: 15s, factor: 2, maxDuration: 5m } }
```

```bash
git add infra/platform gitops
git commit -m "Add RDS MySQL, dkm/db secret and External Secrets store"
git push
```

---

## ✅ Phase 5 checkpoint

```bash
aws rds describe-db-instances --db-instance-identifier dkm-mysql \
  --query 'DBInstances[0].[DBInstanceStatus,PubliclyAccessible,StorageEncrypted]' --output text
# available   False   True

kubectl get clustersecretstore aws-secrets-manager
# NAME                  STATUS   READY
# aws-secrets-manager   Valid    True
```

**Prove the whole chain** with a throwaway ExternalSecret. The real one comes with the app in Phase 7:

```bash
kubectl create namespace dkm
cat <<'EOF' | kubectl apply -f -
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: db-test
  namespace: dkm
spec:
  refreshInterval: 1h
  secretStoreRef: { kind: ClusterSecretStore, name: aws-secrets-manager }
  target: { name: db-test }
  dataFrom:
    - extract: { key: dkm/db }
EOF

kubectl -n dkm get externalsecret db-test          # STATUS SecretSynced, READY True
kubectl -n dkm get secret db-test -o jsonpath='{.data}' | jq 'keys'   # ["dbname","host","password","port","username"]
```

**Prove the database is reachable from the cluster, and only from it:**

```bash
DB_HOST=$(kubectl -n dkm get secret db-test -o jsonpath='{.data.host}' | base64 -d)
kubectl -n dkm run mysql-check --rm -it --restart=Never --image=mysql:8.4 \
  --env="MYSQL_PWD=$(kubectl -n dkm get secret db-test -o jsonpath='{.data.password}' | base64 -d)" \
  -- mysql -h "$DB_HOST" -u shop_admin -e 'SELECT VERSION();'
# 8.4.x

# Same thing from your PC must fail: the database has no public address
nslookup "$DB_HOST"     # resolves to a 10.0.x.x private address
```

Clean up the test: `kubectl -n dkm delete externalsecret db-test`. Deleting it also deletes `db-test`.

### If something goes wrong

| Symptom | Fix |
|---|---|
| ClusterSecretStore `InvalidProviderConfig` / `AccessDenied` | The External Secrets Pod Identity ARN must end in `secret:dkm/*`. Check `aws iam get-role-policy` on the `dkm-external-secrets` role. |
| `ResourceExistsException: … dkm/db … scheduled for deletion` | A secret from a destroyed stack is waiting out its recovery window. `aws secretsmanager delete-secret --secret-id dkm/db --force-delete-without-recovery`, then apply again. |
| `mysql-check` hangs | Security group: the DB allows only the node security group. Check `module.eks.node_security_group_id` is attached to both node types. |

> ### 🛑 End of session
> Same as Phase 4 (delete `platform`, then `karpenter-nodes`, wait for nodes to go), then
> `scripts/tf.sh platform destroy`. The database and its secret are deleted too. Nothing to keep:
> Flyway recreates the schema next session.

**Next:** [Phase 6: CI pipeline](06-ci-pipeline.md)
