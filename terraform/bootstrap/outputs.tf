# Consumed by deploy.ps1 to generate .session/backend.hcl for the stack backend.

output "state_resource_group_name" {
  description = "Resource group that hosts the Terraform state storage account."
  value       = azurerm_resource_group.state.name
}

output "state_storage_account_name" {
  description = "Name of the storage account that holds Terraform remote state."
  value       = azurerm_storage_account.tfstate.name
}

output "state_container_name" {
  description = "Name of the blob container that holds Terraform remote state."
  value       = azurerm_storage_container.tfstate.name
}
