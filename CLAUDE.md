# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository Overview

This repository contains Konstruct (formerly Kubefirst) templates for managing Kubernetes clusters and workloads across different cloud environments. It provides infrastructure-as-code templates using Terraform, Helm charts, and ArgoCD applications.

## Architecture

### Key Components

1. **Templates** - The main template configurations organized by type:
   - **charts/** - Helm chart templates for application deployments
   - **mgmt/** - Management cluster configurations (ArgoCD app projects, cluster definitions)
   - **workload-downstream-cluster/** - Templates for physical downstream workload clusters
   - **workload-downstream-host-vcluster/** - Templates for virtual clusters (vcluster)
   - **workload-project-cluster/** - Templates for project-specific clusters

2. **Terraform Modules** - AWS infrastructure provisioning:
   - Located in `terraform/aws/modules/`
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
helm lint templates/charts/
```

### Template Testing

```bash
# Test token replacement (example)
sed 's/<CLUSTER_NAME>/test-cluster/g' templates/mgmt/registry.yaml

# Dry-run ArgoCD application
kubectl apply --dry-run=client -f templates/mgmt/registry.yaml
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