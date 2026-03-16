# Group creation 
resource "databricks_group" "groups" {
    for_each     = locals.workspace_groups_assignments
    display_name = each.value.group_name  
}

# Catalog creation
resource "databricks_catalog" "catalogs" {
    for_each = toset(var.catalogs_names)
    name     = each.value
    comment  = "Managed by Terraform catalog: ${var.resource_prefix}_${each.value}_${tags.environment}_db"

}

# Schema creation
resource "databricks_schema" "schemas" {
    for_each = {
        for item in flatten([
            for cat in var.catalogs_names : [
                for schema in var.schema_names : "${cat}_${schema}"
            ]
        ]) : item => {
            catalog = "${var.resource_prefix}_${split("_", item)[0]}_${var.tags.environment}_db"
            schema  = split("_", item)[1]
        }
    }
    
    catalog_name = each.value.catalog
    name         = each.value.schema
    comment      = "Managed by Terraform schema: ${var.resource_prefix}_${each.value.schema}_${var.tags.environment}_db"
    
    depends_on = [databricks_catalog.catalogs]
}

# Permissions grants assignments
resource "databricks_grants" "catalog_read_only" {
    for_each = { for idx, grant in local.catalog_grants : idx => grant }
   
    catalog = each.value.catalog

    dynamic "grant" {
      for_each = each.value.read_only_groups
        content {
            principal  = grant.value
            privileges = ["USE_CATALOG"]
        }
    }

    depends_on = [databricks_group.groups, databricks_catalog.catalogs]
}

resource "databricks_grants" "catalog_read_write" {
    for_each = { for idx, grant in local.catalog_grants : idx => grant }
   
    catalog = each.value.catalog

    dynamic "grant" {
      for_each = each.value.read_write_groups
        content {
            principal  = grant.value
            privileges = ["USE_CATALOG", "CREATE_SCHEMA", "CREATE_TABLE", "CREATE_VIEW", "CREATE_FUNCTION"]
        }
    }

    depends_on = [databricks_group.groups, databricks_catalog.catalogs]
}

