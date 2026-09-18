# 🏛️ Camara & Senado Data Infrastructure

![Terraform CI](https://github.com/DamodaraBarbosa/camara-senado-data-infra/actions/workflows/terraform.yml/badge.svg)
![Terraform](https://img.shields.io/badge/Terraform-1.14.7-844FBA?logo=terraform&logoColor=white)
![IaC](https://img.shields.io/badge/IaC-Terraform-844FBA)
![Cloud](https://img.shields.io/badge/Cloud-AWS-FF9900?logo=amazonaws&logoColor=white)

This repository contains the Infrastructure as Code (IaC) to manage the data platform for the Chamber of Deputies and the Senate. It uses Terraform to provision AWS resources (or LocalStack for local development) and includes a CI/CD pipeline via GitHub Actions with OIDC authentication.

## 📁 Project Structure

- `environments/`: Environment-specific Terraform configurations (each with its own S3 backend).
  - `dev/`: Development environment (real AWS, not LocalStack).
    - `main.tf`: 433 lines, provisions buckets, Glue, ECR, IAM, ECS cluster and task definition.
    - `variables.tf`, `provider.tf`, `locals.tf`.
  - `prod/`: Production environment (real AWS).
    - `main.tf`: 691 lines, same as dev plus prod-only resources.
    - `budgets.tf`: Monthly cost budget with SNS notification.
    - `lambda_cost_report.tf`: Lambda function and EventBridge weekly schedule for cost reports.
    - `ec2_credit_activity.tf`: Ephemeral EC2 instance (t4g.micro) for Free Tier credit activity (disabled by default).
    - `variables.tf`, `provider.tf`, `locals.tf`.
- `global/`: Account-wide IAM resources (manually applied, not in CI).
  - `github_oidc.tf`: GitHub Actions OIDC provider for keyless CI/CD auth.
  - `groups_users.tf`: IAM groups and users (`tech_leadership`, `analytics_engineers`, `data_engineers`, `bi_users`).
  - `variables.tf`, `provider.tf`, `locals.tf`.
- `modules/`: Empty directories (unused; all resources are self-contained in root modules).
- `utils/`: Helper scripts.
  - `list_iam.py`: Visualizes IAM hierarchy using boto3 + LocalStack endpoint (legacy, not in use).
  - `requirements.txt`: Python dependencies.
- `docker-compose.yml`: Old LocalStack service config (obsolete, kept for reference only).
- `.github/workflows/`: GitHub Actions CI/CD pipeline.
- `.claude/`: Claude Code setup.
  - `CLAUDE.md`: Repository conventions and commands.
  - `rules/`: Path-scoped rules for Terraform, IAM, CI/CD, Python utilities.
  - `settings.json`: Security guardrails and permission denies.

## 🏗️ Infrastructure Overview

Each environment (`dev` and `prod`) provisions the following AWS resources:

### 🗄️ Storage & Catalog
- **S3 Buckets**: One per catalog (`camara`, `senado`), named `dataplatform-{catalog}-{environment}-db`.
- **AWS Glue Catalog Databases**: One per bucket and schema layer (`raw`, `staging`, `intermediate`, `marts`), enabling queryable data structures.

### 🐳 Container Registry
- **ECR Repositories**: Docker image storage for the data ingestion pipeline, with a lifecycle policy retaining only the 2 most recent images.

### 🔐 Access Control

IAM roles with scoped permissions:

| Role | S3 + Glue | ECR |
|---|---|---|
| `tech_leadership` | Read-write | Read-write |
| `analytics_engineers` | Read-write | Read-write |
| `data_engineers` | Read-write | Read-write |
| `sp_bi` | Read-only | Read-only |
| `sp_ci` | Read-write | Read-write |
| `sp_env` | Read-write | Read-write |
| `airflow` | Read-write | — |

**GitHub Actions CI/CD Role**: Assumed via OIDC (no static AWS keys); scoped to `PowerUserAccess` + tightly-restricted IAM permissions for resource management.

### ⚙️ Data Ingestion Pipeline
- **ECS Fargate Cluster**: Orchestrates containerized data processing tasks.
- **ECS Task Definition**: Python 3.11 container provisioned with Airflow role; logs to CloudWatch. Meant to be invoked by an external orchestrator (e.g., an Airflow `EcsRunTaskOperator`).

## ✅ Prerequisites

- 🧱 [Terraform](https://www.terraform.io/) (v1.10+; CI pins 1.14.7)
- ☁️ [AWS CLI](https://aws.amazon.com/cli/) with credentials for dev and prod AWS accounts
- 🐍 [Python 3.x](https://www.python.org/) (optional, only for utility scripts)
- 🔑 AWS IAM roles for GitHub Actions OIDC (configured in GitHub repository settings)

## 🛠️ Installation & Setup

### 1. Remote Backend Buckets

Three S3 state buckets are manually provisioned (outside Terraform):

| Root | State Bucket | State Key |
|---|---|---|
| `global/` | `dataplatform-terraform-state-<account>-global` | `global/terraform.tfstate` |
| `environments/dev` | `dataplatform-terraform-state-<account>-dev` | `dev/terraform.tfstate` |
| `environments/prod` | `dataplatform-terraform-state-<account>-prod` | `prod/terraform.tfstate` |

Each bucket must exist before running `terraform init`. Contact your AWS admin if missing.

### 2. AWS Credentials

Export AWS credentials for the target account:

```bash
export AWS_DEFAULT_REGION=us-east-1
# Either:
export AWS_ACCESS_KEY_ID=...
export AWS_SECRET_ACCESS_KEY=...
# OR:
aws sso login --profile <profile-name>
export AWS_PROFILE=<profile-name>
```

### 3. Terraform Workflow

For **dev environment**:

```bash
cd environments/dev
terraform init                    # Requires state bucket + AWS creds
terraform validate               # Check syntax
terraform plan -out=tfplan.dev   # Preview changes
terraform apply tfplan.dev       # Apply (local testing only — CI applies on merge)
```

For **prod environment**: same pattern, working directory `environments/prod`. **Never apply locally to prod.** Use CI.

### 4. Global (Manual Bootstrap)

To initialize account-wide IAM and OIDC:

```bash
cd global
terraform init
terraform validate
terraform apply                   # Manual only; not in CI
```

This must run before dev/prod can authenticate via OIDC in CI.

### 5. Python Environment (Optional)

For utility scripts only (not required for Terraform):

```bash
python3 -m venv venv
source venv/bin/activate
pip install -r requirements.txt
```

**Note:** `utils/list_iam.py` targets LocalStack (no longer in use). It is kept for reference.

## 🔄 CI/CD with GitHub Actions

`.github/workflows/terraform.yml` is the only workflow. It uses Terraform to apply changes via keyless OIDC authentication (no static AWS credentials stored).

### ⚡ Workflow Behavior

| Trigger | Job | Environment | Auto-Apply | Role |
|---|---|---|---|---|
| Push/PR to `develop` | `terraform-dev` | `development` (no gate) | Push only | `AWS_ROLE_ARN_DEV` |
| Push/PR to `main` | `terraform-prod` | `production` (manual approval required) | Push only | `AWS_ROLE_ARN_PROD` |

**PRs:** Both jobs run `terraform init`, `validate`, `plan`. The plan appears in the PR comments; no apply.

**Pushes:** Same jobs, plus `terraform apply -auto-approve` (dev on push to `develop`, prod on push to `main` after approval).

### 🚫 What CI Does NOT Do

- Does not run `terraform fmt` (would fail repo-wide; see gaps section below).
- Does not run `tflint` or static analysis.
- Does not apply `global/` (manual only; OIDC setup is bootstrapped once).

### 🚀 Deployment Workflow (Branches)

1. **Feature branch:** `feat/`, `fix/`, `chore/`, etc.
2. **PR to `develop`:** Tests in dev environment (plan-only).
3. **Merge to `develop`:** Auto-applies to dev AWS account.
4. **PR `develop` → `main`:** Tests in prod (plan-only).
5. **Merge to `main`:** Requires GitHub approval (via `environment: production` gate), then auto-applies to prod AWS account.

**⚠️ Warning:** Merging to `main` immediately deploys to production. Review changes carefully before merge.

### 🔧 GitHub Setup

Configure these **repository variables** (not secrets) in GitHub Settings:

- `AWS_ROLE_ARN_DEV`: ARN of dev GitHub Actions IAM role (e.g., `arn:aws:iam::<AWS_ACCOUNT_ID>:role/dataplatform_github_actions_dev`).
- `AWS_ROLE_ARN_PROD`: ARN of prod GitHub Actions IAM role (e.g., `arn:aws:iam::<AWS_ACCOUNT_ID>:role/dataplatform_github_actions_prod`).

Both roles are created in `global/main.tf`. Their OIDC trust policies restrict:
- **Dev:** Any branch in the repo (`repo:*`).
- **Prod:** `main` branch only + pull request events + `environment: production` approval.

### 🔍 CI Filters

The workflow ignores these paths (to avoid stalling on doc changes):

```yaml
paths-ignore:
  - "**.md"
  - "utils/**"
  - "docker-compose.yml"
  - "requirements.txt"
```

Changes to `.claude/settings.json` or `.claude/rules/` will trigger the workflow (they are `.md` files but contain infrastructure context, so this is acceptable).

## 🚨 Known Issues & Gaps

### Formatting

`terraform fmt -check -recursive` currently fails on all `.tf` files (indentation inconsistency). This is not enforced in CI; refactoring is deferred. Do not reformat unrelated code when making changes.

### Local State Files

Stale `*.tfstate` and `*.tfstate.backup` files exist under `environments/dev` and `environments/prod`. These are gitignored and can be safely deleted (real state lives in S3). Do not commit them.

### Dead Variables

Both `dev` and `prod` define but never use:

- `var.emr_release_label`
- `var.cluster_name`, `var.cluster_node_type`, `var.cluster_num_nodes`, `var.cluster_bootstrap_action_path`
- `var.localstack_endpoint`

These are remnants of earlier designs. Do not remove them (compatibility), but do not use them.

### Hardcoded Identifiers

Prod hardcodes (already committed, OK):

- AWS account ID in comments and `variables.tf` defaults for Airflow instance/volume IDs.
- SNS topic ARN default.

Do not spread these to new documentation; use placeholders like `<AWS_ACCOUNT_ID>`.

## 🔗 Related Repository

**`camara-senado-data-ingestion`** (Python)

This repo provisions the AWS infrastructure. The sibling repo provides:
- Data extraction code (Câmara APIs, bulk files, CEAP cotas).
- Airflow DAGs that invoke ECS tasks provisioned here.
- ECR Docker image (pushed to the ECR repo created by this IaC).

See the ingestion repo's `CLAUDE.md` for architecture and data flow details.

---

🏛️ *Maintained by the Data Engineering Team.*
