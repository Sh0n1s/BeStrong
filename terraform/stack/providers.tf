# Provider configuration. Auth: locally via `az login`; in CI via the Azure
# service connection (service principal) exported as ARM_* environment
# variables by the pipeline tasks.

provider "azurerm" {
  subscription_id = var.subscription_id

  # Default resource-provider registration stays ON: a fresh personal
  # subscription has most providers unregistered, and the first apply
  # registers what it needs (one-time, adds a few minutes).

  features {
    key_vault {
      # Purge-on-destroy stays off; the random name suffix avoids
      # soft-deleted vault name collisions between deployments.
      purge_soft_delete_on_destroy = false
    }
  }
}

# Deployer identity - feeds the Key Vault access policy.
data "azurerm_client_config" "current" {}
