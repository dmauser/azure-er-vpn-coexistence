terraform {
  required_version = ">= 1.5"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.0"
    }
  }
}

# Credentials via Application Default Credentials (ADC).
# Run: gcloud auth application-default login
provider "google" {
  project = var.project
  region  = var.region
}
