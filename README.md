# Konstruct Custom Cluster Templates

This repository contains custom cluster templates for [Konstruct](https://konstruct.civonetes.com/docs), enabling you to provision different types of Kubernetes workload clusters with pre-configured platform tools and infrastructure patterns.

## Overview

These templates serve as the starting point foundation for each of three types of workload clusters in Konstruct:

1. **Workload Downstream Cluster** - Physical EKS clusters with dedicated infrastructure
2. **Workload Downstream Host vCluster** - Virtual clusters running inside host clusters for lightweight, multi-tenant environments
3. **Workload Project Cluster** - Full-featured clusters with ArgoCD and Crossplane for managing project-specific infrastructure

## Template Structure

Each template type includes:

- **`kubefirst.yaml`** - Defines the cluster type and configurable input variables
- **ArgoCD Applications** - GitOps configurations for deploying platform components
- **Terraform Modules** - Infrastructure provisioning code for AWS EKS clusters
- **Helm Chart Templates** - Standard application deployment templates

## Template Engines and Cluster Types

Templates come in two engine versions:

- **v1 (token-based)**: a `kubefirst.yaml` at the template root declares `clusterType` and input tokens (`<TOKEN_NAME>`), which Konstruct replaces at hydration time.
- **v2 (Helm-based)**: a Helm chart whose `values.yaml` declares a top-level `clusterType:` key and form inputs via `@input.*` comment annotations. Helm renders the manifests; no token replacement.

Valid `clusterType` values and what they mean to Konstruct:

| clusterType | Meaning |
|---|---|
| `control-plane` | Seed template for the Konstruct control plane itself. **No infrastructure layer** — the cluster already exists when the template is hydrated during bootstrap, so the chart contains no Crossplane `Workspace` manifests. Only consumed by the bootstrap flow. |
| `management` | A management (project) cluster: runs the org's ArgoCD root and provisions workload clusters. |
| `physical` | A physical workload cluster (dedicated infrastructure). |
| `virtual` | A virtual workload cluster (vcluster inside a host cluster). |

## GitOps Registry Layout

The platform gitops repo hydrated from these templates uses a two-tier registry convention:

- **`registry/clusters/<name>/`** — a cluster's **own desired state**: the app-of-apps content its ArgoCD root syncs. Every cluster that runs its own ArgoCD gets one; the control plane's tree is created here at bootstrap.
- **`registry/konstruct-clusters/<child>/`** — the **provisioning workspace** for a child cluster (Crossplane `Workspace` + day-2 wiring), executed by the *parent* cluster's ArgoCD. Each child is registered into its parent's tree via `registry/clusters/<parent>/components/konstruct-clusters/registry-<child>.yaml`.

A seed (`control-plane`) cluster has no entry under `registry/konstruct-clusters/` by definition — there is no infrastructure to provision.

## Using These Templates

### 1. Fork or Clone This Repository

```bash
git clone https://github.com/konstructio/konstruct-templates.git
cd konstruct-templates
```

### 2. Customize the Templates

#### Configure Input Variables

Edit the `kubefirst.yaml` file in your chosen template directory to define custom input variables:

```yaml
clusterType: "physical"  # Options: physical, virtual, gpu
inputs:
  - name: "node-count"
    token: "<WORKLOAD_NODE_COUNT>"
    prompt: "Enter the desired number of worker nodes"
    tip: "3"
  - name: "instance-type"
    token: "<WORKLOAD_INSTANCE_TYPE>"
    prompt: "Enter the EC2 instance type for worker nodes"
    tip: "m5.large"
```

#### Modify Infrastructure

Update the Terraform modules in `terraform/aws/modules/` to customize:
- VPC CIDR ranges
- EKS cluster settings
- Node group configurations
- AWS resource tags

#### Customize Platform Components

Modify the ArgoCD application manifests to:
- Add or remove platform tools
- Adjust sync wave ordering
- Configure tool-specific settings

### 3. Use in Konstruct

When creating a new workload cluster in Konstruct:

1. Select "Custom Template" option
2. Provide your template repository URL
3. Choose the template type (physical/virtual/project)
4. Fill in the prompted input variables
5. Konstruct will replace all tokens and provision your cluster

## Available Tokens

These built-in tokens are automatically replaced by Konstruct:

- `<CLUSTER_NAME>` - The name of your workload cluster
- `<GITOPS_REPO_URL>` - Your GitOps repository URL
- `<PROJECT_AWS_ACCOUNT_ID>` - AWS account ID for the project
- `<PROJECT_CLUSTER_NAME>` - Management cluster name
- `<REPO_NAME>` - Repository name for Helm charts

Plus any custom tokens you define in `kubefirst.yaml`.

## Platform Components

All templates include these core platform tools:

- **cert-manager** - Automated TLS certificate management
- **External Secrets Operator** - Synchronize secrets from external systems
- **External DNS** - Automated DNS record management
- **NGINX Ingress Controller** - Ingress traffic management
- **Reloader** - Automatic pod restarts on ConfigMap/Secret changes

Project clusters additionally include:
- **ArgoCD** - GitOps continuous delivery
- **Crossplane** - Infrastructure as Code management

## Sync Wave Order

Components deploy in this order:
1. **0-20**: Infrastructure and bootstrap components
2. **30**: Core platform services
3. **40**: Configuration resources (issuers, secret stores)
4. **45+**: Environment-specific configurations

## Customization Examples

### Add a New Platform Tool

1. Create an ArgoCD application manifest in your template
2. Set appropriate sync-wave annotation
3. Use tokens for configurable values

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: my-tool
  annotations:
    argocd.argoproj.io/sync-wave: '35'
spec:
  source:
    repoURL: <GITOPS_REPO_URL>
    path: platform/my-tool
    targetRevision: HEAD
```

### Modify Node Configuration

Edit `terraform/aws/modules/workload-*/main.tf`:

```hcl
eks_managed_node_groups = {
  default = {
    instance_types = ["<WORKLOAD_INSTANCE_TYPE>"]
    min_size       = 1
    max_size       = <WORKLOAD_NODE_COUNT>
    desired_size   = <WORKLOAD_NODE_COUNT>
  }
}
```

## Best Practices

1. **Test locally** - Validate YAML and Terraform syntax before using
2. **Document tokens** - Clearly describe each custom token's purpose
3. **Version control** - Tag stable versions of your templates
4. **Security** - Never commit secrets; use External Secrets Operator
5. **Idempotency** - Ensure templates can be applied multiple times safely

## Contributing

Feel free to submit issues and pull requests to improve these templates. Please ensure:
- YAML files pass `yamllint` validation
- Terraform modules pass `terraform validate`
- Token naming follows `<CONTEXT_VARIABLE_NAME>` pattern
- Documentation is updated for new features

## Support

For more information:
- [Konstruct Documentation](https://konstruct.civonetes.com/docs)
- [Custom Templates Guide](https://konstruct.civonetes.com/docs/features/clusters/custom-templates)
- [Konstruct Community](https://konstruct.civonetes.com/community)