# S3 Bucket

resource "civo_object_store" "backup" {
    name = "k1-project-${var.cluster_name}"
    max_size_gb = 500
    region = var.cluster_region
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
  name               = var.cluster_name
  network_id         = civo_network.project-cluster.id
  firewall_id        = civo_firewall.project-cluster.id
  write_kubeconfig   = true
  cluster_type       = "k3s"
  kubernetes_version = "1.35.0-k3s1"
  pools {
    label      = var.cluster_name
    size       = var.node_type
    node_count = var.node_count
  }
}
