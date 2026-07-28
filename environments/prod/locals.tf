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
  # Names are suffixed with the environment because IAM is account-wide, not
  # per-environment: without the suffix, dev and prod would collide on the
  # same role name and only one environment could ever own it.
    iam_roles = {
    tech_leadership     = { name = "${local.prefix}_tech_leadership_${local.environment}",     admin = true,  service = "ec2.amazonaws.com" }
    analytics_engineers = { name = "${local.prefix}_analytics_engineers_${local.environment}", admin = false, service = "ec2.amazonaws.com" }
    data_engineers      = { name = "${local.prefix}_data_engineers_${local.environment}",      admin = false, service = "ec2.amazonaws.com" }
    sp_bi               = { name = "${local.prefix}_sp_bi_${local.environment}",               admin = false, service = "ec2.amazonaws.com" }
    sp_ci               = { name = "${local.prefix}_sp_ci_${local.environment}",               admin = false, service = "ec2.amazonaws.com" }
    sp_env              = { name = "${local.prefix}_sp_${local.environment}", admin = false, service = "ec2.amazonaws.com" }
    airflow             = { name = "${local.prefix}_airflow_${local.environment}",             admin = false, service = "ecs-tasks.amazonaws.com" }
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
        local.iam_roles.sp_env.name,
        local.iam_roles.airflow.name
      ]
    }
  ]
}