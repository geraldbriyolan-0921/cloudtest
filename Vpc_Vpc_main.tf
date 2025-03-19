terraform {
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 4.0"
    }
  }
}
provider "google" {
  project = var.project_id
  region  = var.region
  zone    = var.zone
}
# ---------------------
# CREATE SERVICE ACCOUNT
# ---------------------
resource "google_service_account" "service_account" {

  account_id   = "cloudcadi-user"
  display_name = "Service Account for CloudCadi Deployment"
}
# ---------------------
# ASSIGN IAM ROLES TO SERVICE ACCOUNT
# ---------------------
# Grant the service account necessary roles
resource "google_project_iam_member" "role" {
  project = var.project_id
  for_each = {
    "CloudSQLInstanceManager" = "projects/amadis-gcp/roles/CloudSQLInstanceManager"
    "BigQueryJobUser"         = "roles/bigquery.jobUser"
    "BigQueryResourceViewer"  = "roles/bigquery.resourceViewer"
    "CloudBuildEditor"        = "roles/cloudbuild.builds.editor"
    "CloudFunctionsInvoker"   = "roles/cloudfunctions.invoker"
    "CloudFunctionsViewer"    = "roles/cloudfunctions.viewer"
    "CloudSQLClient"          = "roles/cloudsql.client"
    "CloudSQLInstanceUser"    = "roles/cloudsql.instanceUser"
    "CloudSQLViewer"          = "roles/cloudsql.viewer"
    "ComputeOSLogin"          = "roles/compute.osLogin"
    "ComputeViewer"           = "roles/compute.viewer"
    "FilestoreViewer"         = "roles/file.viewer"
    "ServiceAccountUser"      = "roles/iam.serviceAccountUser"
    "LogsViewer"              = "roles/logging.viewer"
    "MonitoringViewer"        = "roles/monitoring.viewer"
    "StorageObjectViewer"     = "roles/storage.objectViewer"
  }
  role   = each.value
  member = "serviceAccount:${google_service_account.service_account.email}"
}
# ---------------------
# VPC NETWORK & SUBNETS
# ---------------------
resource "google_compute_network" "vpc_network" {
  name                    = "cloudcadi-vpc-network"
  auto_create_subnetworks = false
  mtu                     = 1460
  routing_mode            = "REGIONAL"
}
resource "google_compute_subnetwork" "subnet" {
  name                     = "cloudcadi-subnet"

  ip_cidr_range            = "10.0.10.0/24"
  network                  = google_compute_network.vpc_network.id
  region                   = var.region
  private_ip_google_access = true
  stack_type               = "IPV4_ONLY"
}
# ---------------------
# VPC PEERING
# ---------------------
resource "google_compute_global_address" "vpc_peering" {
  name          = "cloudcadi-vpc-peering"
  purpose       = "VPC_PEERING"
  address_type  = "INTERNAL"
  prefix_length = 24
  network       = google_compute_network.vpc_network.id
  address       = "10.0.20.0"
}
resource "google_service_networking_connection" "private_vpc_peering" {
  network                 = google_compute_network.vpc_network.id
  service                 = "servicenetworking.googleapis.com"
  reserved_peering_ranges = [google_compute_global_address.vpc_peering.name]
}
# ---------------------
# FIREWALL RULES
# ---------------------
# Allow SSH
resource "google_compute_firewall" "allow_ssh" {
  name    = "cloudcadi-allow-ssh"
  network = google_compute_network.vpc_network.name
  allow {
    protocol = "tcp"
    ports    = ["22"]
  }
  source_ranges = ["0.0.0.0/0"]
}
# Allow Custom Traffic (TCP 5432)
resource "google_compute_firewall" "allow_custom" {
  name    = "cloudcadi-allow-custom"
  network = google_compute_network.vpc_network.name
  allow {
    protocol = "tcp"
    ports    = ["5432"]
  }
  source_ranges = ["0.0.0.0/0"]
}
resource "google_compute_firewall" "allow_http" {
  name    = "cloudcadi-allow-http"
  network = google_compute_network.vpc_network.name
  allow {
    protocol = "tcp"
    ports    = ["80"]
  }
  source_ranges = ["0.0.0.0/0"]
  target_tags   = ["http-server"]
}
resource "google_compute_firewall" "allow_https" {
  name    = "cloudcadi-allow-https"
  network = google_compute_network.vpc_network.name
  allow {
    protocol = "tcp"
    ports    = ["443"]
  }
  source_ranges = ["0.0.0.0/0"]
  target_tags   = ["https-server"]
}
# ---------------------
# STATIC EXTERNAL IP
# ---------------------
resource "google_compute_address" "static_external_ip" {
  name         = "cloudcadi-static-external-ip"
  region       = var.region
  address_type = "EXTERNAL"
  network_tier = "STANDARD"

}
# ---------------------
# CLOUD RUN FUNCTION
# ---------------------
resource "google_cloud_run_v2_service" "cloud_run_function" {
  name     = "cloudcadi-cloud-run-function"
  location = var.region
  template {
    containers {
      image = "us-central1-docker.pkg.dev/amadis-gcp/cloud-app-test/cloud-app@sha256:23c1e7dad1f50ca46c986f64c71f174efff1a246be4ed9f0e143b472a4c408fc"
      ports {
        container_port = 8080
      }
      env {
        name  = "API_BASE_URL"
        value = "http://${google_compute_address.static_external_ip.address}"
      }
      resources {
        limits = {
          memory = "1Gi"
        }
      }
    }
    timeout = "3600s"
    vpc_access {
      network_interfaces {
        network    = google_compute_network.vpc_network.id
        subnetwork = google_compute_subnetwork.subnet.id
      }
    }
    service_account = google_service_account.service_account.email
  }
  traffic {
    percent = 100
    type    = "TRAFFIC_TARGET_ALLOCATION_TYPE_LATEST"
  }
}
resource "google_cloud_run_service_iam_policy" "no_unauth" {
  location = google_cloud_run_v2_service.cloud_run_function.location
  service  = google_cloud_run_v2_service.cloud_run_function.name
  policy_data = jsonencode({
    bindings = []
  })
}
# ---------------------
# CLOUD SQL POSTGRES INSTANCE
# ---------------------
resource "google_sql_database_instance" "sql_database" {
  depends_on       = [google_service_networking_connection.private_vpc_peering]
  name             = "cloudcadi-sql-database"
  database_version = "POSTGRES_14"
  region           = var.region
  settings {
    tier              = "db-custom-4-15360"
    availability_type = "ZONAL"
    disk_type         = "PD_SSD"
    disk_size         = 64
    backup_configuration {
      enabled = false
    }
    ip_configuration {
      ipv4_enabled    = false
      private_network = google_compute_network.vpc_network.id
    }
    maintenance_window {
      day  = 1
      hour = 0
    }
    location_preference {
      zone = var.zone
    }
  }
  deletion_protection = true
  timeouts {
    create = "30m"
    update = "30m"
    delete = "30m"
  }
}
resource "random_password" "sql_database_password" {
  length           = 16
  special          = true
  override_special = "_%@"
}
resource "google_sql_user" "default" {
  name     = "cloudcadi-admin"
  instance = google_sql_database_instance.sql_database.name
  password = random_password.sql_database_password.result
}
# ---------------------
# COMPUTE ENGINE VM WITH CONTAINER
# ---------------------
resource "google_compute_instance" "compute_instance" {
  name         = "cloudcadi-compute-engine"
  machine_type = "n4-highcpu-8"
  zone         = var.zone
  boot_disk {
    auto_delete = true
    device_name = "compute_instance"
    initialize_params {
      image = "projects/cos-cloud/global/images/cos-105-17412-535-63"
      size  = 20
      type  = "hyperdisk-balanced"
    }
  }
  can_ip_forward      = false
  deletion_protection = false
  enable_display      = false
  labels = {
    goog-ec-src = "cloudcadi"
  }
  metadata = {
    gce-container-declaration = <<-EOT
      spec:
        containers:
        - name: compute_instance-20250313-101506
          image: us-central1-docker.pkg.dev/amadis-gcp/ajay-repos/cloudcadi-v4:latest
          env:
          - name: POSTGRESQLCONNSTR_DB_HOST
            value: ${google_sql_database_instance.sql_database.private_ip_address}
          - name: POSTGRESQLCONNSTR_DB_NAME
            value: cloudcadi-database
          - name: POSTGRESQLCONNSTR_DB_USER
            value: ${google_sql_user.default.name}
          - name: POSTGRESQLCONNSTR_DB_PASS
            value: ${random_password.sql_database_password.result}
          - name: POSTGRESQLCONNSTR_SSL_STATUS
            value: "true"
          - name: FRONTEND_URL
            value: http://${google_compute_address.static_external_ip.address}
          stdin: false
          tty: false
        restartPolicy: Always
    EOT
    google-logging-enabled    = "true"
    google-monitoring-enabled = "true"
  }
  network_interface {
    subnetwork = google_compute_subnetwork.subnet.id
    access_config {
      nat_ip       = google_compute_address.static_external_ip.address
      network_tier = "STANDARD"
    }
    nic_type    = "GVNIC"
    queue_count = 0
    stack_type  = "IPV4_ONLY"
  }
  scheduling {
    automatic_restart   = true
    on_host_maintenance = "MIGRATE"
    preemptible         = false
    provisioning_model  = "STANDARD"
  }
  service_account {
    email  = google_service_account.service_account.email
    scopes = ["cloud-platform"]
  }
  shielded_instance_config {
    enable_integrity_monitoring = true
    enable_secure_boot          = false
    enable_vtpm                 = true
  }
  tags = ["http-server", "https-server"]
}
# ---------------------
# OUTPUTS
# ---------------------
output "service_account_email" {
  value = google_service_account.service_account.email
}
output "vpc_id" {
  value = google_compute_network.vpc_network.id
}
output "private_vpc_peering_id" {
  value = google_service_networking_connection.private_vpc_peering.id
}
output "sql_instance_name" {
  value = google_sql_database_instance.sql_database.name
}
output "sql_user_password" {
  value     = random_password.sql_database_password.result
  sensitive = true
}
output "cloud_run_name" {
  value = google_cloud_run_v2_service.cloud_run_function.name
}
variable "project_id" {}
variable "region" {}
variable "zone" {}

