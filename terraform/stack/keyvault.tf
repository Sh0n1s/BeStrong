# Key Vault + its own network controls. Access-policy model - the sandbox
# denies RBAC data-plane role assignments. The app never reads Key Vault at
# runtime (it has no identity); the vault demonstrates secret storage and
# audit logging.

resource "azurerm_key_vault" "main" {
  #checkov:skip=CKV_AZURE_110:Purge protection off - avoids undeletable vault ghosts across 4-hour sandbox sessions
  #checkov:skip=CKV_AZURE_42:Purge protection intentionally off; soft delete is on at the 7-day minimum
  #checkov:skip=CKV_AZURE_189:Public network access stays enabled but default-Deny firewalled to the deployer IP
  #checkov:skip=CKV2_AZURE_32:No private endpoints in this stack - service endpoints + PaaS firewalls instead
  name                       = local.key_vault_name
  resource_group_name        = azurerm_resource_group.main.name
  location                   = var.location
  tenant_id                  = data.azurerm_client_config.current.tenant_id
  sku_name                   = "standard"
  purge_protection_enabled   = false
  soft_delete_retention_days = 7
  # azurerm 4.x name (enable_rbac_authorization is the deprecated alias)
  rbac_authorization_enabled = false

  network_acls {
    default_action = "Deny"
    bypass         = "AzureServices"
    ip_rules       = [var.deployer_ip]
  }

  tags = local.tags
}

# Deployer's secret-management rights (object ID from the az login context).
resource "azurerm_key_vault_access_policy" "deployer" {
  key_vault_id = azurerm_key_vault.main.id
  tenant_id    = data.azurerm_client_config.current.tenant_id
  object_id    = data.azurerm_client_config.current.object_id

  secret_permissions = [
    "Get",
    "List",
    "Set",
    "Delete",
    "Purge",
    "Recover",
  ]
}

# SQL admin password (generated in sql.tf). Must wait for the deployer
# access policy - without it the data-plane write is denied.
resource "azurerm_key_vault_secret" "sql_admin_password" {
  #checkov:skip=CKV_AZURE_41:No expiration date; the secret lives at most 4 hours with the sandbox session
  name         = "sql-admin-password"
  value        = random_password.sql_admin.result
  key_vault_id = azurerm_key_vault.main.id
  content_type = "text/plain"
  tags         = local.tags

  depends_on = [azurerm_key_vault_access_policy.deployer]
}
