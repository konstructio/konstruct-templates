# S3 Bucket

resource "civo_object_store" "backup" {
    name = "k1-project-${var.cluster_name}"
    max_size_gb = 500
    region = var.cluster_region
}

# If you create the bucket without credentials, you can read the credentials in this way
data "civo_object_store_credential" "backup" {
    id = civo_object_store.backup.access_key_id
}

# Project Cluster

resource "civo_network" "project-cluster" {
  label = var.cluster_name
}

resource "civo_firewall" "project-cluster" {
  name                 = var.cluster_name
  network_id           = civo_network.project-cluster.id
  create_default_rules = true
}

resource "civo_kubernetes_cluster" "project-cluster" {
  name                = var.cluster_name
  network_id          = civo_network.project-cluster.id
  firewall_id         = civo_firewall.project-cluster.id
  write_kubeconfig    = true
  cluster_type        = "k3s" 
  kubernetes_version  = "1.32.5-k3s1"
  pools {
    label      = var.cluster_name
    size       = var.node_type
    node_count = var.node_count
  }
}

resource "vault_generic_secret" "clusters" {
  path = "secret/clusters/${var.cluster_name}"

  data_json = jsonencode(
    {
      kubeconfig              = civo_kubernetes_cluster.project-cluster.kubeconfig
      client_certificate      = base64decode(yamldecode(civo_kubernetes_cluster.project-cluster.kubeconfig).users[0].user.client-certificate-data)
      client_key              = base64decode(yamldecode(civo_kubernetes_cluster.project-cluster.kubeconfig).users[0].user.client-key-data)
      cluster_ca_certificate  = base64decode(yamldecode(civo_kubernetes_cluster.project-cluster.kubeconfig).clusters[0].cluster.certificate-authority-data)
      host                    = civo_kubernetes_cluster.project-cluster.api_endpoint
      cluster_name            = var.cluster_name
      argocd_manager_sa_token = kubernetes_secret_v1.argocd_manager.data.token
    }
  )
}

provider "kubernetes" {
  host                   = civo_kubernetes_cluster.project-cluster.api_endpoint
  client_certificate     = base64decode(yamldecode(civo_kubernetes_cluster.project-cluster.kubeconfig).users[0].user.client-certificate-data)
  client_key             = base64decode(yamldecode(civo_kubernetes_cluster.project-cluster.kubeconfig).users[0].user.client-key-data)
  cluster_ca_certificate = base64decode(yamldecode(civo_kubernetes_cluster.project-cluster.kubeconfig).clusters[0].cluster.certificate-authority-data)
}

provider "helm" {
  repository_config_path = "${path.module}/.helm/repositories.yaml"
  repository_cache       = "${path.module}/.helm"
  kubernetes = {
    host                   = civo_kubernetes_cluster.project-cluster.api_endpoint
    client_certificate     = base64decode(yamldecode(civo_kubernetes_cluster.project-cluster.kubeconfig).users[0].user.client-certificate-data)
    client_key             = base64decode(yamldecode(civo_kubernetes_cluster.project-cluster.kubeconfig).users[0].user.client-key-data)
    cluster_ca_certificate = base64decode(yamldecode(civo_kubernetes_cluster.project-cluster.kubeconfig).clusters[0].cluster.certificate-authority-data)
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

data "vault_generic_secret" "external_dns" {
  path = "secret/external-dns"
}

resource "kubernetes_secret_v1" "external_dns" {
  metadata {
    name      = "external-dns-secrets"
    namespace = kubernetes_namespace_v1.external_dns.metadata.0.name
  }
  data = {
    token = data.vault_generic_secret.external_dns.data["token"]
  }
  type = "Opaque"
}

# ──────────────────────────────────────────────
# 1. Crossplane Secrets (extract all keys from /crossplane)
# ──────────────────────────────────────────────

resource "kubernetes_namespace_v1" "crossplane_system" {
  metadata {
    name = "crossplane-system"
  }
}

data "vault_generic_secret" "crossplane" {
  path = "secret/crossplane"  # maps to key: /crossplane
}

resource "kubernetes_secret_v1" "crossplane_secrets" {
  metadata {
    name      = "crossplane-secrets"
    namespace = kubernetes_namespace_v1.crossplane_system.metadata.0.name
  }

  # Extract all key-value pairs from Vault into the secret
  data = data.vault_generic_secret.crossplane.data

  type = "Opaque"
}

# ──────────────────────────────────────────────
# 2. Git Credentials (templated creds file)
# ──────────────────────────────────────────────

data "vault_generic_secret" "git_credentials" {
  path = "secret/argocd/repo-credentials-template/${var.project_name}"
}

resource "kubernetes_secret_v1" "git_credentials" {
  metadata {
    name      = "git-credentials"
    namespace = kubernetes_namespace_v1.crossplane_system.metadata.0.name
  }

  data = {
    creds = "https://${data.vault_generic_secret.git_credentials.data["username"]}:${data.vault_generic_secret.git_credentials.data["password"]}@github.com"
  }

  type = "Opaque"
}

