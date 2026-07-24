# Fit-Gap Analysis — ion-C5 delivery vs. „Požiadavky na dodávku C5" (OCP requirements)

**Date:** 2026-07-24
**Analyzed delivery:** ion-C5 1.0.0 (images `1.0.0b1`, ion-discover `1.0.0`, ion-docval `1.3.0`), Administrator's Manual 1.0.0-1, `sample_config.ini`
**Reference:** Zadanie pre dodávateľa – dodávka kontajnerizovanej aplikácie pre OpenShift (chapters 1–15 + acceptance criteria)

---

## 1. Executive summary

The supplier delivered **7 OCI-compliant linux/amd64 images** and a solid administrator's manual covering architecture, data flow and a complete configuration reference (env vars + config file). Runtime configuration, secrets-via-env, stdout logging and horizontal scalability are well covered — the application is architecturally a good fit for OpenShift.

**The delivery does NOT currently meet the acceptance criteria.** The largest gaps:

1. **No Helm chart delivered** (acceptance criterion 3) — mitigated in this repo by a customer-authored chart (`helm/ion-c5/`), but the supplier should adopt/own it or formally agree the customer maintains it.
2. **No health endpoints** (startup/readiness/liveness) documented for any module (acceptance criterion "startup/liveness/readiness endpoints implemented and documented").
3. **No Prometheus metrics, no version endpoint, no recommended alerts** (chapter 8).
4. **No upgrade / rollback / DB-migration documentation** (chapter 12).
5. **restricted-v2 SCC compatibility is not attested and not evident from the images**: no `USER` directive, all images default to **port 80** (below 1024), writable paths undocumented.
6. **Image-only delivery (COTS)** — ion-C5 is a commercial off-the-shelf product; the supplier will not deliver source code. The requirements' closing clause allows this via a **written, customer-approved exception** — it must be formalized, with the compensating supply-chain controls listed in §4a (SBOM, digest-pinned/signed images, CVE response SLA, scan gate in the customer registry).
7. Images are **beta-tagged (`1.0.0b1`)** while the manual says 1.0.0 — not acceptable for PROD acceptance.

Verdict: **usable for TEST deployment now** (with the workarounds encoded in the provided Helm chart), **not acceptable for PROD** until P1 gaps below are closed by the supplier.

---

## 2. What was verified from the images themselves

| Image | Tag | Arch | User | Exposed | Entrypoint/Cmd | Base / notes |
|---|---|---|---|---|---|---|
| ion-c5-receiver | 1.0.0b1 | amd64 | *(none — root)* | 80/tcp | `/var/ion/ion-c5-receiver/ion-c5-receiver` | Debian trixie snapshot, 3 layers |
| ion-c5-processor | 1.0.0b1 | amd64 | *(none)* | 80/tcp | `/var/ion/ion-c5-processor/ion-c5-processor` | Debian trixie snapshot |
| ion-c5-sender | 1.0.0b1 | amd64 | *(none)* | 80/tcp | `/var/ion/ion-c5-sender/ion-c5-sender` | Debian trixie snapshot |
| ion-c5-admin | 1.0.0b1 | amd64 | *(none)* | 80/tcp | `/var/ion/ion-c5-admin/ion-c5-admin` | Debian trixie snapshot |
| ion-c5-setup | 1.0.0b1 | amd64 | *(none)* | 80/tcp | ENTRYPOINT `/var/ion/ion-c5-setup/ion-c5-setup` | one-off init container |
| ion-discover | 1.0.0 | amd64 | *(none)* | 80/tcp | `/var/ion/ion-discover-service/ion-discover-service` | Debian trixie snapshot |
| ion-docval | 1.3.0 | amd64 | *(none)* | 80/tcp | `/var/ion-docval/bin/ion-docval-server` | Debian trixie + **OpenJDK 21 JRE** |

Additional facts: OCI layout tarballs (loadable with `podman load` / `skopeo copy`), built 2026-07-22, **no OCI labels** (no version/build metadata in the image), **no HEALTHCHECK**, no VOLUME declarations, config exclusively via env vars / mounted config file (good).

**Port-80 mitigation:** every module's listen port is runtime-configurable (`ION_C5_*_LISTEN_PORT`, `ION_DISCOVER_LISTEN_PORT`, `ION_DOCVAL_LISTEN_PORT`) — the provided Helm chart moves all listeners to **8080**, so the images can run under restricted-v2 without `NET_BIND_SERVICE`.

---

## 3. Fit-gap by requirement chapter

Status legend: ✅ **Fit** · 🟡 **Partial** · ❌ **Gap** · ❓ **Verify** (cannot be confirmed from the delivery; supplier attestation or a test needed)

### Chapter 2 — Container image

