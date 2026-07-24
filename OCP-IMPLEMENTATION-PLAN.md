# ion-C5 — Implementation plan for OpenShift Container Platform

Step-by-step deployment order for one environment (repeat per TEST → INT → PREPROD → PROD, changing only the environment values file). Commands assume `oc`, `helm` 3 and `podman`/`skopeo` on a bastion/CI runner with access to the cluster and the customer registry.

---

## Phase 0 — Prerequisites (before touching the cluster)

| # | Item | Owner |
|---|---|---|
| 0.1 | Peppol certificate (PEM cert + private key, or PKCS#12) for the C5 SEATID, per environment (test cert for `peppol-test`) | Customer/PA |
| 0.2 | Databases provisioned and reachable from the cluster: **receiver DB**, **TDD DB**, **main DB** (may be one instance in TEST; split recommended for PROD — the receiver DB is the exposure-minimizing boundary). Oracle or PostgreSQL. 3 schemas/users with DDL rights for initial setup | DBA |
| 0.3 | Egress/firewall openings: receiver → Internet (CRL, 80/443); sender → Internet (443, dynamic AP hosts); discover → Internet (DNS 53 + SMP 80/443); all modules → DB ports | Network |
| 0.4 | DNS + TLS: public FQDN for the receiver (e.g. `c5-ap.<env>.customer.sk`) terminating on the OCP router or external LB/WAF; internal FQDN for admin UI; admin source-IP ranges for whitelisting | Network |
| 0.5 | Customer container registry project/robot account with push rights | Platform |
| 0.6 | SMP registration prepared (publish AS4 endpoint `https://<receiver-fqdn>/as4` for the C5 identifier `0242:<SEATID>`) — done **after** smoke tests, but request access early | Peppol/PA |

## Phase 1 — Import images into the customer registry

The supplier tarballs are OCI-layout archives. From the folder `docker_images/`:

```bash
REG=registry.customer.sk/ion-c5        # adjust
for f in ion-c5-receiver_1.0.0b1 ion-c5-processor_1.0.0b1 ion-c5-sender_1.0.0b1 \
         ion-c5-admin_1.0.0b1 ion-c5-setup_1.0.0b1 ion-discover_1.0.0 ion-docval_1.3.0; do
  name=${f%_*}; tag=${f##*_}
  skopeo copy oci-archive:${f}.tar.gz docker://$REG/$name:$tag
done
```

(Alternative: `podman load -i <file>` → `podman tag` → `podman push`.)
Run the registry's vulnerability scan on all 7 images and record results (CVE baseline for the supplier).

## Phase 2 — Project and access

```bash
oc new-project ion-c5-test --display-name="ion-C5 TEST"
# pull secret only if the registry requires auth:
oc create secret docker-registry regcred --docker-server=$REG --docker-username=... --docker-password=...
```

No custom SCC, no elevated RBAC — everything runs under `restricted-v2` (the chart sets listen ports to 8080 and drops all capabilities).

## Phase 3 — Secrets (before Helm install)

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

## Phase 4 — Database initialization

Handled automatically by the chart's **pre-install Helm hook Job** (`ion-c5-setup initialize-databases`) when `setup.enabled=true` (default). To run it manually instead, set `setup.enabled=false` and:

```bash
oc run ion-c5-init --rm -it --image=$REG/ion-c5-setup:1.0.0b1 \
  --env-from=secret/ion-c5-app ... -- initialize-databases
```

> Open point with supplier: idempotency of `initialize-databases` on upgrades (see fit-gap P1-3). Until confirmed, set `setup.enabled=false` on upgrades of an existing environment.

## Phase 5 — Helm install

```bash
cd helm
helm upgrade --install ion-c5 ./ion-c5 \
  -n ion-c5-test \
  -f ./ion-c5/values.yaml \
  -f ./ion-c5/values-test.yaml        # environment overlay: registry, hosts, DB, network
```

Internal start-up/validation order (readiness handles this automatically, but verify in this sequence because of dependencies):

1. **ion-docval** (no dependencies)
2. **ion-discover** (needs Internet egress only)
3. **ion-c5-receiver** (needs receiver DB + CRL egress)
4. **ion-c5-processor** (needs all 3 DBs + docval)
5. **ion-c5-sender** (needs all 3 DBs + discover + Internet egress)
6. **ion-c5-admin** (needs all 3 DBs)

```bash
oc get pods -w
```

## Phase 6 — First administrator user (interactive, one-off)

`create-admin-user` prompts for username/password, so it cannot run as a Job:

```bash
oc run ion-c5-adminuser --rm -it --restart=Never \
  --image=$REG/ion-c5-setup:1.0.0b1 \
  --overrides='{"spec":{"containers":[{"name":"ion-c5-adminuser","image":"'$REG'/ion-c5-setup:1.0.0b1","args":["create-admin-user"],"stdin":true,"tty":true,"envFrom":[{"secretRef":{"name":"ion-c5-app"}},{"configMapRef":{"name":"ion-c5-env"}}]}]}}'
```

(The chart also renders an env-var ConfigMap `ion-c5-env` with the DB connection settings for exactly this purpose.)

## Phase 7 — Exposure and smoke tests

1. Routes are created by the chart: receiver (public, edge TLS) and admin (edge TLS + IP whitelist annotation). Point external DNS/LB/WAF at the router.
2. Confirm `receiver_proxy_ip_addresses` in the values contains the IPs the receiver will see as source (router/ingress pod IPs or external LB IPs) — otherwise sender IPs are logged wrong.
3. Smoke tests (from inside the namespace or via port-forward):
   - discover: `GET http://ion-c5-discover/v2` → `{"detail":"ion-discover ... running"}`; lookup: `GET /v2/peppol-test/0106:84418745` → `exists:true`
   - docval: `POST` an XML to `http://ion-c5-docval/api/validate/` (Content-Type: application/xml) → validation JSON
   - admin UI: log in over the Route with the Phase-6 user; enable **MFA (TOTP)** for every admin account
   - receiver: `https://<receiver-fqdn>/as4` reachable from the Internet (AS4 errors on GET are expected — it is a POST endpoint)
4. End-to-end: from a test Peppol access point (or supplier), send a TDD to your identifier on `peppol-test`; verify: TDD appears in admin UI → MLS is sent (send queue drains) → dead-letters empty. Also send an intentionally invalid document and verify it lands in Dead Letters with an MLS rejection.

## Phase 8 — SMP publication

Publish/update the SMP entry for `0242:<SEATID>` with endpoint `https://<receiver-fqdn>/as4` (TDD document type). Only after Phase 7 passes.

## Phase 9 — Hardening & operations (before PROD)

- **NetworkPolicy**: enable `networkPolicy.enabled=true` in the chart (default-deny + router→receiver/admin, in-namespace→discover/docval) and add egress policies per the network matrix in the fit-gap document.
- **Monitoring**: until the supplier delivers metrics (fit-gap P2-7), configure probe-based availability alerts (KubePodNotReady, restarts, CPU/mem) and DB-side queue-depth SQL checks; add a synthetic AS4/SMP probe from outside.
- **Log forwarding**: stdout/stderr flows into the standard OCP logging stack automatically; add parsing once the supplier documents the log format.
- **Backups**: DB backups for all three databases (TDD DB contains the legally relevant documents — set retention accordingly).
- **GitOps**: commit chart + per-env values to Git, onboard into Argo CD (app-per-environment); secrets via ESO/Sealed Secrets.
- **Upgrade rehearsal**: in TEST, rehearse image-tag bump via values + rollback (`helm rollback` / Argo history) once the supplier documents migration behavior.

## Environment promotion

TEST → INT → PREPROD → PROD: identical chart and images; only `values-<env>.yaml` differs (registry path, hostnames, DB endpoints, `discover_network: peppol` in PROD, replicas/resources, whitelists). PROD additionally requires: production Peppol cert, 3-way DB split, release (non-beta) image tags, and closure of the P1 gaps.
