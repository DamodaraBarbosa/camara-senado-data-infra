---
name: python-utils-and-lambda
description: Python utilities, Lambda functions, and dependencies
paths:
  - utils/**/*.py
  - environments/prod/lambda/**/*.py
  - requirements.txt
---

## Python Utilities (utils/)

### list_iam.py

A script to visualize the IAM hierarchy (groups, users, roles) in LocalStack. It uses boto3 with an endpoint override to `http://localhost:4566`.

**Status:** LocalStack-only. Do not use against real AWS. The script is a dev convenience and is not in CI or Docker images.

**Usage:**
```bash
# Requires docker compose to have LocalStack running
python utils/list_iam.py
```

This script is a legacy artifact from when dev targeted LocalStack. It is documented in README as context but is no longer part of the standard workflow.

## Lambda Functions (environments/prod/lambda/)

### cost_report/main.py

**Runtime:** Python 3.12 (arm64 Lambda).

**Environment variables (required):**
- `SNS_TOPIC_ARN`: ARN of the SNS topic for cost report delivery.

**Environment variables (optional):**
- `CACHE_TTL_SECONDS`: Time-to-live for Cost Explorer API response cache (default ~1 hour, reduces throttling risk).

**Behavior:**
- Runs weekly via EventBridge cron rule (`cron(0 12 ? * MON *)` — Monday 12:00 UTC).
- Queries Cost Explorer API (`GetCostAndUsage`).
- Caches response to avoid throttling.
- Publishes report to SNS.

**Not in requirements.txt:** Lambda has `boto3` pre-installed; no external dependencies listed. The function's code is archived to `.terraform-build/cost_report.zip` by Terraform's `archive_file` data source.

**Access:** Lambda is invoked by EventBridge rule, not directly. No public endpoint; Function URL uses `AWS_IAM` auth (IAM principal auth required).

## Dependencies (requirements.txt)

Current pins:

- **boto3** ~1.43: AWS SDK.
- **botocore** ~1.43: AWS SDK transport layer.
- **docker** ~7.1: Docker client (for local utility scripts).
- **requests** ~2.34: HTTP client.
- **rich** ~15.0: Terminal formatting (for `list_iam.py` output).
- **python-dateutil, urllib3, charset-normalizer, jmespath, six, etc.:** transitive dependencies.

**Never add:** Terraform, Python CLI tools, or dev-only packages to `requirements.txt`. It is for utils only. Lambda has no external deps.

**CI:** does not install requirements.txt (not needed in CI; only `terraform` binary is required).

**Local:** Install via `pip install -r requirements.txt` after `python -m venv venv && source venv/bin/activate`.

## Artifact Management

**Terraform-build directory:** `environments/prod/.terraform-build/`

Terraform uses `archive_file` to zip the Lambda source:

```hcl
data "archive_file" "lambda_cost_report" {
  type        = "zip"
  source_dir  = "${path.module}/lambda/cost_report"
  output_path = "${path.module}/.terraform-build/cost_report.zip"
}
```

**Note:** Running the Lambda function locally leaves `__pycache__/` in the source directory. This is excluded from the zip during Terraform apply (`.dockerignore` also covers it). Do not commit `__pycache__/`.

## Measured Performance

- **Cost Explorer API latency:** P95 ~3s. Cache responses for 1 hour to avoid throttling.
- **Lambda timeout:** 30s (default; sufficient for a single CE query + SNS publish).
- **Invocation frequency:** Once weekly (Monday 12:00 UTC), so cost is negligible.

## Future Extensions

The cost report is intentionally simple (one CE call per run). If you need to add:
- Multi-region cost breakdown: add loops in the Lambda or EventBridge payload.
- Slack notification: use EventBridge SNS integration or add an SQS → Lambda chain.
- Custom metrics to CloudWatch: publish directly from the Lambda.

Keep the Lambda's responsibilities focused. Complex orchestration belongs in Step Functions (add to prod feature files).
