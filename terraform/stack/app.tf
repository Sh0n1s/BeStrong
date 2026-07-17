# App Service plan + Linux Web App for Containers.
# Public HTTPS inbound by design; regional VNet integration into snet-app;
# image pulled from the public ACR endpoint with admin credentials -
# WEBSITE_PULL_IMAGE_OVER_VNET must NOT be set.

resource "azurerm_service_plan" "main" {
  #checkov:skip=CKV_AZURE_211:B1 is the cheapest sandbox-allowlisted tier that supports regional VNet integration
  #checkov:skip=CKV_AZURE_212:Single throwaway instance; failover capacity is pointless in a 4-hour sandbox
  #checkov:skip=CKV_AZURE_225:Zone redundancy requires Premium, outside the sandbox SKU allowlist
  name                = local.app_service_plan_name
  resource_group_name = data.azurerm_resource_group.playground.name
  location            = var.location
  os_type             = "Linux"
  sku_name            = var.app_service_sku
  tags                = local.tags
}

resource "azurerm_linux_web_app" "main" {
  #checkov:skip=CKV_AZURE_13:App Service authentication needs an Entra app registration, unavailable in the sandbox; /health is public by design
  #checkov:skip=CKV_AZURE_16:Managed identity is flag-gated off; the sandbox does not support managed identities
  #checkov:skip=CKV_AZURE_17:Client certificates would break the public /health smoke test
  #checkov:skip=CKV_AZURE_222:Public HTTPS inbound is the intended ingress for this app
  name                      = local.web_app_name
  resource_group_name       = data.azurerm_resource_group.playground.name
  location                  = var.location
  service_plan_id           = azurerm_service_plan.main.id
  https_only                = true
  virtual_network_subnet_id = azurerm_subnet.app.id

  site_config {
    always_on              = true
    minimum_tls_version    = "1.2"
    ftps_state             = "Disabled"
    vnet_route_all_enabled = true
    http2_enabled          = true

    # The sample app's own probe endpoint doubles as the platform health check.
    health_check_path                 = "/health"
    health_check_eviction_time_in_min = 5

    # Pull over the public ACR endpoint with admin credentials (no managed
    # identity available for AcrPull).
    application_stack {
      docker_image_name        = "${local.image_repository}:${var.image_tag}"
      docker_registry_url      = "https://${azurerm_container_registry.main.login_server}"
      docker_registry_username = azurerm_container_registry.main.admin_username
      docker_registry_password = azurerm_container_registry.main.admin_password
    }
  }

  # Platform-side logging: filesystem HTTP logs + error/request tracing.
  # Long-term retention lives in Log Analytics via monitoring.tf diagnostics;
  # this block covers the local/live debugging path.
  logs {
    detailed_error_messages = true
    failed_request_tracing  = true

    http_logs {
      file_system {
        retention_in_days = 3
        retention_in_mb   = 35
      }
    }
  }

  # Azure Files mount by account key - the only auth this mount type supports.
  storage_account {
    name         = local.file_share_name
    type         = "AzureFiles"
    account_name = azurerm_storage_account.main.name
    share_name   = azurerm_storage_share.userfiles.name
    access_key   = azurerm_storage_account.main.primary_access_key
    mount_path   = local.files_mount_path
  }

  # Flag-gated system-assigned identity: off by default; the sandbox may
  # deny even the attempt - the flag makes trying it cheap.
  dynamic "identity" {
    for_each = var.enable_app_identity ? [1] : []

    content {
      type = "SystemAssigned"
    }
  }

  # APP ENV CONTRACT consumed by app/server.js. Secrets arrive as app
  # settings because the app has no identity to read Key Vault.
  app_settings = merge(
    {
      WEBSITES_PORT      = "8080"
      FILES_MOUNT_PATH   = local.files_mount_path
      SQL_SERVER_FQDN    = azurerm_mssql_server.main.fully_qualified_domain_name
      SQL_DATABASE_NAME  = azurerm_mssql_database.main.name
      SQL_ADMIN_LOGIN    = local.sql_admin_login
      SQL_ADMIN_PASSWORD = random_password.sql_admin.result
    },
    var.enable_application_insights ? {
      APPLICATIONINSIGHTS_CONNECTION_STRING = azurerm_application_insights.main[0].connection_string
    } : {}
  )

  tags = local.tags
}
