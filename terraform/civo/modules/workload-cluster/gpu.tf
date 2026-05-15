locals {
  gpu_node_sizes              = [for i in data.civo_size.gpu.sizes : i.name]
  gpu_prefixes                = ["g4g.", "an."] # Civo GPU sizes start with these prefixes - ensure to end with "." to avoid false positives
  deploy_gpu_operator         = contains(local.gpu_node_sizes, var.node_type)

  # Single-H100 node pools need NVLink disabled at driver load, since there is
  # no peer GPU for NVLink to attach to. On multi-H100 or non-H100 nodes this
  # workaround must not be applied — it reduces peer-to-peer bandwidth.
  gpu_is_single_h100 = lower(var.node_type) == "an.g1.h100.kube.x1"

}

# Get all the GPU node types
data "civo_size" "gpu" {
  filter {
    key      = "name"
    values   = local.gpu_prefixes
    match_by = "re"
  }
  filter {
    key    = "type"
    values = ["kubernetes"]
  }
}

resource "kubernetes_namespace" "gpu_operator" {
  count = local.deploy_gpu_operator ? 1 : 0

  metadata {
    name = "gpu-operator"
  }

  depends_on = [civo_kubernetes_cluster.kubefirst]
}

resource "kubernetes_config_map" "nvidia_kernel_config" {
  count = local.deploy_gpu_operator && local.gpu_is_single_h100 ? 1 : 0

  metadata {
    name      = "nvidia-kernel-config"
    namespace = kubernetes_namespace.gpu_operator[0].metadata[0].name
  }

  data = {
    "nvidia.conf" = "options nvidia NVreg_NvLinkDisable=1"
  }
}

resource "helm_release" "gpu_operator" {
  count      = local.deploy_gpu_operator ? 1 : 0
  name       = "gpu-operator"
  repository = "https://helm.ngc.nvidia.com/nvidia"
  chart      = "gpu-operator"
  version    = "v25.10.1"
  namespace  = kubernetes_namespace.gpu_operator[0].metadata[0].name
  timeout    = 900
  wait       = true

  values = [yamlencode({
    driver = merge(
      { enabled = true },
      local.gpu_is_single_h100 ? {
        kernelModuleConfig = { name = "nvidia-kernel-config" }
      } : {}
    )
    toolkit        = { enabled = false }
    devicePlugin   = { enabled = true }
    gfd            = { enabled = true }
    operator       = { defaultRuntime = "containerd" }
    validator      = { cuda = { runtimeClassName = "nvidia" } }
  })]

  depends_on = [
    kubernetes_config_map.nvidia_kernel_config,
    kubernetes_namespace.gpu_operator,
  ]
}
