# Region config
variable "aws_region" {
    type        = string
    default     = "us-east-1"
    description = "AWS Region to deploy resources"
}

# Environment settings
variable "environment" {
    type        = string
    default     = "prod"
    description = "Environment name"
}

variable "localstack_endpoint" {
    type        = string
    default     = "http://localhost:4566"
    description = "Endpoint for LocalStack services"
}

# Storage config
variable "catalogs_names" {
    type        = list(string)
    default     = ["camara", "senado"]
    description = "List of Buckets S3 to create"
}

# Catalog config
variable "schema_names" {
    type        = list(string)
    default     = ["raw", "staging", "intermediate", "marts"]
    description = "List of schema names to create (e.g., raw, staging, intermediate, marts)"
}

# ECR services config
variable "ecr_services" {
    type        = list(string)
    default     = ["docker-images-repository"]
    description = "List of ECR services to create repositories for (e.g., docker-images-repository)"
}

# Ingestion application image
# The "camara-ingestion" ECR repository is published by camara-senado-data-ingestion's
# own CI/CD (.github/workflows/ci.yml), not by this repository's Terraform.
variable "ingestion_ecr_repository" {
    type        = string
    default     = "camara-ingestion"
    description = "ECR repository name of the ingestion application image"
}

variable "ingestion_image_tag" {
    type        = string
    default     = "prod"
    description = "Tag of the ingestion image to deploy in the ECS task definition"
}

# Compute settings
variable "emr_release_label" {
    type        = string
    default     = "emr-6.10.0"
    description = "EMR release label to use for the cluster"
}

variable "cluster_master_instance_type" {
    type        = string
    default     = "m5.xlarge"
    description = "Instance type for EMR master node"
}

variable "cluster_core_instance_type" {
    type        = string
    default     = "m5.xlarge"
    description = "Instance type for EMR core nodes"
}

variable "cluster_instance_count" {
    type        = number
    default     = 2
    description = "Number of EMR core nodes"
}

variable "cluster_auto_termination_minutes" {
    type        = number
    default     = 10
    description = "Auto-termination time in minutes for EMR cluster"
}

# Alerting
# Endpoint da assinatura do topico SNS de alertas. A confirmacao chega por
# e-mail e precisa ser clicada uma vez — ate la o Terraform mantem a
# subscription em "pending confirmation" e nada e entregue.
variable "alert_email" {
    type        = string
    default     = "damodarabarbosa@gmail.com"
    description = "E-mail que recebe os alertas de falha do pipeline"
}

# Resource naming config
variable "resource_prefix" {
    type        = string
    default     = "dataplatform"
    description = "Prefix for all resource names: buckets, roles and IAM policies"
}

# Infrastructure and CI/CD
variable "tags" {
    type        = map(string)
    default = {
      "project"     = "camara-senado-data-infra",
      "environment" = "prod",
      "owner"       = "data-engineering-team",
      "managed_by"  = "terraform"
    }
}
# Host do Airflow, provisionado a mao pelo
# camara-senado-data-ingestion/docs/PROD_AIRFLOW_EC2_RUNBOOK.md. Referenciado
# aqui — e nao criado — porque o backup e o alarme sao aditivos: cobrem o risco
# sem exigir o `terraform import` da instancia inteira.
variable "airflow_instance_id" {
    description = "ID da instancia EC2 que hospeda o scheduler/triggerer do Airflow."
    type        = string
    default     = "i-0e11709bd1c1dae07"
}

variable "airflow_data_volume_id" {
    description = "ID do volume EBS com o metadata DB do Airflow (volume Docker do postgres-airflow)."
    type        = string
    default     = "vol-06402ad2abd2d4999"
}

# ---------------------------------------------------------------------------
# Controle de custo
#
# Ate agora a conta tinha um unico orcamento: o `My Zero-Spend Budget` de US$ 1
# que a AWS cria sozinha em contas do Free Plan, com alerta em qualquer gasto
# acima de US$ 0,01. Enquanto os creditos cobriam a fatura ele nunca disparou,
# e o fim do free tier passou despercebido — a conta consumiu US$ 22,57 em
# creditos entre julho e setembro de 2026 sem nenhum aviso.
#
# A franquia do AWS Budgets e de 60 budget-days por mes, ou seja, dois
# orcamentos ativos o mes inteiro. Com o zero-spend ja ocupando um, este e o
# segundo e ultimo gratuito: um terceiro passaria a custar US$ 0,02/dia.
# ---------------------------------------------------------------------------
variable "monthly_budget_limit_usd" {
    type        = number
    default     = 25
    description = "Limite mensal de custo em USD que dispara os alertas de orcamento"
}

# Instancia efemera usada para resgatar o credito de US$ 20 da atividade de EC2
# do Free Tier (widget "Explore AWS" no console). Fica `false` no repositorio:
# sobe por um PR que a liga, o credito e conferido, e outro PR a desliga. Nao
# tem relacao com o host do Airflow, que continua provisionado a mao.
variable "enable_credit_activity_instance" {
    type        = bool
    default     = true
    description = "Liga a instancia t4g.nano descartavel da atividade de credito do Free Tier"
}

# A conta tem seis subnets default, uma delas em us-east-1e — e us-east-1e nao
# oferece t4g.nano (verificado em ec2:DescribeInstanceTypeOfferings: so a, b,
# c, d e f). Um `data.aws_subnets` seguido de `ids[0]` pode cair justamente
# nela e o apply reprova com Unsupported. Por isso a AZ e fixada, nao sorteada.
variable "credit_activity_availability_zone" {
    type        = string
    default     = "us-east-1a"
    description = "AZ da subnet default onde a instancia efemera de credito sobe"
}
