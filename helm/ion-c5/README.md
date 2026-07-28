# ion-c5 Helm chart

Deploys the ion-C5 Peppol Access Point (corner 5) — receiver, processor, sender, admin UI,
ion-discover and ion-docval — on Red Hat OpenShift under the `restricted-v2` SCC.
Database initialization (`ion-c5-setup initialize-databases`) runs as a pre-install hook Job;
schema migration (`ion-c5-setup migrate`) is available as an opt-in pre-upgrade hook Job.

Chart **0.2.0** targets delivery **1.0.0b2** (images `1.0.0b2` / discover `1.0.1` / docval `1.3.1`).
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
- **Non-root**: images declare named user `c5` (uid 1000). On OpenShift leave
  `securityContext.runAsUser` null (SCC injects the UID); set `1000` on platforms that
  enforce `runAsNonRoot` against the image's non-numeric user (G-1).
- **`readOnlyRootFilesystem: true` by default** — supplier attested (2026-07-28) that b2
  writes nothing to disk; the CRL disk cache auto-disables on a read-only filesystem
  (CRLs held in memory, re-fetched after restart — keep CRL egress open). `/tmp` stays
  an emptyDir in every pod.

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
(PKCS#12 alternative: store the `.p12`/`.pfx` under a key, point `config.peppol_certificate`
at it — auto-detected by extension — and put the file password in
`ION_C5_PEPPOL_PRIVATE_KEY_PASSWORD`.)

## Install

```bash
helm upgrade --install ion-c5 ./ion-c5 -n <namespace> \
  -f ion-c5/values.yaml -f ion-c5/values-<env>.yaml
```

Post-install: create the first admin user interactively (command in NOTES — still
interactive-only in b2), enable MFA (TOTP), run smoke tests (`/version`, `/health/ready`
per module), then publish the receiver Route on the SMP.

## Upgrades

1. DB backup.
2. Bump image tags (TEST/INT) or digests (PREPROD/PROD) in the env values file.
3. Schema migration: `initialize-databases` is idempotent but does **not** migrate.
   Either enable the pre-upgrade migrate Job (`setup.migrateOnUpgrade: true` — confirm
   db-names/ordering with the supplier first, G-7) or run
   `ion-c5-setup migrate <db> latest` manually per DB.
4. `helm upgrade`; rollback via `helm rollback` + `migrate <db> <previous-version>`
   (downgrades supported by the tool; compatibility statement pending, G-7).

## Key values

| Value | Meaning |
|---|---|
| `global.imageRegistry` | registry prefix for all images |
| `components.<name>.image.digest` / `setup.image.digest` | optional sha256 digest — takes precedence over `tag`; pin digests in PREPROD/PROD |
| `config.*` | non-sensitive runtime config (rendered to config.ini); see Administrator's Manual §6.8 |
| `secrets.appSecretName` / `secrets.peppolSecretName` | pre-created Secrets (above) |
| `components.<name>.enabled/replicas/resources/probes/route/hpa/pdb` | per-module tuning |
| `components.<name>.probes.{startupPath,readinessPath,livenessPath,type}` | probe overrides (defaults `/health/*`, type `http`) |
| `components.receiver.route.host` | public AS4 hostname (SMP endpoint) |
| `components.admin.route.annotations` | set `haproxy.router.openshift.io/ip_whitelist`! |
| `components.docval.env` | e.g. `JDK_JAVA_OPTIONS: -XX:MaxRAMPercentage=60` (JVM sizing, G-10) |
| `setup.enabled` / `setup.runOnUpgrade` | DB-init hook (idempotent per manual §5.1) |
| `setup.migrateOnUpgrade` / `setup.migrateDatabases` | pre-upgrade schema-migration Job (default off, G-7) |
| `securityContext.runAsUser` | null on OpenShift; `1000` on vanilla k8s (G-1) |
| `securityContext.readOnlyRootFilesystem` | `true` (supplier-attested, b2); set `false` only when debugging |
| `networkPolicy.enabled` | baseline default-deny ingress policies |

GitOps: Argo CD-compatible (hooks map to Argo PreSync; no Helm lookups or random values used).
