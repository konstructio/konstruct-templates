

locals {
  cluster_name = var.cluster_name
  subnet_name  = lookup(module.vpc.subnets, "${var.cluster_region}/subnet-01-${local.cluster_name}").name
}

data "google_client_config" "current" {}

resource "google_compute_router" "router" {
  name    = "gke-cloud-router-${local.cluster_name}"
  project = data.google_client_config.current.project
  network = local.cluster_name
  region  = var.cluster_region
}

module "cloud-nat" {
  name                               = "gke-nat-config-${local.cluster_name}"
  source                             = "terraform-google-modules/cloud-nat/google"
  version                            = "~> 5.0"
  project_id                         = data.google_client_config.current.project
  region                             = var.cluster_region
  router                             = google_compute_router.router.name
  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"
}

resource "google_service_account" "kubefirst" {
  account_id   = local.cluster_name
  display_name = "Service Account for ${local.cluster_name} cluster"
}

module "vpc" {
  source  = "terraform-google-modules/network/google"
  version = "~> 9.1"

  project_id   = data.google_client_config.current.project
  network_name = local.cluster_name

  subnets = [
    {
      subnet_name           = "subnet-01-${local.cluster_name}"
      subnet_ip             = "10.10.10.0/24"
      subnet_region         = var.cluster_region
      subnet_private_access = "true"
      subnet_flow_logs      = "true"
      description           = "This base subnet."
    },
  ]

  secondary_ranges = {
    "subnet-01-${local.cluster_name}" = [
      {
        range_name    = "subnet-01-${local.cluster_name}-gke-01-pods"
        ip_cidr_range = "10.13.0.0/16"
      },
      {
        range_name    = "subnet-01-${local.cluster_name}-gke-01-services"
        ip_cidr_range = "10.14.0.0/16"
      },
    ]
  }
}

module "gke" {
  source = "terraform-google-modules/kubernetes-engine/google//modules/private-cluster"
  version = "~> 31.0"
  
  project_id               = data.google_client_config.current.project
  name                     = local.cluster_name
  region                   = var.cluster_region
  release_channel          = "STABLE"
  remove_default_node_pool = true

  deletion_protection = false

  // External availability
  enable_private_endpoint = false
  enable_private_nodes    = true

  // Service Account
  create_service_account = true

  // Networking
  network           = module.vpc.network_name
  subnetwork        = local.subnet_name
  ip_range_pods     = "${local.subnet_name}-gke-01-pods"
  ip_range_services = "${local.subnet_name}-gke-01-services"

  // Addons
  dns_cache                  = true
  enable_shielded_nodes      = true
  filestore_csi_driver       = false
  gce_pd_csi_driver          = true
  horizontal_pod_autoscaling = false
  http_load_balancing        = false
  network_policy             = false

  // Node Pools
  node_pools = [
    {
      name      = "kubefirst"
      machine_type = var.node_type

      // Autoscaling
      // PER ZONE
      min_count = var.node_count
      // PER ZONE
      max_count = var.node_count
      // PER ZONE
      initial_node_count = var.node_count

      local_ssd_count = 0
      spot            = false
      disk_size_gb    = 100
      disk_type       = "pd-standard"
      image_type      = "COS_CONTAINERD"
      enable_gcfs     = false
      enable_gvnic    = false
      auto_repair     = true
      auto_upgrade    = true
      preemptible     = false
    },
  ]

  node_pools_oauth_scopes = {
    all = [
      "https://www.googleapis.com/auth/logging.write",
      "https://www.googleapis.com/auth/monitoring",
      "https://www.googleapis.com/auth/devstorage.read_only",
    ]
  }
}

resource "aws_ssm_parameter" "clusters" {
  provider    = aws.PROJECT_REGION
  name        = "/clusters/${local.cluster_name}"
  description = "Cluster configuration for ${local.cluster_name}"
  type        = "String"
  value = jsonencode(
    {
      cluster_ca_certificate = base64decode(module.gke.ca_certificate)
      host                   = "https://${module.gke.endpoint}"
      token                  = data.google_client_config.current.access_token
      cluster_name           = local.cluster_name
      argocd_manager_sa_token = kubernetes_secret_v1.argocd_manager.data.token
    }
  )
}


provider "kubernetes" {
  host                   = "https://${module.gke.endpoint}"
  token                  = data.google_client_config.current.access_token
  cluster_ca_certificate = base64decode(module.gke.ca_certificate)
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
    verbs = ["*"]
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
    name = "argocd-manager"
    namespace = "kube-system"
  }
  secret {
    name = "argocd-manager-token"
  }
}

resource "kubernetes_secret_v1" "argocd_manager" {
  metadata {
    name = "argocd-manager-token"
    namespace = "kube-system"
    annotations = {
      "kubernetes.io/service-account.name" = "argocd-manager"
    }
  }
  type = "kubernetes.io/service-account-token"
  depends_on = [ kubernetes_service_account_v1.argocd_manager ]
}
