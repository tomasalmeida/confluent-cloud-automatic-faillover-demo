# Two public Dedicated clusters (SZ primary, MZ secondary) for Confluent Cloud
# DR Automatic Failover, plus the identities and API keys the demo app needs.
# Demo: https://github.com/danjrichards/transparent-failover

resource "confluent_environment" "this" {
  display_name = "${var.prefix}-${var.environment_name}"

  stream_governance {
    package = "ESSENTIALS"
  }
}

# ---------------------------------------------------------------- clusters
resource "confluent_kafka_cluster" "primary" {
  display_name = "${var.prefix}-primary-sz"
  availability = "SINGLE_ZONE"
  cloud        = var.primary_cloud
  region       = var.primary_region

  dedicated {
    cku = var.cku
  }

  environment {
    id = confluent_environment.this.id
  }
}

resource "confluent_kafka_cluster" "secondary" {
  display_name = "${var.prefix}-secondary-mz"
  availability = "MULTI_ZONE"
  cloud        = var.secondary_cloud
  region       = var.secondary_region

  dedicated {
    cku = var.cku
  }

  environment {
    id = confluent_environment.this.id
  }
}

# ---------------------------------------------------------------- identities
resource "confluent_service_account" "link" {
  display_name = "${var.prefix}-dr-link-sa"
  description  = "Owns the bidirectional cluster link"
}

resource "confluent_service_account" "app" {
  display_name = "${var.prefix}-dr-demo-app-sa"
  description  = "Producer/consumer for the transparent-failover demo"
}

resource "confluent_service_account" "admin" {
  display_name = "${var.prefix}-dr-demo-admin-sa"
  description  = "Switchover API and Metrics API access for the demo dashboard"
}

# Link identity: CloudClusterAdmin on both clusters
resource "confluent_role_binding" "link_primary" {
  principal   = "User:${confluent_service_account.link.id}"
  role_name   = "CloudClusterAdmin"
  crn_pattern = confluent_kafka_cluster.primary.rbac_crn
}

resource "confluent_role_binding" "link_secondary" {
  principal   = "User:${confluent_service_account.link.id}"
  role_name   = "CloudClusterAdmin"
  crn_pattern = confluent_kafka_cluster.secondary.rbac_crn
}

# Dashboard identity: EnvironmentAdmin (Switchover + Metrics APIs)
resource "confluent_role_binding" "admin_env" {
  principal   = "User:${confluent_service_account.admin.id}"
  role_name   = "EnvironmentAdmin"
  crn_pattern = confluent_environment.this.resource_name
}

# Client access on BOTH clusters (RBAC bindings are not synced by the link)
locals {
  clusters = {
    primary   = confluent_kafka_cluster.primary
    secondary = confluent_kafka_cluster.secondary
  }

  app_bindings = {
    for pair in setproduct(keys(local.clusters), ["write", "read", "group"]) :
    "${pair[0]}-${pair[1]}" => {
      cluster = pair[0]
      kind    = pair[1]
    }
  }
}

resource "confluent_role_binding" "app" {
  for_each = local.app_bindings

  principal = "User:${confluent_service_account.app.id}"
  role_name = each.value.kind == "write" ? "DeveloperWrite" : "DeveloperRead"
  crn_pattern = each.value.kind == "group" ? (
    "${local.clusters[each.value.cluster].rbac_crn}/kafka=${local.clusters[each.value.cluster].id}/group=${var.consumer_group}"
    ) : (
    "${local.clusters[each.value.cluster].rbac_crn}/kafka=${local.clusters[each.value.cluster].id}/topic=${var.topic_name}"
  )
}

# ---------------------------------------------------------------- API keys
# Global keys work on both clusters; cluster-scoped keys cannot fail over.
# The cluster link REST API rejects global keys; the link identity needs a
# cluster-scoped key per cluster (used as local and remote credentials).
resource "confluent_api_key" "link_primary" {
  display_name = "${var.prefix}-dr-link-primary-key"
  description  = "Cluster-scoped key for the link identity on the primary cluster"

  owner {
    id          = confluent_service_account.link.id
    api_version = confluent_service_account.link.api_version
    kind        = confluent_service_account.link.kind
  }

  managed_resource {
    id          = confluent_kafka_cluster.primary.id
    api_version = confluent_kafka_cluster.primary.api_version
    kind        = confluent_kafka_cluster.primary.kind

    environment {
      id = confluent_environment.this.id
    }
  }

  depends_on = [confluent_role_binding.link_primary]
}

resource "confluent_api_key" "link_secondary" {
  display_name = "${var.prefix}-dr-link-secondary-key"
  description  = "Cluster-scoped key for the link identity on the secondary cluster"

  owner {
    id          = confluent_service_account.link.id
    api_version = confluent_service_account.link.api_version
    kind        = confluent_service_account.link.kind
  }

  managed_resource {
    id          = confluent_kafka_cluster.secondary.id
    api_version = confluent_kafka_cluster.secondary.api_version
    kind        = confluent_kafka_cluster.secondary.kind

    environment {
      id = confluent_environment.this.id
    }
  }

  depends_on = [confluent_role_binding.link_secondary]
}

