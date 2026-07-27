variable "subscription_id" {
  type        = string
  description = "Azure subscription id. Leave null to fall back to the ARM_SUBSCRIPTION_ID environment variable."
  default     = null
}

variable "resource_group_name" {
  type        = string
  description = "Name of the dedicated resource group the bootstrap creates for the remote-state storage."
  default     = "rg-bestrong-tfstate"
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
  description = "Azure region for the state resource group and storage account."
  default     = "eastus"
}
