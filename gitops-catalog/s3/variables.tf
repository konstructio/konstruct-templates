variable "name" {
  description = "Bucket name"
  type        = string
}

variable "bucket_region" {
 type        = string
}

variable "attributes" {
  description = "List of attribute definitions for keys. Each entry needs name (string) and type (S, N, or B)."
  type = list(object({
    name = string
    type = string
  }))
}
