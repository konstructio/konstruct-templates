variable "cluster_name" {
  description = "the name of the cluster"
  type        = string
}

variable "cluster_region" {
  description = "the region of the cluster"
  type        = string
}

variable "node_count" {
  description = "The node count for the node group"
  default     = "2"
  type        = string
}

variable "node_type" {
  description = "The node type of node group"
  default     = "t3.medium"
  type        = string
}

variable "ami_type" {
  description = "the ami type for node group"
  default = "AL2_x86_64"
  type = string
}

variable "project_aws_account_id" {
  description = "AWS account id of the parent project (management) cluster; its argocd role is granted admin access on this cluster"
  type        = string
}

variable "project_cluster_name" {
  description = "Name of the parent project (management) cluster whose ArgoCD deploys to this cluster"
  type        = string
}

variable "dex_provider_name" {
  description = "Name of the EKS OIDC identity provider config backed by the platform's Dex"
  default     = "dex"
  type        = string
}

variable "dex_issuer_url" {
  description = "Issuer URL of the platform's Dex used for cluster SSO (e.g. https://dex.example.com). Empty skips the OIDC identity provider config entirely."
  default     = ""
  type        = string
}

variable "enable_network_policy" {
  description = "Enforce Kubernetes NetworkPolicies via the VPC CNI network policy agent. Required on theme clusters for the per-app tenant-isolation policies."
  type        = bool
  default     = false
}

variable "konstruct_operator_role_arn" {
  description = "IAM role the konstruct operators run as on the control plane; when set (theme clusters) it is granted cluster-admin via an EKS access entry so the operators can reach this cluster directly. Empty adds no entry."
  default     = ""
  type        = string
}
