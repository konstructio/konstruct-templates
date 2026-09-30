# Horizontal Scaling for provider-terraform — Rollout Runbook

A single provider-terraform controller runs every `terraform init/plan/apply`
in the cluster, so throughput stops scaling past a few hundred Workspaces.
Sharding runs **N controller Deployments side by side**, each reconciling only
the Workspaces labelled `terraform.crossplane.io/shard: shard-N`. A **shard
assigner** writes that label, spreading Workspaces least-loaded, and migrates
them safely when a shard is removed.

This runbook is self-contained: every file you need is reproduced in full
below. Replace the placeholders, commit, and let Argo CD sync.

| Placeholder | Meaning | Example |
| --- | --- | --- |
| `<cluster-name>` | The management/project cluster's name, as used in its other gitops paths and IAM roles | `acme-mgmt` |
| `<aws-account-id>` | AWS account the cluster runs in | `111122223333` |
| `<domain>` | Base domain the cluster's gateway serves | `example.com` |
| `<github-app-vault-key>` | Vault path of the GitHub App credentials Crossplane already uses | `argocd/repo-credentials-template/acme-platform` |
| `<gitops-repo-url>` | Your gitops repository | `https://github.com/acme/gitops.git` |
| `<efs-file-system-id>` | Created in step 6 | `fs-0123456789abcdef0` |

## 1. Prerequisites

| Check | Why |
| --- | --- |
| The Crossplane Provider package is **`xpkg.upbound.io/upbound/provider-terraform:v1.2.0`** | The controller image expects the `tf.m.upbound.io` CRDs. On `v0.20.0` it exits with `no matches for kind "Workspace" in version "tf.m.upbound.io/v1beta1"`. The chart below sets this. |
| IAM role `crossplane-<cluster-name>` trusts `system:serviceaccount:crossplane-system:crossplane-provider-terraform-<cluster-name>` | Every shard runs under the Provider's ServiceAccount. A name mismatch fails `terraform init` with `403 Not authorized to perform sts:AssumeRoleWithWebIdentity`. |
| Terraform backends lock state (S3 + DynamoDB table or `use_lockfile = true`) — *recommended* | The assigner already refuses to move a Workspace off a shard whose pod is still running; backend locking covers the remaining edge cases. |
| Prometheus Operator CRDs are installed | The chart ships a `PrometheusRule` and two `ServiceMonitor`s. |

## 2. Replace `crossplane-components` with the sharded chart

Folder: `registry/konstruct-clusters/<cluster-name>/crossplane-components/`

**Delete the existing plain manifests** in that folder
(`terraform-provider.yaml`, `deployment-runtime-config.yaml`,
`crossplane-secrets.yaml`, `servicemonitor.yaml`, `svc.yaml`) and create the
files below in their place:

```
crossplane-components/
├── Chart.yaml
├── values.yaml
└── templates/
    ├── provider.yaml
    ├── shards.yaml
    ├── shard-assigner.yaml
    ├── externalsecrets.yaml
    ├── logs.yaml
    ├── storage.yaml
    ├── servicemonitor.yaml
    └── alerts.yaml
```

The chart keeps the **same object names** as the plain manifests
(`Provider/crossplane-provider-terraform`, `DeploymentRuntimeConfig/terraform-config`,
`ExternalSecret/crossplane-secrets`, `ExternalSecret/github-app-credentials`,
`HTTPRoute/log-streamer`, `ServiceMonitor/crossplane-provider-terraform`), so
Argo CD updates them in place instead of deleting and recreating them. The only
object pruned is the old `Service/log-streamer-service`.

> **Never let the `Provider` be pruned.** Deleting it deletes its
> ProviderRevision, whose CRDs are then garbage collected, and deleting a CRD
> deletes every Workspace in the cluster. `templates/provider.yaml` sets
> `argocd.argoproj.io/sync-options: Prune=false` on it; keep that, and keep the
> name `crossplane-provider-terraform`.

### `Chart.yaml`

```yaml
apiVersion: v2
name: <cluster-name>-crossplane-components
description: >-
  Sharded provider-terraform for <cluster-name>: the Crossplane Provider and its
  runtime config, N shard Deployments, and the shard assigner that places
  Workspaces across them.
type: application
version: 0.1.0
```

### `values.yaml`

Replace every placeholder. The fields you must change are listed in step 3.

