# infrabase

Central AWS infrastructure management repo.

## The mental model

**infrabase answers: "does this app have a place to live in AWS?"**
It owns the resources that exist independently of any specific deployment:
where container images are stored (ECR), and who is allowed to push them and
update the running app (GitHub Actions IAM role).

**The app repo answers: "what does the app need to run?"**
It owns everything specific to that app: the Lambda function and its config,
API Gateway, EventBridge scheduler, secrets, and runtime environment.

This split means infrabase changes rarely (only when onboarding a new app),
while app repos change freely without touching shared infrastructure.

## Workflow for a new app

1. **infrabase** — add ECR repo + GitHub Actions role, apply (~2 min)
2. **App repo** — add `AWS_ROLE_ARN` GitHub secret, `git push` to push first image to ECR
3. **App repo** — build out `terraform/infra/` in the app repo (it has the context on what the app needs), then `terraform apply`

Step 3 is done entirely from within the app repo. infrabase has no opinion on
how the app runs — only that it has a container registry and deploy credentials.

---

## Architecture overview

```
infrabase (this repo)               app repo (e.g. exampleapp)
─────────────────────               ──────────────────────────────────
terraform/bootstrap/                terraform/infra/
  S3 state bucket                     Lambda function
  DynamoDB lock table                 API Gateway
                                      EventBridge scheduler
terraform/sandbox/                    IAM execution role
terraform/prd/
  ECR repository (per app)
  GitHub Actions OIDC provider      GitHub Actions workflow
  GitHub Actions IAM role (per app)   push to main → sandbox
                                      push v* tag  → prd
```

infrabase applies first. App repos depend on its outputs (ECR URL, IAM role ARN).

---

## Deploying a new app to sandbox

### Step 1 — infrabase: add ECR + GitHub Actions role

**`terraform/sandbox/ecr.tf`** — add a repository block:

```hcl
resource "aws_ecr_repository" "exampleapp" {
  name                 = "exampleapp"
  image_tag_mutability = "MUTABLE"
  force_delete         = true

  image_scanning_configuration {
    scan_on_push = true
  }
}

resource "aws_ecr_lifecycle_policy" "exampleapp" {
  repository = aws_ecr_repository.exampleapp.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Expire untagged images after 7 days"
        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = 7
        }
        action = { type = "expire" }
      },
      {
        rulePriority = 2
        description  = "Keep last 10 tagged images"
        selection = {
          tagStatus   = "any"
          countType   = "imageCountMoreThan"
          countNumber = 10
        }
        action = { type = "expire" }
      }
    ]
  })
}
```

**`terraform/sandbox/iam_github.tf`** — add a role block:

```hcl
resource "aws_iam_role" "github_actions_exampleapp" {
  name = "exampleapp-sandbox-github-actions"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Federated = aws_iam_openid_connect_provider.github.arn
      }
      Action = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
        }
        StringLike = {
          "token.actions.githubusercontent.com:sub" = "repo:${var.github_repo_exampleapp}:*"
        }
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
        Sid      = "ECRAuth"
        Effect   = "Allow"
        Action   = "ecr:GetAuthorizationToken"
        Resource = "*"
      },
      {
        Sid    = "ECRPush"
        Effect = "Allow"
        Action = [
          "ecr:BatchCheckLayerAvailability",
          "ecr:GetDownloadUrlForLayer",
          "ecr:BatchGetImage",
          "ecr:InitiateLayerUpload",
          "ecr:UploadLayerPart",
          "ecr:CompleteLayerUpload",
          "ecr:PutImage",
        ]
        Resource = aws_ecr_repository.exampleapp.arn
      },
      {
        Sid    = "LambdaDeploy"
        Effect = "Allow"
        Action = [
          "lambda:UpdateFunctionCode",
          "lambda:GetFunctionConfiguration",
        ]
        Resource = "arn:aws:lambda:${var.aws_region}:${data.aws_caller_identity.current.account_id}:function:exampleapp-*"
      },
    ]
  })
}
```

**`terraform/sandbox/variables.tf`** — add:

```hcl
variable "github_repo_exampleapp" {
  description = "GitHub repository for exampleapp in owner/repo format (used for OIDC trust policy)"
  type        = string
}
```

**`terraform/sandbox/terraform.tfvars.example`** — add:

```
github_repo_exampleapp = "<github-owner>/exampleapp"
```

**`terraform/sandbox/outputs.tf`** — add:

```hcl
output "exampleapp_ecr_repository_url" {
  description = "ECR repository URL for exampleapp container images"
  value       = aws_ecr_repository.exampleapp.repository_url
}

output "exampleapp_github_actions_role_arn" {
  description = "IAM role ARN for exampleapp GitHub Actions to assume via OIDC"
  value       = aws_iam_role.github_actions_exampleapp.arn
}
```

**Apply:**

```sh
cd terraform/sandbox
# add github_repo_exampleapp = "<owner>/exampleapp" to your terraform.tfvars
terraform apply
```

Note the two outputs — you'll need them in the next steps:
- `exampleapp_ecr_repository_url`
- `exampleapp_github_actions_role_arn`

---

### Step 2 — App repo: set GitHub Actions secret

In the exampleapp GitHub repo → Settings → Secrets and variables → Actions:

Add secret: `AWS_ROLE_ARN` = value of `exampleapp_github_actions_role_arn` output

---

### Step 3 — App repo: push to trigger CI

```sh
git push
```

The GitHub Actions workflow builds the Docker image and pushes it to ECR.
The Lambda update step will fail (Lambda doesn't exist yet) — that's expected
on the very first push.

---

### Step 4 — App repo: apply infrastructure

```sh
cd terraform/infra
cp backend.hcl.example backend.hcl            # fill in real values
cp terraform.tfvars.example terraform.tfvars  # fill in secrets
terraform init -backend-config=backend.hcl
terraform apply -var-file=environments/sandbox.tfvars
```

The image is already in ECR from Step 3, so Lambda creates cleanly.
The `api_gateway_url` output is the live app URL.

From this point on, every `git push` builds and deploys automatically.

---

## Tearing down a sandbox app

To shut down an app and remove all its AWS resources (ECR and GitHub Actions
role remain in infrabase — no re-bootstrap needed to bring it back):

```sh
cd terraform/infra   # in the app repo
terraform destroy -var-file=environments/sandbox.tfvars
```

To bring it back up, ensure an image exists in ECR (re-push if needed) then:

```sh
terraform apply -var-file=environments/sandbox.tfvars
```

---

## What app repos need

For an app to follow this pattern it needs:

**`terraform/infra/`** — Terraform module managing:
- Lambda function (container image, `package_type = "Image"`)
- API Gateway HTTP API + default stage + Lambda integration + route
- Lambda IAM execution role
- EventBridge scheduler (optional)
- `data "aws_ecr_repository"` lookup (ECR is owned by infrabase, not the app)

**`terraform/infra/backends/sandbox.hcl.example`** — S3 backend config pointing
to the infrabase state bucket, key: `<app-name>/sandbox/terraform.tfstate`

**`terraform/infra/environments/sandbox.tfvars`** — committed, non-secret config
(region, environment name, feature flags, etc.)

**`terraform/infra/terraform.tfvars.example`** — template for gitignored secrets
(DB URL, API keys, `target_role_arn`, etc.)

**GitHub Actions workflow** — builds Docker image, pushes to ECR, updates Lambda.
Authenticates to AWS via OIDC using the `AWS_ROLE_ARN` secret.
