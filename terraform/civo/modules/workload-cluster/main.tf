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
  cluster_type        = "k3s"
  kubernetes_version  = "1.35.0-k3s1"
  # cni is create-time (ForceNew): null leaves the provider default and keeps
  # clusters created before this variable existed free of a replacement diff.
  cni                 = var.cni == "" ? null : var.cni
  pools {
    label      = var.cluster_name
    size       = var.node_type
    node_count = var.node_count
  }
}
