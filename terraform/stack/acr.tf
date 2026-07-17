# Container registry. Basic SKU with admin credentials: the Pluralsight
# sandbox caps ACR at Basic and denies managed identities, so admin login is
# the only working pull path; firewalls/private endpoints would need Premium.
# Images are built locally and pushed with docker push (ACR Tasks are blocked).

resource "azurerm_container_registry" "main" {
  #checkov:skip=CKV_AZURE_137:Admin credentials are the only pull mechanism - the sandbox denies the managed identity an AcrPull role would need
  #checkov:skip=CKV_AZURE_139:Network rules and private endpoints require the Premium SKU, unavailable in the sandbox
  #checkov:skip=CKV_AZURE_164:Content trust requires the Premium SKU, unavailable in the sandbox
  #checkov:skip=CKV_AZURE_165:Geo-replication requires the Premium SKU, unavailable in the sandbox
  #checkov:skip=CKV_AZURE_166:Quarantine policy requires the Premium SKU, unavailable in the sandbox
  #checkov:skip=CKV_AZURE_167:Retention policy requires the Premium SKU, unavailable in the sandbox
  #checkov:skip=CKV_AZURE_233:Zone redundancy requires the Premium SKU, unavailable in the sandbox
  #checkov:skip=CKV_AZURE_237:Dedicated data endpoints require the Premium SKU, unavailable in the sandbox
  #checkov:skip=CKV_AZURE_163:Image vulnerability scanning requires a subscription-level, billed Microsoft Defender plan, unavailable in the sandbox
  name                = local.acr_name
  resource_group_name = data.azurerm_resource_group.playground.name
  location            = var.location
  sku                 = "Basic"
  admin_enabled       = true
  tags                = local.tags
}
