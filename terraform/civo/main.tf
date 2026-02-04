provider "civo" {
  region = "<CLOUD_REGION>"
}

locals {
  cluster_name         = "<CLUSTER_NAME>"
  kube_config_filename = "../../../kubeconfig"
}

resource "civo_network" "kubefirst" {
  label = local.cluster_name
}

resource "civo_firewall" "kubefirst" {
  name                 = local.cluster_name
  network_id           = civo_network.kubefirst.id
  create_default_rules = true
}

resource "civo_kubernetes_cluster" "kubefirst" {
  name                = local.cluster_name
  network_id          = civo_network.kubefirst.id
  firewall_id         = civo_firewall.kubefirst.id
  kubernetes_version  = "1.28.7-k3s1"
  write_kubeconfig    = true
  pools {
    label      = local.cluster_name
    size       = "<NODE_TYPE>"
    node_count = tonumber("<NODE_COUNT>") # tonumber() is used for a string token value
  }
}

resource "local_file" "kubeconfig" {
  content  = civo_kubernetes_cluster.kubefirst.kubeconfig
  filename = local.kube_config_filename
}
