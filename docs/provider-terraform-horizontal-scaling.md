# Horizontal Scaling for provider-terraform — Rollout Runbook

A single provider-terraform controller runs every `terraform init/plan/apply`
in the cluster, so throughput stops scaling past a few hundred Workspaces.
Sharding runs **N controller Deployments side by side**, each reconciling only
the Workspaces labelled `terraform.crossplane.io/shard: shard-N`. A **shard
assigner** writes that label, spreading Workspaces least-loaded, and migrates
them safely when a shard is removed.

This is the sequence used to roll it out on `v2-mgmt`. Paths are relative to
the cluster's gitops repo unless they name `konstruct-templates`.

- **Controller + assigner images:** `ghcr.io/konstructio/provider-terraform:branch-46db7d0d`,
  `ghcr.io/konstructio/provider-terraform-shard-assigner:branch-46db7d0d`
- **Change:** [konstructio/provider-terraform#16](https://github.com/konstructio/provider-terraform/pull/16)
- **Shared logs (EFS):** [konstructio/konstruct-templates#113](https://github.com/konstructio/konstruct-templates/pull/113)
- **Reference chart:** `registry/konstruct-clusters/v2-mgmt/crossplane-components/`
- **Design notes:** `docs/shard-assigner.md` in provider-terraform

> **The images predate the tini fix.** `branch-46db7d0d` was built before
> [provider-terraform#17](https://github.com/konstructio/provider-terraform/pull/17)
> (`v0.0.1-rc.20`), so shard pods do not reap zombie `git`/`terraform`
> processes. Rebuild both images from a commit that contains #16 and #17 before
> rolling this out anywhere long-lived.

## Prerequisites

| Check | Why |
| --- | --- |
| Provider package is **`xpkg.upbound.io/upbound/provider-terraform:v1.2.0`** | The controller image expects the `tf.m.upbound.io` CRDs. On `v0.20.0` it exits with `no matches for kind "Workspace" in version "tf.m.upbound.io/v1beta1"`. |
| IAM role `crossplane-<cluster>` trusts `system:serviceaccount:crossplane-system:crossplane-provider-terraform-<cluster>` | Every shard reuses the Provider's ServiceAccount. A mismatched name (we hit `v2-mgmt-mgmt`) fails `terraform init` with `403 Not authorized to perform sts:AssumeRoleWithWebIdentity`. |
| Terraform backends lock state (S3 + DynamoDB or `use_lockfile`) — *recommended* | The assigner already refuses to move a Workspace off a shard whose pod is still running; locking covers the remaining edge cases. |

## 1. Replace `crossplane-components` with the sharded chart

`registry/konstruct-clusters/<cluster>/crossplane-components/`

Copy the chart from `v2-mgmt` (`Chart.yaml`, `values.yaml`, `templates/`) over
the existing plain manifests. It keeps the **same object names** as before
(`Provider/crossplane-provider-terraform`, `DeploymentRuntimeConfig/terraform-config`,
`ExternalSecret/crossplane-secrets`, `ExternalSecret/github-app-credentials`,
`HTTPRoute/log-streamer`, `ServiceMonitor/crossplane-provider-terraform`), so
Argo updates them in place. The only object pruned is the old
`Service/log-streamer-service`.

> **Never let the `Provider` be pruned.** Deleting it deletes its
> ProviderRevision, whose CRDs are then garbage collected — and deleting a CRD
> deletes every Workspace in the cluster. The chart sets
> `argocd.argoproj.io/sync-options: Prune=false` on it; keep that.

What the chart renders:

- The Crossplane `Provider` + `DeploymentRuntimeConfig` at **`replicas: 0`**.
  They exist only to install the CRDs, RBAC and IRSA ServiceAccount;
  Crossplane builds one Deployment per revision and cannot produce a fleet.
- `shardCount` Deployments `provider-terraform-shard-0..N-1`, each started
  with `--shard-name=shard-N --leader-election`.
- The shard assigner Deployment and its RBAC.
- Per-shard log Services and routes, alerts, the ExternalSecrets.

## 2. Set the values

`same folder → values.yaml`

```yaml
shardCount: 5          # start at 1 on a new cluster to prove the assigner first

image:
  controller: ghcr.io/konstructio/provider-terraform:branch-46db7d0d
  assigner: ghcr.io/konstructio/provider-terraform-shard-assigner:branch-46db7d0d
  logStreamer: ghcr.io/konstructio/logs-streamer:v0.0.10

package: xpkg.upbound.io/upbound/provider-terraform:v1.2.0

serviceAccount:
  name: crossplane-provider-terraform-<cluster>
  roleArn: arn:aws:iam::<account-id>:role/crossplane-<cluster>

secretStore: <cluster>-vault-kv-secret

logs:
  hostname: logs-<cluster>.gitops.ing
  efsFileSystemId: ""   # set in step 5

githubApp:
  installations:
    - name: github-app-credentials
      labelled: false
      vaultKey: argocd/repo-credentials-template/<org>-platform
```

Double-check every name against the cluster's other components. The doubled
suffix (`<cluster>-mgmt-mgmt`) slipped into the ServiceAccount, the IAM role,
the secret store and the log hostname on `v2-mgmt`, and each one failed
differently.

## 3. Run the shard pods as UID 2000

`same folder → templates/shards.yaml`

```yaml
      securityContext:
        runAsUser: 2000
        runAsGroup: 2000
        runAsNonRoot: true
        fsGroup: {{ $root.Values.controller.fsGroup }}
```

Crossplane runs provider pods as UID 2000, but the shard Deployments are the
chart's own and the image sets no `USER`, so without this they run as root.
Root's `HOME` is `/root`, so git never reads the image's `/.gitconfig` — the
credential helper that points at the minted GitHub App token — and every
private module clone fails with:

```
fatal: could not read Username for 'https://github.com': No such device or address
```

## 4. Configure the Argo Application

`registry/konstruct-clusters/<cluster>/40-crossplane-components.yaml`

```yaml
spec:
  ignoreDifferences:
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
      - ServerSideApply=true
```

- **`ignoreDifferences` on `/spec/replicas`:** the assigner scales a shard to
  zero to drive a drain it started. Without this, `selfHeal` reverts it and
  the drain never finishes.
- **`ServerSideApply=true` instead of `Replace=true`:** `replace` overwrites
  the whole object, wiping fields controllers set (the patched replicas).
  Server-side apply tracks field ownership, so Argo owns what git declares and
  controllers own what they write.

Keep `terraform.crossplane.io/shard` **out of git** on Workspace manifests.
The assigner owns that label; Argo leaves it alone only as long as git never
declares it.

## 5. Shared logs on EFS

Each shard's pod writes `/logs/<workspace>`. On per-pod `emptyDir` a log is
only readable from the shard that wrote it (`/shard-N/logs/<name>`) and is lost
on restart or migration. A ReadWriteMany EFS volume lets any pod stream any
Workspace at `/logs/<name>`. EBS (`ebs-csi-default-sc`) is ReadWriteOnce and
cannot do this.

### 5a. Let the account role manage EFS

The cluster Terraform runs as the cross-account role
`konstruct-mgmt-<mgmt-cluster>` in the project account (the `role_arn` in
`provider-config/providerconfig.yaml`). Its policy has no EFS actions, which
fails the apply with `not authorized to perform: elasticfilesystem:TagResource`.
Add `elasticfilesystem:*` to its `AdminAccess` statement:

```json
{
  "Sid": "AdminAccess",
  "Effect": "Allow",
  "Action": ["s3:*", "eks:*", "ecr:*", "ec2:*", "elasticfilesystem:*"],
  "Resource": "*"
}
```

Make the same change wherever cloud-account onboarding defines this policy, or
every newly onboarded account fails at the EFS step.

### 5b. Create EFS and the CSI driver

`konstruct-templates → terraform/aws/modules/workload-project-cluster` ([#113](https://github.com/konstructio/konstruct-templates/pull/113))

Adds the `aws-efs-csi-driver` addon with its IRSA role, an encrypted EFS
filesystem with a mount target per private subnet, an NFS (2049) security group
for the VPC CIDR, and `efs_file_system_id` in vault `secret/clusters/<cluster>`.

> **Until #113 merges,** point the cluster's infrastructure Workspace at the
> branch: `.../workload-project-cluster?ref=feat/efs-workload-project-cluster`
> in `registry/konstruct-clusters/<cluster>/infrastructure/workspace.yaml`.
> Switch it back to `?ref=main` only **after** the merge — on the current
> `main` the next reconcile would destroy the EFS resources.
>
> **Once #113 merges,** every project cluster pulling `?ref=main` applies it
> on its next reconcile. The change is additive only.

Verify:

```sh
aws efs describe-file-systems --region <region> \
  --query "FileSystems[?Name=='efs-<cluster>'].[FileSystemId,NumberOfMountTargets]" --output text
kubectl get csidriver efs.csi.aws.com
```

### 5c. Point the chart at the filesystem

`crossplane-components/values.yaml`

```yaml
logs:
  efsFileSystemId: fs-xxxxxxxx
```

This renders an `efs-sc` StorageClass (`provisioningMode: efs-ap`), a
`provider-terraform-logs` RWX PVC mounted at `/logs` on every shard, a single
`log-streamer` Service across all shards, and a catch-all `/` route. The
`/shard-N` routes and per-shard Services stay: they still work, and they carry
each shard's metrics.

## 6. Verify

```sh
# every shard + the assigner running
kubectl get deploy -n crossplane-system

# pods run as 2000, PID 1 is tini (once the image includes #17)
kubectl exec -n crossplane-system deploy/provider-terraform-shard-0 -c package-runtime -- sh -c 'id; ps -o pid,comm | head -3'

# every Workspace has a shard, spread across them
kubectl get workspace.tf.upbound.io -A -L terraform.crossplane.io/shard

# nothing left unplaced or stuck
kubectl logs -n crossplane-system deploy/provider-terraform-shard-assigner | tail -20

# logs from any pod
curl -N https://logs-<cluster>.gitops.ing/logs/<workspace-name>
```

A Workspace with no shard label is reconciled by nothing. If any stay
unlabelled, check the assigner's logs first.

## Operating it

| Action | How | What happens |
| --- | --- | --- |
| **Scale up** | Raise `shardCount` | New shard Deployments appear. Existing Workspaces do not move; new ones land on the emptiest shards. |
| **Scale down** | Lower `shardCount` | Argo prunes the top shard. The assigner waits for its pod to fully exit, then relabels its Workspaces onto the survivors, 5 at a time, least-loaded. |
| **Drain one in the middle** | Add it to `draining: [shard-2]` | Renders it at `replicas: 0`; same flow as scale down. |

During a drain `terraform_shard_drain_blocked{shard="shard-N"}` is `1` until
the old pod is gone. A step-by-step code walkthrough of the drain is in
`docs/shard-assigner.md` in provider-terraform.

Keep `terminationGracePeriodSeconds` (900 by default) above the slowest apply
on the cluster. A pod killed mid-apply leaves a stale S3 state lock that needs
a manual `terraform force-unlock`.

## Clean up

The pre-sharding plain manifests were kept on `v2-mgmt` in
`crossplane-component-2/`. No Argo Application points at that folder, so it
does nothing; delete it once the sharded chart has been stable for a while.