```yaml
# ---------------------------------------------------------------------------
# The knob. Everything below it is plumbing.
# ---------------------------------------------------------------------------

# Number of shards. Raising it adds Deployments; new Workspaces land on the
# empty ones via least-loaded placement. Lowering it prunes Deployments, and
# the assigner migrates their Workspaces away once each pod has actually gone.
#
# There is deliberately no ConfigMap mirroring this: the rendered Deployments
# are what the assigner reads, so there is nothing to drift.
#
# Start at 1. That gives the new topology with a single controller - the same
# behaviour as today - so the assigner can be proven before any shard split.
shardCount: 5

# Shards to drain without removing them, by name. They render with
# replicas: 0, which the assigner treats the same as "removed". Use this to
# drain a shard in the middle of the range, which shardCount alone cannot do.
draining: []
# draining:
#   - shard-2

namespace: crossplane-system

image:
  # Images with sharding support. They carry --shard-name, the shard-aware garbage collector, and the process
  # group fix. The previous v0.0.1-rc.3 has none of them and would crash-loop
  # on the unknown flag.
  controller: ghcr.io/konstructio/provider-terraform:branch-46db7d0d
  assigner: ghcr.io/konstructio/provider-terraform-shard-assigner:branch-46db7d0d
  logStreamer: ghcr.io/konstructio/logs-streamer:v0.0.10

# The Crossplane package. Its Deployment stays at replicas: 0 - it exists to
# establish the CRDs, RBAC and ServiceAccount, not to run the controller,
# because Crossplane builds exactly one Deployment per ProviderRevision and
# replicas: N on it is active/passive HA rather than sharding.
package: xpkg.upbound.io/upbound/provider-terraform:v1.2.0

serviceAccount:
  name: crossplane-provider-terraform-<cluster-name>
  roleArn: arn:aws:iam::<aws-account-id>:role/crossplane-<cluster-name>

controller:
  pollInterval: 4m
  maxReconcileRate: 10
  fsGroup: 65532
  # Must exceed the p99 terraform apply. A terraform killed mid-apply leaves a
  # stale backend lock needing a manual force-unlock - and a shard torn down
  # mid-apply is precisely what a drain has to survive.
  terminationGracePeriodSeconds: 900
  gracefulShutdownTimeout: 10m

assigner:
  # Refuse to migrate a Workspace while its current shard still has a running
  # pod. Only turn this off once the Terraform backend is confirmed to lock
  # state (S3 + DynamoDB table or use_lockfile, GCS, azurerm).
  requireShardOffline: true
  # How many Workspaces migrate at once. Not about handover overlap - the old
  # pod is already gone - but about not hitting the receiving shards with a
  # whole shard's worth of terraform init at once.
  migrationBatch: 5
  staleMigration: 30m

secretStore: <cluster-name>-vault-kv-secret

logs:
  hostname: logs-<cluster-name>.<domain>
  gatewaySectionName: https-logs
  requestTimeout: 3600s
  # EFS filesystem for /logs (efs_file_system_id in vault
  # secret/clusters/<cluster>, from the workload-project-cluster module).
  # Set: every shard shares one ReadWriteMany volume, so any log-streamer can
  # stream any Workspace at /logs/<name>, and logs survive restarts and shard
  # migrations. Empty: per-pod emptyDir, reachable only via /shard-N/logs/<name>.
  efsFileSystemId: ""   # set in step 6

githubApp:
  # One entry per org. Labelled secrets are authoritative for the provider's
  # credential lookup; the ProviderConfig fallback applies only when none
  # exist at all.
  installations:
    - name: github-app-credentials   # legacy name, kept working
      labelled: false
      vaultKey: <github-app-vault-key>
    # - name: github-app-konstructio
    #   labelled: true
    #   vaultKey: argocd/repo-credentials-template/konstructio
```

### `templates/provider.yaml`

The Crossplane `Provider` and its `DeploymentRuntimeConfig`. They install the
CRDs, RBAC and IRSA ServiceAccount, but run at **`replicas: 0`**: Crossplane
builds one Deployment per revision and cannot produce a fleet.

