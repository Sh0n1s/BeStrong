# Observability: Log Analytics workspace, flag-gated Application Insights,
# and diagnostic settings for every stack resource.

resource "azurerm_log_analytics_workspace" "main" {
  name                = local.log_analytics_name
  resource_group_name = data.azurerm_resource_group.playground.name
  location            = var.location
  sku                 = "PerGB2018"
  retention_in_days   = var.log_retention_days
  tags                = local.tags
}

# Workspace-based App Insights; flag-gated off-switch in case a sandbox
# session denies the resource type.
resource "azurerm_application_insights" "main" {
  count = var.enable_application_insights ? 1 : 0

  name                = local.application_insights_name
  resource_group_name = data.azurerm_resource_group.playground.name
  location            = var.location
  workspace_id        = azurerm_log_analytics_workspace.main.id
  application_type    = "web"
  tags                = local.tags
}

# App Service: enumerate exactly these four categories. Do NOT use
# category_group "allLogs" here - on B1 Linux it pulls premium-only
# categories and the diagnostic setting fails to create.
resource "azurerm_monitor_diagnostic_setting" "app" {
  name                       = "diag-app-bestrong-dev"
  target_resource_id         = azurerm_linux_web_app.main.id
  log_analytics_workspace_id = azurerm_log_analytics_workspace.main.id

  enabled_log {
    category = "AppServiceHTTPLogs"
  }

  enabled_log {
    category = "AppServiceConsoleLogs"
  }

  enabled_log {
    category = "AppServiceAppLogs"
  }

  enabled_log {
    category = "AppServicePlatformLogs"
  }

  enabled_metric {
    category = "AllMetrics"
  }
}

resource "azurerm_monitor_diagnostic_setting" "sql_database" {
  name                       = "diag-sqldb-bestrong"
  target_resource_id         = azurerm_mssql_database.main.id
  log_analytics_workspace_id = azurerm_log_analytics_workspace.main.id

  enabled_log {
    category_group = "allLogs"
  }

  # For SQL databases Azure expands "AllMetrics" into the three concrete
  # categories below and stores them expanded, so a config saying AllMetrics
  # produces a permanent phantom diff on every plan. Enumerate them
  # explicitly to keep plans idempotent.
  enabled_metric {
    category = "Basic"
  }

  enabled_metric {
    category = "InstanceAndAppAdvanced"
  }

  enabled_metric {
    category = "WorkloadManagement"
  }
}

# AuditEvent logs provide the Key Vault access audit trail.
resource "azurerm_monitor_diagnostic_setting" "key_vault" {
  name                       = "diag-kv-bestrong"
  target_resource_id         = azurerm_key_vault.main.id
  log_analytics_workspace_id = azurerm_log_analytics_workspace.main.id

  enabled_log {
    category_group = "allLogs"
  }

  enabled_metric {
    category = "AllMetrics"
  }
}

resource "azurerm_monitor_diagnostic_setting" "acr" {
  name                       = "diag-acr-bestrong"
  target_resource_id         = azurerm_container_registry.main.id
  log_analytics_workspace_id = azurerm_log_analytics_workspace.main.id

  enabled_log {
    category_group = "allLogs"
  }

  enabled_metric {
    category = "AllMetrics"
  }
}

# Storage: file service sub-resource - the userfiles share is the only
# data-plane surface in use.
resource "azurerm_monitor_diagnostic_setting" "storage_files" {
  name                       = "diag-st-files-bestrong"
  target_resource_id         = "${azurerm_storage_account.main.id}/fileServices/default"
  log_analytics_workspace_id = azurerm_log_analytics_workspace.main.id

  enabled_log {
    category = "StorageRead"
  }

  enabled_log {
    category = "StorageWrite"
  }

  enabled_log {
    category = "StorageDelete"
  }

  enabled_metric {
    category = "Transaction"
  }
}
