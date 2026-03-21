# Camara & Senado Data Infrastructure

This repository contains the Infrastructure as Code (IaC) to manage the data platform for the Chamber of Deputies and the Senate. It uses Terraform to provision AWS resources (or LocalStack for local development).

## Project Structure

- `environments/`: Contains environment-specific configurations.
  - `dev/`: Development environment (configured for LocalStack).
  - `prod/`: Production environment (configured for real AWS).
- `modules/`: Reusable Terraform modules (catalog, storage, IAM groups/users).
- `volume/`: Local persistence for LocalStack.
- `utils/`: Support scripts (e.g., IAM listing).
- `requirements.txt`: Python dependencies for utility scripts.

## Prerequisites

- [Docker](https://www.docker.com/) & [Docker Compose](https://docs.docker.com/compose/)
- [Terraform](https://www.terraform.io/) (v1.0.0+)
- [AWS CLI](https://aws.amazon.com/cli/)
- [Python 3.x](https://www.python.org/)

## Installation & Setup

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

### 2. Start Local Infrastructure
The project uses LocalStack to simulate AWS services locally.

```bash
docker compose up -d
```

## Local Development (Dev)

Navigate to the `dev` environment to provision local resources:

```bash
cd environments/dev
terraform init
terraform apply
```

### Utility Scripts
We provide a helper script to visualize the IAM hierarchy (Groups, Users, and Roles) created in LocalStack.

```bash
# From the project root
python utils/list_iam.py
```

### Verification
You can also manually verify created resources using the AWS CLI pointing to LocalStack:

- **S3 Buckets:** `aws --endpoint-url=http://localhost:4566 s3 ls`
- **IAM Users:** `aws --endpoint-url=http://localhost:4566 iam list-users`
- **IAM Groups:** `aws --endpoint-url=http://localhost:4566 iam list-groups`

## Workflows

### Infrastructure Changes
1. Create a new branch for your changes.
2. Test changes in the `dev` environment.
3. Open a Pull Request to `main`.
4. Once merged, the GitHub Actions CI/CD will automatically deploy to `prod`.

---
*Maintained by the Data Engineering Team.*
