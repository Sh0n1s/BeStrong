# SQL server + database + their own network controls, plus a flag-gated
# private endpoint experiment (default off). SQL authentication is used
# because the sandbox denies configuring an Entra ID admin.

# The password transits Terraform state - accepted: state is private,
# key-authenticated, and dies with the 4-hour sandbox session.
resource "random_password" "sql_admin" {
  length      = 24
  special     = false
  min_upper   = 2
  min_lower   = 2
  min_numeric = 2
}

resource "azurerm_mssql_server" "main" {
  #checkov:skip=CKV_AZURE_113:Public network access stays enabled but firewalled to the snet-app VNet rule + deployer IP only
  #checkov:skip=CKV_AZURE_23:No server auditing storage sink in the 4-hour sandbox; database diagnostics stream to Log Analytics instead
  #checkov:skip=CKV2_AZURE_7:Entra admin cannot be configured in the sandbox; SQL authentication is the only option
  #checkov:skip=CKV2_AZURE_45:No private endpoint in the baseline; available only via the flag-gated experiment below
  #checkov:skip=CKV2_AZURE_2:Vulnerability assessment needs a Microsoft Defender plan + storage sink, out of scope for a 4-hour sandbox
  #checkov:skip=CKV2_AZURE_27:Entra ID (Azure AD) authentication cannot be configured in the sandbox
  #checkov:skip=CKV_AZURE_24:Auditing itself is skipped (see CKV_AZURE_23), so its 90-day retention requirement is moot in a 4-hour sandbox
  name                          = local.sql_server_name
  resource_group_name           = data.azurerm_resource_group.playground.name
  location                      = var.location
  version                       = "12.0"
  minimum_tls_version           = "1.2"
  public_network_access_enabled = true
  administrator_login           = local.sql_admin_login
  administrator_login_password  = random_password.sql_admin.result
  tags                          = local.tags
}

resource "azurerm_mssql_database" "main" {
  #checkov:skip=CKV_AZURE_229:Basic DTU is the sandbox SKU allowlist ceiling; zone redundancy needs Premium/Business Critical
  #checkov:skip=CKV_AZURE_224:A standard relational DB is what the app needs; cryptographic ledger/nonrepudiation is not a requirement
  name        = local.sql_database_name
  server_id   = azurerm_mssql_server.main.id
  sku_name    = var.sql_database_sku
  max_size_gb = 2
  tags        = local.tags
}

# App outbound path: snet-app service endpoint.
resource "azurerm_mssql_virtual_network_rule" "app" {
  name      = "allow-snet-app"
  server_id = azurerm_mssql_server.main.id
  subnet_id = azurerm_subnet.app.id
}

# Deployer data-plane access for post-apply T-SQL and connectivity probes.
resource "azurerm_mssql_firewall_rule" "deployer" {
  name             = "deployer-ip"
  server_id        = azurerm_mssql_server.main.id
  start_ip_address = var.deployer_ip
  end_ip_address   = var.deployer_ip
}

# --- Flag-gated experiment: SQL private endpoint (default off) -------------
# Attempted only after a green baseline; if the sandbox denies any of these
# (expected failure point: the private DNS zone), flip the flag back to
# false and re-apply - baseline connectivity never depends on them.

resource "azurerm_private_dns_zone" "sql" {
  count = var.enable_sql_private_endpoint ? 1 : 0

  name                = "privatelink.database.windows.net"
  resource_group_name = data.azurerm_resource_group.playground.name
  tags                = local.tags
}

resource "azurerm_private_dns_zone_virtual_network_link" "sql" {
  count = var.enable_sql_private_endpoint ? 1 : 0

  name                  = "pdnsz-link-sql-bestrong-dev"
  resource_group_name   = data.azurerm_resource_group.playground.name
  private_dns_zone_name = azurerm_private_dns_zone.sql[0].name
  virtual_network_id    = azurerm_virtual_network.main.id
  tags                  = local.tags
}

resource "azurerm_private_endpoint" "sql" {
  count = var.enable_sql_private_endpoint ? 1 : 0

  name                = "pe-sql-bestrong-dev"
  resource_group_name = data.azurerm_resource_group.playground.name
  location            = var.location
  subnet_id           = azurerm_subnet.private_endpoints.id
  tags                = local.tags

  private_service_connection {
    name                           = "psc-sql-bestrong-dev"
    private_connection_resource_id = azurerm_mssql_server.main.id
    subresource_names              = ["sqlServer"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "pdzg-sql-bestrong-dev"
    private_dns_zone_ids = [azurerm_private_dns_zone.sql[0].id]
  }
}
