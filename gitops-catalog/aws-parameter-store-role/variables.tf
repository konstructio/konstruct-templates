variable "role_name" {
  description = "Name of the IAM role to create, e.g. my-app-my-namespace-parameter-store"
  type        = string
}

variable "cluster_name" {
  description = "Name of the EKS workload cluster the application runs on; its OIDC provider is trusted"
  type        = string
}

variable "namespace" {
  description = "Kubernetes namespace of the ServiceAccount allowed to assume the role"
  type        = string
}

variable "service_account_name" {
  description = "Kubernetes ServiceAccount allowed to assume the role; for konstruct-app it is <name>-eso"
  type        = string
}

variable "parameter_path" {
  description = "SSM parameter path prefix the role may read, e.g. /apps/my-app"
  type        = string

  validation {
    condition     = startswith(var.parameter_path, "/") && length(trimsuffix(var.parameter_path, "/")) > 1
    error_message = "parameter_path must start with / and name a path below the root, e.g. /apps/my-app."
  }
}

variable "kms_key_arn" {
  description = "ARN of the customer-managed KMS key encrypting the SecureString parameters; leave empty for the default aws/ssm key"
  type        = string
  default     = ""
}
