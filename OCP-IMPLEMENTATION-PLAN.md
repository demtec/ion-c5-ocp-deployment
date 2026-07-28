# ion-C5 — Implementation plan for OpenShift Container Platform

**Rev. 2 (2026-07-28)** — targets delivery **1.0.0b2** and chart **0.2.0**.
Step-by-step deployment order for one environment (repeat per TEST → INT → PREPROD → PROD,
changing only the environment values file). Commands assume `oc`, `helm` 3 and
`podman`/`skopeo` on a bastion/CI runner with access to the cluster and the customer registry.
Role tags per [RESPONSIBILITIES.md](RESPONSIBILITIES.md).

---

## Phase 0 — Prerequisites (before touching the cluster)

| # | Item | Owner |
|---|---|---|
| 0.1 | Peppol certificate (PEM cert + private key, or PKCS#12) for the C5 SEATID, per environment (test cert for `peppol-test`) | PA |
| 0.2 | Databases provisioned and reachable from the cluster: **receiver DB**, **TDD DB**, **main DB** (one instance acceptable below PROD; 3-way split in PROD — the receiver DB is the exposure-minimizing boundary). Oracle. Schemas/users with DDL rights for initial setup (and for `migrate` on upgrades — consider a separate migration user) | DBA |
| 0.3 | Egress/firewall openings: receiver → Internet (CRL, 80/443); sender → Internet (443, dynamic AP hosts); discover → Internet (DNS 53 + SMP 80/443); all modules → DB ports | NET |
| 0.4 | DNS + TLS: public FQDN for the receiver terminating on the OCP router or external LB/WAF; internal FQDN for admin UI; admin source-IP ranges for whitelisting. **Set router/WAF body-size and timeout limits for AS4** (max message size pending supplier — G-17) | NET |
| 0.5 | Customer container registry project/robot account with push rights; quarantine repo + scan gate (§4a) | OCP/SEC |
| 0.6 | SMP registration prepared (publish `https://<receiver-fqdn>/as4` for `0242:<SEATID>`) — done **after** smoke tests, but request access early | PA |

## Phase 1 — Import images into the customer registry (OCP)

The supplier tarballs are OCI-layout archives. From `docker_images/`:

```bash
REG=registry.customer.sk/ion-c5        # adjust
for f in ion-c5-receiver_1.0.0b2 ion-c5-processor_1.0.0b2 ion-c5-sender_1.0.0b2 \
         ion-c5-admin_1.0.0b2 ion-c5-setup_1.0.0b2 ion-discover_1.0.1 ion-docval_1.3.1; do
  name=${f%_*}; tag=${f##*_}
  skopeo copy oci-archive:${f}.tar.gz docker://$REG/$name:$tag
done
```

Then (SEC): vulnerability-scan all 7 in the quarantine repo, record the CVE baseline,
promote to the production repo, and **record the digests** (`skopeo inspect --format '{{.Digest}}'`)
— they go into the PREPROD/PROD values as `image.digest` (§4a pinning).

## Phase 2 — Project and access (OCP)

```bash
oc new-project ion-c5-test --display-name="ion-C5 TEST"
# pull secret only if the registry requires auth:
oc create secret docker-registry regcred --docker-server=$REG --docker-username=... --docker-password=...
```

No custom SCC, no elevated RBAC — everything runs under `restricted-v2` (all listeners on
8080, capabilities dropped, non-root user `c5` in the images; the SCC injects the runtime UID).

## Phase 3 — Secrets (OPS via SEC-approved pipeline, before Helm install)

```bash
# Application secrets — keys are exactly the env var names the modules read:
oc create secret generic ion-c5-app \
  --from-literal=ION_C5_MAIN_DB_PASSWORD='...' \
  --from-literal=ION_C5_RECEIVER_DB_PASSWORD='...' \
  --from-literal=ION_C5_TDD_DB_PASSWORD='...' \
  --from-literal=ION_C5_ADMIN_JWT_SECRET="$(openssl rand -hex 32)" \
  --from-literal=ION_C5_PEPPOL_PRIVATE_KEY_PASSWORD='...'   # omit if key not encrypted

# Peppol certificate + key (PEM):
oc create secret generic ion-c5-peppol \
  --from-file=certificate.pem=./peppol-cert.pem \
  --from-file=private.key=./peppol-key.pem
```

For GitOps, manage these via Sealed Secrets / External Secrets Operator instead of `oc create`.

## Phase 4 — Database initialization (OCP runs, DBA on standby)

Handled by the chart's **pre-install hook Job** (`ion-c5-setup initialize-databases`,
`setup.enabled=true` default). **Confirmed idempotent** in b2 (manual §5.1: checks schema-version
tables, no-ops when present) — safe to leave enabled. Manual alternative:

```bash
oc run ion-c5-init --rm -it --image=$REG/ion-c5-setup:1.0.0b2 ... -- initialize-databases
```

Upgrades use the separate `migrate` mechanism — see Phase 10.

## Phase 5 — Helm install (OCP)

```bash
cd helm
helm upgrade --install ion-c5 ./ion-c5 \
  -n ion-c5-test \
  -f ./ion-c5/values.yaml \
  -f ./ion-c5/values-test.yaml        # environment overlay: registry, hosts, DB, network
```

All six modules carry real HTTP probes (`/health/startup|ready|liveness`, delivery b2);
readiness gates on actual dependencies (DBs, docval, discover), so the rollout self-orders.
Expected dependency order if watching:

1. **ion-docval** (no dependencies) → 2. **ion-discover** (Internet egress) →
3. **receiver** (receiver DB + CRL) → 4. **processor** (3 DBs + docval) →
5. **sender** (3 DBs + discover + Internet) → 6. **admin** (3 DBs)