# Used by the producer, consumer and test client with the global bootstrap URL
resource "confluent_api_key" "app_global" {
  display_name = "${var.prefix}-dr-demo-app-global-key"
  description  = "Global key for the demo producer/consumer"

  owner {
    id          = confluent_service_account.app.id
    api_version = confluent_service_account.app.api_version
    kind        = confluent_service_account.app.kind
  }

  managed_resource {
    id          = "global"
    api_version = "global/v1"
    kind        = "Global"
  }
}

# Cloud API key for the Switchover API and Metrics API
resource "confluent_api_key" "admin_cloud" {
  display_name = "${var.prefix}-dr-demo-admin-cloud-key"
  description  = "Cloud API key for switchover + metrics"

  owner {
    id          = confluent_service_account.admin.id
    api_version = confluent_service_account.admin.api_version
    kind        = confluent_service_account.admin.kind
  }

  depends_on = [confluent_role_binding.admin_env]
}

# ---------------------------------------------------------------- DR wiring
locals {
  link_name = "${var.prefix}-dr-link"

  # Same settings are used in both directions (see DR automatic failover tutorial).
  # Security settings are read-only here; auth comes from the credentials blocks.
  dr_link_config = {
    "auto.create.mirror.topics.enable"  = "true"
    "auto.create.mirror.topics.filters" = jsonencode({ topicFilters = [{ name = "*", patternType = "LITERAL", filterType = "INCLUDE" }] })
    "topic.config.sync.ms"              = "1000"
    "consumer.offset.sync.enable"       = "true"
    "consumer.offset.sync.ms"           = "1000"
    "consumer.offset.group.filters"     = jsonencode({ groupFilters = [{ name = "*", patternType = "LITERAL", filterType = "INCLUDE", topicTypes = ["LOCAL_MIRROR"] }] })
    "acl.sync.enable"                   = "true"
    "acl.sync.ms"                       = "1000"
    "acl.filters" = jsonencode({
      aclFilters = [{
        resourceFilter = { resourceType = "any", patternType = "any" }
        accessFilter   = { operation = "any", permissionType = "any" }
      }]
    })
  }
}

resource "confluent_cluster_link" "primary_to_secondary" {
  count = var.deploy_links ? 1 : 0

  link_name = local.link_name
  link_mode = "BIDIRECTIONAL"
  config    = local.dr_link_config

  local_kafka_cluster {
    id            = confluent_kafka_cluster.primary.id
    rest_endpoint = confluent_kafka_cluster.primary.rest_endpoint
    credentials {
      key    = confluent_api_key.link_primary.id
      secret = confluent_api_key.link_primary.secret
    }
  }

  remote_kafka_cluster {
    id                 = confluent_kafka_cluster.secondary.id
    bootstrap_endpoint = confluent_kafka_cluster.secondary.bootstrap_endpoint
    credentials {
      key    = confluent_api_key.link_secondary.id
      secret = confluent_api_key.link_secondary.secret
    }
  }
}

resource "confluent_cluster_link" "secondary_to_primary" {
  count = var.deploy_links ? 1 : 0

  link_name = local.link_name
  link_mode = "BIDIRECTIONAL"
  config    = local.dr_link_config

  local_kafka_cluster {
    id            = confluent_kafka_cluster.secondary.id
    rest_endpoint = confluent_kafka_cluster.secondary.rest_endpoint
    credentials {
      key    = confluent_api_key.link_secondary.id
      secret = confluent_api_key.link_secondary.secret
    }
  }

  remote_kafka_cluster {
    id                 = confluent_kafka_cluster.primary.id
    bootstrap_endpoint = confluent_kafka_cluster.primary.bootstrap_endpoint
    credentials {
      key    = confluent_api_key.link_primary.id
      secret = confluent_api_key.link_primary.secret
    }
  }

  depends_on = [confluent_cluster_link.primary_to_secondary]
}

# The Switchover service validates the cluster links' remote state when the pair
# is created and fails if it hasn't observed them yet, so give the links time.
resource "time_sleep" "wait_for_links" {
  count = var.deploy_links ? 1 : 0

  create_duration = "120s"

  depends_on = [
    confluent_cluster_link.primary_to_secondary,
    confluent_cluster_link.secondary_to_primary,
  ]
}

# Blocks until the pair is READY_TO_FAILOVER. Secondary must have no clients.
resource "confluent_switchover_pair" "this" {
  count = var.deploy_links ? 1 : 0

  display_name    = "${var.prefix}-transparent-failover-pair"
  environment_crn = confluent_environment.this.resource_name
  active_member   = "primary"

  members {
    name       = "primary"
    member_crn = confluent_kafka_cluster.primary.rbac_crn
  }

  members {
    name       = "secondary"
    member_crn = confluent_kafka_cluster.secondary.rbac_crn
  }

  depends_on = [time_sleep.wait_for_links]
}

