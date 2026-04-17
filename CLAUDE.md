# infrabase

Central AWS infrastructure management repo. Owns platform-level resources that
application repos depend on (state backend, ECR, cross-account IAM, etc.).
Application-specific infrastructure (Lambda, API Gateway, EventBridge) stays in
the app repos.

---

## Security — read this first

**This repo is public on GitHub. Never commit secrets or identifiable data.**

Rules:
- **No account IDs, role ARNs, bucket names, or real resource identifiers in committed files.**
  Use `<placeholder>` syntax in `.example` files.
- **No AWS profile names, usernames, or other personal identifiers** in committed files.
- **All `.tfvars` and `.hcl` files are gitignored** — they hold your real values locally.
  Only `.tfvars.example` and `.hcl.example` files are committed, with placeholders only.
- **`memory/` is gitignored** — internal notes never leave your machine.
- Before committing: `git diff --staged` and grep for account IDs, ARNs, email addresses,
  and real resource names. If in doubt, leave it out.

---

## Account structure

| Account | Role |
|---|---|
| Management account | Runs Terraform; owns the state backend |
| sandbox | Deployment target for sandbox workloads |
| prd | Deployment target for production workloads |

AWS credentials come from your local profile configuration — not committed anywhere.

## Terraform state

All state lives in S3 — created once by `terraform/bootstrap` and never recreated.

- **Bucket:** `tfstate-<mgmt-account-id>` (us-west-2)
- **Lock table:** `terraform-state-lock` (DynamoDB, same region)

State keys follow the pattern `<module>/terraform.tfstate`.

## Module layout

```
terraform/
├── bootstrap/          # One-time setup: S3 bucket + DynamoDB lock table (management account)
├── modules/
│   ├── mgmt/           # Management account resources: ECR repos, ECR resource policies, ECR push IAM roles
│   └── platform/       # Workload account resources: GitHub OIDC provider, Lambda deploy IAM roles
├── mgmt/               # Thin wrapper: calls modules/mgmt for the management account (no assume_role)
├── sandbox/            # Thin wrapper: calls modules/platform for the sandbox account
└── prd/                # Thin wrapper: calls modules/platform for the prd account
```

All four environment directories (`mgmt/`, `sandbox/`, `prd/`, and one-time `bootstrap/`) are thin
wrappers — provider config, backend config, variable declarations, and a module call. No resource
blocks live in environment directories.

Two modules, each with a distinct concern:
- **`modules/mgmt/`** — ECR repositories and cross-account pull policies live here. Central image
  registry; applies once to the management account.
- **`modules/platform/`** — GitHub OIDC provider and Lambda deploy IAM roles live here. Per-environment;
  both `sandbox/` and `prd/` call this module independently.

Adding a new app means editing both modules once. The `mgmt/` environment picks up the new ECR repo;
both `sandbox/` and `prd/` pick up the new Lambda deploy role automatically.

## Running Terraform

### bootstrap (already applied — do not re-run unless recreating from scratch)

```sh
cd terraform/bootstrap
export AWS_PROFILE=<your-mgmt-profile>
cp terraform.tfvars.example terraform.tfvars   # fill in real values
terraform init
terraform apply
```

### mgmt

```sh
cd terraform/mgmt
export AWS_PROFILE=<your-mgmt-profile>
cp backend.hcl.example backend.hcl            # fill in real values
cp terraform.tfvars.example terraform.tfvars  # fill in real values
terraform init -backend-config=backend.hcl
terraform plan
terraform apply
```

No `assume_role` — Terraform runs directly in the management account.

### sandbox

```sh
cd terraform/sandbox
export AWS_PROFILE=<your-mgmt-profile>
cp backend.hcl.example backend.hcl            # fill in real values
cp terraform.tfvars.example terraform.tfvars  # fill in real values
terraform init -backend-config=backend.hcl
terraform plan
terraform apply
```

### prd

```sh
cd terraform/prd
export AWS_PROFILE=<your-mgmt-profile>
cp backend.hcl.example backend.hcl            # fill in real values
cp terraform.tfvars.example terraform.tfvars  # fill in real values
terraform init -backend-config=backend.hcl
terraform plan
terraform apply
```

`target_role_arn` is the IAM role in the target account that Terraform assumes
to create resources. Keep `terraform.tfvars` and `backend.hcl` out of git (they are
gitignored).

---

## Adding a new app (exampleapp walkthrough)

This is the full procedure. Substitute `exampleapp` with the real app name.

CI uses **two IAM roles**: one in the management account to push images to the central ECR, and
one in each workload account to deploy the Lambda. Both are created here in infrabase.

