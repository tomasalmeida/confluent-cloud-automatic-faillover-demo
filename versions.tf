# Reference demo: https://github.com/danjrichards/transparent-failover
terraform {
  required_version = ">= 1.5"

  required_providers {
    confluent = {
      source  = "confluentinc/confluent"
      version = ">= 2.88.0" # switchover pair/endpoint resources
    }
    local = {
      source  = "hashicorp/local"
      version = ">= 2.4.0"
    }
  }
}

# Bootstrap Cloud API key: needs OrganizationAdmin or EnvironmentAdmin
# (Cloud Resource Management or Global scope).
provider "confluent" {
  cloud_api_key    = var.confluent_cloud_api_key
  cloud_api_secret = var.confluent_cloud_api_secret
}
