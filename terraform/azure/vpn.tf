# ---------------------------------------------------------------------------
# Shared VPN pre-shared key — generated once, stored in state.
# ASCII-only (special = false) so it is safe as a PSK.
# ---------------------------------------------------------------------------
resource "random_password" "vpn_shared_key" {
  length  = 24
  special = false
}

# ---------------------------------------------------------------------------
# GCP remote state — only read when the on-prem connection is enabled.
# Expects outputs: gcp_vpn_public_ip, gcp_vpc_cidr  (Tank contract).
# ---------------------------------------------------------------------------
data "terraform_remote_state" "gcp" {
  count   = var.enable_onprem_connection ? 1 : 0
  backend = "local"
  config = {
    path = var.gcp_remote_state_path
  }
}

# ---------------------------------------------------------------------------
# Local Network Gateway — represents the GCP on-prem VPN endpoint.
# Name matches deploy.azcli: lng-onprem-gcp
# ---------------------------------------------------------------------------
resource "azurerm_local_network_gateway" "gcp" {
  count               = var.enable_onprem_connection ? 1 : 0
  name                = "lng-onprem-gcp"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  # try() lets `terraform destroy` proceed even after the GCP side (and its
  # outputs) has already been torn down. During apply the outputs exist, so the
  # real values are always used. 1.2.3.4 is a destroy-only placeholder.
  gateway_address = try(data.terraform_remote_state.gcp[0].outputs.gcp_vpn_public_ip, "1.2.3.4")
  address_space   = [try(data.terraform_remote_state.gcp[0].outputs.gcp_vpc_cidr, "192.168.0.0/24")]
  tags            = local.tags
}

# ---------------------------------------------------------------------------
# VPN Connection: Azure → GCP on-prem.
# Name matches deploy.azcli: Azure-to-OnpremGCP
# ---------------------------------------------------------------------------
resource "azurerm_virtual_network_gateway_connection" "azure_to_onprem_gcp" {
  count                      = var.enable_onprem_connection ? 1 : 0
  name                       = "Azure-to-OnpremGCP"
  location                   = azurerm_resource_group.this.location
  resource_group_name        = azurerm_resource_group.this.name
  type                       = "IPsec"
  virtual_network_gateway_id = azurerm_virtual_network_gateway.vpn.id
  local_network_gateway_id   = azurerm_local_network_gateway.gcp[0].id
  shared_key                 = random_password.vpn_shared_key.result
  tags                       = local.tags
}
