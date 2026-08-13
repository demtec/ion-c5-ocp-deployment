# ion-C5 on OpenShift — customer-side deployment artifacts

Customer-authored artifacts for deploying the ion-C5 Peppol Access Point (corner 5,
a COTS product by Ionite B.V.) on Red Hat OpenShift Container Platform.

Supplier binaries and documentation (container images, administrator's manual) are
**not** part of this repository — they are distributed by the supplier and imported
directly into the customer container registry.

| Artifact | Purpose |
|---|---|
| [RESPONSIBILITIES.md](RESPONSIBILITIES.md) | RACI split: developer vs. OpenShift team (+ OPS/NET/SEC/DBA/PA roles) for chart information and lifecycle |
| [FIT-GAP-ANALYSIS.md](FIT-GAP-ANALYSIS.md) | Supplier delivery vs. customer OCP requirements as of the 1.0.0b2 analysis (rev. 2, 2026-07-28); prioritized gap register incl. COTS supply-chain exception (§4a). Chart mechanics it describes (setup Job, migrate Job) predate chart 0.4.0 — see the chart's own README for current behavior |
| [HELM-CHART-GAP-ANALYSIS.md](HELM-CHART-GAP-ANALYSIS.md) | Chart-boundary specialties G-1…G-18 to settle between developer and OpenShift team (basis: 1.0.0b2/chart 0.2.1; later status changes noted inline per item) |
| [OCP-IMPLEMENTATION-PLAN.md](OCP-IMPLEMENTATION-PLAN.md) | Phased deployment order (TEST → INT → PREPROD → PROD) incl. upgrade rehearsal |
| [helm/ion-c5/](helm/ion-c5/) | Helm chart (currently **0.4.2** for delivery **1.0.0b4** — see its [README](helm/ion-c5/README.md) for the current version; Helm 3, restricted-v2 SCC, HTTP health probes, GitOps-ready) |
