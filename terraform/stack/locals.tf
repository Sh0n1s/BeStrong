# Shared foundation: the stack's resource group, random suffix, naming locals,
# standard tags.

# The stack owns and creates its resource group. (Earlier revisions targeted a
# Pluralsight sandbox where the RG was pre-created and consumed via a data
# source; the project now deploys to a personal Azure subscription.)
resource "azurerm_resource_group" "main" {
  name     = var.resource_group_name
  location = var.location
  tags     = local.tags
}

# 6-char suffix, lower + numeric only; applied only where Azure requires
# global DNS uniqueness. Regenerates with each session's fresh state -
# sidesteps soft-delete name-reuse friction.
resource "random_string" "suffix" {
  length  = 6
  lower   = true
  upper   = false
  numeric = true
  special = false
}

locals {
  suffix = random_string.suffix.result

  # Standard tag map - applied explicitly to every taggable resource.
  tags = {
    project     = "bestrong"
    environment = "dev"
    managed-by  = "terraform"
  }

  # CAF-style names (Azure Cloud Adoption Framework prefixes).
  vnet_name                     = "vnet-bestrong-dev"
  subnet_app_name               = "snet-app"
  subnet_private_endpoints_name = "snet-private-endpoints"
  log_analytics_name            = "log-bestrong-dev"
  application_insights_name     = "appi-bestrong-dev"
  app_service_plan_name         = "asp-bestrong-dev"
  web_app_name                  = "app-bestrong-dev-${local.suffix}"
  sql_server_name               = "sql-bestrong-dev-${local.suffix}"
  sql_database_name             = "sqldb-bestrong"
  storage_account_name          = "stbestrong${local.suffix}"
  acr_name                      = "acrbestrong${local.suffix}"
  key_vault_name                = "kv-bestrong-${local.suffix}"

  sql_admin_login  = "bestrongadmin"
  file_share_name  = "userfiles"
  files_mount_path = "/mounts/userfiles"
  image_repository = "bestrong-sample"
}
