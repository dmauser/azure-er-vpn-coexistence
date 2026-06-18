# ---------------------------------------------------------------------------
# Remote state: reads vpn_gateway_public_ip + vpn_shared_key from Azure side.
# The state file is written by terraform/azure/ (Trinity's config).
# During standalone validate this path need not exist — it only resolves at plan/apply.
# ---------------------------------------------------------------------------
data "terraform_remote_state" "azure" {
  backend = "local"
  config = {
    path = var.azure_remote_state_path
  }
}

# ---------------------------------------------------------------------------
# VPC — custom-mode, REGIONAL routing, MTU 1460 (matches gcloud deploy step)
# ---------------------------------------------------------------------------
resource "google_compute_network" "vpc" {
  name                    = "${var.envname}-vpc"
  auto_create_subnetworks = false
  routing_mode            = "REGIONAL"
  mtu                     = 1460
}

resource "google_compute_subnetwork" "subnet" {
  name          = "${var.envname}-subnet"
  ip_cidr_range = var.vpc_range
  network       = google_compute_network.vpc.id
  region        = var.region
}

# ---------------------------------------------------------------------------
# Firewall — allow TCP/UDP/ICMP from RFC1918 + GCP IAP range + caller IP
# Name matches the gcloud command: <envname>-allow-traffic-from-azure
# ---------------------------------------------------------------------------
resource "google_compute_firewall" "allow_rfc1918_iap" {
  name    = "${var.envname}-allow-traffic-from-azure"
  network = google_compute_network.vpc.name

  allow {
    protocol = "tcp"
  }

  allow {
    protocol = "udp"
  }

  allow {
    protocol = "icmp"
  }

  source_ranges = [
    "192.168.0.0/16",
    "10.0.0.0/8",
    "172.16.0.0/12",
    "35.235.240.0/20", # GCP IAP / Cloud Console SSH range
    "${var.caller_source_ip}/32",
  ]
}

# ---------------------------------------------------------------------------
# Ubuntu 22.04 test VM — e2-micro, 10 GB pd-balanced, PREMIUM NIC
# Mirrors: gcloud compute instances create <envname>-vm1 ...
# ---------------------------------------------------------------------------
resource "google_compute_instance" "vm1" {
  name         = "${var.envname}-vm1"
  machine_type = "e2-micro"
  zone         = var.zone

  boot_disk {
    initialize_params {
      image = "ubuntu-os-cloud/ubuntu-2204-lts"
      size  = 10
      type  = "pd-balanced"
    }
    device_name = "${var.envname}-vm1"
  }

  network_interface {
    subnetwork = google_compute_subnetwork.subnet.self_link

    # PREMIUM tier external IP — required for IAP SSH + internet access
    access_config {
      network_tier = "PREMIUM"
    }
  }
}
