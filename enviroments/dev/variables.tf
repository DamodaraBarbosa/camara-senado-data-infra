# Databricks Configuration
variable "databricks_host" {
    type        = string
    description = "The URL of the Databricks workspace."    
}

variable "databricks_id" {
    type        = string
    description = "The ID of the Databricks workspace."  
}

variable "databricks_token" {
    type        = string
    description = "The Databricks personal access token used for authentication."
    sensitive   = true
}

variable "databricks_workspace_name" {
    type        = string
    description = "The name of the Databricks workspace."
}

# Catalog and Schema
variable "catalogs_names" {
    type        = list(string)
    description = "The names of the Databricks catalogs to be used."
}

variable "schema_names" {
    type        = list(string)
    default     = ["raw", "staging", "intermediate", "marts"]  
    description = "The names of the Databricks schemas to be used."
}

# Cluster Settings
variable "cluster_autotermination_minutes" {
    type        = number
    default     = 5
    description = "The number of minutes of inactivity after which the cluster will be automatically terminated."

}

# Resource Naming
variable "resource_prefix" {
    type        = string
    default     = "dataplatform"
    description = "The prefix to be used for all Databricks resources created by Terraform."
}

# Alerts
variable "alerts_on_failure" {
    type        = bool
    default     = true
}

# Git Integration
variable "git_provider" {
    type        = string
    default     = "gitHub"
    description = "The Git provider to be used for the Databricks job code repository."
  
}

variable "git_username" {
    type        = string
    description = "The username for the Git repository containing the Databricks job code."    
}

variable "git_repository_url" {
    type        = string
    default     = "https://github.com/damodara/camara-senado-data-ingestion.git"
    description = "The URL of the Git repository containing the Databricks job code."
}

variable "git_branch" {
    type        = string
    default     = "develop"
    description = "The branch of the Git repository containing the Databricks job code."
}

# Tags
variable "tags" {
    type = map(string)
    default = {
        "project" = "camara-senado-data-ingestion",
        "environment" = "dev"
        "owner" = "data-engineering-team"
    }
}