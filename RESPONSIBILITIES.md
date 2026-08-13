# Helm chart & deployment — split of responsibilities

**Purpose:** settle who is responsible for which information and which decisions in the
ion-C5 Helm chart and its deployment. ion-C5 is a **COTS product delivered as images only**;
the Helm chart is **customer-authored** (`helm/ion-c5/`). That combination is workable, but
only if the boundary below is agreed and enforced — otherwise every probe timeout and port
number becomes an argument.

**Date:** 2026-07-28 (RACI framework) · last reconciled 2026-08-13, applies to delivery 1.0.0b4.
The framework itself is evergreen; only the "which delivery" reference moves — see the chart's
own README (`helm/ion-c5/README.md`) for the currently-targeted version and chart mechanics
(the DB-init "Setup Job" row below predates chart 0.4.0, which removed it — see the footnote).

---

## 1. Roles

| Role | Abbrev. | Who | Scope in one sentence |
|---|---|---|---|
| **Developer / Supplier** | DEV | Ionite (COTS vendor) | The only authority on **what the application is and needs**: binaries, ports, endpoints, config semantics, resource baselines, upgrade rules. Never touches the cluster. |
| **OpenShift platform team** | OCP | Customer platform group | The only authority on **how anything runs on the cluster**: chart mechanics, SCC/security contexts, Routes, registry, namespaces, GitOps. Owns the chart files. |
| **Internal application operations** | OPS | Customer ops / service owner | Runs the application day-2: environment values content, admin users, queues/dead letters, alert response, capacity, upgrade execution windows. |
| **Network team** | NET | Customer network group | DNS, external LB/WAF, firewall/egress openings, IP whitelists ranges, proxy/source-IP facts (`receiver_proxy_ip_addresses`). |
| **Security team** | SEC | Customer security group | Image scanning & promotion gate, secret-management standard (ESO/Sealed Secrets/Vault), certificate lifecycle policy, exception approvals (COTS §4a), pen-test of admin/receiver exposure. |
| **Database administration** | DBA | Customer DBA group | Oracle instances, schemas/users/grants, connection strings, backups/retention, DB-side monitoring queries. |
| **Peppol / business authority** | PA | Customer e-invoicing owner | Peppol certificate procurement (SEATID), SMP registration, `peppol-test` vs `peppol` decision, legal retention of TDDs. |

RACI legend: **R** = does the work, **A** = accountable/final say, **C** = consulted, **I** = informed.

---

## 2. The core principle

> **DEV is accountable for every fact that comes from inside the container.
> OCP is accountable for every line of YAML that runs on the cluster.
> OPS/NET/SEC/DBA/PA are accountable for the environment-specific values they originate.**

Concretely: the chart is a translation layer. DEV supplies *inputs* (documented facts),
OCP *encodes* them (templates + `values.yaml` defaults), and the per-environment values
files are filled by the role that owns each datum. When a chart value is wrong, the first
question is therefore: *was the input wrong (DEV), the encoding wrong (OCP), or the
environment value wrong (owner role)?* That is the whole dispute-resolution procedure.

---

## 3. RACI — chart artifacts (templates, mechanics)

| Chart artifact | DEV | OCP | OPS | NET | SEC | DBA | PA |
|---|---|---|---|---|---|---|---|
| Chart structure, templates, helpers, releases of the chart itself | C | **A/R** | I | | I | | |
| `Chart.yaml` `appVersion` (which app version the chart targets) | C | **A/R** | I | | | | |
| Deployment spec: images, env wiring, mounts, checksums | C | **A/R** | I | | I | | |
| SecurityContext (runAsNonRoot, drop ALL, seccomp, readOnlyRootFilesystem) | **C**¹ | **A/R** | | | C | | |
| Probe *implementation* (which probe type, thresholds encoding) | **C**² | **A/R** | I | | | | |
| Probe *facts* (endpoint URL, port, expected codes, timing guidance) | **A/R** | C | | | | | |
| Services / ports mapping | **C**³ | **A/R** | | I | | | |
| Routes (TLS termination mode, redirect policy, timeouts) | I | **A/R** | C | **C** | C | | |
| NetworkPolicy templates | I | **A/R** | | **C** | **A**⁴ | | |
| HPA / PDB templates and defaults | **C**⁵ | **A/R** | C | | | | |
| DB init/migration command (`ion-c5-setup`) wiring — manual step since chart 0.4.0, no chart-managed hook Job⁶ | **C**⁶ | **A/R** | C | | | **C** | |
| Secret *object shape* (names, keys, format) — as encoded in chart/README | **C**⁷ | **A/R** | I | | **C** | | |
| ConfigMap rendering of `config.ini` | **C**⁸ | **A/R** | C | | | | |

