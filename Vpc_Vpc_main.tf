provider "google" {
  project = var.project_id
  region  = var.region
}


resource "google_compute_network" "cloudcadi_vpc" {
  name                    = "cloudcadi"
  auto_create_subnetworks = false
  mtu                     = 1460
  routing_mode            = "REGIONAL"
}

# Create Subnet 1
resource "google_compute_subnetwork" "subnet1" {
  name                     = "subnet-1"
  network                  = google_compute_network.cloudcadi_vpc.id
  region                   = "us-central1"
  ip_cidr_range            = "10.0.0.0/24"
  private_ip_google_access = true  # Required for private services
  stack_type               = "IPV4_ONLY"
}

# Create Subnet 2
resource "google_compute_subnetwork" "subnet2" {
  name                     = "subnet-2"
  network                  = google_compute_network.cloudcadi_vpc.id
  region                   = "us-central1"
  ip_cidr_range            = "10.0.1.0/24"
  private_ip_google_access = true  # Required for private services
  stack_type               = "IPV4_ONLY"
}

resource "google_compute_firewall" "allow_rdp" {
  name    = "allow-rdp"
  network = google_compute_network.cloudcadi_vpc.name

  allow {
    protocol = "tcp"
    ports    = ["3389"]
  }

  direction     = "INGRESS"
  priority      = 65534
  source_ranges = ["0.0.0.0/0"] # Modify for security
}

resource "google_compute_firewall" "allow_ssh" {
  name    = "allow-ssh"
  network = google_compute_network.cloudcadi_vpc.name

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }

  direction     = "INGRESS"
  priority      = 65534
  source_ranges = ["0.0.0.0/0"] # Modify for security
}

variable "project_id" {}
variable "region" {}
