# ion-c5 Helm chart

Deploys the ion-C5 Peppol Access Point (corner 5) — receiver, processor, sender, admin UI,
ion-discover and ion-docval — on Red Hat OpenShift under the `restricted-v2` SCC.
`ion-c5-setup` (DB init/migration/create-admin-user CLI) is also chart-managed, but as a
**scale-to-zero Deployment** (`components.setup.replicas: 0` by default) rather than a
server — it has no listen port or health endpoints, so the actual commands are still run
by hand: scale it up, `oc exec` in, run the CLI, scale back down (see Install/Upgrades below).

Chart **0.4.6** targets delivery **1.0.0b5** (images `1.0.0b5` / discover `1.0.2` / docval
`1.4.0-1` — docval versions independently of the ion-c5-1.0.0bN umbrella; some environments
pin an older docval instead, see `values-int.yaml` for an example).
Chart origin: authored by the customer because the supplier does not deliver a chart (COTS);
supplier sign-off pending — see `../../FIT-GAP-ANALYSIS.md` and `../../HELM-CHART-GAP-ANALYSIS.md`.

## Design decisions

- **All listeners on port 8080** via `ION_*_LISTEN_PORT` env vars (also the application
  default since 1.0.0b2); Services expose port 80 → targetPort 8080.
- **`discover_port` / `validator_port` are pinned to 80** in the rendered config (the
  Service port) — the application-side default is 8080 since b2 and would bypass the
  Services (see HELM-CHART-GAP-ANALYSIS.md G-3).
- **HTTP health probes on all six modules** (b2 feature, manual ch. 8; supplier-confirmed
  for all modules incl. discover/docval): startup `/health/startup`, readiness
  `/health/ready` (real dependency checks), liveness `/health/liveness`. Paths overridable
  per component (`probes.startupPath` / `readinessPath` / `livenessPath`);
  `probes.type: tcp` as fallback. Supplier timing guidance: modules start in seconds,
  docval slowest (~10 s XSLT/XSD loading) — the 150 s startup budget is ample.
- **Config split**: non-sensitive settings render into `config.ini` (ConfigMap, mounted
  read-only at `/etc/ion-c5/config.ini`); sensitive values arrive as env vars from a
  pre-created Secret. Env vars override the config file (manual §6.1), so the file never
  contains secrets. Config changes trigger a rolling restart (checksum annotation).
- **Non-root**: as of 1.0.0b3+ images declare no `USER` at all (root by default; b2 declared
  a named user `c5`, uid 1000). On OpenShift leave `securityContext.runAsUser` null (SCC
  injects a namespace-range UID regardless of image default); set `1000` on platforms that
  enforce `runAsNonRoot` without SCC (vanilla k8s) — `/var/ion` is readable/executable by
  uid 1000 via "other" permissions either way (G-1).
