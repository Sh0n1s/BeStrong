# Minimal TFLint configuration shared by both Terraform root modules.
# CI runs: tflint --init --config <this file>, then --chdir per root.

plugin "azurerm" {
  enabled = true
  version = "0.27.0"
  source  = "github.com/terraform-linters/tflint-ruleset-azurerm"
}
