# Resource naming config
variable "resource_prefix" {
    type        = string
    default     = "dataplatform"
    description = "Prefix for all resource names: groups, users and IAM policies"
}

# Infrastructure and CI/CD
variable "tags" {
    type        = map(string)
    default = {
      "project"     = "camara-senado-data-infra",
      "owner"       = "data-engineering-team",
      "managed_by"  = "terraform"
    }
}