- **Admin module starts first** (`startupOrder.waitForAdmin`, default on): every other
  module runs a `wait-for-admin` init container (busybox `wget` loop against the admin
  Service's `/health/ready`) and stays `Init:0/1` until admin is ready. Opt out per
  module via `components.<name>.waitForAdmin: false`. If admin's readiness turns out to
  depend on discover/docval (unconfirmed, ask supplier), exempt those two to avoid a
  startup deadlock.
- **`readOnlyRootFilesystem: true` by default** — supplier attested (2026-07-28) that b2
  writes nothing to disk; the CRL disk cache auto-disables on a read-only filesystem
  (CRLs held in memory, re-fetched after restart — keep CRL egress open). `/tmp` stays
  an emptyDir in every pod.
- **`ion-c5-setup` scale-to-zero:** its image ENTRYPOINT expects a CLI subcommand
  (`initialize-databases` / `migrate <db> <version>` / `create-admin-user`) and exits
  otherwise, so `components.setup.command` overrides it to idle (`sleep infinity`).
  Not gated by `wait-for-admin` (`waitForAdmin: false`) since DB init may need to run
  before anything else — including admin — can start successfully.

## Prerequisites

1. Images pushed to your registry (`global.imageRegistry`) with the tags used in values,
   including the wait image (`busybox`, used by the startup-ordering init containers).
2. Databases reachable, with schemas/users for receiver / TDD / main DBs.
3. Two Secrets in the target namespace:

### Secret `ion-c5-app` (name via `secrets.appSecretName`)

Keys are exactly the env var names the modules consume:

| Key | Required | Purpose |
|---|---|---|
| `ION_C5_MAIN_DB_PASSWORD` | yes | main DB password |
| `ION_C5_RECEIVER_DB_PASSWORD` | yes | receiver DB password |
| `ION_C5_TDD_DB_PASSWORD` | yes | TDD DB password |
| `ION_C5_ADMIN_JWT_SECRET` | yes | ≥32-char random string, signs admin JWTs |
| `ION_C5_PEPPOL_PRIVATE_KEY_PASSWORD` | if key encrypted | Peppol private key passphrase |

```bash
oc create secret generic ion-c5-app \
  --from-literal=ION_C5_MAIN_DB_PASSWORD='...' \
  --from-literal=ION_C5_RECEIVER_DB_PASSWORD='...' \
  --from-literal=ION_C5_TDD_DB_PASSWORD='...' \
  --from-literal=ION_C5_ADMIN_JWT_SECRET="$(openssl rand -hex 32)"
```

### Secret `ion-c5-peppol` (name via `secrets.peppolSecretName`)

| Key | Purpose |
|---|---|
| `certificate.pem` | Peppol certificate (public) |
| `private.key` | Peppol private key (PEM) |

Mounted read-only at `/etc/ion-c5/peppol/` in receiver and sender only.
(PKCS#12 alternative: store the `.p12`/`.pfx` under a key, point `config.peppol_certificate`
at it — auto-detected by extension — and put the file password in
`ION_C5_PEPPOL_PRIVATE_KEY_PASSWORD`.)

## Install

```bash
helm upgrade --install ion-c5 ./ion-c5 -n <namespace> \
  -f ion-c5/values.yaml -f ion-c5/values-<env>.yaml
```

Pre-install: initialize the databases and create the first admin user via the `setup`
component:

```bash
oc scale deployment/<release>-ion-c5-setup --replicas=1
oc exec -it deploy/<release>-ion-c5-setup -- /var/ion/ion-c5-setup/ion-c5-setup initialize-databases
oc exec -it deploy/<release>-ion-c5-setup -- /var/ion/ion-c5-setup/ion-c5-setup create-admin-user   # interactive-only in b2
oc scale deployment/<release>-ion-c5-setup --replicas=0
```

Post-install: enable MFA (TOTP), run smoke tests (`/version`, `/health/ready` per module),
then publish the receiver Route on the SMP.

## Upgrades

1. DB backup.
2. Bump image tags (TEST/INT) or digests (PREPROD/PROD) in the env values file
   (`components.setup.image.tag` too, so its CLI matches the target release).
3. Schema migration: scale `setup` to 1, `oc exec` in and run `ion-c5-setup migrate <db>
   latest` per DB (confirm db-names/ordering with the supplier first, G-7), scale back to 0.
4. `helm upgrade`; rollback via `helm rollback` + the same `migrate <db> <previous-version>`
   pattern (downgrades supported by the tool; compatibility statement pending, G-7).

## Key values

| Value | Meaning |
|---|---|
| `global.imageRegistry` | registry prefix for all images |
| `components.<name>.image.digest` | optional sha256 digest — takes precedence over `tag`; pin digests in PREPROD/PROD |
| `config.*` | non-sensitive runtime config (rendered to config.ini); see Administrator's Manual §6.8 |
| `secrets.appSecretName` / `secrets.peppolSecretName` | pre-created Secrets (above) |
| `components.<name>.enabled/replicas/resources/probes/route/hpa/pdb` | per-module tuning |
| `components.<name>.probes.{startupPath,readinessPath,livenessPath,type}` | probe overrides (defaults `/health/*`, type `http`) |
| `components.receiver.route.host` | public AS4 hostname (SMP endpoint) |
| `components.admin.route.annotations` | set `haproxy.router.openshift.io/ip_whitelist`! |
| `components.<name>.route.extraHosts` | additional alias hostnames for the same backend Service, each its own Route (`tls: false` for plain HTTP) |
| `components.setup.replicas` | `0` by default — scale to 1 to run `ion-c5-setup` commands via `oc exec`, then back to 0 |
| `components.<name>.command` | overrides the image ENTRYPOINT (used by `setup` to idle instead of exiting) |
| `components.docval.env` | e.g. `JDK_JAVA_OPTIONS: -XX:MaxRAMPercentage=60` (JVM sizing, G-10) |
| `startupOrder.waitForAdmin` | admin starts first; other modules gate on admin readiness via init container (default `true`) |
| `components.<name>.waitForAdmin` | per-module opt-out of the admin gate (set `false`) |
| `securityContext.runAsUser` | null on OpenShift; `1000` on vanilla k8s (G-1) |
| `securityContext.readOnlyRootFilesystem` | `true` (supplier-attested, b2); set `false` only when debugging |
| `networkPolicy.enabled` | baseline default-deny ingress policies |

GitOps: Argo CD-compatible (no Helm hooks, lookups or random values used).