```yaml
# The Crossplane package. It establishes the Workspace CRDs, the RBAC and the
# ServiceAccount; it does NOT run the controller - see replicas: 0 below and
# the shard Deployments that do the work.
apiVersion: pkg.crossplane.io/v1
kind: Provider
metadata:
  name: crossplane-provider-terraform
  annotations:
    argocd.argoproj.io/sync-wave: '20'
    # Never prune this object. Deleting a Provider deletes its
    # ProviderRevision, and Crossplane relies on garbage collection to remove
    # the CRDs the revision owns - see the comment on the deletion branch in
    # its revision reconciler. Deleting a CRD deletes every custom resource of
    # that kind, so pruning this would take every Workspace in the cluster
    # with it, and Terraform state with them.
    #
    # This conversion does not rename the object, so Argo updates it in place
    # rather than replacing it. The annotation is here so that a future
    # mistake - a broken render, a moved file, a renamed release - cannot
    # turn into data loss.
    argocd.argoproj.io/sync-options: Prune=false
spec:
  runtimeConfigRef:
    name: terraform-config
  ignoreCrossplaneConstraints: false
  package: {{ .Values.package }}
  packagePullPolicy: IfNotPresent
  revisionActivationPolicy: Automatic
  revisionHistoryLimit: 1
  skipDependencyResolution: false
---
# Crossplane builds one Deployment per ProviderRevision, so it cannot produce a
# fleet, and replicas: N on it would be active/passive HA rather than sharding.
# It stays at zero and the shards run beside it, reusing its ServiceAccount.
#
# spec.deploymentTemplate.spec embeds a full apps/v1 DeploymentSpec, so the CRD
# requires `selector` even though Crossplane overwrites it on the rendered
# Deployment with its own labels (DeploymentWithSelectors in its runtime
# builder). Omitting it fails admission with:
#
#   DeploymentRuntimeConfig "terraform-config" is invalid:
#   spec.deploymentTemplate.spec.selector: Required value
#
# The value is therefore structural, not functional - it just has to be there.
apiVersion: pkg.crossplane.io/v1beta1
kind: DeploymentRuntimeConfig
metadata:
  name: terraform-config
  annotations:
    argocd.argoproj.io/sync-wave: '10'
  labels:
    app: crossplane-provider-terraform
spec:
  serviceAccountTemplate:
    metadata:
      name: {{ .Values.serviceAccount.name }}
      annotations:
        eks.amazonaws.com/role-arn: {{ .Values.serviceAccount.roleArn }}
  deploymentTemplate:
    metadata:
      annotations:
        eks.amazonaws.com/role-arn: {{ .Values.serviceAccount.roleArn }}
    spec:
      replicas: 0
      # Deliberately no strategy override. Crossplane patches the existing
      # Deployment, and a patch cannot remove the rollingUpdate block the live
      # object already carries, so setting type: Recreate here fails admission
      # with "spec.strategy.rollingUpdate: Forbidden: may not be specified when
      # strategy `type` is 'Recreate'" - which blocks the whole patch,
      # including replicas: 0. At zero replicas the strategy is moot anyway.
      selector:
        matchLabels:
          pkg.crossplane.io/provider: terraform
      template:
        metadata:
          labels:
            pkg.crossplane.io/provider: terraform
        spec:
          containers:
            - name: package-runtime
              image: {{ .Values.image.controller }}
```

### `templates/shards.yaml`

One Deployment per shard, `provider-terraform-shard-0` … `shard-(N-1)`. Keep
the `terraform.crossplane.io/shard` label on **both** the Deployment and its
pod template: the assigner reads the first to learn which shards exist, and the
second to confirm a shard's pod is gone before migrating its Workspaces.

The pod `securityContext` must keep `runAsUser: 2000`. As root, git's `HOME` is
`/root`, it never reads the image's `/.gitconfig` (the credential helper for
the GitHub App token), and every private module clone fails with
`fatal: could not read Username for 'https://github.com'`.

```yaml
{{- $root := . -}}
{{- range $i := until (int .Values.shardCount) }}
{{- $shard := printf "shard-%d" $i }}
{{- $replicas := 1 }}
{{- if has $shard $root.Values.draining }}{{ $replicas = 0 }}{{ end }}
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: provider-terraform-{{ $shard }}
  namespace: {{ $root.Values.namespace }}
  annotations:
    argocd.argoproj.io/sync-wave: '30'
  labels:
    app: provider-terraform
    # REQUIRED on the Deployment. This is how the assigner discovers which
    # shards exist and reads spec.replicas as their desired state.
    terraform.crossplane.io/shard: {{ $shard }}
spec:
  replicas: {{ $replicas }}
  # No surge: two pods with the same --shard-name would both reconcile the
  # same Workspaces during a rollout.
  strategy:
    type: Recreate
  selector:
    matchLabels:
      app: provider-terraform
      terraform.crossplane.io/shard: {{ $shard }}
  template:
    metadata:
      labels:
        app: provider-terraform
        # REQUIRED on the pod template. This is how a migration confirms the
        # old shard's process is gone before relabelling its Workspaces.
        terraform.crossplane.io/shard: {{ $shard }}
      annotations:
        prometheus.io/scrape: "true"
        prometheus.io/port: "8080"
        prometheus.io/path: "/metrics"
    spec:
      serviceAccountName: {{ $root.Values.serviceAccount.name }}
      terminationGracePeriodSeconds: {{ $root.Values.controller.terminationGracePeriodSeconds }}
      # Crossplane runs provider pods as UID 2000; these Deployments are ours,
      # so set it here. As root, HOME=/root and git never reads /.gitconfig
      # (the credential helper), so private module clones prompt and fail.
      securityContext:
        runAsUser: 2000
        runAsGroup: 2000
        runAsNonRoot: true
        fsGroup: {{ $root.Values.controller.fsGroup }}
      containers:
        - name: package-runtime
          image: {{ $root.Values.image.controller }}
          args:
            - -d
            - --poll={{ $root.Values.controller.pollInterval }}
            - --max-reconcile-rate={{ $root.Values.controller.maxReconcileRate }}
            - --shard-name={{ $shard }}
            - --graceful-shutdown-timeout={{ $root.Values.controller.gracefulShutdownTimeout }}
            # Required. Without it, replicas > 1 on one shard means two
            # processes reconciling the same Workspaces rather than
            # active/passive; the lease ID carries the shard name.
            - --leader-election
          envFrom:
            - secretRef:
                name: crossplane-secrets
          ports:
            - containerPort: 8080
              name: metrics
              protocol: TCP
          volumeMounts:
            - mountPath: /.cache
              name: helmcache
            - mountPath: /logs
              name: shared-logs

        - name: log-streamer
          image: {{ $root.Values.image.logStreamer }}
          imagePullPolicy: Always
          ports:
            - containerPort: 9090
              name: http
              protocol: TCP
          env:
            - name: PORT
              value: "9090"
            - name: LOG_DIR
              value: "/logs"
          volumeMounts:
            - mountPath: /logs
              name: shared-logs
              readOnly: true

      volumes:
        - name: helmcache
          emptyDir:
            sizeLimit: 500Mi
        - name: shared-logs
          {{- if $root.Values.logs.efsFileSystemId }}
          persistentVolumeClaim:
            claimName: provider-terraform-logs
          {{- else }}
          emptyDir: {}
          {{- end }}
{{- end }}
```

