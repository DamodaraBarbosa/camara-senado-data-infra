---
name: ci-and-git
description: GitHub Actions workflow, branch strategy, commit conventions
paths:
  - .github/workflows/**
  - .github/**
---

## GitHub Actions Workflow

`.github/workflows/terraform.yml` is the only workflow.

### Triggers

```yaml
on:
  push:
    branches: [develop, main]
    paths-ignore:
      - "**.md"
      - "utils/**"
      - "docker-compose.yml"
      - "requirements.txt"
  pull_request:
    branches: [develop, main]
    paths-ignore: [...]
```

**Rationale for `paths-ignore`:** A documentation-only PR stalled on an environment gate for 44 hours. `paths-ignore` prevents workflows from running for harmless changes.

### Jobs

#### terraform-dev
- **Trigger:** Push to `develop` or PR with base `develop`.
- **Environment:** `development` (no approval gate).
- **Working directory:** `environments/dev`.
- **AWS role:** `vars.AWS_ROLE_ARN_DEV`.
- **Steps:** configure credentials (OIDC), `terraform init`, `validate`, `plan -no-color`.
- **Apply:** Only on push (not PR); uses `apply -auto-approve`.

#### terraform-prod
- **Trigger:** Push to `main` or PR with base `main`.
- **Environment:** `production` (requires manual approval).
- **Working directory:** `environments/prod`.
- **AWS role:** `vars.AWS_ROLE_ARN_PROD`.
- **Apply:** Only on push to `main` (not PR).

### Env & Vars

- `AWS_REGION=us-east-1`
- `TF_VERSION="1.14.7"` (pinned, may differ from local)
- Repository variables (not secrets): `AWS_ROLE_ARN_DEV`, `AWS_ROLE_ARN_PROD`
- OIDC credential exchange: no static AWS keys stored

### What CI Does NOT Do

- No `terraform fmt` check (would fail repo-wide; documented in README).
- No `tflint` or static analysis.
- No `terraform apply` on `global/` (manual only).

## Branch Strategy

1. **Feature branches:** `feat/`, `fix/`, `chore/`, `docs/`, `hotfix/` prefix.
2. **PR to `develop`:** Runs plan only (no apply). Must pass CI before merge.
3. **Merge to `develop`:** Auto-applies to dev environment.
4. **PR from `develop` to `main`:** Runs plan only. Merge requires manual approval via `environment: production` gate.
5. **Merge to `main`:** Auto-applies to prod environment (merge = prod deploy).

**Implication:** Be careful when merging to `main`. The change goes live immediately to prod AWS.

## Commit Style (Conventional Commits)

Format: `<type>: <subject>`

Types:
- `feat:` — New resource or feature (rare; most commits are infra updates)
- `fix:` — Bug fix or workaround (IAM permission fix, role naming, etc.)
- `chore:` — Routine updates (dependency bumps, CI config, tooling)
- `docs:` — Documentation updates (README, CLAUDE.md, rules)
- `hotfix:` — Urgent fix to prod (e.g., broken alert, role trust)

**Subject:**
- Lowercase, imperative mood ("fix role naming" not "fixed role naming").
- ~60 characters max.

**Body (optional but encouraged):**
- Wrap at 72 characters.
- Explain the *why*, not the *what*.
- Cite the commit that introduced the issue (if a fix).
- Reference measured numbers or AWS constraints that motivated the change.

**Example:**
```
feat: add cost-report Lambda and weekly EventBridge trigger

The Finance team needs a weekly cost report to track the free tier credits spend.
Lambda queries Cost Explorer and publishes to SNS. Scheduled for Monday 12:00 UTC.

Measured: Cost API has a 3-second P95 latency; cache for 1 hour to avoid throttling.
```

**Trailer:**
```
Co-Authored-By: Claude Haiku 4.5 <noreply@anthropic.com>
```

## Merge Commits

GitHub generates merge commits on `Merge pull request #N from DamodaraBarbosa/<branch>`. These are fine; no squash or rebase required.

## Common Mistakes

- **Pushing directly to `main` or `develop`:** Use feature branches and PRs. Merging to `main` immediately applies to prod.
- **Running `terraform apply` locally:** Always use CI. Local applies affect real infrastructure and can race with CI.
- **Loosening the prod OIDC trust:** Don't do this. It bypasses the `main` branch restriction and environment approval gate.
- **Forgetting the commit trailer:** Add it manually or ask the AI assistant to do so.
- **Hardcoding account IDs in new code:** Use `local.` vars and `var.` inputs instead.
