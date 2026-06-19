# ---------------------------------------------------------------------------
# Resource group + region
# ---------------------------------------------------------------------------
variable "resource_group_name" {
  description = "Name of the Azure resource group"
  type        = string
  default     = "lab-er-vpn-coexistence"
}

variable "location" {
  description = "Azure region for all resources"
  type        = string
  default     = "centralus"
}

# ---------------------------------------------------------------------------
# VNet name prefixes
# ---------------------------------------------------------------------------
variable "hub_name" {
  description = "Hub VNet name prefix (e.g. Az-Hub)"
  type        = string
  default     = "Az-Hub"
}

variable "spoke1_name" {
  description = "Spoke 1 VNet name prefix (e.g. Az-Spk1)"
  type        = string
  default     = "Az-Spk1"
}

variable "spoke2_name" {
  description = "Spoke 2 VNet name prefix (e.g. Az-Spk2)"
  type        = string
  default     = "Az-Spk2"
}

# ---------------------------------------------------------------------------
# Address plan — must not overlap; defaults match deploy.azcli
# ---------------------------------------------------------------------------
variable "hub_address_space" {
  description = "Hub VNet address space"
  type        = string
  default     = "10.0.10.0/24"
}

variable "hub_subnet_prefix" {
  description = "Hub VM subnet (subnet1) prefix"
  type        = string
  default     = "10.0.10.0/27"
}

variable "gateway_subnet_prefix" {
  description = "GatewaySubnet prefix (shared by VPN + ExpressRoute gateways)"
  type        = string
  default     = "10.0.10.32/27"
}

variable "spoke1_address_space" {
  description = "Spoke 1 VNet address space"
  type        = string
  default     = "10.0.11.0/24"
}

variable "spoke1_subnet_prefix" {
  description = "Spoke 1 VM subnet (subnet1) prefix"
  type        = string
  default     = "10.0.11.0/27"
}

variable "spoke2_address_space" {
  description = "Spoke 2 VNet address space"
  type        = string
  default     = "10.0.12.0/24"
}

variable "spoke2_subnet_prefix" {
  description = "Spoke 2 VM subnet (subnet1) prefix"
  type        = string
  default     = "10.0.12.0/27"
}

# ---------------------------------------------------------------------------
# VM credentials (required — no defaults)
# ---------------------------------------------------------------------------
variable "vm_admin_username" {
  description = "Admin username for all Linux VMs"
  type        = string
}

variable "vm_admin_password" {
  description = "Admin password for all Linux VMs"
  type        = string
  sensitive   = true
}

variable "vm_size" {
  description = "Azure VM size for all test VMs"
  type        = string
  default     = "Standard_B1s"
}

# ---------------------------------------------------------------------------
# VPN Gateway
# ---------------------------------------------------------------------------
variable "gateway_sku" {
  description = "VPN gateway SKU. Must be an AZ SKU (VpnGw1AZ-VpnGw5AZ); Azure no longer allows non-AZ VpnGw1-5 SKUs for new VPN gateways."
  type        = string
  default     = "VpnGw1AZ"

  validation {
    condition     = can(regex("^VpnGw[1-5]AZ$", var.gateway_sku))
    error_message = "gateway_sku must be an AZ SKU (VpnGw1AZ, VpnGw2AZ, VpnGw3AZ, VpnGw4AZ, or VpnGw5AZ). Non-AZ SKUs (VpnGw1-5) are no longer supported by Azure for new VPN gateways."
  }
}

variable "vpn_gateway_generation" {
  description = "VPN gateway generation (Generation1 or Generation2)"
  type        = string
  default     = "Generation1"
}

# ---------------------------------------------------------------------------
# Phase toggles
# ---------------------------------------------------------------------------
variable "enable_onprem_connection" {
  description = "Phase-2 toggle: creates Local Network Gateway (lng-onprem-gcp) + VPN connection (Azure-to-OnpremGCP). Requires GCP state at gcp_remote_state_path."
  type        = bool
  default     = false
}

variable "enable_expressroute" {
  description = "Phase-3 toggle: creates the ExpressRoute circuit (az-hub-er-circuit). The ER gateway connection is gated separately by enable_er_connection."
  type        = bool
  default     = false
}

variable "enable_er_connection" {
  description = "Phase-3b toggle: creates the ER gateway connection (ER-Connection-to-Onprem). Only set true AFTER the circuit shows serviceProviderProvisioningState=Provisioned, otherwise the attach fails. Requires enable_expressroute = true."
  type        = bool
  default     = false
}

# ---------------------------------------------------------------------------
# ExpressRoute circuit parameters
# ---------------------------------------------------------------------------
variable "express_route_peering_location" {
  description = "ExpressRoute peering location"
  type        = string
  default     = "Chicago"
}

variable "express_route_provider" {
  description = "ExpressRoute service provider name"
  type        = string
  default     = "Megaport"
}

variable "express_route_bandwidth_mbps" {
  description = "ExpressRoute circuit bandwidth in Mbps"
  type        = number
  default     = 50
}

# ---------------------------------------------------------------------------
# GCP remote state path (consumed when enable_onprem_connection = true)
# ---------------------------------------------------------------------------
variable "gcp_remote_state_path" {
  description = "Relative path to the GCP Terraform local state file. Used to read gcp_vpn_public_ip and gcp_vpc_cidr."
  type        = string
  default     = "../gcp/terraform.tfstate"
}