### `templates/shard-assigner.yaml`

```yaml
# The shard assigner. Nothing else writes terraform.crossplane.io/shard, and a
# Workspace without it is reconciled by no shard at all.
apiVersion: v1
kind: ServiceAccount
metadata:
  name: provider-terraform-shard-assigner
  namespace: {{ .Values.namespace }}
  annotations:
    argocd.argoproj.io/sync-wave: '25'
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: provider-terraform-shard-assigner
  annotations:
    argocd.argoproj.io/sync-wave: '25'
rules:
  # Placement. Patches metadata.labels and metadata.annotations only - never
  # spec or status.
  - apiGroups: ["tf.upbound.io", "tf.m.upbound.io"]
    resources: ["workspaces"]
    verbs: ["get", "list", "watch", "patch"]
  # The shard Deployments ARE the desired state; spec.replicas is read to learn
  # which shards are placeable. Patch is for driving a drain it started itself.
  # It never creates or deletes them - existence stays in Git, so image
  # upgrades and `git revert` keep working the way they do today.
  - apiGroups: ["apps"]
    resources: ["deployments"]
    verbs: ["get", "list", "watch", "patch"]
  # Shard liveness. A Workspace is never moved off a shard whose pod is still
  # running: two terraform processes would write the same remote state.
  - apiGroups: [""]
    resources: ["pods"]
    verbs: ["get", "list"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: provider-terraform-shard-assigner
  annotations:
    argocd.argoproj.io/sync-wave: '25'
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: provider-terraform-shard-assigner
subjects:
  - kind: ServiceAccount
    name: provider-terraform-shard-assigner
    namespace: {{ .Values.namespace }}
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: provider-terraform-shard-assigner-leader-election
  namespace: {{ .Values.namespace }}
  annotations:
    argocd.argoproj.io/sync-wave: '25'
rules:
  - apiGroups: ["coordination.k8s.io"]
    resources: ["leases"]
    verbs: ["get", "list", "watch", "create", "update", "patch"]
  # Leader election records who acquired the lease as an Event. Without this
  # the assigner still works, but every acquisition logs a forbidden error.
  - apiGroups: [""]
    resources: ["events"]
    verbs: ["create", "patch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: provider-terraform-shard-assigner-leader-election
  namespace: {{ .Values.namespace }}
  annotations:
    argocd.argoproj.io/sync-wave: '25'
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: provider-terraform-shard-assigner-leader-election
subjects:
  - kind: ServiceAccount
    name: provider-terraform-shard-assigner
    namespace: {{ .Values.namespace }}
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: provider-terraform-shard-assigner
  namespace: {{ .Values.namespace }}
  annotations:
    argocd.argoproj.io/sync-wave: '25'
  labels:
    app: provider-terraform-shard-assigner
spec:
  # Leader election keeps exactly one writing; a second assigner would defeat
  # the single-writer premise placement rests on.
  replicas: 1
  selector:
    matchLabels:
      app: provider-terraform-shard-assigner
  template:
    metadata:
      labels:
        app: provider-terraform-shard-assigner
    spec:
      serviceAccountName: provider-terraform-shard-assigner
      securityContext:
        runAsNonRoot: true
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: shard-assigner
          image: {{ .Values.image.assigner }}
          args:
            - --namespace={{ .Values.namespace }}
            - --migration-batch={{ .Values.assigner.migrationBatch }}
            - --stale-migration={{ .Values.assigner.staleMigration }}
            # kingpin boolean: the bare flag or --no-<flag>. Passing
            # --require-shard-offline=true is rejected with "unexpected true".
            {{- if .Values.assigner.requireShardOffline }}
            - --require-shard-offline
            {{- else }}
            - --no-require-shard-offline
            {{- end }}
          ports:
            - name: metrics
              containerPort: 8080
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop: ["ALL"]
          resources:
            requests:
              cpu: 50m
              memory: 128Mi
            limits:
              memory: 256Mi
---
apiVersion: v1
kind: Service
metadata:
  name: provider-terraform-shard-assigner
  namespace: {{ .Values.namespace }}
  annotations:
    argocd.argoproj.io/sync-wave: '25'
  labels:
    app: provider-terraform-shard-assigner
spec:
  selector:
    app: provider-terraform-shard-assigner
  ports:
    - name: metrics
      port: 8080
      targetPort: metrics
      protocol: TCP
```

