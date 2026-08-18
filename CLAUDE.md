# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository Overview

This repository contains Konstruct (formerly Kubefirst) templates for managing Kubernetes clusters and workloads across different cloud environments. It provides infrastructure-as-code templates using Terraform, Helm charts, and ArgoCD applications.

## Architecture

### Key Components

The repository root holds one directory per template kind:

1. **`cluster-templates/`** - Templates that provision a cluster, grouped by cloud:
   - **`aws/`** - `kontract-cluster`, `project-cluster`, `workload-cluster`, `workload-vcluster` (v2 Helm charts)
   - **`civo/`** - `kontract-cluster`, `project-cluster`, `workload-cluster` (v2 Helm charts)
   - **`control-plane/`** - Seed template for the Konstruct control plane itself (v2 Helm chart)
   - **`google-workload-cluster/`** - GCP workload cluster (v1 token-based)
   - **`mgmt/`** - Management cluster gitops scaffolding (ArgoCD app projects, cluster registry)
   - **`shared/`** - Token-based snippets fetched at runtime by the operators rather than
     hydrated as part of a template tree (currently `45-environment.yaml`)

2. **`helm-templates/`** - Helm chart templates for application deployments:
   - **`charts/`** - The generic web-service chart every registered app is deployed with
     (its `Chart.yaml` name is the `<REPO_NAME>` token, replaced at registration time)

3. **`pipeline-templates/`** - CI/CD pipeline templates:
   - **`workflows/`** - Default GitHub Actions / GitLab CI workflows for app registration
   - **`promotion/`** - Environment promotion and release workflows

4. **`gitops-catalog/`** - Installable platform applications (one directory per app)

5. **`terraform/`** - Infrastructure provisioning modules, grouped by cloud
   (`terraform/aws/modules/`, `terraform/civo/modules/`, `terraform/gcp/modules/`):
   - Includes bootstrap configurations and cluster-specific modules
   - EKS cluster version: 1.32

### Token Replacement System

The templates use placeholder tokens that get replaced during provisioning:
- `<CLUSTER_NAME>` - Target cluster name
- `<GITOPS_REPO_URL>` - GitOps repository URL
- `<PROJECT_AWS_ACCOUNT_ID>` - AWS account ID
- `<PROJECT_CLUSTER_NAME>` - Project cluster name
- `<REPO_NAME>` - Repository name for Helm charts

### ArgoCD Application Structure

Applications follow a wave-based deployment pattern using `argocd.argoproj.io/sync-wave` annotations:
- Infrastructure components (0-20)
- Platform services (30-40)
- Environment configurations (45+)

### Cluster Types

- **Physical Clusters**: Full EKS clusters with dedicated infrastructure
- **Virtual Clusters (vcluster)**: Lightweight clusters running inside host clusters
- **Project Clusters**: Clusters with full platform capabilities including ArgoCD, Crossplane

## Development Commands

Since this is a template repository without traditional build tools, development focuses on:

### Validation Commands

```bash
# Validate YAML syntax
find . -name "*.yaml" -o -name "*.yml" | xargs yamllint

# Validate Terraform modules
cd terraform/aws/modules/<module-name>
terraform init
terraform validate

# Check Helm chart syntax
helm lint helm-templates/charts/
```

### Template Testing

```bash
# Test token replacement (example)
sed 's/<CLUSTER_NAME>/test-cluster/g' cluster-templates/mgmt/registry.yaml

# Dry-run ArgoCD application
kubectl apply --dry-run=client -f cluster-templates/mgmt/registry.yaml
```

## Important Patterns

### ArgoCD Applications
- All ArgoCD applications use automated sync with prune and self-heal enabled
- Applications target the `registry/clusters/<CLUSTER_NAME>` path in the GitOps repo
- Sync waves ensure proper deployment ordering

### Crossplane Integration
- Project clusters include Crossplane for infrastructure management
- Uses Terraform provider for Crossplane with controller configurations
- Secrets managed via External Secrets Operator

### Security Components
- cert-manager for TLS certificate management
- External Secrets Operator for secret synchronization
- Cluster secret stores configured for each workload type

## Working with Templates

When modifying templates:
1. Maintain consistent token naming conventions
2. Respect sync wave ordering for dependencies
3. Ensure all placeholders are documented in kubefirst.yaml files
4. Test YAML validity before committing changes