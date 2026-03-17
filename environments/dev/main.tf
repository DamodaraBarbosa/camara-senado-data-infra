# Group creation 
resource "databricks_group" "groups" {
    for_each     = toset(var.catalogs_names)
    display_name = each.value.group_name  
}

# Schema creation (Databases in Hive Metastore - Community/Free Edition compatible)
resource "databricks_schema" "schemas" {
    for_each = {
        for item in flatten([
            for cat in var.catalogs_names : [
                for schema in var.schema_names : {
                    # No Community Edition, simulamos a separação de catálogo no nome do schema
                    full_name = "${cat}_${schema}"
                }
            ]
        ]) : item.full_name => item
    }
    
    catalog_name =  "main"
    name    = each.value.full_name
    comment = "Managed by Terraform: ${each.value.full_name}"
}

# Permissions grants assignments (Unity Catalog specific - disabled for Community Edition)
/*
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

    # depends_on = [databricks_group.groups, databricks_catalog.catalogs]
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

    # depends_on = [databricks_group.groups, databricks_catalog.catalogs]
}
*/

