# Fit-Gap Analysis — ion-C5 delivery vs. „Požiadavky na dodávku C5" (OCP requirements)

**Date:** 2026-07-28 (rev. 2 — supersedes rev. 1 of 2026-07-24)
**Analyzed delivery:** ion-C5 **1.0.0b2** (images `1.0.0b2`, ion-discover `1.0.1`, ion-docval `1.3.1`), Administrator's Manual 1.0.0b2-1, `sample_config.ini`
**Reference:** Zadanie pre dodávateľa – dodávka kontajnerizovanej aplikácie pre OpenShift (chapters 1–15 + acceptance criteria)
**Companions:** [RESPONSIBILITIES.md](RESPONSIBILITIES.md) (who owns what), [HELM-CHART-GAP-ANALYSIS.md](HELM-CHART-GAP-ANALYSIS.md) (chart-boundary specialties G-1…G-18)

---

## 1. Executive summary

The 1.0.0b2 delivery **closes the worst gaps of b1**. Newly delivered and verified:

- **Health endpoints on every runtime module** (`/health/startup`, `/health/ready`, `/health/liveness` + `/version`), including dedicated health-only listeners on processor and sender, with Kubernetes-correct semantics (503 while starting; readiness checks real dependencies). Chart 0.2.0 now uses HTTP probes everywhere — the b1 acceptance blocker on probes is **resolved pending TEST verification** (paths on ion-discover/ion-docval still unconfirmed, G-4).
- **Idempotent `initialize-databases` + a real migration command** (`migrate <db> <version|latest>`, up **and** down, per-DB schema versioning) — the upgrade story went from "nothing" to "mechanism exists, procedure still undocumented".
- **All default listen ports moved to 8080** (>1024, random-UID friendly) and a **named non-root `USER c5`** in every image.
- **MFA (TOTP)** in the admin UI; forced password rotation for new users.
- **Per-module memory sizing table** in the manual (chart resource values now match it).
- Partial **OCI labels** and the build **Dockerfile shipped inside each image** (good transparency).

**Still open — the delivery does not yet meet PROD acceptance:**

1. **No Prometheus metrics** (chapter 8) — the queue depths that should drive HPA and alerting exist only in the DB/admin UI (G-12).
2. **No changelog/release notes** — and b2 proved why this matters: defaults changed 80→8080 silently and would have broken in-cluster service wiring had the chart not pinned ports (G-3).
3. **Upgrade *procedure* still undocumented** (migrate db-names, ordering, rollback compatibility — G-7) although the mechanism now exists.
4. **restricted-v2 attestation still missing**: named (non-numeric) user without group-0 file permissions works on OCP only via SCC UID injection (G-1); writable paths unattested; "persistent storage" for TDDs still unmapped (G-6) — blocks `readOnlyRootFilesystem` and storage/backup planning.
5. **Beta tags again** (`1.0.0b2`), plus dev-build remnants in the sender image (G-14) — not release-grade.
6. **COTS image-only delivery** — unchanged position: formal exception + §4a compensating controls; SBOM still not delivered.
7. `create-admin-user` still interactive-only (G-8); graceful shutdown still unstated (G-9).

Verdict: **ready for TEST/INT installation now** (chart 0.2.0, real probes, idempotent init). **PROD acceptance** still requires: metrics, release notes + release-grade tags, upgrade procedure, restricted-v2/writable-path attestation, and the §4a supply-chain package.

---

## 2. What was verified from the images themselves (b2)

| Image | Tag | User | Exposed | Entrypoint/Cmd | Notes |
|---|---|---|---|---|---|
| ion-c5-receiver | 1.0.0b2 | `c5` (named, uid 1000) | *(none)* | CMD `/var/ion/ion-c5-receiver/ion-c5-receiver` | PyInstaller Python 3.13; AS4 endpoint |
| ion-c5-processor | 1.0.0b2 | `c5` | *(none)* | CMD `…/ion-c5-processor` | Python 3.13; bundles Peppol pMode TOMLs |
| ion-c5-sender | 1.0.0b2 | `c5` | *(none)* | CMD `…/ion-c5-sender` | Python 3.13; contains stray `ion_c5_base-1.0.0b3.dev0` dist-info (G-14) |
| ion-c5-admin | 1.0.0b2 | `c5` | *(none)* | CMD `…/ion-c5-admin` | Python 3.13; argon2/crypto UI stack |
| ion-c5-setup | 1.0.0b2 | `c5` | *(none)* | **ENTRYPOINT** `…/ion-c5-setup` | CLI tool → Job/`oc run` with args |
| ion-discover | 1.0.1 | `c5` | *(none)* | CMD `…/ion-discover-service` | ships `/etc/ion-discover.conf`: 0.0.0.0:8080, `enable_health_api=true` |
| ion-docval | 1.3.1 | `c5` | *(none)* | CMD `/var/ion-docval/bin/ion-docval-server` | OpenJDK 21 JRE (237 MB layer); `/etc/ion-docval.conf`: 0.0.0.0:8080, `EnableHealthEndpoints=true`; SK TDD 1.0.0 + BIS3 + MLS validation artifacts |