```bash
oc get pods -w
```

Probe endpoints are supplier-confirmed for all modules (email 2026-07-28); the pods run
with a **read-only root filesystem** (attested — the CRL disk cache auto-disables, so CRLs
are re-fetched after every receiver restart: CRL egress must work at pod start). If
discover/docval probes unexpectedly 404, documented fallbacks exist in values.yaml
(discover: `probes.readinessPath=/v2`; docval: `probes.type=tcp`).

## Phase 6 — First administrator user (OPS; interactive, one-off — G-8)

`create-admin-user` still prompts for username/password (b2), so it cannot run as a Job:

```bash
oc run ion-c5-adminuser --rm -it --restart=Never \
  --image=$REG/ion-c5-setup:1.0.0b2 \
  --overrides='{"spec":{"containers":[{"name":"ion-c5-adminuser","image":"'$REG'/ion-c5-setup:1.0.0b2","args":["create-admin-user"],"stdin":true,"tty":true,"envFrom":[{"secretRef":{"name":"ion-c5-app"}},{"configMapRef":{"name":"ion-c5-env"}}]}]}}'
```

(The chart renders the env-var ConfigMap `ion-c5-env` for exactly this purpose.)
Then log in and **enable MFA (TOTP)** — available since b2 — for every admin account.

## Phase 7 — Exposure and smoke tests (OCP + OPS)

1. Routes are created by the chart: receiver (public, edge TLS) and admin (edge TLS + IP
   whitelist annotation — mandatory). Point external DNS/LB/WAF at the router (NET).
2. Confirm `receiver_proxy_ip_addresses` covers the source IPs the receiver actually sees
   (router/ingress pod IPs or external LB IPs) — otherwise sender IPs are logged wrong.
3. Smoke tests (from inside the namespace or via port-forward):
   - every module: `GET /version` → `{"name":"ion-c5-...","version":"1.0.0b2"}`;
     `GET /health/ready` → 200 with per-dependency status/latency (processor/sender via pod IP:8080)
   - discover: `GET http://ion-c5-discover/v2` → running; lookup `GET /v2/peppol-test/0106:84418745` → `exists:true`
   - docval: `POST` an XML to `http://ion-c5-docval/api/validate/` (Content-Type: application/xml) → validation JSON
   - admin UI over the Route with the Phase-6 user (MFA enrolled)
   - receiver: `https://<receiver-fqdn>/as4` reachable from the Internet (AS4 error on GET is expected — POST endpoint)
4. End-to-end: from a test Peppol AP (or supplier), send a TDD to your identifier on
   `peppol-test`; verify TDD in admin UI → MLS sent (send queue drains) → dead letters empty.
   Send an intentionally invalid document → Dead Letters + MLS rejection (AS4 error
   semantics per manual §3: EBMS:0004/0101/0102).

## Phase 8 — SMP publication (PA)

Publish/update the SMP entry for `0242:<SEATID>` with endpoint `https://<receiver-fqdn>/as4`
(TDD document type). Only after Phase 7 passes.

## Phase 9 — Hardening & operations (before PREPROD/PROD)

- **NetworkPolicy** (OCP/SEC/NET): `networkPolicy.enabled=true` (default-deny + router→receiver/admin,
  in-namespace) + egress policies per the fit-gap §5 matrix. Kubelet probes are unaffected (G-16).
- **Monitoring** (OPS): until supplier metrics land (P2-6): blackbox-exporter scrapes of
  `/health/ready` per module (dependency health + latency), probe/restart/resource alerts,
  and **queue-depth SQL exporter** against the three DBs (reference queries requested from
  supplier, P2-7). Synthetic AS4/SMP probe from outside.
- **Log forwarding** (OCP): stdout → OCP logging stack; parsing once log format is specified (P2-11).
- **Backups** (DBA): all three DBs; TDD DB carries the legally relevant documents — retention
  accordingly. DB-only persistence is attested in substance ("no writes to disk", email
  2026-07-28); one explicit TDD-in-DB sentence in the manual closes the backup scope (G-6).
- **GitOps** (OCP): chart + env values in Git, Argo CD app-per-environment (tool decision
  pending); secrets via ESO/Sealed Secrets.
- **Security** (SEC): decision on plaintext in-cluster hops (G-15: accept / IPsec / mesh);
  digest pinning + periodic re-scans (§4a).

## Phase 10 — Upgrade rehearsal (TEST; OCP + OPS + DBA)

Now partially unblocked by b2's `migrate` command:

1. DB backup (DBA).
2. Bump image tags/digests in the env values file.
3. Schema migration: preferred — confirm db-names/ordering with supplier (G-7), then either
   enable the chart's pre-upgrade Job (`setup.migrateOnUpgrade=true`) or run manually:
   `oc run ... --image=$REG/ion-c5-setup:<new> -- migrate main latest` (repeat per DB).
4. `helm upgrade`; watch readiness.
5. Rollback rehearsal: `helm rollback` + `migrate <db> <previous-version>` (downgrade is
   supported by the tool; app-vs-schema compatibility statement still owed by supplier, G-7).

## Environment promotion

TEST → INT → PREPROD → PROD: identical chart and images; only `values-<env>.yaml` differs
(registry path, hostnames, DB endpoints, `discover_network: peppol` in PROD, replicas/
resources, whitelists, **image digests instead of tags** in PREPROD/PROD). PROD additionally
requires: production Peppol cert, 3-way DB split, **release-grade (non-beta) image tags**,
and closure of the P1 gaps (fit-gap §4).
