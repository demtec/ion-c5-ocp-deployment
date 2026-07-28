# Helm chart gap analysis — specialties to settle between the developer and the OpenShift team

**Scope:** issues that live exactly on the boundary between the COTS product (Ionite, "DEV")
and the customer platform ("OCP" + OPS/NET/SEC/DBA roles per [RESPONSIBILITIES.md](RESPONSIBILITIES.md)).
These are the things that cause installs to fail or arguments to start; each item names the
owner of the *fact* and the owner of the *fix*.

**Basis:** delivery 1.0.0b2 (images inspected layer-by-layer 2026-07-28), Administrator's
Manual 1.0.0b2-1 (fully read), chart `helm/ion-c5/` 0.2.0.

**Verdict up front:** with 1.0.0b2 the product is deployable on OpenShift under
`restricted-v2` with real health probes — a major step vs. b1. The remaining specialties
are: identity/permissions inside the images (G-1), unverified probe paths on the two
standalone modules (G-4), unmapped "persistent storage" (G-6), migration semantics (G-7),
and everything observability (G-12).

## Summary table

| # | Specialty | Fact owner | Fix owner | Severity | Status |
|---|---|---|---|---|---|
| G-1 | Named `USER c5` vs. runAsNonRoot / arbitrary UID | DEV | DEV (image), OCP (workaround) | High | Open |
| G-2 | No EXPOSE/port metadata in images | DEV | DEV | Low | Open |
| G-3 | Silent default-port change 80→8080 broke in-cluster wiring | DEV | OCP (chart pins 80) | High | **Mitigated in chart** |
| G-4 | Probe paths unverified on ion-discover / ion-docval | DEV | DEV confirm + OCP test | High | Open — verify in TEST |
| G-5 | Probe timing budgets are guesses (worst-case startup unknown) | DEV | OCP | Medium | Open |
| G-6 | "Persistent storage" for TDDs unmapped; readOnlyRootFilesystem blocked | DEV | DEV | High | Open |
| G-7 | `migrate <db>` argument names + upgrade order unconfirmed | DEV | DEV | High | Open — chart guesses `main/receiver/tdd`, Job default-off |
| G-8 | `create-admin-user` interactive-only — not Job-able | DEV | DEV | Medium | Open |
| G-9 | No graceful-shutdown/SIGTERM statement | DEV | DEV | Medium | Open |
| G-10 | ion-docval JVM sizing undefined | DEV | DEV recommend, OCP set | Medium | Open |
| G-11 | Documentation errata (env-var typo, db_type values, undocumented keys) | DEV | DEV | Medium | Open |
| G-12 | No metrics ⇒ no queue-based HPA/alerting | DEV | DEV (product) / OPS+DBA (interim) | High | Open |
| G-13 | Secret & config contract needs DEV sign-off | DEV+OCP | DEV approval | Medium | Open |
| G-14 | Build hygiene: beta tags, dev remnants, single-arch | DEV | DEV | Medium | Open |
| G-15 | No TLS in modules; internal hops plaintext | DEV (fact) | SEC decision | Medium | Open |
| G-16 | Kubelet probes vs. default-deny NetworkPolicy | — | OCP | Info | No action (OVN allows) |
| G-17 | Route/AS4 limits: message size, router timeouts | DEV+NET | OCP/NET | Medium | Open |
| G-18 | Config-change restart semantics | DEV | OCP (checksum restart in chart) | Low | Mitigated in chart |

---

## G-1 — Named `USER c5` vs. `runAsNonRoot` and arbitrary UIDs (High)

**Fact (from images):** all 7 images declare `USER c5` (named), created as uid=1000 gid=1000
with home `/home/c5`; app files under `/var/ion` are **not** group-0 owned and have no
`g=u` permissions.

**Why it matters:**
- On **OpenShift restricted-v2** this *works by accident*: SCC admission injects a numeric
  `runAsUser` from the namespace range, so the kubelet's "non-numeric user" check never
  fires — but the process then runs as an **arbitrary UID that is neither root nor 1000**.
  Any write attempt to `$HOME` or the app dir will fail with EACCES.
