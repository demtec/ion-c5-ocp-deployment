# Helm chart gap analysis — specialties to settle between the developer and the OpenShift team

**Scope:** issues that live exactly on the boundary between the COTS product (Ionite, "DEV")
and the customer platform ("OCP" + OPS/NET/SEC/DBA roles per [RESPONSIBILITIES.md](RESPONSIBILITIES.md)).
These are the things that cause installs to fail or arguments to start; each item names the
owner of the *fact* and the owner of the *fix*.

**Basis:** delivery 1.0.0b2 (images inspected layer-by-layer 2026-07-28), Administrator's
Manual 1.0.0b2-1 (fully read), chart `helm/ion-c5/` 0.2.1, **supplier email of 2026-07-28**
(gap responses — cross-checked against the artifacts; statuses below reflect it).

**Verdict up front:** with 1.0.0b2 plus the supplier's written answers, the product is
deployable on OpenShift under `restricted-v2` with real health probes and a **read-only
root filesystem**. The remaining specialties are: identity/permissions inside the images
(G-1), migration/rollback compatibility (G-7), observability (G-12 — supplier has committed
to Prometheus metrics before 1.0.0), and the SEC decision on plaintext hops (G-15).

**Status update (2026-08-13):** this document's per-item statuses below are as of the
2026-07-28 supplier email and chart 0.2.1; several have since changed and are noted inline:
G-1 (images now drop `USER` entirely as of 1.0.0b3, rather than fixing it to numeric — a
different, not-asked-for outcome), G-2 (`EXPOSE 8080` confirmed added in b3 — **closed**),
G-7 (b3 manual's worked `migrate` examples partially confirm the `<db>` argument spelling).
Separately, **chart 0.4.0 removed the pre-upgrade migrate Job this document references** (G-7
below) — migration is now a manual step outside the chart.

## Summary table

| # | Specialty | Fact owner | Fix owner | Severity | Status | Comment from DEV
|---|---|---|---|---|---|---|
| G-1 | Named `USER c5` vs. runAsNonRoot / arbitrary UID | DEV | DEV (image), OCP (workaround) | High | Open — **status changed 2026-08-13**: b3+ images drop `USER` entirely rather than fixing it to numeric (harmless on OpenShift SCC; still a `runAsNonRoot` risk on vanilla k8s without the chart's `runAsUser` mitigation) | Resolved in b4, USER removed, application can run with any UID
| G-2 | No EXPOSE/port metadata in images | DEV | DEV | Low | **Closed 2026-08-13** — `EXPOSE 8080` confirmed present on all 7 images as of 1.0.0b3 |
| G-3 | Silent default-port change 80→8080 broke in-cluster wiring | DEV | OCP (chart pins 80) | High | **Mitigated in chart**; release-notes ask stands | Manual now contains Changelog section; separate releasenotes/changelog can be provided if desired.
| G-4 | Probe paths on ion-discover / ion-docval | DEV | OCP quick test | ~~High~~ Low | **Confirmed by email** ("all modules"); routine TEST verify |
| G-5 | Probe timing budgets | DEV | OCP | Low | **Largely answered**: start "within seconds", docval ~10 s worst; 150 s budget ample; manual section still to add | Added section to health endpoints section
| G-6 | Writable paths / readOnlyRootFilesystem / TDD storage | DEV | DEV | ~~High~~ Low | **Attested**: CRL-write oversight fixed in b2, "no other writes to disk" → chart default now `readOnlyRootFilesystem: true`. Residual: explicit TDD=DB sentence for backup scope | Added section to database chapter, explaining the database(s), and specifically mentioning the `tdd` and `tdd_transaction` tables.
| G-7 | `migrate` semantics | DEV | DEV | Medium | **Partially answered**: per-DB, order admin-defined, idempotent, up/down, nothing to migrate yet. Residual: exact `<db>` names + app-vs-schema rollback compatibility | Added section on migration in manual
| G-8 | `create-admin-user` interactive-only — not Job-able | DEV | DEV | Medium | Open | Since 1.0.0b4 the first admin user is created automatically. Additionally, the ion-c5-setup image should also be usable in openshift since 1.0.0b5
| G-9 | No graceful-shutdown/SIGTERM statement | DEV | DEV | Medium | Open | Added a section on graceful shutdown
| G-10 | ion-docval JVM sizing undefined | DEV | DEV recommend, OCP set | Medium | Open | Added line to memory usage section.
| G-11 | Documentation errata | DEV | DEV | Medium | Open — **new item**: email says `*_listen_address`, manual says `*_listen_host` | This should have been _host in the email.
| G-12 | No metrics ⇒ no queue-based HPA/alerting | DEV | DEV (product) / OPS+DBA (interim) | High | Open — **DEV committed: Prometheus metrics before 1.0.0 release** | This has been added in 1.0.0b5
| G-13 | Secret & config contract needs DEV sign-off | DEV+OCP | DEV approval | Medium | **Informal approval in email** ("not seeing anything that seems wrong"); formalize per chart release |
| G-14 | Build hygiene: beta tags, dev remnants, labels | DEV | DEV | Medium | **Partially answered**: 4 OCI labels added, `bN`-until-feature-complete scheme stated, SBOM extraction in progress; residual: clean builds, empty `created` label, digest list |
| G-15 | No TLS in modules; internal hops plaintext | DEV (fact) | SEC decision | Medium | Open | Currently not on roadmap but will be immediately added if required by customer.
| G-16 | Kubelet probes vs. default-deny NetworkPolicy | — | OCP | Info | No action (OVN allows) |
| G-17 | Route/AS4 limits: message size, router timeouts | DEV+NET | OCP/NET | Medium | Open | Added section "Routing and message sizes" to manual
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
path). Plus a written attestation: "runs under arbitrary UID, writes only to X, Y" —
the 2026-07-28 email delivered the writes-to-disk half (see G-6) but did not address the
named-user/UID topic; it remains the one P1-class image item without a supplier response.

**OCP meanwhile:** chart exposes `securityContext.runAsUser` (default null on OCP; set
`1000` on platforms that enforce the numeric check). Do **not** pin 1000 on OpenShift —
it would require an SCC exception for no benefit.

**Update (2026-08-13, from 1.0.0b3 image inspection):** the supplier did not implement the
numeric-`USER` ask — instead, **all 7 images as of b3 declare no `USER` directive at all**
(root by default), the opposite of both the b2 state and the request. Practical impact,
confirmed by inspecting the extracted image layers: `/var/ion` is owned `root:root` with
group-0-equal permissions (directories `775`, files `664`/`755`), so **on OpenShift
restricted-v2 this remains a non-issue** — SCC admission injects an arbitrary UID plus
supplemental group 0 regardless of the image's declared user, and that UID can read/execute
everything it needs. On vanilla Kubernetes without SCC this is now unambiguously
root-by-default, which more reliably trips `runAsNonRoot` admission than the old named-user
case did — but the chart's existing mitigation (`securityContext.runAsUser: 1000` on such
platforms) is unaffected and still works. Net: not fixed, arguably a documentation/attestation
regression, but not a new functional blocker for the OpenShift target, and no chart change
needed.

