# Confluent Cloud DR Automatic Failover: Terraform

Deploys what [danjrichards/transparent-failover](https://github.com/danjrichards/transparent-failover) needs on the Confluent side, using **public networking** (no Private Link):

- Environment (Stream Governance Essentials)
- Primary: Dedicated **single-zone** cluster (`westeurope`); secondary: Dedicated **multi-zone** cluster (`northeurope`), same CKUs
- Service accounts: `dr-link-sa` (CloudClusterAdmin on both clusters), `dr-demo-app-sa` (client), `dr-demo-admin-sa` (EnvironmentAdmin)
- API keys: cluster-scoped keys for the link (the cluster link API rejects Global keys), Global key for the app (cluster-scoped keys can't fail over), Cloud API key for the Switchover/Metrics APIs
- Client RBAC on both clusters (topic `purchases`, group `dr-demo-consumer`)
- Demo topic `purchases` (primary) and `demo.env` for the app
- With `deploy_links = true`: bidirectional cluster link on both sides, switchover pair, public switchover endpoint, and the global bootstrap URL output

Docs: [automatic failover tutorial](https://docs.confluent.io/cloud/current/multi-cloud/cluster-linking/dr-automatic-failover-tutorial.html), [DR failover](https://docs.confluent.io/cloud/current/multi-cloud/cluster-linking/dr-failover.html). The feature is Early Access, so use dev/test only.

## Use

```bash
cp terraform.tfvars.example terraform.tfvars   # add a Cloud API key (OrgAdmin/EnvAdmin)
terraform init
terraform apply
# also writes demo.env for the demo app
```

If the pair step fails because the clusters aren't ready, re-run `terraform apply`. The secondary must have no clients or consumer groups when the pair is created.

## Deploy the demo app

`terraform apply` also creates the `purchases` topic on the primary (mirrored to the secondary by the link) and writes `demo.env` (gitignored, mode 0600) with every variable `demo-app/config.js` reads, including the global bootstrap URL and the app/Cloud API keys. The demo producer generates its own data, so the repo's datagen connector isn't needed. Public networking means no jump-box VM: run the app locally.

```bash
git clone https://github.com/danjrichards/transparent-failover && cd transparent-failover/demo-app
npm install --omit=dev
set -a; source ../../demo.env; set +a    # adjust the path to this repo's demo.env
node server.js                            # dashboard on http://localhost:3000 (PORT in demo.env)
```

Use the dashboard's Failover / Fail Back / Restore Standby buttons (they call the Switchover API with the admin Cloud key), or the CLI below. `terraform output -raw demo_env` prints the same file.

## Not covered by Terraform

- Failover, restore and failback are CLI/REST only (the dashboard buttons call the same API):
  `confluent switchover pair failover <SW> --active-member secondary --failover-type PLANNED|UNPLANNED --environment <env>`
- Running the app itself (`npm install`, `node server.js`), and the repo's optional datagen connector and VM/Private Link setup (not used here).
- Schema Registry (schema linking), connectors, Flink and ksqlDB aren't failed over automatically.

## Destroy

1. If you failed over, fail back so the **primary is the active member** (`confluent switchover pair describe <SW> --environment <env>`).
2. Stop the demo app so no clients or consumer groups remain.
3. Wait for any other Terraform run to finish, then:

```bash
terraform destroy -lock-timeout=60s -refresh=false -parallelism=2
```

`-refresh=false` avoids the provider's cluster-link read timing out (408) on a slow standby; lower parallelism does the same for delete calls. A `terraform_data.mirror_cleanup` resource promotes and deletes the mirror of the demo topic on the secondary before the link is deleted, since the link can't be deleted while it has mirror topics.

### Known issues and workarounds

**`kafka_api_key, kafka_api_secret, kafka_rest_endpoint ... should be set or not set at the same time`**
The provider also reads `KAFKA_API_KEY`, `KAFKA_API_SECRET`, `KAFKA_REST_ENDPOINT` and `KAFKA_ID` from the environment, and a partial set fails validation. Clear them and retry:

```bash
unset KAFKA_API_KEY KAFKA_API_SECRET KAFKA_REST_ENDPOINT KAFKA_ID
terraform destroy -lock-timeout=60s -refresh=false -parallelism=2
```

**`403 ... Cluster link <name> ... in use by topics: [<topic>]`**
Only the demo topic is cleaned up automatically. Any other mirror topic (for example one you created by hand, or one on the primary after a failover) blocks the link delete. On each cluster the error or `mirror list` points at, promote the mirror, optionally delete it, and re-run:

```bash
confluent kafka mirror list --link <link-name> --cluster <cluster-id> --environment <env-id>
confluent kafka mirror promote <topic> --link <link-name> --cluster <cluster-id> --environment <env-id>   # or `failover` if the other side is down
confluent kafka topic delete <topic> --cluster <cluster-id> --environment <env-id>                        # optional
terraform destroy -lock-timeout=60s -refresh=false -parallelism=2
```

The link exists on both clusters, so check both.

**`Auto-mirrored topic cannot be deleted. The topic <topic> should be excluded from auto.create.mirror.topics.filters`**
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

**Stale state lock**
A stale lock (`.terraform.tfstate.lock.info` with no running Terraform) can be cleared with `terraform force-unlock <ID>`.
