# IAM role for one application to read its own SSM parameters through a
# namespaced External Secrets SecretStore (see konstruct-app).
#
# Created in the workload cluster's account: that is where the cluster's OIDC
# provider lives, and where the parameters are read from.

data "aws_region" "current" {}

data "aws_caller_identity" "current" {}

data "aws_eks_cluster" "this" {
  name = var.cluster_name
}

data "aws_iam_openid_connect_provider" "this" {
  url = data.aws_eks_cluster.this.identity[0].oidc[0].issuer
}

locals {
  oidc_issuer    = trimprefix(data.aws_eks_cluster.this.identity[0].oidc[0].issuer, "https://")
  parameter_path = trimsuffix(var.parameter_path, "/")
  parameter_arn  = "arn:aws:ssm:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:parameter${local.parameter_path}"
}

# Only the one ServiceAccount in the one namespace can assume the role.
data "aws_iam_policy_document" "trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [data.aws_iam_openid_connect_provider.this.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_issuer}:sub"
      values   = ["system:serviceaccount:${var.namespace}:${var.service_account_name}"]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_issuer}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

data "aws_iam_policy_document" "read_parameters" {
  # GetParametersByPath is authorised against the path itself; the others
  # against each parameter below it.
  statement {
    effect = "Allow"
    actions = [
      "ssm:GetParameter",
      "ssm:GetParameters",
      "ssm:GetParametersByPath",
    ]
    resources = [
      local.parameter_arn,
      "${local.parameter_arn}/*",
    ]
  }

  # The External Secrets find/path lookup lists parameters first.
  statement {
    effect    = "Allow"
    actions   = ["ssm:DescribeParameters"]
    resources = ["*"]
  }

  # The default aws/ssm key's own policy already lets SSM decrypt for callers
  # in the account; a customer-managed key needs the grant here (and in its key
  # policy).
  dynamic "statement" {
    for_each = var.kms_key_arn == "" ? [] : [var.kms_key_arn]
    content {
      effect    = "Allow"
      actions   = ["kms:Decrypt"]
      resources = [statement.value]
    }
  }
}

resource "aws_iam_role" "this" {
  name               = var.role_name
  assume_role_policy = data.aws_iam_policy_document.trust.json

  tags = {
    Name           = var.role_name
    Cluster        = var.cluster_name
    Namespace      = var.namespace
    ServiceAccount = var.service_account_name
    ManagedBy      = "Terraform"
  }
}

resource "aws_iam_role_policy" "read_parameters" {
  name   = "read-parameters"
  role   = aws_iam_role.this.id
  policy = data.aws_iam_policy_document.read_parameters.json
}