Common: base `debian:trixie` reproducible snapshot (identical shared layer → registry dedup);
amd64/linux only; 4 layers; OCI labels `created/name/ref.name/version` (created empty in 6/7);
**no** EXPOSE, VOLUME, HEALTHCHECK, StopSignal; no env-var defaults (config read at runtime);
Dockerfile shipped at `/` in each image; user `c5` = uid 1000, gid 1000, **no group-0
permissions** on app dirs (G-1).

Changes vs. b1 images: `USER` added (was root-default) ✅ · EXPOSE 80 removed (was misleading) ✅ · OCI labels added (partial) 🟡 · still beta-tagged ❌.

---

## 3. Fit-gap by requirement chapter

Status legend: ✅ **Fit** · 🟡 **Partial** · ❌ **Gap** · ❓ **Verify** · ⬆️ = improved vs. b1

### Chapter 2 — Container image

| Requirement | Status | Evidence / comment |
|---|---|---|
| OCI-compliant image, linux/amd64 | ✅ | 7 OCI-layout tarballs, verified |
| Runs under restricted / restricted-v2 SCC | 🟡⬆️ | Named `USER c5` + all listeners on 8080 → runs under SCC-injected arbitrary UID. **Still required:** supplier attestation + numeric-USER/group-0 fix (G-1) |
| Runs under random UID | ❓ | Works via SCC injection; file perms not group-0 → any app-dir/home write would fail. Attestation needed (G-1) |
| No root / no privileged / no host* | ✅⬆️ | Non-root user declared; nothing needs privileges |
| No hardcoded config/certs/credentials | ✅ | Config externalized; sample uses placeholders; discover/docval ship benign default configs in-image |
| Logs exclusively to stdout/stderr | ✅ | Confirmed (manual §6; no file paths anywhere) |
| Writes only to /tmp or defined mounts | ❓ | Still unattested; PyInstaller onedir suggests no /tmp extraction; TDD "persistent storage" unmapped (G-6) — blocks readOnlyRootFilesystem |
| State app+image version, runtime, base image, tagging scheme | 🟡⬆️ | `/version` endpoint added ✅; partial OCI labels ✅; runtime (Python 3.13/Java 21) and base still undocumented in the manual; beta tagging scheme unexplained ❌ |

### Chapter 3 — Deployment (Helm)

| Requirement | Status | Comment |
|---|---|---|
| Helm chart (Helm 3, OpenShift, GitOps-ready) | ❌ (mitigated) | Still not delivered. Customer chart `helm/ion-c5/` **0.2.0** targets b2 (HTTP health probes, migrate Job, digest pinning). **Supplier sign-off required** (G-13, P1-2) |
| Multi-env via values.yaml, no hardcoded env values | 🟡 | Achieved by the customer chart |
| Alternative: full deployment documentation | 🟡⬆️ | Manual now states the container-platform config pattern explicitly (read-only config volume + Secrets→env, §6.1) — good, but no K8s objects |

### Chapter 4 — Runtime configuration

| Requirement | Status | Comment |
|---|---|---|
| Fully configurable without rebuild | ✅ | INI/TOML/JSON file + `ION_C5_*` env overrides (env wins); per-module `*_CONFIG_FILE` pointers |
| All parameters documented (name, type, meaning, mandatory, default, delivery) | 🟡⬆️ | §6.8 catalogue complete incl. defaults & required-per-module. Still missing: explicit types, restart-required flags. **New: errata needed** — `admin_workers` env-var typo, `oracle`/`oracledb`/`sqlite` inconsistency, undocumented `*_db_driver` (G-11) |

