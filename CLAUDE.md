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
│   └── platform/       # Shared module: all resource definitions live here (ECR, OIDC, IAM)
├── sandbox/            # Thin wrapper: calls modules/platform for the sandbox account
└── prd/                # Thin wrapper: calls modules/platform for the prd account
```

Resource definitions (ECR repos, IAM roles, OIDC provider) live **only** in `modules/platform/`.
The `sandbox/` and `prd/` directories contain only provider config, backend config, variable
declarations, and module calls — no resource blocks. Adding a new app means editing the module
once; both environments pick it up.

## Running Terraform

### bootstrap (already applied — do not re-run unless recreating from scratch)

```sh
cd terraform/bootstrap
export AWS_PROFILE=<your-mgmt-profile>
cp terraform.tfvars.example terraform.tfvars   # fill in real values
terraform init
terraform apply
```

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
The 4-step workflow is: infrabase apply → set GitHub secret → push image → app apply.

### Step 1 — infrabase: edit the shared module, then apply

All resource definitions live in `terraform/modules/platform/`. You never touch
`sandbox/` or `prd/` resource files — they don't have any.

**`terraform/modules/platform/ecr.tf`** — add ECR repository + lifecycle policy:

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
```

**`terraform/modules/platform/iam_github.tf`** — add role + policy (reuses the existing
`aws_iam_openid_connect_provider.github` resource):

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
      { Sid = "ECRAuth", Effect = "Allow", Action = "ecr:GetAuthorizationToken", Resource = "*" },
      {
        Sid      = "ECRPush"
        Effect   = "Allow"
        Action   = ["ecr:BatchCheckLayerAvailability","ecr:GetDownloadUrlForLayer","ecr:BatchGetImage","ecr:InitiateLayerUpload","ecr:UploadLayerPart","ecr:CompleteLayerUpload","ecr:PutImage"]
        Resource = aws_ecr_repository.exampleapp.arn
      },
      {
        Sid      = "LambdaDeploy"
        Effect   = "Allow"
        Action   = ["lambda:UpdateFunctionCode","lambda:GetFunctionConfiguration"]
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

**`terraform/modules/platform/outputs.tf`** — add two outputs:
```hcl
output "exampleapp_ecr_repository_url" {
  value = aws_ecr_repository.exampleapp.repository_url
}
output "exampleapp_github_actions_role_arn" {
  value = aws_iam_role.github_actions_exampleapp.arn
}
```

**Wire the new variable in each environment wrapper** — same edit in both `sandbox/` and `prd/`:

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

**Add real values to your local `terraform.tfvars` in both `sandbox/` and `prd/`** (gitignored):
```
github_repo_exampleapp = "<owner>/exampleapp"
```

**Also add pass-through outputs in `sandbox/outputs.tf` and `prd/outputs.tf`:**
```hcl
output "exampleapp_ecr_repository_url" {
  value = module.platform.exampleapp_ecr_repository_url
}
output "exampleapp_github_actions_role_arn" {
  value = module.platform.exampleapp_github_actions_role_arn
}
```

**Apply sandbox first:**
```sh
cd terraform/sandbox
terraform apply
terraform output exampleapp_github_actions_role_arn   # copy this value
```

### Step 2 — App repo: set GitHub Actions secret

GitHub repo → Settings → Secrets and variables → Actions → environment `sandbox`:
Add `AWS_ROLE_ARN` = (output from step 1)

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

| App | infrabase outputs used |
|---|---|
| balance-tracker | `balance_tracker_ecr_repository_url`, `balance_tracker_github_actions_role_arn` |

ECR URLs are stable — they only change if the repository is destroyed and recreated.

## Tearing down a sandbox app

```sh
cd terraform/infra   # in the app repo
terraform destroy -var-file=environments/sandbox.tfvars
```

ECR and the GitHub Actions role remain in infrabase. To bring back up, ensure
an image exists in ECR (re-push if needed), then `terraform apply`.
