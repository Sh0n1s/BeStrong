variable "subscription_id" {
  type        = string
  description = "Azure subscription id of the current sandbox session (from .session/session.auto.tfvars)."
}

variable "resource_group_name" {
  type        = string
  description = "Name of the pre-created playground resource group that hosts the state storage account."
}

# Declared but unused here — mirrors session.auto.tfvars so the shared
# -var-file passes validation for both root modules.
# tflint-ignore: terraform_unused_declarations
variable "deployer_ip" {
  type        = string
  description = "Public IP of the deploying machine. Unused by bootstrap; declared to accept the shared session var-file."
}

variable "location" {
  type        = string
  description = "Azure region for the state storage account; must be a sandbox-allowlisted region."
  default     = "eastus"
}
