# Input variables.

variable "subscription_id" {
  type        = string
  description = "Azure subscription id. Leave null to fall back to the ARM_SUBSCRIPTION_ID environment variable (how the CI pipeline supplies it via the service connection)."
  default     = null
}

variable "resource_group_name" {
  type        = string
  description = "Name of the resource group the stack creates for all workload resources."
  default     = "rg-bestrong-dev"
}

variable "deployer_ip" {
  type        = string
  description = "Public IP allowed through the Key Vault, SQL, and Storage firewalls: the deployer workstation locally, or the hosted agent's IP in CI (discovered per run)."
}

variable "location" {
  type        = string
  description = "Azure region for all resources. centralus: empirically verified to allow both B1 App Service plans and SQL server provisioning on a free-trial subscription (eastus denies both - SQL ProvisioningDisabled + zero Basic VM quota)."
  default     = "centralus"
}

variable "image_tag" {
  type        = string
  description = "Tag of the bestrong-sample container image the Web App pulls from ACR. CI passes the git short SHA of the build."
  default     = "v1"
}

variable "enable_application_insights" {
  type        = bool
  description = "Deploy Application Insights. Documented off-switch in case a sandbox session denies the resource type."
  default     = true
}

variable "enable_sql_private_endpoint" {
  type        = bool
  description = "Optional SQL Private Link experiment. Flip only after a green baseline deployment."
  default     = false
}

variable "enable_app_identity" {
  type        = bool
  description = "Add a system-assigned managed identity to the Web App. Off by default (a legacy of the original sandbox target); safe to enable in a personal subscription."
  default     = false
}

variable "app_service_sku" {
  type        = string
  description = "App Service plan SKU. B1 is the cheapest sandbox-allowlisted tier with regional VNet integration."
  default     = "B1"
}

variable "sql_database_sku" {
  type        = string
  description = "SQL database SKU. Basic DTU is the sandbox allowlist floor and sufficient for /health."
  default     = "Basic"
}

variable "file_share_quota_gb" {
  type        = number
  description = "Quota in GB for the userfiles Azure Files share."
  default     = 100
}

variable "log_retention_days" {
  type        = number
  description = "Retention in days for the Log Analytics workspace."
  default     = 30
}