## G-2 — No EXPOSE / port metadata (Low — **closed 2026-08-13**)

b1 images declared `EXPOSE 80`; b2 declares nothing — the email confirms this was
deliberate ("ports are configurable anyway") and offers to restore it. **Our answer: yes,
please add `EXPOSE 8080`** — k8s ignores it at runtime, but it documents the default in
the artifact itself and keeps scanners/humans oriented; since b2 every module has a web
interface, one uniform port is now accurate. Labels: DEV asked "do we want additional
labels?" — requested set: `org.opencontainers.image.revision` (build/commit),
`…vendor`, `…licenses`, `…description`, `…base.name` + `…base.digest`; and fix the bug
that `…created` is an **empty string in 6 of 7 b2 images** (only admin has it populated).

**Update (2026-08-13):** `EXPOSE 8080` is confirmed present on all 7 images as of 1.0.0b3 —
**this half of G-2 is closed**. The additional labels requested above were **not** added
(only the original 4 labels are present), and `…created` is **still empty in 6 of 7 images**
in b3 — that part of G-2/G-14 remains open.

## G-3 — Silent default-port change 80→8080 (High — mitigated, but instructive)

Between b1 and b2 the application defaults for `discover_port`/`validator_port` (and all
listen ports) moved from 80 to 8080 — **with no changelog**. The chart's Services listen on
port 80, so any consumer relying on the new defaults would dial the Service on 8080 and
hang. The chart now **pins `discover_port=80` / `validator_port=80`** in the rendered
config (`_helpers.tpl`), so this cannot regress. Lesson for the register: this is exactly
the class of break that the missing release notes (fit-gap P2) are supposed to prevent.
DEV must list **every changed default** per release in the release manifest.

## G-4 — Probe paths on ion-discover / ion-docval (downgraded to Low)