### Chapter 5 — Kubernetes Secrets

| Requirement | Status | Comment |
|---|---|---|
| Sensitive data via Secrets, documented | 🟡 | Mechanism explicitly recommended by manual §6.1; concrete Secret spec still customer-defined (chart README: `ion-c5-app`, `ion-c5-peppol`) — needs DEV sign-off (G-13) |
| No sensitive data in image | ✅ | Verified (only benign default configs shipped) |
| Secrets masked in logs | ✅ | `password`/`secret` values logged as `XXXXX` (manual §6.1) |

### Chapter 6 — Network communication

| Requirement | Status | Comment |
|---|---|---|
| Complete inbound/outbound documentation | 🟡⬆️ | Per-module needs now clearer (receiver: CRL egress; sender: Internet + discover; processor: DBs + docval). Consolidated matrix in §5 below. Still unconfirmed: CRL/OCSP URL list, SML zone details, max message size (G-17) |

### Chapter 7 — Health endpoints

| Requirement | Status | Comment |
|---|---|---|
| startup / readiness / liveness endpoints with URL, port, codes | ✅⬆️ **(major)** | Manual ch. 8: `/health/startup` (503→200), `/health/ready` (dependency checks incl. per-component `latency_ms`), `/health/liveness`, `/version` — all modules except setup, on the listen port (8080). Processor/sender run health-only listeners. Chart uses HTTP probes for all 6. **Residual:** paths on discover/docval to verify in TEST (G-4); recommended probe timings not stated (G-5) |

### Chapter 8 — Monitoring, logging, observability

| Requirement | Status | Comment |
|---|---|---|
| Monitorable state incl. dependency health | 🟡⬆️ | `/health/ready` delivers dependency status + latency per component — scrapeable interim signal |
| Version identification | ✅⬆️ | `/version` endpoint on every module |
| Prometheus metrics endpoint | ❌ | **Still nothing.** Queue depths remain DB/UI-only. Top P2 ask; interim SQL-exporter plan in G-12 |
| Recommended alerts with thresholds | ❌ | Still not delivered |
| Logs to stdout/stderr; runtime log level | ✅ | Global + per-module `*_log_level` |
| Log format specification (timestamp, severity, traceId) | ❓ | Still undocumented; request samples |
| OpenTelemetry (if supported) | 🟡 | Not claimed — acceptable with written statement |

### Chapter 9 — HPA

| Requirement | Status | Comment |
|---|---|---|
| Scaling documentation | 🟡⬆️ | Multi-replica now explicitly safe: processor uses DB-transaction locking on queue entries; admin "one instance + failover"; discover intentionally few replicas (cache). CPU-based HPA possible today (chart); **queue-based scaling still blocked on metrics** (G-12) |

### Chapter 10 — Operational requirements

| Requirement | Status | Comment |
|---|---|---|
| Writable dirs, PV, S3 | ❓ | "Persistent storage" for TDDs still unmapped — **the key unwritten sentence of the delivery** (G-6) |
| DB timeouts, retry | 🟡 | Sender exponential backoff (`schedule_at`, `attempts`, attempt limit + last-error persistence) documented ⬆️; DB timeout behavior still not |
| Behavior on external outage | 🟡 | Queue semantics + AS4 error codes (EBMS:0004/0101/0102) now documented ⬆️ |
| Graceful shutdown + terminationGracePeriodSeconds | ❌ | Still nothing (G-9); chart keeps conservative 60 s |
| Backup/restore | ❌ | Still nothing; DBs are the only state (pending G-6), so DB backups + retention are the whole story — needs supplier confirmation |

### Chapter 12 — Upgrades

| Requirement | Status | Comment |
|---|---|---|
| Versioning, upgrade procedure, zero-downtime, order, migrations, rollback | 🟡⬆️ | **Mechanism delivered:** idempotent `initialize-databases`; per-DB schema versions; `migrate <db> <version|latest>` up **and down**. **Procedure still missing:** db argument names, migrate-vs-rollout ordering, vN-1-app-on-vN-schema compatibility, component update order (G-7). Chart ships opt-in pre-upgrade migrate Job |

### Chapter 13 — Security

