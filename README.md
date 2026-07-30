# 🏛️ Camara & Senado Data Infrastructure

![Terraform CI](https://github.com/DamodaraBarbosa/camara-senado-data-infra/actions/workflows/terraform.yml/badge.svg)
![Terraform](https://img.shields.io/badge/Terraform-1.14.7-844FBA?logo=terraform&logoColor=white)
![IaC](https://img.shields.io/badge/IaC-Terraform-844FBA)
![Cloud](https://img.shields.io/badge/Cloud-AWS-FF9900?logo=amazonaws&logoColor=white)

This repository contains the Infrastructure as Code (IaC) to manage the data platform for the Chamber of Deputies and the Senate. It uses Terraform to provision AWS resources (or LocalStack for local development) and includes a CI/CD pipeline via GitHub Actions with OIDC authentication.

## 📁 Project Structure

- `environments/`: Environment-specific Terraform configurations.
  - `dev/`: Development environment (targets LocalStack by default, can be re-configured for AWS).
  - `prod/`: Production environment (targets real AWS).
- `global/`: Account-wide IAM resources shared across environments.
  - `github_oidc.tf`: GitHub Actions OIDC identity provider for keyless CI/CD authentication.
  - `groups_users.tf`: IAM groups and users (`tech_leadership`, `analytics_engineers`, `data_engineers`, `bi_users`).
- `utils/`: Helper scripts (e.g., `list_iam.py` to visualize IAM hierarchy in LocalStack).
- `.github/workflows/`: GitHub Actions CI/CD pipeline.
- `requirements.txt`: Python dependencies for utility scripts.
- `docker-compose.yml`: LocalStack service configuration for local development.

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

- 🐳 [Docker](https://www.docker.com/) & [Docker Compose](https://docs.docker.com/compose/)
- 🧱 [Terraform](https://www.terraform.io/) (v1.0.0+)
- ☁️ [AWS CLI](https://aws.amazon.com/cli/)
- 🐍 [Python 3.x](https://www.python.org/)

## 🛠️ Installation & Setup

### 1. Python Environment
It is highly recommended to use a virtual environment to run the utility scripts.

```bash
# Create a virtual environment
python3 -m venv venv

# Activate it
source venv/bin/activate

# Install dependencies
pip install -r requirements.txt
```

### 2. Start Local Infrastructure (LocalStack)
The project uses LocalStack to simulate AWS services locally.

```bash
docker compose up -d
```

## 💻 Local Development (Dev Environment)

Navigate to the `dev` environment to provision local resources:

```bash
cd environments/dev
terraform init
terraform apply
```

### 🧰 Utility Scripts

List the IAM hierarchy (Groups, Users, and Roles) created in LocalStack:

```bash
# From the project root
python utils/list_iam.py
```

### 🔍 Verification

Manually verify created resources using the AWS CLI pointing to LocalStack:

- **S3 Buckets:** `aws --endpoint-url=http://localhost:4566 s3 ls`
- **IAM Users:** `aws --endpoint-url=http://localhost:4566 iam list-users`
- **IAM Groups:** `aws --endpoint-url=http://localhost:4566 iam list-groups`

## 🔄 CI/CD with GitHub Actions

The repository includes a GitHub Actions workflow (`.github/workflows/terraform.yml`) that automatically applies Terraform changes using keyless OIDC authentication — no static AWS credentials are stored or used.

### ⚡ Workflow Triggers and Jobs

| Job | Trigger | Auto-Apply | IAM Role |
|---|---|---|---|
| `terraform-dev` | Push/PR to `develop` | Push only | `AWS_ROLE_ARN_DEV` |
| `terraform-prod` | Push/PR to `main` | Push only | `AWS_ROLE_ARN_PROD` |

Both jobs always run `terraform init`, `validate`, and `plan`. PRs are plan-only — `terraform apply -auto-approve` runs only on push events.

### 🔧 Setup Requirements

To enable the GitHub Actions workflow, configure the following **repository variables** (not secrets) in your GitHub repository settings:

- `AWS_ROLE_ARN_DEV`: ARN of the GitHub Actions IAM role for the dev environment (e.g., `arn:aws:iam::ACCOUNT_ID:role/dataplatform_github_actions_dev`).
- `AWS_ROLE_ARN_PROD`: ARN of the GitHub Actions IAM role for the prod environment (e.g., `arn:aws:iam::ACCOUNT_ID:role/dataplatform_github_actions_prod`).

The workflow uses `aws-actions/configure-aws-credentials@v4` with the `role-to-assume` parameter pointing to these roles. The OIDC trust relationship is pre-configured in the IAM role and restricts assumptions to events from the GitHub repository and branch specified in the role's trust policy.

### 🚀 Deployment Workflow

1. Create a new branch for your infrastructure changes.
2. Push to `develop` and open a pull request to test changes in the `dev` environment (plan-only).
3. Merge to `develop` once approved; the `terraform-dev` job automatically applies changes to dev.
4. Open a pull request from `develop` to `main` to prepare production changes.
5. Merge to `main` once approved; the `terraform-prod` job automatically applies changes to prod.

---

🏛️ *Maintained by the Data Engineering Team.*