**Resolved by the supplier email**: health endpoints exist on all runtime modules
("all modules now have a web interface"; discover 1.0.1 and docval 1.3.1 were bumped
precisely "due to some additions for health and version"). In-image configs agree
(`enable_health_api=true`, `EnableHealthEndpoints=true`). Residual: routine verification
on first TEST install; fallbacks stay documented in `values.yaml` (discover `/v2`,
docval `type: tcp`), and the paths remain per-component overridable.

## G-5 — Probe timing budgets (downgraded to Low)

**Largely answered in the email**: modules start "within seconds"; ion-docval is the
slowest (XSLT/XSD loading), ~10 s on reasonable cores. The supplier's semantic guidance
matches the chart's wiring: `/health/liveness` = cheap is-it-running check,
`/health/startup` = initialization complete, `/health/ready` = the slower
dependency-checking endpoint. Chart budgets (startup ≤150 s at 30×5 s; readiness timeout
5 s; liveness every 20 s) are comfortably above the stated worst case — keep them.
Residual: DEV to add the timing section to the manual so the numbers are contractual,
not email folklore; TEST measurements remain the tiebreaker (RESPONSIBILITIES.md §7.3).

## G-6 — Writable paths attested; read-only rootfs ENABLED (downgraded to Low)

**Resolved in substance by the supplier email**: b2 fixed the one write-to-disk oversight
(the CRL validator cached CRLs to disk; now auto-disabled on a read-only filesystem) and
states **"there are no other writes to disk so read-only root can be enabled."** Chart
0.2.1 therefore defaults `readOnlyRootFilesystem: true` (`/tmp` stays an emptyDir).

Operational consequence of the CRL change worth knowing: with the disk cache disabled,
CRLs live in memory only — every receiver restart re-fetches them, so **CRL egress must
work at pod start** (it is in the network matrix; a broken CRL path now surfaces as
receive-side validation failures right after restarts, not gradually).

Residuals: (a) one explicit sentence in the manual that TDD documents persist in the TDD
**database** only (the email implies it — "no other writes to disk" — but backup scope and
TDD tablespace/BLOB sizing for DBA should rest on a documented statement, not an
implication); (b) fold the attestation into the formal restricted-v2 statement (G-1).

## G-7 — `migrate` semantics: db names and rollback compatibility (Medium)

**Partially answered in the email**: migrations run **per database individually, order
defined by the admin** (so the chart's fixed `main → receiver → tdd` sequence is a
legitimate admin choice, not a guess about product behavior); up/down to a version or
`latest`; no-op when already at target; **all schemas are at v1 — there is nothing to
migrate yet**, and the command doubles as a schema-version check. At the time of this
analysis the chart had an opt-in pre-upgrade Job (`setup.migrateOnUpgrade`) kept off by
default; **chart 0.4.0 removed this Job (and all `setup.*` values) entirely** — migration is
now always a manual step run outside the chart, per the current chart README.

Still owed by DEV: the exact `<db>` argument spelling in the manual (chart assumes
`main`/`receiver`/`tdd` — trivially testable with the no-arg `migrate` version report),
and the **compatibility contract** once real migrations exist: is schema vN readable by
app vN-1 (governs rolling upgrades and `helm rollback` without a schema downgrade)?
DBA note stands: DDL rights are needed during migration only — consider a separate
migration user.