| Requirement | Status | Comment |
|---|---|---|
| restricted mode, no capabilities, no privileged | 🟡⬆️ | Expected pass (non-root user, 8080, drop ALL in chart); formal attestation outstanding (G-1) |
| Secret rotation without rebuild | ✅ | Secret update + rolling restart |
| Runtime certificate configuration | ✅ | PEM path/inline or PKCS#12 (`.pfx`/`.p12` auto-detected); password via env |
| Admin UI hardening | ✅⬆️ | **MFA (TOTP)** added; JWT secure cookies; forced password change; view-only UI. Note: local accounts only (no LDAP/OIDC); permissions system exists but is not exposed in this version |
| Internal TLS | ❌ | No TLS/mTLS in modules (by design, proxy-terminated) — SEC decision needed on plaintext in-cluster hops (G-15) |
| CVE / dependency updates | ❌ | No process stated; SBOM still missing. §4a package remains the ask |

### Chapter 14 — OpenShift version compatibility

| Requirement | Status | Comment |
|---|---|---|
| Compatibility commitment | ❌ | Still contractual-only; unchanged |

### Chapter 15 — Documentation

| Requirement | Status | Comment |
|---|---|---|
| Technical description, config & ENV docs | ✅⬆️ | Manual improved (config catalogue, health chapter, AS4 error semantics, sizing table) |
| Secrets/health/network/metrics/ops/upgrade docs | 🟡⬆️ | Health ✅, sizing ✅, network 🟡, upgrade 🟡 (mechanism only), metrics ❌, backup ❌ |
| Release notes / changelog | ❌ | **Still none — and b2's silent 80→8080 default change demonstrated the cost (G-3)** |
| Source-code delivery preference | 🟡 exception | Unchanged: COTS image-only exception + §4a controls; formalize in writing |

---

## 4. Prioritized gap register (supplier action list) — rev. 2

Closed since rev. 1: ~~P1-1 health endpoints~~ ✅ (residual: G-4 path verification on discover/docval) · ~~P1-6 version identification~~ ✅ (`/version`) · ~~P3-15 idempotency of initialize-databases~~ ✅ (+ `migrate`) · memory sizing ✅.

**P1 — acceptance blockers (PROD):**
1. **Release notes/changelog per release**, including every changed default (b2 changed listen-port defaults silently — G-3). *(was P2)*
2. Helm chart: formally approve customer chart 0.2.0 as the supported deployment (G-13).
3. **Upgrade procedure**: `migrate` db-names, ordering contract (migrate→rollout?), rollback/schema compatibility, component update order (G-7).
4. **restricted-v2 attestation + writable paths** (target `readOnlyRootFilesystem: true`); numeric `USER 1000` + group-0 permissions in images (G-1); TDD "persistent storage" mapping — DB-only confirmation (G-6).
5. Release-grade tags for the acceptance version (no `bN`), clean builds (no `.dev` remnants), populated OCI labels, digest list (G-14, §4a).

**P2 — required for stable operations:**
6. **Prometheus metrics**: queue depths (receive/send), dead-letter count, attempts, request counts/errors/latency; `/health/ready` already computes `latency_ms` per dependency — export it (G-12). Plus recommended alerts + thresholds.
7. Interim (customer-side, until 6 lands): supplier delivers the **reference SQL queries** for queue/dead-letter monitoring (they power the admin dashboard).
8. Graceful-shutdown statement per module + recommended `terminationGracePeriodSeconds` (G-9).
9. Probe timing guidance: worst-case startup (docval artifact load, receiver first CRL fetch), readiness cost under DB latency (G-5); confirm discover/docval probe paths (G-4).
10. Network matrix confirmation: CRL/OCSP URLs, SML zones, **max AS4 message size + exchange duration** for router/WAF limits (G-17).
11. Log format specification + samples; backup/restore statement (DB-only expected, pending G-6).
12. ion-docval JVM sizing recommendation (`MaxRAMPercentage` or launcher default) (G-10).

**P3 — contractual/process:**
13. CVE/patch process + SLA; SBOM per release; OCP version compatibility commitment (§4a).
14. Formalize the COTS image-only-delivery exception in writing (§4a).
15. Non-interactive `create-admin-user` (flags/env/stdin) for bootstrap automation (G-8); password-reset path documentation.
16. Documentation errata batch (G-11); restart-required flags + types per config parameter; runtime/base-image statement in the manual.
17. mTLS/internal-TLS roadmap statement (G-15); LDAP/OIDC roadmap for admin UI; expose the already-implemented permissions system.

### §4a — Compensating controls for COTS image-only delivery

