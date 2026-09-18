---
name: terraform-conventions
description: File structure, naming patterns, variable/locals/tag conventions for Terraform code
paths:
  - environments/**/*.tf
  - global/**/*.tf
---

## File Layout

Each root module (`global/`, `environments/dev`, `environments/prod`) has:

- `provider.tf`: terraform block (required_version, required_providers), backend (S3 with `use_lockfile = true`), provider config.
- `variables.tf`: input variables with descriptions.
- `locals.tf`: locals (never a separate `outputs.tf` — one value per file is not worth it).
- `main.tf`: resources (dev: 433 lines; prod: 691 lines).
- **Prod only:** one file per feature topic: `budgets.tf`, `lambda_cost_report.tf`, `ec2_credit_activity.tf`.

**Never add:**
- `outputs.tf` (if needed, inline into `main.tf`)
- `versions.tf` (provider constraints go in `provider.tf`)
- `terraform.tfvars` or `*.tfvars.json` (gitignored, and CI uses `TF_VAR_*` env vars)

## Naming Conventions

### Resource Naming (AWS names)

- **IAM Roles:** `dataplatform_<role>_<env>` with **underscores**. The CI role scope in prod is `role/dataplatform_*`, so underscores are required.
  - Example: `dataplatform_airflow_dev`, `dataplatform_airflow_prod`.
  
- **IAM Policies, SNS topics, ECS resources, CloudWatch logs:** `dataplatform-<resource>-<env>` with **hyphens**.
  - Example: `dataplatform-alerts-prod`, `dataplatform-ecs-cluster-dev`.
  
- **S3 buckets, ECR repositories, Glue database names:** lowercase via `lower()`.
  - Example: `dataplatform-camara-dev-db`, `camara-ingestion`.

### Terraform Identifiers (in `.tf` files)

- **Resource names:** snake_case, describe what they are (e.g., `aws_s3_bucket.catalog`, `aws_iam_role.data_roles`).
- **Variable names:** snake_case (e.g., `var.environment`, `var.resource_prefix`, `var.enable_credit_activity_instance`).
- **Locals:** snake_case (e.g., `local.prefix`, `local.environment`, `local.s3_buckets`).
- **Collections:** use `for_each` over `toset(...)` or maps, never `count` (exception: prod credit-activity instance uses `count` with a feature flag).

## Variables & Locals

### var.tags (Required)

Every root defines this map with keys:
- `project = "camara-senado-data-infra"`
- `environment = "<dev|prod>"` (set from `var.environment`)
- `owner = "data-engineering-team"`
- `managed_by = "terraform"`

`global/` has the same map without `environment`.

### local.prefix & local.environment

- `local.prefix = var.resource_prefix` (default `"dataplatform"`)
- `local.environment = var.tags.environment`

Use these everywhere; never hardcode "dev" or "prod".

### Dead Variables (Document But Never Use)

Dev and prod both define but never use:
- `var.emr_release_label`
- `var.cluster_name`, `var.cluster_node_type`, `var.cluster_num_nodes`, `var.cluster_bootstrap_action_path`
- `var.localstack_endpoint` (old LocalStack dev flow, removed)

Document in README but do not spread or code around them.

## Resource Patterns

### IAM Roles & Policies

- **Never use inline `aws_iam_role_policy`.** Always use managed policy + `aws_iam_role_policy_attachment`.
- **Policy lifecycle:**
  ```hcl
  lifecycle {
    create_before_destroy = true
  }
  ```
- **Policy content:** use `jsonencode()`, not raw strings.
- **Examples:**
  - S3 read-only policy vs. S3 read-write (with Glue perms).
  - ECR read-only vs. ECR read-write.
  - Lambda execution role (trusts Lambda service).
  - ECS task execution role and app role.

### for_each Resources

Use `for_each` for collections:

```hcl
resource "aws_s3_bucket" "catalog" {
  for_each = toset(local.s3_buckets)
  bucket   = each.value
  tags     = var.tags
}

resource "aws_glue_catalog_database" "catalog_db" {
  for_each = { for pair in flatten([...]) : pair.key => pair.db_name }
  name     = lower(each.value)
  parameters = { PROJECT = local.project, ENVIRONMENT = local.environment }
}
```

### Prod-Only Resources

Use `var.environment == "prod" ? value : default` or conditionals:

```hcl
force_destroy = var.environment == "prod" ? false : true
log_retention_in_days = var.environment == "prod" ? 30 : 7
```

Examples: S3 versioning, lifecycle rules, SNS alerts, DLM snapshots, Lambda/EventBridge, budgets, EC2 credit-activity instance (gated by `var.enable_credit_activity_instance`, default `false`).

### S3 Buckets (Prod)

Prod adds:
- Versioning enabled (`enabled = true`).
- Lifecycle rule: abort multipart uploads after 7 days, expire non-current versions after 30, move raw/* to GLACIER_IR after 60.
- SSE: `sse_algorithm = "AES256"`.
- Public-access block: all false.

## Comments & Documentation

**File headers:** English, brief purpose.

**Rationale comments:** Long blocks explaining the incident, AWS constraint, or measured evidence that motivated a resource. Use Portuguese without accents or English, 3–5 lines. Example:

```hcl
# DLM policy for daily EBS snapshots. Required for prod RTO/RPO targets.
# Commit a4fa58b fixed a role-naming bug where we used hyphens instead of underscores.
```

## Formatting

**No reformat unrelated code.** `terraform fmt -check` currently fails repo-wide (tracked in README gaps). Do not run `terraform fmt -recursive` on the entire repo. If a file needs new code, match the existing style (4-space or 2-space indentation per file — not yet consistent).

## Terraform Versions

- **Backend minimum:** 1.10 (for `use_lockfile = true`).
- **CI pin:** 1.14.7 (`TF_VERSION` env var in `.github/workflows/terraform.yml`).
- **Local:** Can be newer, must be >= 1.10.

Never run `terraform init` without matching the backend AWS region and state bucket. The state buckets are manually created outside Terraform.
