# Stack outputs - names are a contract with scripts/deploy.ps1 and
# scripts/test.ps1; do not rename.

output "app_name" {
  description = "Name of the Linux Web App."
  value       = azurerm_linux_web_app.main.name
}

output "app_default_hostname" {
  description = "Default hostname of the Web App (smoke test target: https://<hostname>/health)."
  value       = azurerm_linux_web_app.main.default_hostname
}

output "acr_name" {
  description = "Name of the container registry."
  value       = azurerm_container_registry.main.name
}

output "acr_login_server" {
  description = "ACR login server (docker push target)."
  value       = azurerm_container_registry.main.login_server
}

output "key_vault_name" {
  description = "Name of the Key Vault."
  value       = azurerm_key_vault.main.name
}

output "key_vault_uri" {
  description = "Data-plane URI of the Key Vault."
  value       = azurerm_key_vault.main.vault_uri
}

output "sql_server_name" {
  description = "Name of the SQL logical server."
  value       = azurerm_mssql_server.main.name
}

output "sql_server_fqdn" {
  description = "Fully qualified domain name of the SQL logical server."
  value       = azurerm_mssql_server.main.fully_qualified_domain_name
}

output "sql_admin_login" {
  description = "SQL administrator login name (password lives in Key Vault)."
  value       = azurerm_mssql_server.main.administrator_login
}

output "sql_database_name" {
  description = "Name of the SQL database."
  value       = azurerm_mssql_database.main.name
}

output "storage_account_name" {
  description = "Name of the workload storage account."
  value       = azurerm_storage_account.main.name
}

output "file_share_name" {
  description = "Name of the Azure Files share mounted into the Web App."
  value       = azurerm_storage_share.userfiles.name
}

output "log_analytics_workspace_name" {
  description = "Name of the Log Analytics workspace."
  value       = azurerm_log_analytics_workspace.main.name
}

output "application_insights_name" {
  description = "Name of Application Insights; empty string when enable_application_insights is off."
  value       = var.enable_application_insights ? azurerm_application_insights.main[0].name : ""
}
