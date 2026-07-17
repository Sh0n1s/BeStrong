# Input variables. Session-specific inputs have NO defaults - they arrive via
# the machine-generated .session/session.auto.tfvars written by deploy.ps1.

variable "subscription_id" {
  type        = string
  description = "Sandbox subscription ID for the current session (per-session, discovered by deploy.ps1)."
}

variable "resource_group_name" {
  type        = string
  description = "Name of the pre-created playground resource group (per-session, pattern 1-xxxxxxxx-playground-sandbox). Consumed, never created."
}

variable "deployer_ip" {
  type        = string
  description = "Public IP of the deployer workstation (per-session). Allowlisted in the Key Vault, SQL, and Storage firewalls."
}

variable "location" {
  type        = string
  description = "Azure region for all resources. Default is the safest sandbox-allowlisted region; the playground RG location is intentionally NOT used."
  default     = "eastus"
}

variable "image_tag" {
  type        = string
  description = "Tag of the bestrong-sample container image the Web App pulls from ACR. deploy.ps1 passes the git short SHA."
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
  description = "Add a system-assigned managed identity to the Web App. Off: the sandbox does not support managed identities."
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
