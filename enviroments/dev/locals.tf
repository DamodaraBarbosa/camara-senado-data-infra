locals {
  # Workspace settings
  workspace_host = var.databricks_host
  workspace_id   = var.databricks_id
  workspace_name = var.databricks_workspace_name

  # Catalog settings
  catalog_name = var.catalogs_names

  catalog = [
    "${var.resource_prefix}_${catalog_name[0]}_${tags.environment}_db",
    "${var.resource_prefix}_${catalog_name[1]}_${tags.environment}_db"
  ]

  # Users and groups settings
  project_name = var.tags.project

  catalog_grants = [
    {
        catalog = "${var.resource_prefix}_${var.catalogs_names[0]}_${tags.environment}_db"
        read_only_groups = [
            "${var.resource_prefix}_sp_bi"
        ]
        read_write_groups = [
            "${var.resource_prefix}_tech_leadership",
            "${var.resource_prefix}_analytics_engineers",
            "${var.resource_prefix}_data_engineers",
            "${var.resource_prefix}_sp_ci",
            "${var.resource_prefix}_sp_${var.tags.environment}"
        ]
    },
    {
        catalog = "${var.resource_prefix}_${var.catalogs_names[1]}_${tags.environment}_db"
        read_only_groups = [
            "${var.resource_prefix}_sp_bi"
        ]
        read_write_groups = [
            "${var.resource_prefix}_tech_leadership",
            "${var.resource_prefix}_analytics_engineers",
            "${var.resource_prefix}_data_engineers",
            "${var.resource_prefix}_sp_ci",
            "${var.resource_prefix}_sp_${var.tags.environment}"
        ]
    }
  ]

  # Workspace groups assignments settings
  workspace_groups_assignments = [
    {
        group_name = "${var.resource_prefix}_tech_leadership"
        workspace_access = true
        permissions = ["ADMIN"]
    }, 
    {
        group_name = "${var.resource_prefix}_analytics_engineers"
        workspace_access = true
        permissions = ["USER"]
    }, 
    {
        group_name = "${var.resource_prefix}_data_engineers"
        workspace_access = true
        permissions = ["USER"]
    },
    {
        group_name = "${var.resource_prefix}_sp_bi"
        workspace_access = true
        permissions = ["USER"]
    },
    {
        group_name = "${var.resource_prefix}_sp_ci"
        workspace_access = true
        permissions = ["USER"]
    },
    {
        group_name = "${var.resource_prefix}_sp_${tags.environment}"
        workspace_access = true
        permissions = ["USER"]
    }
  ]
}