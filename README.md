# ion-C5 on OpenShift — customer-side deployment artifacts

Customer-authored artifacts for deploying the ion-C5 Peppol Access Point (corner 5,
a COTS product by Ionite B.V.) on Red Hat OpenShift Container Platform.

Supplier binaries and documentation (container images, administrator's manual) are
**not** part of this repository — they are distributed by the supplier and imported
directly into the customer container registry.

| Artifact | Purpose |
|---|---|
| [FIT-GAP-ANALYSIS.md](FIT-GAP-ANALYSIS.md) | Supplier delivery vs. customer OCP requirements; prioritized gap register incl. COTS supply-chain exception (§4a) |
| [OCP-IMPLEMENTATION-PLAN.md](OCP-IMPLEMENTATION-PLAN.md) | Phased deployment order (TEST → INT → PREPROD → PROD) |
| [helm/ion-c5/](helm/ion-c5/) | Helm chart (Helm 3, restricted-v2 SCC, GitOps-ready); see its [README](helm/ion-c5/README.md) |
