# Terraform and provider version constraints.

terraform {
  required_version = ">= 1.5"

  # Partial backend configuration: values are supplied at init time by
  # deploy.ps1 via -backend-config=.session/backend.hcl, because the state
  # storage account is bootstrapped inside the sandbox every session.
  backend "azurerm" {}

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
}