- On plain Kubernetes (or if anyone tests with docker/podman defaults), `runAsNonRoot: true`
  + named user **fails admission** ("container has runAsNonRoot and image has non-numeric user").

**Ask of DEV (image fix, one line each):** `USER 1000` (numeric) and OpenShift file
conventions: `chgrp -R 0 /var/ion && chmod -R g=u /var/ion` (same for any runtime-writable
path). Plus a written attestation: "runs under arbitrary UID, writes only to X, Y".

**OCP meanwhile:** chart exposes `securityContext.runAsUser` (default null on OCP; set
`1000` on platforms that enforce the numeric check). Do **not** pin 1000 on OpenShift —
it would require an SCC exception for no benefit.

## G-2 — No EXPOSE / port metadata (Low)

b1 images declared `EXPOSE 80`; b2 declares nothing. Harmless at runtime (k8s ignores
EXPOSE) but it removes the last in-image signal of intended ports and confuses scanners
and humans. Ask DEV: `EXPOSE 8080` + complete OCI labels (only `created/name/ref.name/
version` are present; `created` is even empty in 6 of 7 images).

## G-3 — Silent default-port change 80→8080 (High — mitigated, but instructive)

Between b1 and b2 the application defaults for `discover_port`/`validator_port` (and all
listen ports) moved from 80 to 8080 — **with no changelog**. The chart's Services listen on
port 80, so any consumer relying on the new defaults would dial the Service on 8080 and
hang. The chart now **pins `discover_port=80` / `validator_port=80`** in the rendered
config (`_helpers.tpl`), so this cannot regress. Lesson for the register: this is exactly
the class of break that the missing release notes (fit-gap P2) are supposed to prevent.
DEV must list **every changed default** per release in the release manifest.

## G-4 — Probe paths on ion-discover / ion-docval unverified (High until tested)

Manual ch. 8 says *"All modules, except the ion-c5-setup tool, have version and health
endpoints"* (`/health/{startup,ready,liveness}`, `/version`), and both standalone modules
ship in-image config with health APIs enabled (`enable_health_api=true` in
`/etc/ion-discover.conf`; `EnableHealthEndpoints=true` in `/etc/ion-docval.conf`). But the
worked examples cover only the c5-* modules, and ion-discover/ion-docval are separate
products with their own docs. **Risk:** wrong path ⇒ pods never Ready ⇒ install "fails"
and the blame ping-pong starts.

**Action:** first TEST install verifies `GET /health/ready` on both (fallbacks already
documented in `values.yaml`: discover `/v2`, docval `type: tcp`; probe paths are
per-component overridable). DEV confirms canonical paths + expected codes in writing.

## G-5 — Probe timing budgets are guesses (Medium)

Chart budgets: startup ≤150 s (30×5 s), readiness timeout 5 s (the manual warns
`/health/ready` runs real dependency checks — DB round-trips — and "may react slower"),
liveness every 20 s. DEV owes worst-case startup figures (docval loading all schematron
artifacts; receiver first CRL download; Oracle connection storms after failover) so OCP
can set budgets instead of guessing. Until then: measured values from TEST become the
documented facts (RESPONSIBILITIES.md §7.3).

## G-6 — "Persistent storage" for TDDs unmapped; read-only rootfs blocked (High)

The manual repeatedly says valid TDDs go to "persistent storage" *and* metadata to the TDD
DB, but never names a path, volume, or bucket; no config key exists for a storage location;
images declare no VOLUMEs. Everything points to the documents living **in the TDD database**
— but nobody has it in writing. Until DEV states "no filesystem persistence; all writes go
to /tmp only":
- `readOnlyRootFilesystem` stays `false` (chart value ready to flip),
- no PVC/S3 can be planned (or ruled out) for capacity and backups,
- DBA cannot size the TDD tablespace for BLOB growth.
This is the single most consequential unwritten sentence in the delivery. (Supporting
evidence from image inspection: PyInstaller onedir bundles — no self-extraction to /tmp;
Java will want /tmp for tmpfiles. `/tmp` is already an emptyDir in every pod.)

## G-7 — `migrate` semantics: db names and ordering (High for upgrades)