**Update (2026-08-13):** the 1.0.0b3 manual now documents worked examples — `migrate`
(report only), `migrate main latest`, `migrate main 1`, `migrate main 2` (errors "no version
2") — confirming `main` as a valid `<db>` argument. `receiver`/`tdd` are still inferred by
naming convention, not literally shown in an example; residual narrowed, not fully closed.

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
7. **New (from the gap-response email):** the email names the four new options
   `processor_listen_address` / `sender_listen_address` (+ `_port`), while manual §6.8
   documents `processor_listen_host` / `sender_listen_host`. One of the two is wrong —
   confirm the key the code reads (the chart only relies on the `*_LISTEN_PORT` env vars,
   which both sources agree on).

## G-12 — No metrics ⇒ observability gap shapes the whole day-2 design (High)

Still nothing in b2: no Prometheus endpoint, no queue-depth export, no version metric.
Consequences, concretely: HPA limited to CPU (wrong signal for queue workers); alerting
limited to probe/restart/resource signals; the *right* signals (receive-queue depth,
send-queue depth + attempts, dead-letter count) exist only in the DB and admin UI.
**Interim plan (OPS+DBA, works today):** the readiness endpoints give dependency health for
free — scrape-able by a blackbox exporter; queue depths via a SQL exporter
(oracledb-exporter) against the three DBs — DEV to supply the reference queries (they
already power the admin dashboard). **Product ask stays:** native `/metrics`; this remains
the top P2 item — and the email confirms it is planned: *"still need to add at least
prometheus metrics"* before the 1.0.0 release tag. Note `/health/ready` includes
per-dependency `latency_ms` — half a metrics endpoint already exists; exporting it is a
small step for DEV. When specifying, include queue depths / dead-letter count / send
attempts (the HPA + alerting signals), not just process metrics.

## G-13 — The Secret/config contract needs a signature (Medium)

The chart defines the de-facto interface: Secret `ion-c5-app` (keys = env var names),
Secret `ion-c5-peppol` (`certificate.pem`/`private.key`), ConfigMap-rendered
`config.ini` at `/etc/ion-c5/config.ini` via `ION_C5_*_CONFIG_FILE`. All of it is *derived
from* the manual, and the email gives an **informal review**: *"I'll mostly defer to your
own expertise as to most of the yaml specifics … Other than that I'm not seeing anything
that seems wrong atm."* That is exactly the right division of labor per
RESPONSIBILITIES.md — DEV reviews application correctness, not platform choices — but it
should be upgraded from email prose to a **formal per-release sign-off** (one sentence:
"chart 0.2.1 is a supported deployment of 1.0.0b2"), so no incident starts with
"unsupported deployment".

## G-14 — Build hygiene (Medium, acceptance-relevant — partially answered)

Answered by the email: beta tags are **deliberate** (customer asked for `b2`; 1.0.0 tag
comes once feature-complete, metrics being the known remainder) — acceptable, now it is a
documented scheme. Four OCI labels added on request. **SBOM movement:** every image already
contains an internal dependency list; DEV is extracting it into a standard format (ask for
**SPDX or CycloneDX** explicitly, §4a-1) and has CVE tooling for Python deps + will roll
updates — this is the §4a package materializing.

Still open: sender ships a stray `ion_c5_base-1.0.0b3.dev0` dist-info (build not from a
clean env — which code is actually inside?); `image.created` label **empty in 6/7 images**;
digest list per release; single-arch amd64 (fine — document as a platform constraint).

**Noteworthy offer to evaluate:** DEV floated delivering **linux-runnable binaries instead
of full images**, letting the customer rebuild on its own patched base images. That would
dissolve the base-image CVE half of the COTS problem (§4a) at the cost of owning the
build. Recommendation: keep image delivery for 1.0.0, but put the binary option on the
contract agenda as the long-term CVE-patching model — it is rare for a COTS vendor to
offer this; don't let it lapse.

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

## Recommended settlement package (one meeting agenda — updated after the 2026-07-28 email)

Resolved by the email, close formally: probes on all modules + timings (G-4/G-5),
read-only rootfs attestation (G-6), migration mechanics (G-7 core), tagging scheme (G-14),
informal chart review (G-13).

1. **DEV image fixes (cheap, high value):** numeric `USER 1000` + group-0 perms (G-1 — as of
   b3 the images dropped `USER` entirely instead, the opposite of this ask; still open),
   ~~`EXPOSE 8080` restore~~ **done as of b3** (G-2, closed), additional OCI labels + fix
   empty `created` (still open, G-2/G-14 residual), clean release builds (G-14).
2. **DEV written statements (no code):** fold the email's attestations into the manual
   (timings G-5, read-only/TDD-in-DB sentence G-6); migrate `<db>` spelling + rollback
   compatibility contract once migrations exist (G-7); SIGTERM behavior (G-9); max AS4
   message size (G-17); JVM sizing (G-10); errata batch incl. `listen_address` vs
   `listen_host` (G-11).
3. **DEV product backlog (committed/queued):** `/metrics` before 1.0.0 — send DEV the
   desired metric list now, queue depths included (G-12); SBOM in SPDX/CycloneDX (G-14/§4a);
   non-interactive `create-admin-user` (G-8); mTLS roadmap statement (G-15).
4. **Customer-side decisions:** SEC verdict on plaintext internal hops (G-15);
   OPS+DBA interim SQL-exporter monitoring until metrics land (G-12);
   NET router/WAF limits (G-17); position on the **binaries-instead-of-images** offer (G-14).
5. **Formal act:** DEV signs off chart 0.2.1 as the supported deployment (G-13, fit-gap P1-2).