| Requirement | Status | Evidence / comment |
|---|---|---|
| OCI-compliant image | ✅ | OCI image-layout tarballs; standard blobs + index.json |
| linux/amd64 | ✅ | Confirmed in image config of all 7 images |
| Runs under restricted / restricted-v2 SCC | ❓ | Not attested. No `USER` set; default listen port 80. Likely works with random UID + port moved to 8080 (chart does this), **must be verified by test + supplier confirmation** |
| Runs under random UID | ❓ | No `USER`/group-0 ownership visible; binaries under `/var/ion` — needs runtime verification |
| No root privileges | ❓ | Image *defaults* to root (no `USER`); OCP forces non-root, but supplier must declare support |
| No privileged container | ✅ | Nothing in the delivery requires privileges |
| No hostNetwork/hostPID/hostIPC | ✅ | Not used/required |
| No hardcoded config/certs/credentials | ✅/❓ | Config fully externalized (env/file); sample config uses placeholders. Deep image scan recommended |
| Logs exclusively to stdout/stderr | ✅ | Manual ch. 5 (config echo to standard logging) |
| Writes only to /tmp or defined mounts | ❓ | **Undocumented.** No VOLUME declared. Must be confirmed to enable `readOnlyRootFilesystem` |
| State app+image version, runtime, base image, tagging scheme | ❌ | Not stated anywhere. Derived by analysis: Debian trixie base; docval = Java 21; c5-modules runtime undeclared. No image labels. Beta tag `b1` unexplained |

### Chapter 3 — Deployment (Helm)

| Requirement | Status | Comment |
|---|---|---|
| Helm chart (Helm 3, OpenShift, GitOps-ready) | ❌ | **Not delivered.** Customer-side chart provided in `helm/ion-c5/` covering Deployments, Services, Routes, ConfigMap, Secret refs, probes, resources, replicas, HPA, PDB, ServiceAccount, NetworkPolicy — supplier should adopt or formally approve |
| No env-specific hardcoded values, multi-env via values.yaml | 🟡 | Achieved by the provided chart (values-per-environment); not by the supplier delivery |
| Alternative: full deployment documentation | 🟡 | Manual describes modules and dependencies but not Kubernetes objects |

### Chapter 4 — Runtime configuration

| Requirement | Status | Comment |
|---|---|---|
| Fully configurable without image rebuild | ✅ | Env vars override config file (INI/JSON/TOML); documented ch. 5–6.8 |
| All parameters documented (name, type, meaning, mandatory, default, delivery method) | 🟡 | Names, env vars, defaults, meaning and per-module required/optional: documented. **Missing:** explicit type, and "does change require restart" per parameter (in practice: all changes require pod restart — supplier to confirm) |

### Chapter 5 — Kubernetes Secrets

| Requirement | Status | Comment |
|---|---|---|
| Sensitive data via K8s Secrets, documented (name, keys, format, mandatory) | 🟡 | Mechanism supported (secrets → env vars, recommended in manual ch. 5); **no Secret object specification delivered**. Defined by the provided chart: `ion-c5-app` (5 keys) + `ion-c5-peppol` (cert+key) — see chart README |
| No sensitive data inside image | ✅/❓ | Design confirms; image content scan recommended |
| Passwords/secrets masked in logs | ✅ | Manual: values containing `password`/`secret` logged as `XXXXX` |

### Chapter 6 — Network communication

| Requirement | Status | Comment |
|---|---|---|
| Complete inbound/outbound documentation for NetworkPolicy design | 🟡 | Present in prose, scattered. Consolidated table derived below (§5). **Supplier must confirm** CRL/OCSP URLs and any NTP/DNS specifics |

### Chapter 7 — Health endpoints

| Requirement | Status | Comment |
|---|---|---|
| startup / readiness / liveness endpoints with URL, port, codes, timeouts | ❌ | **Nothing documented for any module.** Only smoke-test URLs exist: discover `GET /v2` (200), docval `GET /validate` (UI). Receiver/admin/processor/sender: no known health URL. Chart falls back to TCP probes (receiver/admin/docval) and HTTP `/v2` (discover); **processor & sender probes disabled** pending supplier info — this is an acceptance blocker |

### Chapter 8 — Monitoring, logging, observability

| Requirement | Status | Comment |
|---|---|---|
| Monitorable state incl. dependency health | ❌ | No dependency-health endpoint documented |
| Version identification (endpoint/metric/startup log) | ❌ | Not documented; no image labels either. Verify whether startup log prints version |
| Prometheus metrics endpoint | ❌ | Not mentioned anywhere. Queue depths are only visible in admin UI — ideal HPA/alerting metrics exist internally but are not exported |
| Recommended alerts with thresholds | ❌ | Not delivered |
| Logs to stdout/stderr | ✅ | Confirmed |
| Log level runtime-configurable | ✅ | `log_level` + per-module levels via env |
| Log content (timestamp, severity, app, version, traceId) | ❓ | Format not documented; no samples delivered |
| OpenTelemetry tracing (if supported) | 🟡 | Not supported/claimed — acceptable if stated in writing |

