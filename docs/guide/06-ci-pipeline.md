# Phase 6: CI pipeline

**Goal:** a GitHub Actions workflow that, on every push to `remodelled`, scans for secrets, builds and tests, runs
SonarQube, builds a multi-arch image, scans it with Trivy, pushes it to ECR, signs it with Cosign, attaches an
SBOM, and commits the new image **digest** to the GitOps values file. Argo CD takes over from there. Pull
requests run the checks only and never touch AWS.

**Time:** 2–3 hours · **Cost:** $0 (GitHub-hosted runners are free for public repos; the cluster doesn't need to be running)

---

## 6.1 Why the step names matter

Your portfolio's live pipeline view lights up each box by finding a **word at the start of a word** in the
step names (see the portfolio README). The names below are chosen so every box matches exactly once:

| Diagram box | Word it looks for | Step that matches |
|---|---|---|
| GitHub | `checkout` | Checkout |
| Gitleaks | `gitleaks` | Gitleaks secret scan |
| SonarQube | `sonar` | SonarQube scan |
| Maven build | `maven` | Maven build and test |
| Docker Buildx | `docker` | Docker build |
| Trivy | `trivy` | Trivy image scan |
| Amazon ECR | `ecr` | Push image to ECR |
| Cosign + Syft | `cosign` | Cosign sign and attest SBOM |
| GitOps repo | `digest` | Bump image digest in GitOps values |
| Slack | `slack` | Notify Slack |

⚠️ **Helper steps are named so they don't match early.** For example "Registry login" rather than "Log in to
Amazon ECR", and "Install signing tool" rather than "Install Cosign". Otherwise the ECR box would turn green at
login, before anything is pushed.

---

## 6.2 One-time setup

### SonarQube Cloud

1. In sonarcloud.io: **+ → Analyze new project → dkojo/dkmwebapp → Set up**.
2. Choose **"With GitHub Actions"** as the analysis method.
3. ⚠️ Under **Administration → Analysis Method**, turn **Automatic Analysis off**. CI analysis and automatic
   analysis can't both run.
4. Copy the token it gives you, and note the **project key** (usually `dkojo_dkmwebapp`) and
   **organization key**.

### Slack incoming webhook

Slack → **Apps → Incoming Webhooks → Add to Slack → channel `#deployments`** → copy the webhook URL.

### Repository secrets

Credentials and anything containing your account ID go in **secrets**, which GitHub masks in logs:

```bash
gh secret set SONAR_TOKEN        --repo dkojo/dkmwebapp     # paste the SonarQube token
gh secret set SLACK_WEBHOOK_URL  --repo dkojo/dkmwebapp     # paste the webhook URL
gh secret set AWS_CI_ROLE_ARN    --repo dkojo/dkmwebapp \
  --body "$(scripts/tf.sh foundation output -raw ci_role_arn)"

gh variable set SONAR_PROJECT_KEY  --repo dkojo/dkmwebapp --body "dkojo_dkmwebapp"
gh variable set SONAR_ORGANIZATION --repo dkojo/dkmwebapp --body "‹your organization key›"
```

### The GitOps values file CI will update

Create `gitops/envs/prod/values.yaml` (Phase 7 uses it). CI only ever rewrites the `digest` and `version` lines:

```yaml
image:
  repository: ‹scripts/tf.sh foundation output -raw ecr_repository_url›
  digest: ""          # set by CI: sha256:…
  version: ""         # set by CI: short commit SHA, shown at /api/version
```

---

## 6.3 The workflow: `.github/workflows/ci.yml`

Every third-party action is pinned to the exact commit of its release (the comment shows the version).
Dependabot keeps them current (6.5).

```yaml
name: CI

on:
  push:
    branches: [remodelled]
    paths: ['app/**', '.github/workflows/ci.yml']
  pull_request:
    paths: ['app/**', '.github/workflows/ci.yml']
  workflow_dispatch:

permissions:
  contents: read

# One remodelled-branch run at a time, so two runs can't both commit a digest
concurrency:
  group: ci-${{ github.ref }}
  cancel-in-progress: ${{ github.event_name == 'pull_request' }}

env:
  IMAGE_NAME: dkmwebapp

jobs:
  pipeline:
    name: Build, scan, sign and publish
    runs-on: ubuntu-latest
    timeout-minutes: 30
    permissions:
      contents: write   # commit the new digest to gitops/
      id-token: write   # OIDC: AWS sign-in and Cosign keyless signing
    steps:
      - name: Checkout
        uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
        with:
          fetch-depth: 0   # full history for Gitleaks and SonarQube blame data

      - name: Gitleaks secret scan
        uses: gitleaks/gitleaks-action@e0c47f4f8be36e29cdc102c57e68cb5cbf0e8d1e # v3.0.0
        env:
          GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}

      - name: Set up JDK
        uses: actions/setup-java@77dd5b2ce225ea11469928ac317850245a74ae78 # v6.2.0
        with:
          distribution: temurin
          java-version: '21'
          cache: maven

      - name: Maven build and test
        working-directory: app
        run: ./mvnw -B verify

      - name: SonarQube scan
        if: env.SONAR_TOKEN != ''   # pull requests from forks get no secrets
        working-directory: app
        env:
          SONAR_TOKEN: ${{ secrets.SONAR_TOKEN }}
        run: >
          ./mvnw -B org.sonarsource.scanner.maven:sonar-maven-plugin:sonar
          -Dsonar.projectKey=${{ vars.SONAR_PROJECT_KEY }}
          -Dsonar.organization=${{ vars.SONAR_ORGANIZATION }}
          -Dsonar.host.url=https://sonarcloud.io
          -Dsonar.qualitygate.wait=true

      - name: Set up Buildx
        uses: docker/setup-buildx-action@f87e5991a6d7451dcb8d9637bfbc97413f497069 # v4.4.1

      - name: Docker build
        uses: docker/build-push-action@c3c9e263c25d99ce0380d002d59b67737d91b0dc # v7.4.0
        with:
          context: app
          platforms: linux/amd64
          load: true                          # into the runner's Docker, for Trivy
          tags: ${{ env.IMAGE_NAME }}:scan
          cache-from: type=gha
          cache-to: type=gha,mode=max

      - name: Trivy image scan
        uses: aquasecurity/trivy-action@ed142fd0673e97e23eac54620cfb913e5ce36c25 # v0.36.0
        with:
          image-ref: ${{ env.IMAGE_NAME }}:scan
          severity: CRITICAL,HIGH
          ignore-unfixed: true                # fail only on vulnerabilities that have a fix
          exit-code: '1'

      - name: Trivy IaC scan
        uses: aquasecurity/trivy-action@ed142fd0673e97e23eac54620cfb913e5ce36c25 # v0.36.0
        with:
          scan-type: config
          scan-ref: .
          skip-dirs: legacy-2024              # archived 2024 code, never deployed; accepted findings are in .trivyignore
          severity: CRITICAL,HIGH
          exit-code: '1'

      # Everything below runs only for pushes to remodelled: pull requests stop here

      - name: Configure AWS credentials
        if: github.event_name != 'pull_request'
        uses: aws-actions/configure-aws-credentials@e1253824e5c10ff9df46874f81ed3ec929e19cfd # v6.3.0
        with:
          role-to-assume: ${{ secrets.AWS_CI_ROLE_ARN }}
          role-session-name: dkm-ci-${{ github.run_id }}
          aws-region: us-east-1
          mask-aws-account-id: true

      - name: Registry login
        if: github.event_name != 'pull_request'
        id: registry
        uses: aws-actions/amazon-ecr-login@03f1aad4c6c7ffd436567f42f9384779290529bd # v2.1.7

      - name: Push image to ECR
        if: github.event_name != 'pull_request'
        id: push
        uses: docker/build-push-action@c3c9e263c25d99ce0380d002d59b67737d91b0dc # v7.4.0
        with:
          context: app
          platforms: linux/amd64,linux/arm64  # arm64 lets Karpenter use cheaper Graviton nodes
          push: true
          tags: ${{ steps.registry.outputs.registry }}/${{ env.IMAGE_NAME }}:${{ github.sha }}
          cache-from: type=gha
          provenance: mode=max                # SLSA build provenance attached to the image

      - name: Install signing tool
        if: github.event_name != 'pull_request'
        uses: sigstore/cosign-installer@756fe2d284c7292c4e9b62c8a28f1e5629c59532 # v4.1.3

      - name: Generate SBOM
        if: github.event_name != 'pull_request'
        uses: anchore/sbom-action@66cbf4bc1f1c0d2edc94016e65bc221b6bb0ad6c # v0.24.3
        with:
          image: ${{ steps.registry.outputs.registry }}/${{ env.IMAGE_NAME }}@${{ steps.push.outputs.digest }}
          format: spdx-json
          output-file: sbom.spdx.json
          upload-artifact: false

      - name: Cosign sign and attest SBOM
        if: github.event_name != 'pull_request'
        env:
          IMAGE: ${{ steps.registry.outputs.registry }}/${{ env.IMAGE_NAME }}@${{ steps.push.outputs.digest }}
        run: |
          # Keyless: the signature is tied to this workflow's GitHub identity, recorded in the public Rekor log
          cosign sign --yes "$IMAGE"
          cosign attest --yes --type spdxjson --predicate sbom.spdx.json "$IMAGE"

      - name: Bump image digest in GitOps values
        if: github.event_name != 'pull_request'
        env:
          DIGEST: ${{ steps.push.outputs.digest }}
        run: |
          short_sha="${GITHUB_SHA::7}"
          sed -i "s|^  digest: .*|  digest: \"${DIGEST}\"|; s|^  version: .*|  version: \"${short_sha}\"|" gitops/envs/prod/values.yaml
          git config user.name  "github-actions[bot]"
          git config user.email "41898282+github-actions[bot]@users.noreply.github.com"
          git add gitops/envs/prod/values.yaml
          git commit -m "Deploy dkmwebapp ${short_sha}" -m "Image digest ${DIGEST}"
          git pull --rebase origin remodelled
          git push origin HEAD:remodelled
          # Pushes made with GITHUB_TOKEN don't start new workflow runs, so this can't loop

      - name: Notify Slack
        if: always()                          # every run, push or PR, pass or fail
        uses: slackapi/slack-github-action@dcb1066f776dd043e64d0e8ba94ca15cc7e1875d # v4.0.0
        with:
          webhook: ${{ secrets.SLACK_WEBHOOK_URL }}
          webhook-type: incoming-webhook
          payload: |
            text: "${{ job.status == 'success' && '✅' || job.status == 'cancelled' && '⚪' || '❌' }} dkmwebapp CI *${{ job.status }}* · ${{ github.event_name == 'pull_request' && format('PR #{0}', github.event.number) || format('push to {0}', github.ref_name) }} by ${{ github.actor }} · ${{ github.server_url }}/${{ github.repository }}/actions/runs/${{ github.run_id }}"
```

### What the image's account ID exposure means

The ECR URL in `gitops/envs/prod/values.yaml` contains your account ID, and that file is public. AWS doesn't
treat account IDs as secrets: knowing one doesn't grant access. Credentials are the real risk, and there
are none anywhere in this repo. The workflow still masks the ID in logs (`mask-aws-account-id`), as good hygiene.

---

### Before the first run: make every gate pass on purpose

Run the same scanners locally first. A red first run teaches nothing; a finding you've read and decided on does.

```bash
# IaC: what the "Trivy IaC scan" step will see (skip your local module downloads, which CI doesn't have)
trivy config --severity CRITICAL,HIGH --exit-code 1 --skip-dirs legacy-2024 \
  --skip-dirs infra/platform/.terraform --skip-dirs infra/foundation/.terraform .

# Image: what the "Trivy image scan" step will see
docker build -t dkmwebapp:scan app
trivy image --severity CRITICAL,HIGH --ignore-unfixed --exit-code 1 dkmwebapp:scan

# Secrets in the whole history (the workflow's manual trigger scans all of it)
MSYS_NO_PATHCONV=1 docker run --rm -v "$(pwd -W):/repo" ghcr.io/gitleaks/gitleaks:latest git /repo --redact -v
```

For each finding, decide: **fix it**, or **accept it with a written reason**. The first run of this guide found:

| Finding | Decision |
|---|---|
| `app/Dockerfile`: image user is root (DS-0002) | **Fixed**: `USER 65532:65532` (Phase 1). Distroless `:nonroot` already ran as 65532, but scanners can't see that from the Dockerfile. |
| `ecr.tf`: mutable tags (AWS-0031) | **Accepted**: Cosign stores signatures as tags; deploys pin the digest. |
| EKS module: public API endpoint (AWS-0040) | **Accepted**: restricted to your /32. Production: private endpoint. |
| EKS module: unrestricted node egress (AWS-0104) | **Accepted**: nodes must reach ECR and AWS APIs; egress filtering is a firewall's job. |
| `legacy-2024/`: 30 findings | **Excluded** from the scan (`skip-dirs`): archived, never deployed. |
| Gitleaks: two `generic-api-key` hits in 2024 commits | **False positives**: a Secrets Manager ARN (an address, not a credential). Exact fingerprints in `.gitleaksignore`. |

`.trivyignore` (repo root):

```
# Accepted Trivy findings. Each one is deliberate; the reason is next to it.
# Re-check this list whenever the architecture changes.

# ECR tags are mutable on purpose: Cosign stores signatures as tags (sha256-<digest>.sig), and deploys pin
# image@sha256:<digest>, which can never point at different content. (infra/foundation/ecr.tf)
AVD-AWS-0031

# EKS API endpoint is public but restricted to the admin's /32 (admin_cidrs). Production: private endpoint
# reached through a VPN or SSM. (terraform-aws-modules/eks)
AVD-AWS-0040

# Node security group allows all egress: nodes must reach ECR, AWS APIs and image registries. Egress
# filtering belongs in a network firewall or proxy, not in node security groups. (terraform-aws-modules/eks)
AVD-AWS-0104
```

`.gitleaksignore` (repo root) lists **exact fingerprints**, never whole rules or files, so a new leak still fails:

```
# False positives, reviewed ‹date›: Secrets Manager ARNs (identifiers, not credentials) in 2024 commits.
‹commit›:terraform/rds/main.tf:generic-api-key:6
```

⚠️ An ignore file is a list of decisions, not a mute button. Each line needs a reason a reviewer would accept.

---

## 6.4 Run it

```bash
git add .github gitops/envs app/Dockerfile .trivyignore .gitleaksignore
git commit -m "Add CI pipeline: scan, build, sign, publish and bump digest"
git push
gh run watch
```

The first run takes 6–10 minutes; later runs are faster because of the Docker and Maven caches.

---

## ✅ Phase 6 checkpoint

```bash
gh run list --workflow ci.yml --limit 1      # ✓ completed  success
git pull                                     # brings in the bot's "Deploy dkmwebapp ‹sha›" commit
grep -E 'digest|version' gitops/envs/prod/values.yaml     # digest: "sha256:…"  version: "‹short sha›"

# The image is signed by this workflow, on remodelled:
IMAGE="$(scripts/tf.sh foundation output -raw ecr_repository_url)@$(grep digest gitops/envs/prod/values.yaml | cut -d'"' -f2)"
aws ecr get-login-password | docker login --username AWS --password-stdin "${IMAGE%%/*}"
cosign verify "$IMAGE" \
  --certificate-identity-regexp '^https://github.com/dkojo/dkmwebapp/\.github/workflows/ci\.yml@refs/heads/remodelled$' \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com | jq '.[0].optional.Subject'
# "https://github.com/dkojo/dkmwebapp/.github/workflows/ci.yml@refs/heads/remodelled"

docker manifest inspect "$IMAGE" | jq -r '.manifests[].platform.architecture' | sort -u   # amd64 arm64 (+ unknown = attestations)
```

Also check: SonarQube Cloud shows the project with a **Passed** quality gate, and `#deployments` got a ✅ message.

**Prove the gates work** on a branch, through a pull request:

1. Add a fake AWS key to a file, for example `app/src/main/resources/test.txt` containing
   `AKIAIOSFODNN7EXAMPLE` and a matching-looking secret. Open a PR. **Gitleaks fails.** Close the PR and delete the branch.
2. In another PR, change the runtime image in `app/Dockerfile` to an old one, for example
   `eclipse-temurin:17-jre-focal`. **Trivy fails** on known CVEs. Take a screenshot of this for the portfolio, then close the PR.

### If something goes wrong

| Symptom | Fix |
|---|---|
| `Not authorized to perform sts:AssumeRoleWithWebIdentity` | The trust condition doesn't match the token. Compare `gh api repos/dkojo/dkmwebapp/actions/oidc/customization/sub` with `github_oidc_subject_prefix` in `infra/foundation/envs/prod.tfvars`. |
| SonarQube: `You are running CI analysis while Automatic Analysis is enabled` | Turn Automatic Analysis off (6.2). |
| SonarQube quality gate fails on coverage | Expected at first if tests are thin. Add tests, or adjust the gate in SonarQube Cloud (Quality Gates). |
| Bump step: `! [rejected] … (fetch first)` | Another commit landed. The `git pull --rebase` should handle it; re-run the job if two runs overlapped. |
| Trivy IaC scan fails on Terraform findings | Read them. Many are real (for example "no VPC flow logs"). Fix them, or add a justified entry to `.trivyignore`. |

---

## 6.5 Dependabot: `.github/dependabot.yml`

```yaml
version: 2
updates:
  - package-ecosystem: maven
    directory: /app
    schedule: { interval: weekly }
    groups:
      minor-and-patch: { update-types: [minor, patch] }
  - package-ecosystem: docker
    directory: /app
    schedule: { interval: weekly }
  - package-ecosystem: github-actions
    directory: /
    schedule: { interval: weekly }
  - package-ecosystem: terraform
    directories: [/infra/foundation, /infra/platform]
    schedule: { interval: monthly }
```

```bash
git add .github/dependabot.yml && git commit -m "Add Dependabot" && git push
```

⚠️ **Dependabot reads this file only from the repo's default branch (`main`).** While the rebuild lives on
`remodelled`, the file is there but Dependabot ignores it. It switches on when `remodelled` becomes the
default branch or is merged into `main` (Phase 12). Until then, the pinned versions simply stay as they are.

**Next:** [Phase 7: Deploy the app](07-deploy-app.md)