### Step 1a — infrabase: edit modules/mgmt/ (ECR + ECR push role)

**`terraform/modules/mgmt/ecr.tf`** — add ECR repository + lifecycle policy + update the resource policy principal list:

```hcl
# ── exampleapp ────────────────────────────────────────────────────────────────

resource "aws_ecr_repository" "exampleapp" {
  name                 = "exampleapp"
  image_tag_mutability = "MUTABLE"
  force_delete         = true
  image_scanning_configuration { scan_on_push = true }
}

resource "aws_ecr_lifecycle_policy" "exampleapp" {
  repository = aws_ecr_repository.exampleapp.name
  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Expire untagged images after 7 days"
        selection    = { tagStatus = "untagged", countType = "sinceImagePushed", countUnit = "days", countNumber = 7 }
        action       = { type = "expire" }
      },
      {
        rulePriority = 2
        description  = "Keep last 10 tagged images"
        selection    = { tagStatus = "any", countType = "imageCountMoreThan", countNumber = 10 }
        action       = { type = "expire" }
      }
    ]
  })
}

resource "aws_ecr_repository_policy" "exampleapp" {
  repository = aws_ecr_repository.exampleapp.name
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid    = "AllowCrossAccountPull"
      Effect = "Allow"
      Principal = {
        AWS = [
          "arn:aws:iam::${var.sandbox_account_id}:root",
          "arn:aws:iam::${var.prd_account_id}:root",
        ]
      }
      Action = [
        "ecr:GetDownloadUrlForLayer",
        "ecr:BatchGetImage",
        "ecr:BatchCheckLayerAvailability",
      ]
    }]
  })
}
```

**`terraform/modules/mgmt/iam_github.tf`** — add ECR push role (reuses the existing OIDC provider):

```hcl
# ── exampleapp ────────────────────────────────────────────────────────────────

resource "aws_iam_role" "github_actions_exampleapp_ecr_push" {
  name = "exampleapp-ecr-push-github-actions"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = aws_iam_openid_connect_provider.github.arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = { "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com" }
        StringLike   = { "token.actions.githubusercontent.com:sub" = "repo:${var.github_repo_exampleapp}:*" }
      }
    }]
  })
}

resource "aws_iam_role_policy" "github_actions_exampleapp_ecr_push" {
  name = "ecr-push"
  role = aws_iam_role.github_actions_exampleapp_ecr_push.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      { Sid = "ECRAuth", Effect = "Allow", Action = "ecr:GetAuthorizationToken", Resource = "*" },
      {
        Sid    = "ECRPush"
        Effect = "Allow"
        Action = ["ecr:BatchCheckLayerAvailability","ecr:GetDownloadUrlForLayer","ecr:BatchGetImage","ecr:InitiateLayerUpload","ecr:UploadLayerPart","ecr:CompleteLayerUpload","ecr:PutImage"]
        Resource = aws_ecr_repository.exampleapp.arn
      },
    ]
  })
}
```

**`terraform/modules/mgmt/variables.tf`** — add:
```hcl
variable "github_repo_exampleapp" {
  description = "GitHub repository for exampleapp in owner/repo format"
  type        = string
}
```

**`terraform/modules/mgmt/outputs.tf`** — add two outputs:
```hcl
output "exampleapp_ecr_repository_url" {
  value = aws_ecr_repository.exampleapp.repository_url
}
output "exampleapp_ecr_push_role_arn" {
  description = "IAM role ARN for exampleapp GitHub Actions to push images to central ECR"
  value = aws_iam_role.github_actions_exampleapp_ecr_push.arn
}
```

**Wire the variable in `mgmt/`:**

`mgmt/main.tf` — add to the module call:
```hcl
github_repo_exampleapp = var.github_repo_exampleapp
```

`mgmt/variables.tf` — add:
```hcl
variable "github_repo_exampleapp" {
  description = "GitHub repository for exampleapp in owner/repo format"
  type        = string
}
```

`mgmt/terraform.tfvars.example` — add placeholder line:
```
github_repo_exampleapp = "<github-owner>/exampleapp"
```

`mgmt/outputs.tf` — add pass-through outputs:
```hcl
output "exampleapp_ecr_repository_url" {
  value = module.mgmt.exampleapp_ecr_repository_url
}
output "exampleapp_ecr_push_role_arn" {
  value = module.mgmt.exampleapp_ecr_push_role_arn
}
```

**Apply mgmt:**
```sh
cd terraform/mgmt
terraform init -backend-config=backend.hcl
terraform apply
terraform output exampleapp_ecr_repository_url      # copy — needed for app repo Terraform
terraform output exampleapp_ecr_push_role_arn       # copy — needed for AWS_ECR_PUSH_ROLE_ARN secret
```

