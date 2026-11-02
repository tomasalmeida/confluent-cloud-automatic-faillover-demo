variable "confluent_cloud_api_key" {
  description = "Bootstrap Cloud API key used by Terraform (OrganizationAdmin or EnvironmentAdmin)."
  type        = string
  sensitive   = true
}

variable "confluent_cloud_api_secret" {
  type      = string
  sensitive = true
}

variable "environment_name" {
  type    = string
  default = "transparent-failover"
}

variable "primary_cloud" {
  description = "Cloud provider for the primary cluster (AWS, AZURE, GCP)."
  type        = string
  default     = "AZURE"
}

variable "secondary_cloud" {
  description = "Cloud provider for the secondary cluster (AWS, AZURE, GCP)."
  type        = string
  default     = "AWS"
}

variable "primary_region" {
  description = "Region of the primary (single-zone) cluster."
  type        = string
  default     = "westeurope"
}

variable "secondary_region" {
  description = "Region of the secondary (multi-zone) cluster."
  type        = string
  default     = "eu-west-1"
}

variable "cku" {
  description = "CKUs for BOTH clusters. Must be identical and >= 2 (multi-zone minimum)."
  type        = number
  default     = 2

  validation {
    condition     = var.cku >= 2
    error_message = "Multi-zone Dedicated clusters need at least 2 CKUs; keep both clusters equal."
  }
}

variable "deploy_links" {
  description = "Create the bidirectional cluster links, switchover pair and endpoint (Early Access feature). Set false to only create clusters, identities and keys."
  type        = bool
  default     = true
}

variable "topic_name" {
  description = "Topic used by the demo app."
  type        = string
  default     = "purchases"
}

variable "consumer_group" {
  description = "Consumer group used by the demo app."
  type        = string
  default     = "dr-demo-consumer"
}

variable "prefix" {
  description = "Prefix added to the names of all created resources (avoids name collisions in the org)."
  type        = string
}

variable "topic_partitions" {
  description = "Partitions of the demo topic."
  type        = number
  default     = 6
}

variable "demo_port" {
  description = "Port the demo dashboard listens on (the app defaults to 80, which needs root)."
  type        = number
  default     = 3000
}