### `templates/externalsecrets.yaml`

```yaml
{{- $root := . -}}
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: crossplane-secrets
  namespace: {{ .Values.namespace }}
  annotations:
    argocd.argoproj.io/sync-wave: "0"
spec:
  refreshInterval: 10s
  secretStoreRef:
    kind: ClusterSecretStore
    name: {{ .Values.secretStore }}
  target:
    name: crossplane-secrets
    creationPolicy: Owner
    deletionPolicy: Retain
  dataFrom:
    - extract:
        key: /crossplane
        conversionStrategy: Default
        decodingStrategy: None
{{- range .Values.githubApp.installations }}
---
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: {{ .name }}
  namespace: {{ $root.Values.namespace }}
  annotations:
    argocd.argoproj.io/sync-wave: "0"
spec:
  refreshInterval: 120s
  secretStoreRef:
    kind: ClusterSecretStore
    name: {{ $root.Values.secretStore }}
  target:
    name: {{ .name }}
    creationPolicy: Owner
    template:
      metadata:
        annotations:
          managed-by: argocd.argoproj.io
        labels:
          argocd.argoproj.io/secret-type: repository
          {{- if .labelled }}
          # Discovered by the provider's multi-org GitHub App lookup.
          # Labelled secrets are authoritative: the ProviderConfig fallback
          # applies only when none exist at all.
          tf.konstruct.io/github-app: "true"
          {{- end }}
      type: Opaque
      data:
        type: "{{ `{{ .type }}` }}"
        url: "{{ `{{ .url }}` }}"
        app_id: "{{ `{{ .githubAppID }}` }}"
        installation_id: "{{ `{{ .githubAppInstallationID }}` }}"
        github_app_private_key: "{{ `{{ .githubAppPrivateKey }}` }}"
  dataFrom:
    - extract:
        key: {{ .vaultKey }}
{{- end }}
```

### `templates/logs.yaml`

One `log-streamer` Service selects every shard pod. The ServiceMonitor scrapes
each pod behind it individually, so every shard's metrics are collected. With
`logs.efsFileSystemId` set, that Service and a single `/` route serve any
Workspace at `/logs/<name>`. Without it, logs are local to each pod, so the
chart adds per-shard Services and `/shard-N/logs/<name>` routes instead.

```yaml
{{- $root := . -}}
# Log routing and metrics.
#
# One Service selects every shard pod. The ServiceMonitor scrapes each endpoint
# behind it individually, so every shard's metrics are still collected, and
# provider metrics carry a shard label to tell them apart.
#
# With logs.efsFileSystemId set, every shard shares one /logs volume, so that
# Service also streams any Workspace at /logs/<name> from whichever pod answers.
# Without it each pod's logs are local, so per-shard Services and /shard-N
# routes reach the pod that wrote them.
---
apiVersion: v1
kind: Service
metadata:
  name: log-streamer
  namespace: {{ .Values.namespace }}
  annotations:
    argocd.argoproj.io/sync-wave: '35'
  labels:
    app: log-streamer
spec:
  # Selects by app, not by package revision. The previous Service pinned
  # pkg.crossplane.io/revision to a specific hash, so it silently selected
  # nothing after any provider upgrade.
  selector:
    app: provider-terraform
  ports:
    - name: http
      port: 9090
      targetPort: 9090
      protocol: TCP
    - name: metrics
      port: 8080
      targetPort: 8080
      protocol: TCP
{{- if not .Values.logs.efsFileSystemId }}
{{- range $i := until (int .Values.shardCount) }}
{{- $shard := printf "shard-%d" $i }}
---
apiVersion: v1
kind: Service
metadata:
  name: log-streamer-{{ $shard }}
  namespace: {{ $root.Values.namespace }}
  annotations:
    argocd.argoproj.io/sync-wave: '35'
  labels:
    # No app: log-streamer label: the Service above already covers metrics.
    terraform.crossplane.io/shard: {{ $shard }}
spec:
  selector:
    app: provider-terraform
    terraform.crossplane.io/shard: {{ $shard }}
  ports:
    - name: http
      port: 9090
      targetPort: 9090
      protocol: TCP
{{- end }}
{{- end }}
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: log-streamer
  namespace: {{ .Values.namespace }}
  annotations:
    argocd.argoproj.io/sync-wave: '35'
spec:
  parentRefs:
    - name: eg
      namespace: default
      sectionName: {{ .Values.logs.gatewaySectionName }}
  hostnames:
    - {{ .Values.logs.hostname }}
  rules:
{{- if .Values.logs.efsFileSystemId }}
    # Shared volume: any pod can serve any Workspace's log.
    - matches:
        - path:
            type: PathPrefix
            value: /
      backendRefs:
        - name: log-streamer
          port: 9090
      # long-lived log streams
      timeouts:
        request: {{ .Values.logs.requestTimeout }}
{{- else }}
{{- range $i := until (int .Values.shardCount) }}
{{- $shard := printf "shard-%d" $i }}
    # Find a workspace's shard with:
    #   kubectl get workspace <name> -L terraform.crossplane.io/shard
    - matches:
        - path:
            type: PathPrefix
            value: /{{ $shard }}
      filters:
        - type: URLRewrite
          urlRewrite:
            path:
              type: ReplacePrefixMatch
              replacePrefixMatch: /
      backendRefs:
        - name: log-streamer-{{ $shard }}
          port: 9090
      # long-lived log streams
      timeouts:
        request: {{ $root.Values.logs.requestTimeout }}
{{- end }}
{{- end }}
```