### Step 1b — infrabase: edit modules/platform/ (Lambda deploy role)

**`terraform/modules/platform/iam_github.tf`** — add Lambda deploy role (reuses the existing OIDC provider):

```hcl
# ── exampleapp ────────────────────────────────────────────────────────────────

resource "aws_iam_role" "github_actions_exampleapp" {
  name = "exampleapp-${var.environment}-github-actions"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = aws_iam_openid_connect_provider.github.arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = { "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com" }
        StringLike   = { "token.actions.githubusercontent.com:sub" = "repo:${var.github_repo_exampleapp}:*" }
      }
    }]
  })
}

resource "aws_iam_role_policy" "github_actions_exampleapp" {
  name = "deploy"
  role = aws_iam_role.github_actions_exampleapp.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "LambdaDeploy"
        Effect = "Allow"
        Action = ["lambda:UpdateFunctionCode","lambda:GetFunctionConfiguration"]
        Resource = "arn:aws:lambda:${var.aws_region}:${data.aws_caller_identity.current.account_id}:function:exampleapp-*"
      },
    ]
  })
}
```

**`terraform/modules/platform/variables.tf`** — add:
```hcl
variable "github_repo_exampleapp" {
  description = "GitHub repository for exampleapp in owner/repo format"
  type        = string
}
```

**`terraform/modules/platform/outputs.tf`** — add output:
```hcl
output "exampleapp_deploy_role_arn" {
  description = "IAM role ARN for exampleapp GitHub Actions to deploy Lambda"
  value = aws_iam_role.github_actions_exampleapp.arn
}
```

**Wire the variable in both `sandbox/` and `prd/`** — same edit in each:

`sandbox/main.tf` and `prd/main.tf` — add to the module call:
```hcl
github_repo_exampleapp = var.github_repo_exampleapp
```

`sandbox/variables.tf` and `prd/variables.tf` — add:
```hcl
variable "github_repo_exampleapp" {
  description = "GitHub repository for exampleapp in owner/repo format"
  type        = string
}
```

`sandbox/terraform.tfvars.example` and `prd/terraform.tfvars.example` — add placeholder line:
```
github_repo_exampleapp = "<github-owner>/exampleapp"
```

`sandbox/outputs.tf` and `prd/outputs.tf` — add pass-through output:
```hcl
output "exampleapp_deploy_role_arn" {
  value = module.platform.exampleapp_deploy_role_arn
}
```

**Apply sandbox:**
```sh
cd terraform/sandbox
terraform init -backend-config=backend.hcl
terraform apply
terraform output exampleapp_deploy_role_arn           # copy — needed for AWS_DEPLOY_ROLE_ARN secret
```

### Step 2 — App repo: set GitHub Actions secrets

GitHub repo → Settings → Secrets and variables → Actions → environment `sandbox`:
- `AWS_ECR_PUSH_ROLE_ARN` = ECR push role ARN (from mgmt output)
- `AWS_DEPLOY_ROLE_ARN` = Lambda deploy role ARN (from sandbox output)

### Step 3 — App repo: push to trigger CI (pushes first image to ECR)

```sh
git push
```

The Lambda update step in CI will fail on first push (Lambda doesn't exist yet).
That's expected — the image landing in ECR is all that's needed.

### Step 4 — App repo: apply infrastructure

```sh
cd terraform/infra
cp backends/sandbox.hcl.example backends/sandbox.hcl
cp environments/sandbox.tfvars.example environments/sandbox.tfvars   # fill in secrets + target_role_arn
terraform init -backend-config=backends/sandbox.hcl
terraform apply -var-file=environments/sandbox.tfvars
```

App is live. `api_gateway_url` output is the URL. Every subsequent `git push`
builds and deploys automatically.

---

## Cross-repo relationships

| App | Output | Source environment |
|---|---|---|
| balance-tracker | `balance_tracker_ecr_repository_url` | `mgmt/` |
| balance-tracker | `balance_tracker_ecr_push_role_arn` | `mgmt/` |
| balance-tracker | `balance_tracker_deploy_role_arn` | `sandbox/` or `prd/` |

ECR URLs are stable — they only change if the repository is destroyed and recreated.

## Tearing down a sandbox app

```sh
cd terraform/infra   # in the app repo
terraform destroy -var-file=environments/sandbox.tfvars
```

ECR and the GitHub Actions role remain in infrabase. To bring back up, ensure
an image exists in ECR (re-push if needed), then `terraform apply`.