resource "confluent_switchover_endpoint" "this" {
  count = var.deploy_links ? 1 : 0

  display_name        = "${var.prefix}-transparent-failover-endpoint"
  parent_resource_crn = "${confluent_switchover_pair.this[0].environment_crn}/switchover-pair=${confluent_switchover_pair.this[0].id}"

  # Endpoint types must match on both sides (public here)
  endpoints {
    name = "primary-ep"
    endpoint_filter {
      type = "public"
    }
  }

  endpoints {
    name = "secondary-ep"
    endpoint_filter {
      type = "public"
    }
  }
}

# ---------------------------------------------------------------- demo app prep
data "confluent_organization" "this" {}

# Demo topic on the primary only; the link auto-creates the mirror on the
# secondary. Created after the pair so the secondary stays client-free.
resource "confluent_kafka_topic" "demo" {
  topic_name       = var.topic_name
  partitions_count = var.topic_partitions
  rest_endpoint    = confluent_kafka_cluster.primary.rest_endpoint

  kafka_cluster {
    id = confluent_kafka_cluster.primary.id
  }

  credentials {
    key    = confluent_api_key.link_primary.id
    secret = confluent_api_key.link_primary.secret
  }

  depends_on = [confluent_switchover_endpoint.this]
}

# Destroy-time cleanup. The link auto-created a mirror of the topic on the
# secondary, and Terraform only knows about the source topic, so the link
# delete fails ("link has mirror topics"). Depending on the link makes this run
# first on destroy. Best-effort: failures are printed, not fatal, so destroy
# still proceeds and reports the real error.
resource "terraform_data" "mirror_cleanup" {
  count = var.deploy_links ? 1 : 0

  input = {
    rest    = confluent_kafka_cluster.secondary.rest_endpoint
    cluster = confluent_kafka_cluster.secondary.id
    topic   = var.topic_name
    link    = local.link_name
    key     = confluent_api_key.link_secondary.id
    secret  = confluent_api_key.link_secondary.secret
  }

  provisioner "local-exec" {
    when        = destroy
    interpreter = ["/bin/bash", "-c"]
    environment = {
      KEY    = self.input.key
      SECRET = self.input.secret
    }
    command = <<-EOT
      base="${self.input.rest}/kafka/v3/clusters/${self.input.cluster}"
      curl -sS -m 60 -u "$KEY:$SECRET" -X POST -H 'Content-Type: application/json' \
        -d '{"mirror_topic_names":["${self.input.topic}"]}' \
        "$base/links/${self.input.link}/mirrors:promote" || true
      curl -sS -m 60 -u "$KEY:$SECRET" -X DELETE "$base/topics/${self.input.topic}" || true
    EOT
  }

  depends_on = [confluent_cluster_link.secondary_to_primary]
}

locals {
  # The app expects host:port; the provider returns SASL_SSL://host:port.
  primary_bootstrap   = trimprefix(confluent_kafka_cluster.primary.bootstrap_endpoint, "SASL_SSL://")
  secondary_bootstrap = trimprefix(confluent_kafka_cluster.secondary.bootstrap_endpoint, "SASL_SSL://")

  # Variable names match demo-app/config.js. Values are quoted for a shell `source`.
  demo_env = <<-EOT
    PORT=${var.demo_port}
    GLOBAL_BOOTSTRAP="${var.deploy_links ? format("glkc-%s-%s.global.glb.confluent.cloud:9092", confluent_switchover_pair.this[0].id, confluent_switchover_endpoint.this[0].id) : ""}"
    PRIMARY_BOOTSTRAP="${local.primary_bootstrap}"
    DR_BOOTSTRAP="${local.secondary_bootstrap}"
    PRIMARY_CLUSTER_ID="${confluent_kafka_cluster.primary.id}"
    DR_CLUSTER_ID="${confluent_kafka_cluster.secondary.id}"
    PRIMARY_LABEL="Primary (${var.primary_region})"
    DR_LABEL="DR (${var.secondary_region})"
    KAFKA_API_KEY="${confluent_api_key.app_global.id}"
    KAFKA_API_SECRET="${confluent_api_key.app_global.secret}"
    CLOUD_API_KEY="${confluent_api_key.admin_cloud.id}"
    CLOUD_API_SECRET="${confluent_api_key.admin_cloud.secret}"
    CONFLUENT_ENV_ID="${confluent_environment.this.id}"
    CONFLUENT_ORG_ID="${data.confluent_organization.this.id}"
    SWITCHOVER_PAIR_ID="${try(confluent_switchover_pair.this[0].id, "")}"
    TOPIC="${var.topic_name}"
    CONSUMER_GROUP="${var.consumer_group}"
  EOT
}

# Ready-to-use environment for demo-app/ (gitignored, mode 0600)
resource "local_sensitive_file" "demo_env" {
  filename        = "${path.module}/demo.env"
  content         = local.demo_env
  file_permission = "0600"

  depends_on = [confluent_kafka_topic.demo]
}
