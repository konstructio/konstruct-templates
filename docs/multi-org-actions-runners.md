# Multi-Org GitHub Actions Runners — Rollout Runbook

One actions-runner-controller (ARC) can register self-hosted runners in any
number of GitHub orgs. The controller keeps its default credentials
(`authSecret` → `controller-manager`), and each `RunnerDeployment` for another
org points at that org's GitHub App secret with `githubAPICredentialsFrom`.
Install the App in an org, add one secret and one `RunnerDeployment`, and that
org gets runners. No PAT and no second controller are needed.

- **Chart:** `actions-runner-controller` **0.23.7** (controller v0.27.6).
  Per-resource credentials need chart **>= 0.21.0** (controller v0.26.0).
- **Tested on:** `v2-mgmt`, adding the `gitops-biz` org next to the default org.

> **Why the chart bump is required:** chart 0.20.2's CRDs already contain
> `githubAPICredentialsFrom`, so the API server accepts the field, but its
> controller (v0.25.2) ignores it and always uses `controller-manager`. The
> runner then fails with
> `POST https://api.github.com/orgs/<org>/actions/runners/registration-token: 403 Resource not accessible by integration`
> even though the App's permissions and the org's installation are correct.

## How it works

A runner registers to exactly one scope (a repo, an org, or an enterprise), so
each org needs its own `RunnerDeployment`. The controller reconciles each one:

1. It picks the credentials: `githubAPICredentialsFrom` if set, otherwise the
   default `authSecret`.
2. It calls the GitHub API with them to get a short-lived registration token for
   the `RunnerDeployment`'s `organization`.
3. It creates runner pods with that token. The App private key never goes into
   the runner pod.

```
RunnerDeployment org-a ─┐                 ┌─ controller-manager (default) ─→ runners register in org-a
                        ├─→ ARC ──────────┤
RunnerDeployment org-b ─┘                 └─ github-app-org-b (override) ─→ runners register in org-b
```

## 1. Bump the chart

`root-gitops → registry/konstruct-clusters/<cluster-name>/51-actions-runner-application.yaml`

```yaml
spec:
  source:
    targetRevision: 0.23.7
    helm:
      values: |-
        # ...
        metrics:
          serviceAnnotations: {}
          serviceMonitor:        # was `serviceMonitor: false`
            enable: false
```

`metrics.serviceMonitor` changed from a bool to an object in chart 0.23.x. With
the old `serviceMonitor: false` the chart fails to render
(`can't evaluate field enable in type interface {}`). Keep
`authSecret.name: "controller-manager"` as it is. It stays the default for
every `RunnerDeployment` without an override, so existing runners are not
affected.

> **Minimal alternative:** chart **0.21.0** has the same `values.yaml` as
> 0.20.2, so you can bump `targetRevision` alone without the `serviceMonitor`
> change.

## 2. Create one secret per extra org

`same cluster folder → actions-runner-controller/51-actions-runner-externalsecret.yaml`

The secret must be in the same namespace as the runners (`github-runner`) and
use the keys ARC expects:

```yaml
---
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: github-app-<org>
  namespace: github-runner
  annotations:
    argocd.argoproj.io/sync-wave: "49"
spec:
  target:
    name: github-app-<org>
  secretStoreRef:
    kind: ClusterSecretStore
    name: <cluster-name>-vault-kv-secret
  data:
  - remoteRef:
      key: argocd/repo-credentials-template/<org>
      property: githubAppID
    secretKey: github_app_id
  - remoteRef:
      key: argocd/repo-credentials-template/<org>
      property: githubAppInstallationID
    secretKey: github_app_installation_id
  - remoteRef:
      key: argocd/repo-credentials-template/<org>
      property: githubAppPrivateKey
    secretKey: github_app_private_key
```

| Secret key                   | Value                                                                                                                  |
| ---------------------------- | ---------------------------------------------------------------------------------------------------------------------- |
| `github_app_id`              | Same for every installation of the same App.                                                                           |
| `github_app_private_key`     | Same for every installation of the same App.                                                                           |
| `github_app_installation_id` | **Differs per org.** Org Settings → GitHub Apps → Configure: the number at the end of the URL (`.../installations/<id>`). |

## 3. Add one `RunnerDeployment` per extra org

`same cluster folder → actions-runner-controller/51-actions-runner-runnerdeployment.yaml`

```yaml
---
apiVersion: actions.summerwind.dev/v1alpha1
kind: RunnerDeployment
metadata:
  name: actions-runner-<cluster-name>-<org>
  namespace: github-runner
  annotations:
    argocd.argoproj.io/sync-wave: '52'
spec:
  replicas: 2
  template:
    spec:
      organization: <org>
      githubAPICredentialsFrom:
        secretRef:
          name: github-app-<org>
      image: mirror.gcr.io/summerwind/actions-runner-dind
      serviceAccountName: github-runner-<cluster-name>
      dockerdWithinRunnerContainer: true
      automountServiceAccountToken: true
```

The `actions-runner-controller/` folder is already synced by
`50-actions-runner-controller.yaml`, so no new Argo CD Application is needed.
If you add a `HorizontalRunnerAutoscaler` for the org, give it the same
`githubAPICredentialsFrom` block.

**To add another org later:** install the GitHub App in the org, put its
credentials in Vault at `argocd/repo-credentials-template/<org>`, and repeat
steps 2 and 3. The controller and its values don't change.

## GitHub App requirements

The App must be installed in each org with:

- **Organization permissions → Self-hosted runners:** Read and write
- **Repository permissions → Metadata:** Read (Administration: Read and write is
  recommended)

If the App's permissions change, an org admin has to accept them per org
(Org Settings → GitHub Apps → Configure → review the permission request).

## Verify

```sh
# controller is on the new version
kubectl -n github-runner get deploy -l app.kubernetes.io/name=actions-runner-controller \
  -o jsonpath='{.items[*].spec.template.spec.containers[0].image}'

# the org's secret was synced from Vault
kubectl -n github-runner get externalsecret github-app-<org>

# runners exist and are running
kubectl -n github-runner get runnerdeployment,runners
```

The runners should also appear online under the org's
Settings → Actions → Runners.

## Troubleshooting

| Symptom in controller logs                                                         | Cause                                                                                                                         |
| ---------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------- |
| `403 Resource not accessible by integration` on `.../registration-token`           | Controller older than v0.26.0 (chart < 0.21.0) ignoring the override, **or** the token is for another org's installation, **or** the permission above is missing or not accepted. |
| `404` / installation not found                                                     | Wrong `github_app_installation_id` for this App.                                                                              |
| `401`                                                                              | `github_app_private_key` doesn't belong to `github_app_id`.                                                                   |
| Secret not found                                                                   | The `ExternalSecret` failed to sync (check the Vault path and properties) or is in a different namespace from the runners.    |

After fixing Vault, force a refresh instead of waiting for the refresh interval:

```sh
kubectl -n github-runner annotate externalsecret github-app-<org> force-sync=$(date +%s) --overwrite
```

## Rollback

Remove the org's `RunnerDeployment` and `ExternalSecret`. The runners are
deregistered from GitHub when their pods are deleted. The chart bump can stay:
`RunnerDeployment`s without `githubAPICredentialsFrom` behave exactly as before.
