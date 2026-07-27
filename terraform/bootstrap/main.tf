# Bootstrap root module: creates the storage account + blob container that hold
# remote state for terraform/stack. Runs with LOCAL state; deploy.ps1 redirects
# the local state file under .session/ via -backend-config="path=...".

terraform {
  required_version = ">= 1.5"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }

  # Local backend; actual state path supplied by scripts (-backend-config).
  backend "local" {}
}

# Provider config mirrors terraform/stack. Default resource-provider
# registration stays on (fresh subscriptions have most providers unregistered).
provider "azurerm" {
  subscription_id = var.subscription_id

  features {}
}

locals {
  tags = {
    project     = "bestrong"
    environment = "dev"
    managed-by  = "terraform"
  }
}

# Dedicated long-lived resource group for remote state: state now outlives any
# single deployment of the workload stack.
resource "azurerm_resource_group" "state" {
  name     = var.resource_group_name
  location = var.location
  tags     = local.tags
}

# Suffix for the globally unique state storage account name. Generated once;
# the bootstrap state (and therefore the name) is long-lived.
resource "random_string" "suffix" {
  length  = 6
  upper   = false
  special = false
}

resource "azurerm_storage_account" "tfstate" {
  #checkov:skip=CKV_AZURE_35:State must be reachable from hosted CI agents and the workstation over the public endpoint; access is key-authenticated
  #checkov:skip=CKV_AZURE_59:Public endpoint access is the working state path for this learning project; no private endpoints in scope
  #checkov:skip=CKV_AZURE_33:State blobs only; no queue service in use
  #checkov:skip=CKV_AZURE_206:Standard LRS is sufficient durability for a learning project's state
  #checkov:skip=CKV2_AZURE_1:Platform-managed encryption is sufficient here; no CMK requirement
  #checkov:skip=CKV2_AZURE_33:No private endpoints in scope for the state backend
  #checkov:skip=CKV2_AZURE_40:Backend auth uses storage keys retrieved through ARM by the pipeline backend config; Entra data-plane auth is a noted future hardening
  #checkov:skip=CKV2_AZURE_41:No SAS tokens issued
  name                = "sttfstate${random_string.suffix.result}"
  resource_group_name = azurerm_resource_group.state.name
  location            = var.location

  account_kind             = "StorageV2"
  account_tier             = "Standard"
  account_replication_type = "LRS"

  https_traffic_only_enabled      = true
  min_tls_version                 = "TLS1_2"
  allow_nested_items_to_be_public = false

  # Soft delete protects the state blob against accidental deletion.
  blob_properties {
    delete_retention_policy {
      days = 7
    }
  }

  tags = local.tags
}

resource "azurerm_storage_container" "tfstate" {
  #checkov:skip=CKV2_AZURE_21:No blob-read audit sink for the short-lived state account; logging/observability targets the workload stack, not this backend
  name                  = "tfstate"
  storage_account_id    = azurerm_storage_account.tfstate.id
  container_access_type = "private"
}