### Chapter 9 — HPA

| Requirement | Status | Comment |
|---|---|---|
| Scaling documentation (method, thresholds, behavior) | 🟡 | Architecture is explicitly horizontally scalable (manual ch. 2) with worker counts per node; **no HPA guidance, no custom metrics**. CPU-based HPA feasible for receiver/docval/discover (enabled optionally in the chart). Queue-length-based scaling for processor/sender impossible until metrics are exported |

### Chapter 10 — Operational requirements

| Requirement | Status | Comment |
|---|---|---|
| Writable dirs, PV, S3 requirements | ❌/❓ | Undocumented. **Open question:** manual says valid TDDs go to "persistent storage" *and* metadata to the TDD DB — no storage path is configurable, so this appears to be the TDD **database** (BLOBs), but the supplier must confirm no PV/S3 is required |
| DB timeouts, retry mechanisms | 🟡 | Sender retry with exponential backoff documented; DB timeout behavior not |
| Behavior on external-system outage | 🟡 | Partially derivable (queues); not systematically documented |
| Graceful shutdown + terminationGracePeriodSeconds | ❌ | Not documented (chart defaults to 60 s conservatively) |

### Chapter 12 — Upgrades

| Requirement | Status | Comment |
|---|---|---|
| Versioning, upgrade procedure, strategy, zero-downtime, component order, DB migrations, rollback, known incompatibilities | ❌ | **Nothing delivered.** `ion-c5-setup initialize-databases` exists but its idempotency/migration behavior on upgrade is undocumented. Blocker for PROD operations |

### Chapter 13 — Security

| Requirement | Status | Comment |
|---|---|---|
| restricted mode, no extra capabilities, no privileged | ❓ | Expected to pass with chart settings (port 8080, drop ALL); must be attested |
| Secret rotation without rebuild | ✅ | Secrets are env/file inputs; rotation = update Secret + rolling restart |
| Runtime certificate configuration | ✅ | `peppol_certificate`/`peppol_private_key` as file path or inline value; PKCS#12 supported |
| CVE / dependency updates | ❌ | No process stated. Compounded by image-only delivery (customer cannot rebuild). Debian trixie base + OpenJDK 21 will need patch cadence |

### Chapter 14 — OpenShift version compatibility

| Requirement | Status | Comment |
|---|---|---|
| Compatibility commitment across OCP versions | ❌ | Not stated in delivery — contractual item |

### Chapter 15 — Documentation

| Requirement | Status | Comment |
|---|---|---|
| Technical description, config & ENV docs | ✅ | Manual is good here |
| Secrets, health, network, metrics, resources, HPA, ops, upgrade/rollback docs | ❌/🟡 | Missing as itemized above |
| Release notes / changelog | ❌ | Not delivered |
| **Source-code delivery preference** | 🟡 exception | COTS product — supplier will only ever deliver images. Permissible under the closing exception clause; formalize the exception in writing and bind the compensating controls of §4a into the contract |

---

## 4. Prioritized gap register (supplier action list)

**P1 — acceptance blockers (PROD):**
1. Health endpoints for all 6 runtime modules (URL, port, expected codes, recommended probe settings) — or written statement + supported alternative (e.g. exec probe) for processor/sender.
2. Helm chart: deliver, or formally approve the customer-maintained chart (`helm/ion-c5/`).
3. Upgrade/rollback/DB-migration procedure incl. `ion-c5-setup` idempotency on upgrade and component update ordering.
4. Written attestation of restricted-v2/random-UID/non-root operation + list of writable paths (target: `readOnlyRootFilesystem: true` + `/tmp` emptyDir).
5. Release-grade image tags (no `b1`) with a documented tagging scheme; image OCI labels with version/build/commit.
6. Version identification at runtime (endpoint, metric or startup log line).

**P2 — required for stable operations:**
7. Prometheus metrics (at minimum: request counts/errors/latency for receiver & admin; **receive-queue and send-queue depth, dead-letter count** for processor/sender — these are also the right HPA signals) + metric documentation.
8. Recommended alerts with thresholds and runbook actions.
9. Consolidated network matrix confirmation (incl. CRL/OCSP endpoints of the Peppol CA, SML DNS zone, SMP targets).
10. Graceful-shutdown behavior + recommended `terminationGracePeriodSeconds`; DB timeout/retry parameters.
11. Confirmation that valid TDD payloads are stored in the TDD DB only (no PV/S3), and DB sizing guidance.
12. Log format specification + samples (normal + error), confirmation of no sensitive data in logs.