¹ DEV must attest the images run non-root/random-UID and list writable paths (readOnlyRootFilesystem depends on it).
² DEV documents endpoints + recommended timings; OCP decides final probe numbers on the platform.
³ DEV documents what each module listens on and what `ION_*_LISTEN_PORT` accepts.
⁴ SEC is accountable that a default-deny policy exists in PROD; NET consulted on egress specifics; OCP implements.
⁵ DEV documents scaling rules (which modules may run >1 replica, worker semantics, scaling signal).
⁶ DEV documents idempotency/migration semantics of `initialize-databases`. Chart ≤0.2.x ran this
as a pre-install hook Job; chart 0.4.0 removed it entirely (no `setup.*` values, no `-env`
ConfigMap) — it is now a manual `oc run`/CLI step performed outside the chart, per the current
chart README.
⁷ DEV documents which env vars are secret-worthy and their exact names; the Secret **objects** themselves are created by OPS/SEC pipelines, never by the chart.
⁸ DEV owns the config reference (every key: type, default, restart-required); OCP owns which keys are exposed as chart values.

---

## 4. RACI — values (who owns each `values*.yaml` datum)

### 4.1 Application-shape values (in `values.yaml`, change only with a new app release)

| Value(s) | Origin of truth | A | R (edits chart) |
|---|---|---|---|
| `components.<m>.image.repository/tag` (which images make up release X) | DEV release manifest | DEV | OCP |
| `image.digest` pins (PREPROD/PROD) | DEV release manifest (digests) + SEC scan gate | SEC | OCP |
| `listenPortEnv` / `configFileEnv` / `useAppSecret` / `peppolCert` wiring keys | DEV manual | DEV | OCP |
| `containerPort` (8080 convention) | OCP platform standard, DEV must support via env | OCP | OCP |
| Probe endpoints/paths per module | DEV manual | DEV | OCP |
| Default resource requests/limits per module | DEV sizing guidance (until then: OCP measured estimates) | DEV⁹ | OCP |
| `config.*` keys exposed & their defaults | DEV config reference | DEV (semantics) / OCP (selection) | OCP |
| `terminationGracePeriodSeconds` | DEV graceful-shutdown docs | DEV | OCP |
| `setup.runOnUpgrade` | DEV migration/idempotency statement | DEV | OCP |
| `securityContext.readOnlyRootFilesystem` | DEV writable-paths statement | DEV | OCP |

⁹ Until DEV publishes sizing guidance, OCP's measured values stand and DEV cannot reject a
performance ticket on grounds of "wrong resources". This must be stated in the contract annex.

### 4.2 Environment values (in `values-<env>.yaml`, change per environment)

| Value(s) | A (owns the datum) | Provides it to | Notes |
|---|---|---|---|
| `global.imageRegistry`, pull secrets | OCP | — | registry is platform infrastructure |
| DB hosts/service names/users (`config.*_db_*`) | **DBA** | OPS → values PR | 3-way split in PROD |
| DB passwords (Secret `ion-c5-app`) | **DBA** creates, **SEC** stores | secret pipeline (ESO/Sealed) | never in values files |
| `config.peppol_identifier`, `discover_network` | **PA** | OPS | `peppol` only in PROD |
| Peppol cert + key (Secret `ion-c5-peppol`) | **PA** procures, **SEC** stores | secret pipeline | test cert below PROD |
| `components.receiver.route.host` (public AS4 FQDN) | **NET** | OPS | must match SMP publication (PA) |
| `components.admin.route.host` + `ip_whitelist` ranges | **NET** (ranges) + **SEC** (policy that it exists) | OPS | whitelist is mandatory, not optional |
| `config.receiver_proxy_ip_addresses` | **NET** | OPS | router/LB source IPs as seen by pods |
| `replicas`, HPA min/max, worker counts, batch sizes | **OPS** | — | within DEV's documented scaling rules |
| Environment resource overrides | **OPS** (with OCP capacity review) | — | |
| `networkPolicy.enabled`, egress rules | **SEC** (that they exist) / **NET** (contents) | OCP implements | mandatory in PREPROD/PROD |

