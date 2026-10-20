output "environment_id" {
  value = confluent_environment.this.id
}

output "environment_crn" {
  value = confluent_environment.this.resource_name
}

output "primary" {
  description = "Primary (single-zone) cluster"
  value = {
    id        = confluent_kafka_cluster.primary.id
    crn       = confluent_kafka_cluster.primary.rbac_crn
    bootstrap = confluent_kafka_cluster.primary.bootstrap_endpoint
    rest      = confluent_kafka_cluster.primary.rest_endpoint
  }
}

output "secondary" {
  description = "Secondary (multi-zone) cluster"
  value = {
    id        = confluent_kafka_cluster.secondary.id
    crn       = confluent_kafka_cluster.secondary.rbac_crn
    bootstrap = confluent_kafka_cluster.secondary.bootstrap_endpoint
    rest      = confluent_kafka_cluster.secondary.rest_endpoint
  }
}

output "switchover_pair_id" {
  value = try(confluent_switchover_pair.this[0].id, null)
}

output "switchover_endpoint_id" {
  value = try(confluent_switchover_endpoint.this[0].id, null)
}

output "global_bootstrap" {
  description = "Global bootstrap URL clients use to fail over transparently"
  value = var.deploy_links ? format(
    "glkc-%s-%s.global.glb.confluent.cloud:9092",
    confluent_switchover_pair.this[0].id,
    confluent_switchover_endpoint.this[0].id,
  ) : null
}

output "link_api_keys" {
  description = "Cluster-scoped API keys used by the cluster link identity"
  value = {
    primary   = { key = confluent_api_key.link_primary.id, secret = confluent_api_key.link_primary.secret }
    secondary = { key = confluent_api_key.link_secondary.id, secret = confluent_api_key.link_secondary.secret }
  }
  sensitive = true
}

output "app_global_api_key" {
  description = "Kafka Global API key for producer/consumer/test client"
  value       = { key = confluent_api_key.app_global.id, secret = confluent_api_key.app_global.secret }
  sensitive   = true
}

output "admin_cloud_api_key" {
  description = "Cloud API key (EnvironmentAdmin) for Switchover + Metrics APIs"
  value       = { key = confluent_api_key.admin_cloud.id, secret = confluent_api_key.admin_cloud.secret }
  sensitive   = true
}

# Environment for demo-app/ (also written to demo.env)
output "demo_env" {
  sensitive = true
  value     = local.demo_env
}
