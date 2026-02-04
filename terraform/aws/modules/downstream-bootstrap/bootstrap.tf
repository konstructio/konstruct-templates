data "aws_ssm_parameter" "cluster" {
  provider = aws.PROJECT_REGION
  name = "/clusters/${var.cluster_name}"
}

data "aws_eks_cluster" "cluster" {
  name = var.cluster_name
}

data "aws_eks_cluster_auth" "cluster" {
  name = var.cluster_name
}

locals {
  cluster_config = jsondecode(data.aws_ssm_parameter.cluster.value)
}

provider "kubernetes" {
  host                   = local.cluster_config.host
  cluster_ca_certificate = base64decode(local.cluster_config.cluster_ca_certificate)
  token                  = data.aws_eks_cluster_auth.cluster.token
}

resource "kubernetes_namespace_v1" "external_dns" {
  metadata {
    name = "external-dns"
  }
}

resource "kubernetes_namespace_v1" "external_secrets_operator" {
  metadata {
    name = "external-secrets-operator"
  }
}