### 4.3 Process rules for values files

1. Environment values live in Git; changes go by PR. **OPS assembles** the PR, the owner
   role of each datum approves it (CODEOWNERS can encode this), **OCP merges/deploys**.
2. No secret material ever enters a values file or the chart — Secrets travel only through
   the SEC-approved secret pipeline.
3. A new DEV release = a new **release manifest** (images + digests + config changes +
   migration notes). OCP translates it into a chart/values change; OPS schedules it.
   DEV never edits chart or values directly.

---

## 5. RACI — lifecycle activities

| Activity | DEV | OCP | OPS | NET | SEC | DBA | PA |
|---|---|---|---|---|---|---|---|
| Deliver images + release manifest + SBOM + changelog | **A/R** | I | I | | C | | |
| Scan & promote images (quarantine → prod registry) | I | R | | | **A** | | |
| Provision DBs, schemas, grants | C | | | | | **A/R** | |
| Run `initialize-databases` (manual command, no chart-managed Job since chart 0.4.0) | C | **R** | A | | | C | |
| Create Secrets (pipeline) | | C | R | | **A** | C | C |
| Helm install/upgrade execution | C | **R** | **A** (window/approval) | | | | |
| First admin user + MFA enrollment | C | C | **A/R** | | I | | |
| DNS/LB/WAF/firewall changes | | C | | **A/R** | C | | |
| SMP registration / endpoint publication | C | | C | C | | | **A/R** |
| Day-2 monitoring & alert response | C¹⁰ | C (platform alerts) | **A/R** | | | C (DB alerts) | |
| Incident triage: app defect vs platform vs config | **R** (app) | **R** (platform) | **A** (runs triage) | C | C | C | |
| Upgrade rehearsal + rollback in TEST | C | **R** | **A** | | | C | |
| CVE handling in images | **A/R** (fix) | R (redeploy) | I | | **A** (tracking) | | |
| Chart changes after DEV doc updates | C (input) | **A/R** | I | | | | |

¹⁰ DEV supplies recommended alerts + thresholds + runbook actions (fit-gap P2-8); OPS operates them.

---

## 6. What DEV must never be asked to do — and vice versa

To prevent the recurring arguments:

**Not DEV's job:** writing OpenShift YAML, choosing SCCs, Route/TLS setup, NetworkPolicy
syntax, HPA thresholds on the customer cluster, secret storage technology, registry layout.
If DEV's documentation forces a specific cluster configuration (e.g. "must run as root",
"needs port 80"), that is a **product defect** against the requirements document, not an
OCP-team implementation problem.

**Not OCP's/OPS's job:** guessing application facts. Health endpoints, writable paths,
graceful-shutdown behavior, migration idempotency, scaling semantics, config-key meaning
— if it isn't documented, it is a **DEV documentation gap** (fit-gap register), and any
chart workaround (guessed migrate db-names with the migrate Job default-off, pinned
`discover_port`/`validator_port`, `runAsUser` knob for the named-user issue) is a
*temporary mitigation attributable to that gap*, not an accepted design. The chart marks
every such workaround with a fit-gap / G-item reference (see HELM-CHART-GAP-ANALYSIS.md).
Worked example of the boundary done right: the 2026-07-28 gap-response email — DEV supplied
facts (probe timings, writes-to-disk attestation, migration semantics) and explicitly
deferred YAML specifics to the platform team; those facts then flowed into chart 0.2.1.

**Chart ownership:** OCP owns and versions the chart; DEV **reviews and formally approves**
each chart release against its product knowledge (this approval is fit-gap P1-2). DEV's
approval covers application correctness (wiring, ports, env vars, probe facts), not
platform choices.

---

## 7. Escalation

1. Disagreement on a value/behavior → check §2: input fact (DEV) vs encoding (OCP) vs
   environment datum (owner role).
2. If the fact is undocumented → new entry in the fit-gap register (owner: DEV), workaround
   decision by OCP+OPS, SEC informed if security-relevant.
3. If DEV and OCP disagree on feasibility (e.g. probe timings, resource limits) → test it
   in TEST environment; measurements beat opinions; result becomes documented fact.
4. Contract-level items (SLA, exception §4a, OCP version support) → steering level with
   the fit-gap register as the agenda.
