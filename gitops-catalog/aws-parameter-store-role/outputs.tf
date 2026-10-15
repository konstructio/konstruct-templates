output "role_arn" {
  description = "ARN of the IAM role; use it as roleArn in konstruct-app"
  value       = aws_iam_role.this.arn
}

output "role_name" {
  description = "Name of the IAM role"
  value       = aws_iam_role.this.name
}

output "parameter_path" {
  description = "SSM parameter path the role can read"
  value       = local.parameter_path
}
