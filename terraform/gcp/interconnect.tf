# ---------------------------------------------------------------------------
# Cloud Router + Partner Interconnect VLAN attachment
# Gated on var.enable_interconnect (default false).
# Mirrors the gcloud steps:
#   gcloud compute routers create <envname>-router --asn=16550
#   gcloud compute interconnects attachments partner create <envname>-vlan \
#     --edge-availability-domain availability-domain-1 --admin-enabled
# ---------------------------------------------------------------------------

resource "google_compute_router" "this" {
  count   = var.enable_interconnect ? 1 : 0
  name    = "${var.envname}-router"
  network = google_compute_network.vpc.name
  region  = var.region

  bgp {
    asn = 16550
  }
}

resource "google_compute_interconnect_attachment" "this" {
  count                    = var.enable_interconnect ? 1 : 0
  name                     = "${var.envname}-vlan"
  region                   = var.region
  type                     = "PARTNER"
  edge_availability_domain = "AVAILABILITY_DOMAIN_1"
  admin_enabled            = true
  router                   = google_compute_router.this[0].id
}
