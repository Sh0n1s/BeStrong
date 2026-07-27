# Storage account + userfiles file share + their own network controls:
# default-deny firewall, snet-app service endpoint, deployer IP.

resource "azurerm_storage_account" "main" {
  #checkov:skip=CKV_AZURE_59:Public network stays enabled but default-Deny firewalled (snet-app service endpoint + deployer IP)
  #checkov:skip=CKV_AZURE_206:Standard LRS is intentional - data is throwaway inside a 4-hour sandbox session
  #checkov:skip=CKV_AZURE_33:Scope is the file share only; no queue service in use
  #checkov:skip=CKV2_AZURE_1:Customer-managed keys need Key Vault key access via identity plumbing the sandbox denies
  #checkov:skip=CKV2_AZURE_33:No private endpoints in this stack - service endpoints + PaaS firewalls instead
  #checkov:skip=CKV2_AZURE_40:The App Service Azure Files mount can only authenticate by account key (platform limitation)
  #checkov:skip=CKV2_AZURE_41:No SAS tokens issued; the account lives at most 4 hours
  name                            = local.storage_account_name
  resource_group_name             = azurerm_resource_group.main.name
  location                        = var.location
  account_kind                    = "StorageV2"
  account_tier                    = "Standard"
  account_replication_type        = "LRS"
  https_traffic_only_enabled      = true
  min_tls_version                 = "TLS1_2"
  allow_nested_items_to_be_public = false

  network_rules {
    default_action             = "Deny"
    bypass                     = ["AzureServices"]
    ip_rules                   = [var.deployer_ip]
    virtual_network_subnet_ids = [azurerm_subnet.app.id]
  }

  # Blob soft delete: near-moot inside a 4-hour session, but free and a
  # sane data-protection default.
  blob_properties {
    delete_retention_policy {
      days = 7
    }
  }

  tags = local.tags
}

# Mounted into the Web App at /mounts/userfiles by account key - the only
# auth App Service Azure Files mounts support (see app.tf storage_account).
resource "azurerm_storage_share" "userfiles" {
  name               = local.file_share_name
  storage_account_id = azurerm_storage_account.main.id
  quota              = var.file_share_quota_gb
}