**P3 — contractual/process:**
13. CVE/patch process and SLA for base-image updates; OCP version compatibility commitment.
14. Formalize the **COTS image-only-delivery exception** in writing (see §4a for the compensating controls to attach).
15. Non-interactive variant of `create-admin-user` (flags/env/stdin) so first-admin creation can be automated; document password-reset path if the temporary password is lost.
16. Restart-required flag per configuration parameter; parameter types.

### §4a — Compensating controls for COTS image-only delivery

Since the customer cannot rebuild the images in its own CI/CD, the software-supply-chain
requirement is met through supplier obligations plus customer-side gates:

**Supplier obligations (contractual):**
1. **SBOM per image per release** (SPDX or CycloneDX) covering OS packages and application dependencies.
2. **Digest-pinned releases** — a release manifest listing image name, tag and sha256 digest for every component; ideally images **signed** (cosign/Sigstore or registry-native signing) with a published public key.
3. **CVE response SLA** — defined remediation times per severity (e.g. critical ≤ 7 days, high ≤ 30 days) for base image (Debian trixie) and bundled runtimes (OpenJDK 21 in ion-docval); rebuilt patched images delivered as new tags, never overwritten tags.
4. **Release notes/changelog** per version incl. security-fix identification (already P2/P15 items).
5. Immutable tags — a published tag must never be re-pushed with different content (digest change = new tag).

**Customer-side gates (platform):**
6. Quarantine flow: supplier tarballs land in a staging repo, are scanned (registry scanner / ACS), and are promoted to the production repo only after policy pass.
7. Helm values pin images **by digest** in PREPROD/PROD (chart supports `image.tag`; switch to `name@sha256:...` form at promotion).
8. Periodic re-scan of deployed images; findings routed to the supplier under the SLA of item 3.

---

## 5. Derived network communication matrix (to validate with supplier)

**Inbound**

| Module | Port (chart) | Protocol | Source | Purpose |
|---|---|---|---|---|
| ion-c5-receiver | 8080 | HTTP (TLS at Route/LB) | Internet (Peppol APs) via router | AS4 endpoint `/as4` |
| ion-c5-admin | 8080 | HTTP (TLS at Route/LB) | Admin networks only (IP whitelist) | Management UI |
| ion-discover | 8080 | HTTP | processor, sender (in-namespace) | SML/SMP lookup API |
| ion-docval | 8080 | HTTP | processor (in-namespace) | XML validation API |
| processor / sender | — | — | none | queue pollers, no inbound needed (EXPOSE 80 exists in image; purpose unconfirmed — ask supplier if it is a health port) |

**Outbound**

| Module | Destination | Port | Purpose |
|---|---|---|---|
| receiver | receiver DB (Oracle/PostgreSQL) | 1521/5432 | receive queue + dead letters |
| receiver | Internet: Peppol CA CRL distribution points | 80/443 | sender certificate validation (CRL download) |
| processor | receiver DB, TDD DB, main DB | 1521/5432 | orchestration |
| processor | ion-docval | 8080 | validation |
| sender | main DB, TDD DB, receiver DB | 1521/5432 | send queue, MLS results |
| sender | ion-discover | 8080 | recipient lookup |
| sender | Internet: recipient APs (dynamic hosts) | 443 | AS4 MLS transmission |
| discover | Internet: SML (DNS) + SMPs (dynamic) | 53, 80/443 | Peppol discovery |
| admin | receiver DB, TDD DB, main DB | 1521/5432 | management UI |
| all | DNS, NTP (platform) | 53, 123 | platform services |

---

## 6. Open questions

**For the supplier** — items 1–16 in §4, plus: purpose of EXPOSE 80 on processor/sender; runtime/language of the c5 modules; whether `initialize-databases` is safe to re-run (idempotent) and whether it performs schema migrations between versions.

**Customer-side decisions (status 2026-07-24):**
1. ✅ Registry naming per plan (fill actual URL into `global.imageRegistry` in the env values files).
2. ✅ Oracle; 3-way DB split (receiver/TDD/main) for PROD, single instance acceptable below PROD.
3. ✅ Receiver/admin hostname pattern per environment as in the plan; concrete FQDNs + admin IP ranges to be filled into the env values files.
4. ✅ `peppol-test` in all environments except PROD (`peppol`).
5. ⬜ GitOps tool (Argo CD?) — still open.
6. ✅ Supplier model confirmed as **COTS, image-only delivery** — handled as a formal exception with compensating controls (§4a); source delivery will not be pursued.
