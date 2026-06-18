# ---------------------------------------------------------------------------
# Classic VPN — mirrors the gcloud deploy steps exactly:
#   target-vpn-gateways create onpremvpn
#   addresses create onpremvpn-pip
#   forwarding-rules create onpremvpn-rule-esp / udp500 / udp4500
#   vpn-tunnels create vpn-to-azure  (IKEv2, static selectors 0.0.0.0/0)
#   routes create vpn-to-azure-route-1  (10.0.0.0/8 → tunnel)
# ---------------------------------------------------------------------------

resource "google_compute_vpn_gateway" "onpremvpn" {
  name    = "onpremvpn"
  network = google_compute_network.vpc.id
  region  = var.region
}

resource "google_compute_address" "onpremvpn_pip" {
  name   = "onpremvpn-pip"
  region = var.region
}

# Three forwarding rules that steer ESP, IKE (UDP 500), and NAT-T (UDP 4500)
# traffic from the static IP into the target VPN gateway.

resource "google_compute_forwarding_rule" "esp" {
  name        = "onpremvpn-rule-esp"
  region      = var.region
  ip_address  = google_compute_address.onpremvpn_pip.address
  ip_protocol = "ESP"
  target      = google_compute_vpn_gateway.onpremvpn.self_link
}

resource "google_compute_forwarding_rule" "udp500" {
  name        = "onpremvpn-rule-udp500"
  region      = var.region
  ip_address  = google_compute_address.onpremvpn_pip.address
  ip_protocol = "UDP"
  port_range  = "500"
  target      = google_compute_vpn_gateway.onpremvpn.self_link
}

resource "google_compute_forwarding_rule" "udp4500" {
  name        = "onpremvpn-rule-udp4500"
  region      = var.region
  ip_address  = google_compute_address.onpremvpn_pip.address
  ip_protocol = "UDP"
  port_range  = "4500"
  target      = google_compute_vpn_gateway.onpremvpn.self_link
}

# ---------------------------------------------------------------------------
# VPN Tunnel to Azure
# peer_ip and shared_secret come from the Azure Terraform state (Trinity's outputs).
# The shared key is generated on the Azure side — it is never created here.
# ---------------------------------------------------------------------------
resource "google_compute_vpn_tunnel" "to_azure" {
  name   = "vpn-to-azure"
  region = var.region

  peer_ip                 = data.terraform_remote_state.azure.outputs.vpn_gateway_public_ip
  shared_secret           = data.terraform_remote_state.azure.outputs.vpn_shared_key
  ike_version             = 2
  local_traffic_selector  = ["0.0.0.0/0"]
  remote_traffic_selector = ["0.0.0.0/0"]
  target_vpn_gateway      = google_compute_vpn_gateway.onpremvpn.id

  # Forwarding rules must exist before the tunnel can be negotiated.
  depends_on = [
    google_compute_forwarding_rule.esp,
    google_compute_forwarding_rule.udp500,
    google_compute_forwarding_rule.udp4500,
  ]
}

# ---------------------------------------------------------------------------
# Static route — 10.0.0.0/8 → VPN tunnel (covers all Azure VNets in the lab)
# ---------------------------------------------------------------------------
resource "google_compute_route" "to_azure" {
  name                = "vpn-to-azure-route-1"
  network             = google_compute_network.vpc.name
  dest_range          = "10.0.0.0/8"
  priority            = 1000
  next_hop_vpn_tunnel = google_compute_vpn_tunnel.to_azure.id
}