Since the customer cannot rebuild the images in its own CI/CD, the software-supply-chain
requirement is met through supplier obligations plus customer-side gates:

**Supplier obligations (contractual):**
1. **SBOM per image per release** (SPDX or CycloneDX) covering OS packages and application dependencies.
2. **Digest-pinned releases** — a release manifest listing image name, tag and sha256 digest for every component; ideally images **signed** (cosign/Sigstore or registry-native signing) with a published public key.
3. **CVE response SLA** — defined remediation times per severity (e.g. critical ≤ 7 days, high ≤ 30 days) for base image (Debian trixie) and bundled runtimes (Python 3.13 PyInstaller bundles, OpenJDK 21 in ion-docval); rebuilt patched images delivered as new tags, never overwritten tags.
4. **Release notes/changelog** per version incl. security-fix identification and **changed defaults** (P1-1).
5. Immutable tags — a published tag must never be re-pushed with different content (digest change = new tag).

**Customer-side gates (platform):**
6. Quarantine flow: supplier tarballs land in a staging repo, are scanned (registry scanner / ACS), and are promoted to the production repo only after policy pass.
7. Helm values pin images **by digest** in PREPROD/PROD (chart supports `image.digest` per component).
8. Periodic re-scan of deployed images; findings routed to the supplier under the SLA of item 3.

---

## 5. Derived network communication matrix (to validate with supplier)

**Inbound**

| Module | Port (chart) | Protocol | Source | Purpose |
|---|---|---|---|---|
| ion-c5-receiver | 8080 | HTTP (TLS at Route/LB) | Internet (Peppol APs) via router | AS4 endpoint `/as4` |
| ion-c5-admin | 8080 | HTTP (TLS at Route/LB) | Admin networks only (IP whitelist at proxy — product has none) | Management UI |
| ion-discover | 8080 | HTTP | processor, sender (via Service :80) | SML/SMP lookup API |
| ion-docval | 8080 | HTTP | processor (via Service :80) | XML validation API |
| processor / sender | 8080 | HTTP | kubelet only | **health-check-only listeners** (manual §6.8) — no Service rendered |
| all modules | 8080 | HTTP | kubelet | `/health/*`, `/version` |

**Outbound**

| Module | Destination | Port | Purpose |
|---|---|---|---|
| receiver | receiver DB (Oracle/PostgreSQL) | 1521/5432 | receive queue + dead letters |
| receiver | Internet: Peppol CA CRL distribution points | 80/443 | sender certificate validation (CRL download) |
| processor | receiver DB, TDD DB, main DB | 1521/5432 | orchestration |
| processor | ion-docval Service | 80 | validation (plaintext XML — G-15) |
| sender | main DB, TDD DB, receiver DB | 1521/5432 | send queue, MLS results |
| sender | ion-discover Service | 80 | recipient lookup |
| sender | Internet: recipient APs (dynamic hosts) | 443 | AS4 MLS transmission |
| discover | Internet: SML (DNS) + SMPs (dynamic) | 53, 80/443 | Peppol discovery |
| admin | receiver DB, TDD DB, main DB | 1521/5432 | management UI |
| all | DNS, NTP (platform) | 53, 123 | platform services |

---

## 6. Open questions

**For the supplier** — P1–P3 above; sharpest first: TDD persistence mapping (G-6), migrate
db-names/ordering (G-7), discover/docval probe paths (G-4), release notes going forward (P1-1),
runtime/base statement, max AS4 message size (G-17).

**Customer-side decisions (status 2026-07-28):**
1. ✅ Registry naming per plan (fill actual URL into `global.imageRegistry` in the env values files).
2. ✅ Oracle; 3-way DB split (receiver/TDD/main) for PROD, single instance acceptable below PROD.
3. ✅ Receiver/admin hostname pattern per environment; concrete FQDNs + admin IP ranges into env values files.
4. ✅ `peppol-test` in all environments except PROD (`peppol`).
5. ⬜ GitOps tool (Argo CD?) — still open.
6. ✅ COTS image-only delivery — formal exception + §4a controls; source delivery not pursued.
7. ⬜ **NEW — SEC decision:** accept plaintext in-cluster hops, or require IPsec/mesh (G-15).
8. ⬜ **NEW — OPS/DBA:** stand up interim queue monitoring via SQL exporter (G-12) for PREPROD/PROD.
