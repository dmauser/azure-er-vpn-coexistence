variable "project" {
  description = "GCP project ID."
  type        = string
}

variable "region" {
  description = "GCP region."
  type        = string
  default     = "us-central1"
}

variable "zone" {
  description = "GCP availability zone."
  type        = string
  default     = "us-central1-c"
}

variable "vpc_range" {
  description = "CIDR for the GCP on-prem subnet (e.g. 192.168.0.0/24)."
  type        = string
  default     = "192.168.0.0/24"
}

variable "machine_type" {
  description = "GCE machine type for the test VM (e.g. e2-micro, e2-small, e2-medium)."
  type        = string
  default     = "e2-micro"
}

variable "envname" {
  description = "Prefix applied to all resource names."
  type        = string
  default     = "vpnlab"
}

variable "caller_source_ip" {
  description = "Your current public IP address (no CIDR mask). Added as /32 to the firewall allow-list."
  type        = string
}

variable "enable_interconnect" {
  description = "When true, deploys Cloud Router and a Partner Interconnect VLAN attachment."
  type        = bool
  default     = false
}

variable "azure_remote_state_path" {
  description = "Path to the Azure Terraform state file consumed via terraform_remote_state (relative to this module root)."
  type        = string
  default     = "../azure/terraform.tfstate"
}