`ion-c5-setup migrate <db> latest` exists (idempotent, supports downgrade — good design).
Unconfirmed: the exact `<db>` argument values (chart guesses `main`, `receiver`, `tdd`
from the manual's prose "main db"), and the **orchestration contract**: migrate before or
after the new application pods start? Is schema vN readable by app vN-1 (needed for rolling
upgrades and for `helm rollback` after a failed upgrade)? The chart ships a pre-upgrade
migrate Job (`setup.migrateOnUpgrade`, **default off**) that encodes the "migrate first,
then roll pods" answer — DEV must either bless that or specify differently. Also: DB user
needs DDL rights during migration only — DBA may want a separate migration user.

## G-8 — First admin user cannot be automated (Medium)

`create-admin-user` remains interactive-only in b2 (prompts for username/password; manual
§5.1.1). Consequence: cannot run as a Job/hook; every environment bootstrap needs a human
with `oc run -it` (documented in NOTES.txt). GitOps-complete environment provisioning is
impossible until DEV adds flags/env/stdin input. Interim is acceptable for 4 environments;
it becomes a real problem for DR rebuild automation. Keep as P3 supplier item.

## G-9 — Graceful shutdown undefined (Medium)

No SIGTERM/drain statement anywhere. Open questions with operational consequences:
does the receiver finish in-flight AS4 exchanges on SIGTERM (an aborted exchange = sender
AP retries, acceptable)? Does the processor finish its current batch or roll back the
`PROCESSING` transaction (manual suggests DB transaction covers it — good, but unwritten)?
Does the sender abandon an in-flight AS4 send cleanly? Chart keeps
`terminationGracePeriodSeconds: 60` as a conservative default; DEV to confirm per-module
behavior + recommended values. Matters for node drains, HPA scale-down, and rolling updates.

## G-10 — ion-docval JVM sizing (Medium)

Java 21 JRE, no `-Xmx`/`JAVA_OPTS` guidance, launcher is a plain shell script. Container-aware
JVM defaults give heap = 25 % of the 2 Gi limit (512 Mi) — probably fine, possibly wasteful
or tight under large validation loads. DEV to recommend `MaxRAMPercentage` (or ship it in
the launcher); OCP exposes it via `components.docval.env.JDK_JAVA_OPTIONS` (already
documented in values.yaml). Until then the manual's 1–2 Gi table stands.

## G-11 — Documentation errata to fix in one batch (Medium)

For the DEV errata list (each has bitten or will bite the values files):
1. `admin_workers` env var printed as `ION_C5_PROCESSOR_WORKERS` (manual p. 22) — presumably
   a typo for `ION_C5_ADMIN_WORKERS`; confirm which name the code actually reads. Note the
   chart's generated `-env` ConfigMap derives `ION_C5_ADMIN_WORKERS` by convention.
2. `db_type` accepted values inconsistent: `postgresql`/`oracledb` (p. 10) vs. "sqlite,
   postgresql, oracle" (p. 22); the shipped sample uses `oracle`. State the canonical list.
3. `*_db_driver` keys appear in per-module lists but are absent from the §6.8 reference.
4. p. 20 says "ion-discover … minimalistic web frontend" where ion-docval is meant.
5. Prose uses `*_idle_wait_time` while the real keys are `*_idle_wait_seconds`.
6. ion-discover 1.0.1 / ion-docval 1.3.1 versions appear nowhere in the manual.

## G-12 — No metrics ⇒ observability gap shapes the whole day-2 design (High)

Still nothing in b2: no Prometheus endpoint, no queue-depth export, no version metric.
Consequences, concretely: HPA limited to CPU (wrong signal for queue workers); alerting
limited to probe/restart/resource signals; the *right* signals (receive-queue depth,
send-queue depth + attempts, dead-letter count) exist only in the DB and admin UI.
**Interim plan (OPS+DBA, works today):** the readiness endpoints give dependency health for
free — scrape-able by a blackbox exporter; queue depths via a SQL exporter
(oracledb-exporter) against the three DBs — DEV to supply the reference queries (they
already power the admin dashboard). **Product ask stays:** native `/metrics`; this remains
the top P2 item. Note `/health/ready` includes per-dependency `latency_ms` — half a metrics
endpoint already exists; exporting it is a small step for DEV.

## G-13 — The Secret/config contract needs a signature (Medium)

The chart defines the de-facto interface: Secret `ion-c5-app` (keys = env var names),
Secret `ion-c5-peppol` (`certificate.pem`/`private.key`), ConfigMap-rendered
`config.ini` at `/etc/ion-c5/config.ini` via `ION_C5_*_CONFIG_FILE`. All of it is *derived
from* the manual, but DEV has never signed off the chart (fit-gap P1-2). Chart approval =
DEV confirms wiring keys, env names, mount paths, and the two-Secret split. Without it,
every incident starts with "unsupported deployment".

## G-14 — Build hygiene (Medium, acceptance-relevant)

Found in the b2 images: sender ships a stray `ion_c5_base-1.0.0b3.dev0` dist-info (build
not from a clean env — which code is actually inside?); tags still beta (`b2`) while PROD
acceptance requires release-grade versioning; `image.created` label empty in 6/7 images;
full Dockerfile shipped at `/` (transparency win — keep it); single-arch amd64 (fine —
document as a platform constraint). Ask: clean release builds, populated OCI labels,
release tags for the acceptance version, digest list in the release manifest (§4a).

## G-15 — No TLS in the modules; internal hops are plaintext HTTP (Medium — SEC decision)

Fact (manual §4): receiver/admin rely on the reverse proxy for HTTPS; inter-module traffic
(processor→docval carries decrypted invoice XML, sender→discover, module→health) is plain
HTTP by design; no mTLS option exists. On OCP this means: Routes terminate TLS at the
router (edge) — traffic router→pod and pod→pod crosses the SDN unencrypted. Mitigations
available without DEV: OVN-Kubernetes IPsec cluster-wide, or a service mesh sidecar (needs
DEV statement that a sidecar proxy is supported). **SEC must explicitly accept or require
one of these**; record the decision. DEV should state whether mTLS is on any roadmap.

## G-16 — Kubelet probes under default-deny NetworkPolicy (Info)

The chart's default-deny ingress does not block health probes: OVN-Kubernetes sends kubelet
probe traffic from the node's management address, which NetworkPolicy implicitly allows.
No action; recorded here because it is a recurring OpenShift argument.

## G-17 — AS4 message limits vs. router settings (Medium)

Nobody has stated the maximum TDD/AS4 message size. The OCP router and any WAF/LB in front
impose body-size and timeout limits (HAProxy default timeout 30 s; WAF body limits often
1–10 MB). A large signed+encrypted TDD hitting a router timeout produces sender-side
retries and duplicate-delivery noise that will be misdiagnosed as an application bug.
DEV: state max supported message size + typical AS4 exchange duration. NET/OCP: set router
`haproxy.router.openshift.io/timeout` and WAF limits accordingly (values.yaml
`route.annotations` is the hook).

## G-18 — Config-change restart semantics (Low — mitigated)

The manual never says which config changes take effect at runtime; operational assumption:
all require restart. The chart already forces a rolling restart on any config change
(`checksum/config` pod annotation), which is the safe universal answer. DEV can refine
per-key restart flags later (fit-gap P3); until then no action needed.

---

## Recommended settlement package (one meeting agenda)

1. **DEV image fixes (cheap, high value):** numeric `USER 1000` + group-0 perms (G-1),
   `EXPOSE 8080` + full OCI labels (G-2), clean release builds + release tags (G-14).
2. **DEV written statements (no code):** TDD persistence = DB-only + writable paths (G-6),
   probe paths for discover/docval + startup worst-cases (G-4/G-5), migrate db-names +
   ordering contract (G-7), SIGTERM behavior (G-9), max AS4 message size (G-17),
   JVM sizing (G-10), errata batch (G-11).
3. **DEV product backlog:** `/metrics` (G-12), non-interactive `create-admin-user` (G-8),
   mTLS roadmap statement (G-15).
4. **Customer-side decisions:** SEC verdict on plaintext internal hops (G-15);
   OPS+DBA interim SQL-exporter monitoring (G-12); NET router/WAF limits (G-17).
5. **Formal act:** DEV signs off chart 0.2.0 as the supported deployment (G-13, fit-gap P1-2).
