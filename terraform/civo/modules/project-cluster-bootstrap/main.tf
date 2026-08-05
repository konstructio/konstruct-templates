data "civo_object_store_credential" "backup" {
  name   = "k1-project-${var.cluster_name}"
  region = var.cluster_region
}

data "civo_kubernetes_cluster" "project" {
  name   = var.cluster_name
  region = var.cluster_region
}

locals {
  kc = yamldecode(data.civo_kubernetes_cluster.project.kubeconfig)
}

provider "kubernetes" {
  host                   = local.kc.clusters[0].cluster.server
  client_certificate     = base64decode(local.kc.users[0].user.client-certificate-data)
  client_key             = base64decode(local.kc.users[0].user.client-key-data)
  cluster_ca_certificate = base64decode(local.kc.clusters[0].cluster.certificate-authority-data)
}

provider "helm" {
  repository_config_path = "${path.module}/.helm/repositories.yaml"
  repository_cache       = "${path.module}/.helm"
  kubernetes = {
    host                   = local.kc.clusters[0].cluster.server
    client_certificate     = base64decode(local.kc.users[0].user.client-certificate-data)
    client_key             = base64decode(local.kc.users[0].user.client-key-data)
    cluster_ca_certificate = base64decode(local.kc.clusters[0].cluster.certificate-authority-data)
  }
}

# ── Vault: hand-off point for downstream consumers (ArgoCD registration etc.)

resource "vault_generic_secret" "clusters" {
  path = "secret/clusters/${var.cluster_name}"

  data_json = jsonencode(
    {
      kubeconfig              = data.civo_kubernetes_cluster.project.kubeconfig
      client_certificate      = base64decode(local.kc.users[0].user.client-certificate-data)
      client_key              = base64decode(local.kc.users[0].user.client-key-data)
      cluster_ca_certificate  = base64decode(local.kc.clusters[0].cluster.certificate-authority-data)
      host                    = data.civo_kubernetes_cluster.project.api_endpoint
      cluster_name            = var.cluster_name
      argocd_manager_sa_token = kubernetes_secret_v1.argocd_manager.data.token
    }
  )
}

# ── ArgoCD manager SA on the project cluster

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

# ──────────────────────────────────────────────
# Crossplane Secrets
# ──────────────────────────────────────────────

resource "kubernetes_namespace_v1" "crossplane_system" {
  metadata {
    name = "crossplane-system"
  }
}

resource "kubernetes_secret_v1" "crossplane_secrets" {
  metadata {
    name      = "crossplane-secrets"
    namespace = kubernetes_namespace_v1.crossplane_system.metadata.0.name
  }

  data = {
    AWS_ACCESS_KEY_ID     = data.civo_object_store_credential.backup.access_key_id
    AWS_SECRET_ACCESS_KEY = data.civo_object_store_credential.backup.secret_access_key
  }

  type = "Opaque"
}

resource "random_password" "cluster_token" {
  length  = 32
  special = false
}

provider "kubernetes" {
  alias = "incluster"
}

resource "kubernetes_secret_v1" "preshared_token_mgmt" {
  provider = kubernetes.incluster
  metadata {
    name      = "pre-shared-token"
    namespace = var.project_name
  }
  data = {
    token = random_password.cluster_token.result
  }
}

resource "kubernetes_namespace_v1" "argocd" {
  metadata {
    name = "argocd"
  }
}

resource "kubernetes_secret_v1" "preshared_token_argocd" {
  metadata {
    name      = "platform-cluster-identity"
    namespace = kubernetes_namespace_v1.argocd.metadata.0.name
  }
  data = {
    token  = random_password.cluster_token.result
    org_id = var.project_name
  }
}

resource "kubernetes_secret_v1" "preshared_token_crossplane" {
  metadata {
    name      = "platform-cluster-identity"
    namespace = kubernetes_namespace_v1.crossplane_system.metadata.0.name
  }
  data = {
    token  = random_password.cluster_token.result
    org_id = var.project_name
  }
}
