locals {
  prefix = var.resource_prefix

  # IAM Groups and Users mapping — shared across dev and prod (IAM is account-wide, not per-environment)
  iam_groups = {
    tech_leadership     = ["damodarabarbosa@gmail.com", "damodara-developer"]
    analytics_engineers = ["analytics-eng-user"]
    data_engineers      = ["data-eng-user"]
    bi_users            = ["bi-user"]
  }

  user_to_group = flatten([
    for group, users in local.iam_groups : [
      for user in users : {
        user  = user
        group = group
      }
    ]
  ])
}
