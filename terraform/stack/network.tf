# VNet + subnets. Network baseline is service endpoints + per-service PaaS
# firewalls: no NSGs, no private DNS zones, no private endpoints here.
# Each service file owns its own firewall rules next to the resource.

resource "azurerm_virtual_network" "main" {
  name                = local.vnet_name
  resource_group_name = azurerm_resource_group.main.name
  location            = var.location
  address_space       = ["10.20.0.0/16"]
  tags                = local.tags
}

resource "azurerm_subnet" "app" {
  #checkov:skip=CKV2_AZURE_31:No NSGs by design - delegated egress-only subnet; protection comes from service endpoints + PaaS firewalls
  name                 = local.subnet_app_name
  resource_group_name  = azurerm_resource_group.main.name
  virtual_network_name = azurerm_virtual_network.main.name
  address_prefixes     = ["10.20.1.0/24"]
  service_endpoints    = ["Microsoft.Sql", "Microsoft.KeyVault", "Microsoft.Storage"]

  # Regional VNet integration for the Web App.
  delegation {
    name = "appservice-delegation"

    service_delegation {
      name    = "Microsoft.Web/serverFarms"
      actions = ["Microsoft.Network/virtualNetworks/subnets/action"]
    }
  }
}

# Reserved subnet - used only by the flag-gated SQL private endpoint
# experiment in sql.tf (default off).
resource "azurerm_subnet" "private_endpoints" {
  #checkov:skip=CKV2_AZURE_31:No NSGs by design - reserved subnet, empty unless the SQL private endpoint experiment is enabled
  name                              = local.subnet_private_endpoints_name
  resource_group_name               = azurerm_resource_group.main.name
  virtual_network_name              = azurerm_virtual_network.main.name
  address_prefixes                  = ["10.20.2.0/24"]
  private_endpoint_network_policies = "Disabled"
}
