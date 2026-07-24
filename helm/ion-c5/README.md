# ion-c5 Helm chart

Deploys the ion-C5 Peppol Access Point (corner 5) — receiver, processor, sender, admin UI,
ion-discover and ion-docval — on Red Hat OpenShift under the `restricted-v2` SCC.
Database initialization (`ion-c5-setup initialize-databases`) runs as a pre-install hook Job.

Chart origin: authored by the customer because the supplier delivery (ion-C5 1.0.0b1)
did not include a Helm chart. See `../../FIT-GAP-ANALYSIS.md` for open supplier items.

## Design decisions

- **All listeners moved to port 8080** via `ION_*_LISTEN_PORT` env vars, because the images
  default to port 80, which is not bindable by a random-UID container without extra capabilities.
- **Config split**: non-sensitive settings render into `config.ini` (ConfigMap, mounted read-only
  at `/etc/ion-c5/config.ini`); sensitive values arrive as env vars from a pre-created Secret.
  Per the manual, env vars override the config file, so the file never contains secrets.
- `discover_host` / `validator_host` default to the chart's own Services (port 80 → 8080).
- Probes: TCP for receiver/admin/docval, HTTP `GET /v2` for discover; **disabled** for
  processor/sender until the supplier documents health endpoints.
- `readOnlyRootFilesystem: false` until the supplier confirms writable paths (`/tmp` is already
  an emptyDir in every pod); flip `securityContext.readOnlyRootFilesystem` to `true` after that.

## Prerequisites

1. Images pushed to your registry (`global.imageRegistry`) with the tags used in values.
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
(PKCS#12 alternative: store the `.p12` under a key, point `config.peppol_certificate` at it and
put the file password in `ION_C5_PEPPOL_PRIVATE_KEY_PASSWORD`.)

## Install

```bash
helm upgrade --install ion-c5 ./ion-c5 -n <namespace> \
  -f ion-c5/values.yaml -f ion-c5/values-<env>.yaml
```

Post-install: create the first admin user interactively (command printed in NOTES / release notes),
run smoke tests, then publish the receiver Route on the SMP.

## Upgrades

Bump image tags in the env values file and `helm upgrade`. The setup Job does **not** run on
upgrades by default (`setup.runOnUpgrade: false`) because migration idempotency is not yet
confirmed by the supplier. Rollback: `helm rollback` (DB rollback procedure pending supplier docs).

## Key values

| Value | Meaning |
|---|---|
| `global.imageRegistry` | registry prefix for all images |
| `components.<name>.image.digest` / `setup.image.digest` | optional sha256 digest — takes precedence over `tag`; pin digests in PREPROD/PROD |
| `config.*` | non-sensitive runtime config (rendered to config.ini); see Administrator's Manual §6.8 |
| `secrets.appSecretName` / `secrets.peppolSecretName` | pre-created Secrets (above) |
| `components.<name>.enabled/replicas/resources/probes/route/hpa/pdb` | per-module tuning |
| `components.receiver.route.host` | public AS4 hostname (SMP endpoint) |
| `components.admin.route.annotations` | set `haproxy.router.openshift.io/ip_whitelist`! |
| `setup.enabled` / `setup.runOnUpgrade` | DB-init hook behavior |
| `networkPolicy.enabled` | baseline default-deny ingress policies |
| `securityContext.readOnlyRootFilesystem` | enable after supplier confirms writable paths |

GitOps: Argo CD-compatible (hooks map to Argo PreSync; no Helm lookups or random values used).
