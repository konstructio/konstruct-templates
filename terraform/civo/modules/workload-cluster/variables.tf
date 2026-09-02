variable "cluster_name" {
  type = string
}

variable "cluster_region" {
  type = string
}

variable "node_count" {
  type = number
}

variable "node_type" {
  type = string
}

variable "environment" {
  description = "Environment name for the workload cluster (passed by the Konstruct workload-cluster template; unused placeholder to accept the standard var set)"
  type        = string
  default     = ""
}

variable "cni" {
  description = "CNI for the cluster: cilium or flannel. Theme clusters require cilium so the per-app tenant-isolation NetworkPolicies are enforced. Empty leaves the provider default (also avoids a replacement diff on clusters created before this variable existed)."
  type        = string
  default     = ""
}