### `templates/storage.yaml`

Rendered only when `logs.efsFileSystemId` is set (step 6).

```yaml
{{- if .Values.logs.efsFileSystemId }}
# One ReadWriteMany volume for /logs shared by every shard. Wave 25: bound
# before the shard Deployments (30) mount it.
#
# efs-ap gives the claim its own access point, which performs every file
# operation as one POSIX uid/gid, so the provider (uid 2000) and the
# log-streamer see the same ownership without relying on fsGroup (which EFS
# volumes do not apply).
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: efs-sc
  annotations:
    argocd.argoproj.io/sync-wave: '25'
provisioner: efs.csi.aws.com
parameters:
  provisioningMode: efs-ap
  fileSystemId: {{ .Values.logs.efsFileSystemId }}
  directoryPerms: "700"
reclaimPolicy: Retain
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: provider-terraform-logs
  namespace: {{ .Values.namespace }}
  annotations:
    argocd.argoproj.io/sync-wave: '25'
spec:
  accessModes:
    - ReadWriteMany
  storageClassName: efs-sc
  resources:
    requests:
      # EFS is elastic; the size is required by the API but not enforced.
      storage: 5Gi
{{- end }}
```

### `templates/servicemonitor.yaml`

```yaml
# Selects the log-streamer Service. Prometheus scrapes every endpoint behind
# it, so each shard pod is scraped on its own without listing them here.
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: crossplane-provider-terraform
  namespace: {{ .Values.namespace }}
  labels:
    app: crossplane-provider-terraform
spec:
  namespaceSelector:
    matchNames:
      - {{ .Values.namespace }}
  selector:
    matchLabels:
      app: log-streamer
  endpoints:
    - port: metrics
      path: /metrics
      scheme: http
      interval: 15s
---
# The assigner's own placement metrics - workspaces per shard, drains blocked,
# migrations. Separate because it is not a log-streamer.
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: provider-terraform-shard-assigner
  namespace: {{ .Values.namespace }}
  labels:
    app: provider-terraform-shard-assigner
spec:
  namespaceSelector:
    matchNames:
      - {{ .Values.namespace }}
  selector:
    matchLabels:
      app: provider-terraform-shard-assigner
  endpoints:
    - port: metrics
      path: /metrics
      scheme: http
      interval: 15s
```

### `templates/alerts.yaml`

```yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: provider-terraform-sharding
  namespace: {{ .Values.namespace }}
  annotations:
    argocd.argoproj.io/sync-wave: '40'
spec:
  groups:
    - name: provider-terraform-sharding
      rules:
        # The silent one. An unlabelled Workspace is reconciled by no shard,
        # and nothing else surfaces it - it simply stops.
        - alert: TerraformWorkspaceUnsharded
          expr: terraform_shard_workspaces_unlabelled > 0
          for: 5m
          labels: {severity: critical}
          annotations:
            summary: Workspaces have no shard label and are not being reconciled
            description: >-
              {{ `{{ $value }}` }} Workspace(s) carry no shard label. The
              assigner is wedged, not running, or something is stripping the
              label - check whether Argo is reverting it.

        # Desired state says alive, reality says dead. Their Workspaces look
        # correctly placed while being reconciled by nobody.
        - alert: TerraformShardWithoutPods
          expr: terraform_shard_without_pods > 0
          for: 15m
          labels: {severity: critical}
          annotations:
            summary: An active shard has no running pod
            description: >-
              Shard {{ `{{ $labels.shard }}` }} asks for replicas but has no
              running pod. Its Workspaces are unreconciled. Fix the pod, or set
              that shard's replicas to 0 to have its Workspaces migrated away.

        - alert: TerraformShardDrainBlocked
          expr: terraform_shard_drain_blocked > 0
          for: 15m
          labels: {severity: warning}
          annotations:
            summary: A draining shard still has a running pod
            description: >-
              Shard {{ `{{ $labels.shard }}` }} is being drained but still has a
              running pod, so its Workspaces will not be moved - two terraform
              processes would write the same state. Usually clears itself; if
              not, that pod is stuck terminating.

        - alert: TerraformWorkspaceOnInactiveShard
          expr: terraform_shard_workspaces_inactive_shard > 0
          for: 30m
          labels: {severity: warning}
          annotations:
            summary: Workspaces are still pointing at a removed shard
            description: >-
              Migrations run {{ .Values.assigner.migrationBatch }} at a time, so
              a large drain takes a while; half an hour without progress is not
              expected.

        - alert: TerraformShardMigrationStalled
          expr: terraform_shard_workspaces_migrating > 0
          for: 30m
          labels: {severity: warning}
          annotations:
            summary: A Workspace migration has not completed
            description: >-
              A Workspace has been migrating for over 30 minutes without
              reaching Synced=True on its new shard. Past the cutoff it stops
              holding a batch slot, so check why it is not syncing.
```

