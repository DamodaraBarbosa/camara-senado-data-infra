locals {
  # Org tags
  environment = var.tags.environment
  project     = var.tags.project
  prefix      = var.resource_prefix

  # Mapping of Buckets S3
  s3_buckets = [
    for name in var.catalogs_names :
    lower("${local.prefix}-${name}-${local.environment}-db")
  ]

  # Roles configs
  iam_roles = {
    tech_leadership     = { name = "${local.prefix}_tech_leadership", admin = true }
    analytics_engineers = { name = "${local.prefix}_analytics_engineers", admin = false }
    data_engineers      = { name = "${local.prefix}_data_engineers", admin = false }
    sp_bi               = { name = "${local.prefix}_sp_bi", admin = false }
    sp_ci               = { name = "${local.prefix}_sp_ci", admin = false }
    sp_env              = { name = "${local.prefix}_sp_${local.environment}", admin = false }
  }

  # ECR repositories
  ecr_repositories = [
    for service in var.ecr_services :
    lower("${local.prefix}-${service}-${local.environment}")
  ]

  # Roles grants
  bucket_access_control = [
    for bucket in local.s3_buckets : {
      bucket_name = bucket
      read_only_roles = [
        local.iam_roles.sp_bi.name
      ]
      read_write_roles = [
        local.iam_roles.tech_leadership.name,
        local.iam_roles.analytics_engineers.name,
        local.iam_roles.data_engineers.name,
        local.iam_roles.sp_ci.name,
        local.iam_roles.sp_env.name
      ]
    }
  ]

  # IAM Groups and Users mapping
  iam_groups = {
    tech_leadership     = ["damodara-developer"]
    analytics_engineers = ["analytics-eng-user"]
    data_engineers      = ["data-eng-user"]
    bi_users            = ["bi-user"]
  }
}