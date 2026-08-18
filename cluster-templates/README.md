# Cluster templates

Templates that provision a Kubernetes cluster. Konstruct hydrates one of these
into a customer's gitops repo whenever a cluster is created, and the resulting
manifests are what that cluster's ArgoCD syncs.

## Layout

```
cluster-templates/
├── aws/                        # v2 Helm charts, AWS
│   ├── kontract-cluster/
│   ├── project-cluster/
│   ├── workload-cluster/
│   └── workload-vcluster/
├── civo/                       # v2 Helm charts, Civo
│   ├── kontract-cluster/
│   ├── project-cluster/
│   └── workload-cluster/
├── control-plane/              # v2 Helm chart — seed for the Konstruct control plane
├── google-workload-cluster/    # v1 token-based, GCP
├── mgmt/                       # management-cluster gitops scaffolding (not a chart)
└── shared/                     # token snippets the operators fetch at runtime
```

Provider-specific templates are grouped by cloud; the Terraform each one drives
lives in the sibling `terraform/<cloud>/modules/` tree, referenced by URL from
the chart's `values.yaml` (see `workloadClusterTerraformModuleUrl`).

## Cluster types

Every chart declares a top-level `clusterType` in its `values.yaml`. Konstruct
reads that key to decide how to treat the template:

| Template | `clusterType` | Meaning |
|---|---|---|
| `control-plane` | `control-plane` | Seed template for the Konstruct control plane itself. **No infrastructure layer** — the cluster already exists when this is hydrated during bootstrap, so the chart ships no Crossplane `Workspace`. Only the bootstrap flow consumes it. |
| `aws/project-cluster`, `civo/project-cluster` | `management` | A management cluster: runs the org's ArgoCD root and provisions workload clusters below it. |
| `aws/workload-cluster`, `civo/workload-cluster`, `*/kontract-cluster` | `physical` | A workload cluster with dedicated infrastructure. |
| `aws/workload-vcluster` | `virtual` | A virtual cluster (vcluster) running inside a host cluster. |

## Template engines

**v2 (Helm-based)** — the default for everything new. A Helm chart whose
`values.yaml` declares `clusterType` at the top level and exposes form inputs
via `@input.*` comment annotations directly above the key they describe:

```yaml
clusterType: physical

# @input.type: string
# @input.description: the complete URL for the Terraform module for infrastructure provisioning
# @input.required: true
workloadClusterTerraformModuleUrl: "git::https://github.com/konstructio/konstruct-templates.git//terraform/civo/modules/workload-cluster?ref=main"
```

Konstruct parses those annotations to build the cluster-creation form, then
renders the chart with the submitted values. There is no token replacement.

**v1 (token-based)** — legacy, `google-workload-cluster` only. A `kubefirst.yaml`
at the template root declares the cluster type and `<TOKEN_NAME>` inputs, which
Konstruct substitutes at hydration time. Do not add new v1 templates.

## Non-chart directories

**`mgmt/`** is not a template in its own right — it is the static gitops
scaffolding (`clusters.yaml`, `appprojects.yaml`, `registry.yaml`, and two
placeholder component directories) that `team-management-operator` copies into
`registry/clusters/<cluster-name>/` in the customer's gitops repo. It is
identical across clouds.

**`shared/`** holds token-based snippets that belong to no single template
because an operator fetches them over raw HTTP and detokenizes them itself. See
[`shared/README.md`](shared/README.md) — those files must stay token-based.

## Who consumes what

These paths are **hardcoded in other services**, which clone this repo at the
ref in `KONSTRUCT_VERSION` and join path segments onto it. Renaming a directory
here breaks them at runtime, not at build time.

| Path | Consumer |
|---|---|
| `control-plane/` | `team-management-operator` — `NewGitOpsBootstrapper` fallback path |
| `<cloud>/workload-cluster/`, `aws/workload-vcluster/` | `team-management-operator` — `workloadCopyPairs` |
| `<cloud>/project-cluster/` | `team-management-operator` — control-plane render; `konstruct-api` seeds `civo/project-cluster` as every org's default management template |
| `mgmt/` | `team-management-operator` — `mgmtFilesToCopy` |
| `shared/45-environment.yaml` | `workloadcluster-operator` — `getEnvironmentTemplate` |

## Adding a template

1. Copy the closest existing chart for your cloud and cluster shape.
2. Set `clusterType` in `values.yaml` to one of the values in the table above.
3. Annotate every value a user must supply with `@input.*`.
4. Keep sync-wave ordering intact (see the root README) so dependencies deploy
   in the right order.
5. Verify it renders before committing:

   ```bash
   helm lint cluster-templates/<cloud>/<template>
   helm template test cluster-templates/<cloud>/<template>
   ```

   Nothing outside `templates/` is rendered, so keep non-manifest files (notes,
   docs) out of that directory — anything in there ends up in the customer's
   gitops repo as a manifest.