## 3. Fields to change in `values.yaml`

| Field | Set to | Notes |
| --- | --- | --- |
| `shardCount` | `1` for the first sync, then the target (e.g. `5`) | One shard is the same behaviour as today, so the assigner is proven before any split. |
| `image.controller` | Controller image with sharding support | Must support `--shard-name`; older images crash-loop on the unknown flag. |
| `image.assigner` | Matching shard-assigner image | Use the same build as the controller. |
| `package` | `xpkg.upbound.io/upbound/provider-terraform:v1.2.0` | See prerequisites. |
| `serviceAccount.name` | `crossplane-provider-terraform-<cluster-name>` | Must match the IAM role's trust policy exactly. |
| `serviceAccount.roleArn` | `arn:aws:iam::<aws-account-id>:role/crossplane-<cluster-name>` | The role Crossplane already uses. |
| `secretStore` | `<cluster-name>-vault-kv-secret` | The `ClusterSecretStore` your other ExternalSecrets use. |
| `logs.hostname` | `logs-<cluster-name>.<domain>` | Must match a hostname the gateway's `https-logs` listener serves. |
| `logs.gatewaySectionName` | `https-logs` | Listener name on the `eg` Gateway in `default`. |
| `logs.efsFileSystemId` | `""` now, `<efs-file-system-id>` in step 6 | Empty keeps per-pod logs. |
| `githubApp.installations[].vaultKey` | `<github-app-vault-key>` | Add one entry per GitHub org, with `labelled: true` for every entry after the first. |
| `controller.terminationGracePeriodSeconds` | Above your slowest `terraform apply` | Default `900`. A pod killed mid-apply leaves a stale state lock needing `terraform force-unlock`. |

Everything else can stay as shown.

Check each name against the cluster's other components before committing. A
typo in the ServiceAccount, role, secret store or hostname each fails in a
different place.

## 4. Update the Argo CD Application

File: `registry/konstruct-clusters/<cluster-name>/40-crossplane-components.yaml`

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: <cluster-name>-crossplane-components
  namespace: argocd
  annotations:
    argocd.argoproj.io/sync-wave: '40'
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: <cluster-name>
  source:
    repoURL: <gitops-repo-url>
    path: registry/konstruct-clusters/<cluster-name>/crossplane-components
    targetRevision: HEAD
  destination:
    name: <cluster-name>
    namespace: crossplane-system
  ignoreDifferences:
    # The shard assigner patches spec.replicas to drive a drain it started
    # itself - scaling a shard to zero and waiting for its pod to go before
    # moving that shard's Workspaces. Without this, selfHeal reverts the
    # scale-to-zero and the drain never completes.
    - group: apps
      kind: Deployment
      jsonPointers:
        - /spec/replicas
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
      # Was Replace=true. `kubectl replace` overwrites the whole object,
      # wiping fields set by controllers - including the replicas the assigner
      # just patched. Server-side apply tracks field ownership instead, so
      # Argo owns what it declares and controllers own what they write.
      - ServerSideApply=true
---
```

- **`ignoreDifferences` on `/spec/replicas`:** the assigner scales a shard to
  zero to drive a drain it started. Without this, `selfHeal` reverts it and the
  drain never finishes.
- **`ServerSideApply=true`**, not `Replace=true`: `replace` overwrites the whole
  object and wipes fields controllers set, including the replicas the assigner
  patched. Server-side apply tracks field ownership, so Argo CD owns what git
  declares and controllers own what they write.

Keep `terraform.crossplane.io/shard` **out of git** on Workspace manifests. The
assigner owns that label; Argo CD leaves it alone only as long as git never
declares it.

## 5. Verify sharding

```sh
# the shards and the assigner are running; the Crossplane Deployment sits at 0/0
kubectl get deploy -n crossplane-system

# shard pods run as uid 2000
kubectl exec -n crossplane-system deploy/provider-terraform-shard-0 -c package-runtime -- id

# every Workspace has a shard label
kubectl get workspace.tf.upbound.io -A -L terraform.crossplane.io/shard

