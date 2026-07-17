# Provider configuration. Auth context: plain `az login` with the sandbox
# user credentials - no service principal exists in the sandbox.

provider "azurerm" {
  subscription_id = var.subscription_id

  # The sandbox denies resource-provider registration writes.
  resource_provider_registrations = "none"

  features {
    key_vault {
      # The sandbox may deny purge operations; the per-session random name
      # suffix avoids soft-deleted name collisions instead.
      purge_soft_delete_on_destroy = false
    }
  }
}

# Deployer identity - feeds the Key Vault access policy.
data "azurerm_client_config" "current" {}
