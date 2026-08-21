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