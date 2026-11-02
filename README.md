# Confluent Cloud DR Automatic Failover: Terraform

Terraform for the Confluent Cloud side of [danjrichards/transparent-failover](https://github.com/danjrichards/transparent-failover), using **public networking** (no Private Link, no jump-box VM). It builds two Dedicated clusters linked in both directions, plus a switchover pair and a **global bootstrap URL**. Clients that use that URL fail over without any change to their connection config.

> **Early Access.** DR automatic failover is an Early Access feature. Use it for dev/test only.
> Docs: [automatic failover tutorial](https://docs.confluent.io/cloud/current/multi-cloud/cluster-linking/dr-automatic-failover-tutorial.html), [DR failover](https://docs.confluent.io/cloud/current/multi-cloud/cluster-linking/dr-failover.html).

**Contents:** [Architecture](#architecture) · [Prerequisites](#prerequisites) · [Quick start](#quick-start) · [Configuration](#configuration) · [Outputs](#outputs) · [Run the demo app](#run-the-demo-app) · [Failover operations](#failover-operations) · [Destroy](#destroy) · [Troubleshooting](#troubleshooting)

## Architecture

```
                      Confluent Cloud environment (Stream Governance Essentials)

   ┌───────────────────────────┐   cluster link (both directions)   ┌───────────────────────────┐
   │ Primary: Dedicated,       │ ◄────────────────────────────────► │ Secondary: Dedicated,     │
  │ Azure SZ, westeurope      │                                    │ AWS MZ, eu-west-1         │
   │ topic: purchases          │ ───── auto-created mirror ───────► │ mirror: purchases         │
   └─────────────▲─────────────┘                                    └─────────────▲─────────────┘
                 │                                                                │
                 └────────────── switchover pair + public endpoint ───────────────┘
                                              ▲
                                    global bootstrap URL
                                  (demo app / your clients)
```

### What gets created

| Area | Resources |
| --- | --- |
| Environment | One environment with Stream Governance Essentials |
| Clusters | Primary: Azure Dedicated **single-zone** (`westeurope`). Secondary: AWS Dedicated **multi-zone** (`eu-west-1`). Same CKUs on both. |
| Identities | `dr-link-sa` (CloudClusterAdmin on both clusters), `dr-demo-app-sa` (client), `dr-demo-admin-sa` (EnvironmentAdmin) |
| API keys | Cluster-scoped keys for the link (the cluster link API rejects Global keys). A Global key for the app (cluster-scoped keys can't fail over). A Cloud API key for the Switchover and Metrics APIs. |
| RBAC | Client access on both clusters (topic `purchases`, group `dr-demo-consumer`) |
| Demo | Topic `purchases` on the primary (mirrored by the link) and a `demo.env` file for the app |
| DR wiring (`deploy_links = true`) | Cluster links on both sides, switchover pair, public switchover endpoint, global bootstrap URL |

## Prerequisites

- [Terraform](https://developer.hashicorp.com/terraform/install) (see [versions.tf](versions.tf) for the required version and provider).
- A Confluent Cloud **Cloud API key** with OrganizationAdmin or EnvironmentAdmin.
- Access to the DR automatic failover Early Access feature for your organization.
- To run the demo app: Node.js and `git`.
- For the CLI operations below: the [Confluent CLI](https://docs.confluent.io/confluent-cli/current/install.html).

## Quick start

```bash
cp terraform.tfvars.example terraform.tfvars   # add your Cloud API key and a prefix
terraform init
terraform apply                                # also writes demo.env for the demo app
```

If the pair step fails because the clusters aren't ready, re-run `terraform apply`. The secondary must have **no clients or consumer groups** when the pair is created.

## Configuration

Set these in `terraform.tfvars` (see [terraform.tfvars.example](terraform.tfvars.example)). The file is gitignored because it holds credentials.

| Variable | Default | Description |
| --- | --- | --- |
| `confluent_cloud_api_key` / `confluent_cloud_api_secret` | required | Cloud API key Terraform uses (sensitive) |
| `prefix` | required | Prefix for all resource names, to avoid collisions in the org |
| `primary_cloud` | `AZURE` | Cloud provider for the primary cluster (`AWS`, `AZURE`, `GCP`) |
| `secondary_cloud` | `AWS` | Cloud provider for the secondary cluster (`AWS`, `AZURE`, `GCP`) |
| `primary_region` | `westeurope` | Region of the primary (single-zone) cluster |
| `secondary_region` | `eu-west-1` | Region of the secondary (multi-zone) cluster |
| `cku` | `2` | CKUs for **both** clusters. Must be equal and ≥ 2 (the multi-zone minimum) |
| `deploy_links` | `true` | Create the links, switchover pair and endpoint. `false` creates only clusters, identities and keys. |
| `environment_name` | `transparent-failover` | Environment display name |
| `topic_name` | `purchases` | Demo topic |
| `topic_partitions` | `6` | Partitions of the demo topic |
| `consumer_group` | `dr-demo-consumer` | Consumer group used by the demo app |
| `demo_port` | `3000` | Dashboard port (the app's own default, 80, needs root) |

## Outputs

| Output | Notes |
| --- | --- |
| `global_bootstrap` | Global bootstrap URL for transparent failover |
| `primary`, `secondary` | Cluster ID, CRN, bootstrap and REST endpoints |
| `environment_id`, `environment_crn` | Environment identifiers |
| `switchover_pair_id`, `switchover_endpoint_id` | Needed for the failover CLI commands |
| `demo_env` | Contents of `demo.env` (sensitive) |
| `link_api_keys`, `app_global_api_key`, `admin_cloud_api_key` | Generated keys (sensitive) |

Sensitive outputs are shown with `terraform output -json <name>` or `terraform output -raw demo_env`.

## Run the demo app

`terraform apply` writes `demo.env` (gitignored, mode 0600) with every variable `demo-app/config.js` reads, including the global bootstrap URL and the app and Cloud API keys. The demo producer generates its own data, so the repo's datagen connector isn't needed. With public networking you can run the app on your laptop.

```bash
git clone https://github.com/danjrichards/transparent-failover && cd transparent-failover/demo-app
npm install --omit=dev
set -a; source ../../demo.env; set +a    # adjust the path to this repo's demo.env
node server.js                            # dashboard on http://localhost:3000 (PORT in demo.env)
```

The dashboard's **Failover**, **Fail Back** and **Restore Standby** buttons call the Switchover API with the admin Cloud key. `terraform output -raw demo_env` prints the same file as `demo.env`.

## Failover operations

Failover, restore and failback are not managed by Terraform. Use the dashboard buttons or the CLI:

```bash
confluent switchover pair describe <SW> --environment <env>
confluent switchover pair failover <SW> --active-member secondary \
  --failover-type PLANNED|UNPLANNED --environment <env>
```

Not covered by this repo:

- Running the app itself (`npm install`, `node server.js`), and the upstream repo's optional datagen connector and VM/Private Link setup.
- Schema Registry (schema linking), connectors, Flink and ksqlDB. None of these fail over automatically.

## Destroy

1. If you failed over, fail back so the **primary is the active member**.
2. Stop the demo app so no clients or consumer groups remain.
3. Wait for any other Terraform run to finish, then:

```bash
terraform destroy -lock-timeout=60s -refresh=false -parallelism=2
```

- `-refresh=false` avoids the provider's cluster-link read timing out (408) on a slow standby.
- Lower parallelism does the same for delete calls.
- `terraform_data.mirror_cleanup` promotes and deletes the demo topic's mirror on the secondary before the link is deleted, because a link with mirror topics can't be deleted.

## Troubleshooting

| Symptom | Jump to |
| --- | --- |
| `kafka_api_key, kafka_api_secret, kafka_rest_endpoint ... should be set or not set at the same time` | [Partial `KAFKA_*` env vars](#partial-kafka_-environment-variables) |
| `403 ... Cluster link <name> ... in use by topics` | [Link in use by mirror topics](#link-in-use-by-mirror-topics) |
| `Auto-mirrored topic cannot be deleted` | [Auto-mirrored topic](#auto-mirrored-topic-cannot-be-deleted) |
| `error deleting Kafka Topic ... HTTP 500` | [Topic delete returns 500](#topic-delete-returns-http-500) |
| `switchover pair ... provisioning failed: ... remote link state has not been observed yet` | [Pair fails right after the links](#switchover-pair-fails-right-after-the-links) |
| `409 Conflict: LKC ... is already part of switchover pair` | [Pair fails right after the links](#switchover-pair-fails-right-after-the-links) |
| Stale state lock | [Stale lock](#stale-state-lock) |

### Partial `KAFKA_*` environment variables

The provider also reads `KAFKA_API_KEY`, `KAFKA_API_SECRET`, `KAFKA_REST_ENDPOINT` and `KAFKA_ID` from the environment, and a partial set fails validation. Clear them and retry:

```bash
unset KAFKA_API_KEY KAFKA_API_SECRET KAFKA_REST_ENDPOINT KAFKA_ID
terraform destroy -lock-timeout=60s -refresh=false -parallelism=2
```

### Link in use by mirror topics

Only the demo topic is cleaned up automatically. Any other mirror topic blocks the link delete. Examples are one you created by hand, or one on the primary after a failover. The link exists on both clusters, so check both. On each cluster the error points at (or `mirror list` shows), promote the mirror, optionally delete it, and re-run:

```bash
confluent kafka mirror list --link <link-name> --cluster <cluster-id> --environment <env-id>
confluent kafka mirror promote <topic> --link <link-name> --cluster <cluster-id> --environment <env-id>   # or `failover` if the other side is down
confluent kafka topic delete <topic> --cluster <cluster-id> --environment <env-id>                        # optional
terraform destroy -lock-timeout=60s -refresh=false -parallelism=2
```

### Auto-mirrored topic cannot be deleted

Full error: `Auto-mirrored topic cannot be deleted. The topic <topic> should be excluded from auto.create.mirror.topics.filters`.

Add an `EXCLUDE` entry for the topic on the cluster link, otherwise the link re-creates it after you delete it. The update replaces the whole filter, so keep the existing `INCLUDE` entry:

```bash
cat > filters.json <<'EOF2'
{"topicFilters":[
  {"name":"*","patternType":"LITERAL","filterType":"INCLUDE"},
  {"name":"<topic>","patternType":"LITERAL","filterType":"EXCLUDE"}
]}
EOF2
confluent kafka link configuration update <link-name> \
  --config "auto.create.mirror.topics.filters=$(jq -c . filters.json)" \
  --cluster <cluster-id> --environment <env-id>
confluent kafka topic delete <topic> --cluster <cluster-id> --environment <env-id>
```

If the delete still fails because the topic is an active mirror, promote it first (see above).

### Topic delete returns HTTP 500

`error deleting Kafka Topic "<cluster>/<topic>": ... received HTTP 500 Internal Server Error` during destroy, after the retries run out. This can be a transient Confluent Cloud error, or the source topic being deleted while the link still has an active mirror of it.

1. Re-run `terraform destroy`.
2. If it persists, promote the mirror on the secondary, then destroy again:

   ```bash
   confluent kafka mirror promote <topic> --link <link-name> --cluster <secondary-cluster-id> --environment <env-id>
   terraform destroy -lock-timeout=60s -refresh=false -parallelism=2
   ```

3. If it still fails, open a support ticket with the cluster ID and the time of the request.

### Switchover pair fails right after the links

Full error: `error waiting for switchover pair "<id>" to provision: ... ResourceValidationComplete=False (ValidationFailed): Cluster link <cluster>_<link> remote link state has not been observed yet, cannot verify it is available for switchover`.

The Switchover service validates the cluster links when the pair is created. If it hasn't observed their remote state yet, validation fails. `time_sleep.wait_for_links` adds a 120s delay between the links and the pair to avoid this. If you still hit it, increase `create_duration` on that resource.

The failed create leaves the pair in Confluent Cloud but not in Terraform state. The next `terraform apply` then fails with `409 Conflict: LKC <id> is already part of switchover pair <id>`. Delete the orphaned pair (the ID is in the first error, or in `confluent switchover pair list`) and re-apply:

```bash
confluent switchover pair delete <pair-id> --environment <env-id>
terraform apply
```

Importing the pair is not a reliable alternative. `terraform import` returned `400 Bad Request` for this resource.

### Stale state lock

A stale lock (`.terraform.tfstate.lock.info` with no running Terraform) can be cleared with `terraform force-unlock <ID>`.
