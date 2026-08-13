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
