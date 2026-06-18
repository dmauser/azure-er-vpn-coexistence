output "gcp_vpn_public_ip" {
  description = "Static public IP of the Classic VPN gateway. Azure Local Network Gateway must point here."
  value       = google_compute_address.onpremvpn_pip.address
}

output "gcp_vpc_cidr" {
  description = "GCP on-prem subnet CIDR. Azure Local Network Gateway uses this as the on-prem address prefix."
  value       = var.vpc_range
}

output "interconnect_pairing_key" {
  description = "Partner Interconnect pairing key. Provide to your connectivity provider (e.g. Megaport) to create the VXC."
  value       = var.enable_interconnect ? google_compute_interconnect_attachment.this[0].pairing_key : null
  sensitive   = true
}

output "interconnect_attachment_name" {
  description = "Name of the Partner Interconnect VLAN attachment (only set when enable_interconnect = true)."
  value       = var.enable_interconnect ? google_compute_interconnect_attachment.this[0].name : null
}