# assigner activity
kubectl logs -n crossplane-system deploy/provider-terraform-shard-assigner | tail -20
```

A Workspace with no shard label is reconciled by nothing. The
`TerraformWorkspaceUnsharded` alert fires if any stay unlabelled for 5 minutes.

Once one shard is healthy, raise `shardCount` to the target.

## 6. Shared logs on EFS

Each shard writes `/logs/<workspace>` on its own pod. Without shared storage a
log is only reachable through its shard (`/shard-N/logs/<name>`) and is lost
on restart or migration. EBS (`ebs-csi-default-sc`) is ReadWriteOnce and cannot
be shared between nodes, so this uses EFS.

### 6a. Allow the cluster's Terraform role to manage EFS

The role that applies your cluster's Terraform in `<aws-account-id>` (the
`role_arn` in `provider-config/providerconfig.yaml`) needs EFS permissions.
Without them, the apply fails with
`not authorized to perform: elasticfilesystem:TagResource`. Add
`elasticfilesystem:*` to its policy:

```json
{
  "Sid": "AdminAccess",
  "Effect": "Allow",
  "Action": ["s3:*", "eks:*", "ecr:*", "ec2:*", "elasticfilesystem:*"],
  "Resource": "*"
}
```

### 6b. Add EFS and the EFS CSI driver to the cluster Terraform

In the Terraform module that creates the cluster's EKS cluster and VPC, add the
driver to the EKS module's `cluster_addons`:

```hcl
  cluster_addons = {
    # ...existing addons...
    aws-efs-csi-driver = {
      most_recent              = true
      service_account_role_arn = module.aws_efs_csi_driver.iam_role_arn
    }
  }
```

and add these resources alongside it:

```hcl
module "aws_efs_csi_driver" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.42.0"

  role_name             = upper("EFS-CSI-DRIVER-${var.cluster_name}")
  attach_efs_csi_policy = true

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["kube-system:efs-csi-controller-sa", "kube-system:efs-csi-node-sa"]
    }
  }

  tags = local.tags
}

resource "aws_efs_file_system" "shared" {
  creation_token = "efs-${var.cluster_name}"
  encrypted      = true

  tags = merge(local.tags, { Name = "efs-${var.cluster_name}" })
}

# Managed node groups here use the default launch template, so nodes carry the
# cluster primary security group rather than the module's node group; allow NFS
# from the VPC instead of from a specific group.
resource "aws_security_group" "efs" {
  name        = "efs-${var.cluster_name}"
  description = "NFS from the ${var.cluster_name} VPC to EFS"
  vpc_id      = module.vpc.vpc_id

  ingress {
    description = "NFS"
    from_port   = 2049
    to_port     = 2049
    protocol    = "tcp"
    cidr_blocks = [local.vpc_cidr]
  }

  tags = local.tags
}

resource "aws_efs_mount_target" "shared" {
  count = length(local.azs)

  file_system_id  = aws_efs_file_system.shared.id
  subnet_id       = module.vpc.private_subnets[count.index]
  security_groups = [aws_security_group.efs.id]
}
```

The references `module.eks`, `module.vpc`, `local.azs`, `local.vpc_cidr` and
`local.tags` are the names the standard Konstruct project-cluster module uses;
adjust them if yours differ. The security group allows NFS from the VPC CIDR
because managed node groups on the default launch template carry the cluster
primary security group, not the module's node group.

Apply it, then confirm:

```sh
aws efs describe-file-systems --region <region> \
  --query "FileSystems[?Name=='efs-<cluster-name>'].[FileSystemId,NumberOfMountTargets]" --output text
kubectl get csidriver efs.csi.aws.com
```

Expect a filesystem ID with one mount target per private subnet.

### 6c. Point the chart at the filesystem

In `crossplane-components/values.yaml`:

```yaml
logs:
  efsFileSystemId: "<efs-file-system-id>"
```

This renders the `efs-sc` StorageClass and the `provider-terraform-logs`
ReadWriteMany claim, mounts it at `/logs` on every shard, and replaces the
per-shard Services and `/shard-N` routes with a single `/` route to the
`log-streamer` Service. Shard pods restart onto the new volume; logs written
before the switch are not carried over.

```sh
kubectl get pvc -n crossplane-system provider-terraform-logs     # Bound
curl -N https://logs-<cluster-name>.<domain>/logs/<workspace-name>
```

## Operating it

| Action | How | What happens |
| --- | --- | --- |
| **Scale up** | Raise `shardCount` | New shard Deployments appear. Existing Workspaces do not move; new ones land on the emptiest shards. |
| **Scale down** | Lower `shardCount` | Argo CD prunes the top shard. The assigner waits for its pod to fully exit, then relabels its Workspaces onto the remaining shards, `migrationBatch` at a time, least-loaded. |
| **Drain one in the middle** | Add it to `draining`, e.g. `[shard-2]` | Renders it at `replicas: 0`; same flow as scale down. |

During a drain `terraform_shard_drain_blocked{shard="shard-N"}` is `1` until
the old pod is gone, and `TerraformShardDrainBlocked` fires if that lasts
15 minutes. Pod restarts, OOM kills and node drains never trigger migrations;
only the Deployments in git do.
