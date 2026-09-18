# CLAUDE.md — Camara & Senado Data Infrastructure

## Overview

This repository is the Infrastructure as Code (IaC) for the AWS data platform backing the Câmara dos Deputados data ingestion pipeline (`camara-senado-data-ingestion`). It uses Terraform to provision buckets, Glue catalogs, ECR registries, ECS clusters, Lambda functions, IAM roles, and monitoring for dev and prod environments in AWS us-east-1. No LocalStack dev flow exists; all development targets real AWS.

## Repository Layout

The repo has **three independent Terraform root modules**, each with its own S3 remote backend and native locking (`use_lockfile = true`, requires Terraform >= 1.10):

- **`global/`** — Account-wide resources (GitHub OIDC provider, IAM groups/users for four teams: tech_leadership, analytics_engineers, data_engineers, bi_users). *Manually applied; not in CI.*
- **`environments/dev/`** — Real AWS dev environment (single `main.tf`, 433 lines).
- **`environments/prod/`** — Real AWS prod environment (`main.tf` plus feature files: `budgets.tf`, `lambda_cost_report.tf`, `ec2_credit_activity.tf`). Includes S3 versioning, lifecycle, DLM snapshots, auto-recover alarms, SNS alerts, and cost-reporting Lambda.

`modules/` is empty and unused. `volume/` is a stale LocalStack bind mount (gitignored, can be ignored).

## Commands & Local Workflow

Per-environment setup (dev or prod):

```bash
cd environments/<env>
terraform init          # Requires S3 backend bucket + real AWS credentials
terraform validate      # Check syntax
terraform plan          # Preview changes
terraform apply         # Apply (CI automates this on push to develop/main)
```

**Never run `terraform apply/destroy/import/state` locally.** CI is the deployment path. Local runs affect real infrastructure and are error-prone.

The Terraform version in CI is pinned to 1.14.7 (`TF_VERSION` in `.github/workflows/terraform.yml`). Local version can differ (currently 1.16.3), but must be >= 1.10 for backend locking to work.

## Development Rules & Constraints

See `.claude/rules/` for scoped conventions:

- **`terraform-conventions.md`** — File structure, naming (roles use `_` because CI role scope is `role/dataplatform_*`; policies/SNS/logs use `-`), tags, `for_each`, managed policies, prod-only resources.
- **`iam-and-security.md`** — CI role permissions, OIDC trust differences (dev `repo:*`, prod restricted to `main` branch), `global/` is manual, no account IDs in docs.
- **`ci-and-git.md`** — Workflow triggers, `paths-ignore` rationale, environment gates, branch flow.
- **`python-utils-and-lambda.md`** — `utils/list_iam.py` (LocalStack-only), Lambda runtime (Python 3.12 arm64), cost_report env vars.

**Security guardrails:**
- Never read/print `.env`, `*.tfstate`, `*.tfstate.backup`, `.terraform/`, `volume/cache/*.pem`.
- Use `<AWS_ACCOUNT_ID>` placeholders in docs; real IDs are hardcoded in prod files but not spread further.

## Git & CI/CD

**Branch strategy:** Feature branches → PRs to `develop` (runs dev `plan` only; no apply) → `develop` merges auto-apply to dev → PRs from `develop` to `main` → `main` merges auto-apply to prod.

**Conventional Commits:** type (feat/fix/chore/docs/hotfix), scope (optional), lowercase imperative, explanatory body citing the incident or AWS constraint.

**CI workflow (`.github/workflows/terraform.yml`):**
- Triggers: push and PR on `develop` and `main`.
- `paths-ignore: **.md, utils/**, docker-compose.yml, requirements.txt` (reason: a docs-only PR caused a 44-hour stall on an environment gate).
- Two jobs: `terraform-dev` (uses `environment: development`) and `terraform-prod` (uses `environment: production` with manual approval).
- Both run `init`, `validate`, `plan`. `apply -auto-approve` runs only on push (not PR).

## Sibling Repository

`camara-senado-data-ingestion` (Python) publishes ECR images and Airflow DAGs referenced in this infra code. See that repo's README and `CLAUDE.md` for data sources, extraction patterns, and orchestration.

---

For detailed conventions per file pattern, see `.claude/rules/`.
