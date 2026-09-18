---
name: iam-and-security
description: IAM patterns, OIDC trust differences, and security guardrails
paths:
  - "**/*iam*.tf"
  - environments/**/main.tf
  - global/**
---

## IAM Role Naming & Scope

The CI role (`dataplatform_github_actions_<env>`) has an IAM permission boundary:

```hcl
Action: ["iam:*"]
Resource: [
  "arn:aws:iam::*:role/dataplatform_*",
  "arn:aws:iam::*:policy/dataplatform-*"
]
```

This means:
- **New IAM roles must be named `dataplatform_<name>_<env>`** (with underscores).
- **New IAM policies must be named `dataplatform-<name>-<env>`** (with hyphens).

The CI role **cannot**:
- `iam:PutRolePolicy` (inline policy creation).
- Create instance profiles.
- Assume roles outside the prefix scope.

If you need new IAM resources, follow the naming rule. Do not loosen the role's trust or permission boundary.

## OIDC Trust Policy Differences

### Dev (`environments/dev/main.tf`)

```hcl
sub = "repo:<owner>/<repo>:*"
```

This allows **any branch, any event type** in the repo to assume the role.

### Prod (`environments/prod/main.tf`)

```hcl
sub = "repo:<owner>/<repo>:ref:refs/heads/main"
condition = "StringEquals"
sub_claim = "<repo>:pull_request"  # Also allow PR events
```

Prod restricts to:
- Push events on the `main` branch only.
- Pull request events from any branch (for `plan`).
- `environment:production` gate (manual approval in GitHub).

**Never loosen the prod trust policy.** A looser policy would allow any branch (e.g., a feature branch) to assume the prod role and apply prod changes.

## global/ — Manual Apply

`global/` is not in CI. There is no workflow that applies `global/` changes.

**Why?** The OIDC setup itself lives in `global/github_oidc.tf`. A circular dependency would result (the role doesn't exist until you apply global). So `global/` is applied manually as a bootstrapping step.

**Implication:** If you modify `global/` (IAM users, groups, OIDC config), you must apply it locally:

```bash
cd global
terraform init
terraform apply
```

This requires AWS credentials in your shell environment with IAM, IAM Trust Policy, and OIDC provider permissions.

## No Account IDs or Instance IDs in New Docs

The prod environment hardcodes:
- AWS account ID in comments and Airflow instance/volume ID defaults in `variables.tf`.
- SNS topic ARN default.
- Security group and subnet IDs in the DAG (sibling repo).

**Do not spread these to new `.claude/rules/` or README text.** Use placeholders like `<AWS_ACCOUNT_ID>`, `<AIRFLOW_INSTANCE_ID>`, `<SECURITY_GROUP_ID>` in documentation. The actual values can stay in the `.tf` files (they are tracked) but not in rules.

## Sensitive Files (Never Read, Print, or Edit)

- `.env` (gitignored, locally sourced).
- `*.tfstate`, `*.tfstate.backup`, `*.tfstate.lock.info` (stale local state; real state lives in S3).
- `.terraform/` directory (cached providers, gitignored).
- `volume/cache/server.test.pem` and `.pem.key` (old LocalStack TLS, gitignored).
- `.terraform.lock.hcl` (gitignored, provider lock file).

These files must never be committed. If you see them staged (`git status`), unstage them immediately.

## Local vs. Production Operations

- **Local:** `terraform plan` only. Never `apply`, `destroy`, `import`, or `state` commands outside CI.
- **CI:** Auto-applies on push to `develop` (dev env) or `main` (prod env, with approval gate).
- **Merge = Deploy:** A merged PR to `main` triggers an automatic `terraform apply` to prod. Review and test carefully before merge.

## Audit & Cost Monitoring

- **Budget:** prod has a monthly budget (`budgets.tf`) with cost notifications to SNS.
- **Cost Report:** Lambda function runs weekly on Monday 12:00 UTC, publishes a Cost Explorer report to SNS.
- **Alarms:** EC2 auto-recover alarm on `StatusCheckFailed_System` triggers instance reboot and SNS notification.

These are **informational only**; they do not auto-remediate. Review alerts in SNS.
