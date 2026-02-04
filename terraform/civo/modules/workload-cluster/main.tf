resource "civo_network" "kubefirst" {
  label = var.cluster_name
}

resource "civo_firewall" "kubefirst" {
  name                 = var.cluster_name
  network_id           = civo_network.kubefirst.id
  create_default_rules = true
}

resource "civo_kubernetes_cluster" "kubefirst" {
  name                = var.cluster_name
  network_id          = civo_network.kubefirst.id
  firewall_id         = civo_firewall.kubefirst.id
  write_kubeconfig    = true
  cluster_type        = local.is_gpu ? "talos" : "k3s" # k3s doesn't support GPU
  kubernetes_version  = local.is_gpu ?  "1.27.0" : "1.32.5-k3s1"
  pools {
    label      = var.cluster_name
    size       = var.node_type
    node_count = var.node_count
    labels = local.is_gpu ? {
      "nvidia.com/gpu.deploy.operator-validator" = "false"
    } : {}
  }
}

resource "aws_ssm_parameter" "clusters" {
  provider    = aws.PROJECT_REGION
  name        = "/clusters/${var.cluster_name}"
  description = "Cluster configuration for ${var.cluster_name}"
  type        = "String"
  tier = "Advanced"
  value = jsonencode({
      kubeconfig              = civo_kubernetes_cluster.kubefirst.kubeconfig
      client_certificate      = base64decode(yamldecode(civo_kubernetes_cluster.kubefirst.kubeconfig).users[0].user.client-certificate-data)
      client_key              = base64decode(yamldecode(civo_kubernetes_cluster.kubefirst.kubeconfig).users[0].user.client-key-data)
      cluster_ca_certificate  = base64decode(yamldecode(civo_kubernetes_cluster.kubefirst.kubeconfig).clusters[0].cluster.certificate-authority-data)
      host                    = civo_kubernetes_cluster.kubefirst.api_endpoint
      cluster_name            = var.cluster_name
      argocd_manager_sa_token = kubernetes_secret_v1.argocd_manager.data.token
  })
}

provider "kubernetes" {
  host                   = civo_kubernetes_cluster.kubefirst.api_endpoint
  client_certificate     = base64decode(yamldecode(civo_kubernetes_cluster.kubefirst.kubeconfig).users[0].user.client-certificate-data)
  client_key             = base64decode(yamldecode(civo_kubernetes_cluster.kubefirst.kubeconfig).users[0].user.client-key-data)
  cluster_ca_certificate = base64decode(yamldecode(civo_kubernetes_cluster.kubefirst.kubeconfig).clusters[0].cluster.certificate-authority-data)
}

provider "helm" {
  repository_config_path = "${path.module}/.helm/repositories.yaml"
  repository_cache       = "${path.module}/.helm"
  kubernetes = {
    host                   = civo_kubernetes_cluster.kubefirst.api_endpoint
    client_certificate     = base64decode(yamldecode(civo_kubernetes_cluster.kubefirst.kubeconfig).users[0].user.client-certificate-data)
    client_key             = base64decode(yamldecode(civo_kubernetes_cluster.kubefirst.kubeconfig).users[0].user.client-key-data)
    cluster_ca_certificate = base64decode(yamldecode(civo_kubernetes_cluster.kubefirst.kubeconfig).clusters[0].cluster.certificate-authority-data)
  }
}

resource "kubernetes_cluster_role_v1" "argocd_manager" {
  metadata {
    name = "argocd-manager-role"
  }

  rule {
    api_groups = ["*"]
    resources  = ["*"]
    verbs      = ["*"]
  }
  rule {
    non_resource_urls = ["*"]
    verbs             = ["*"]
  }
}


resource "kubernetes_cluster_role_binding_v1" "argocd_manager" {
  metadata {
    name = "argocd-manager-role-binding"
  }
  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = kubernetes_cluster_role_v1.argocd_manager.metadata.0.name
  }
  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account_v1.argocd_manager.metadata.0.name
    namespace = "kube-system"
  }
}

resource "kubernetes_service_account_v1" "argocd_manager" {
  metadata {
    name      = "argocd-manager"
    namespace = "kube-system"
  }
  secret {
    name = "argocd-manager-token"
  }
}

resource "kubernetes_secret_v1" "argocd_manager" {
  metadata {
    name      = "argocd-manager-token"
    namespace = "kube-system"
    annotations = {
      "kubernetes.io/service-account.name" = "argocd-manager"
    }
  }
  type       = "kubernetes.io/service-account-token"
  depends_on = [kubernetes_service_account_v1.argocd_manager]
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

resource "kubernetes_namespace_v1" "environment" {
  metadata {
    name = var.cluster_name
  }
}

