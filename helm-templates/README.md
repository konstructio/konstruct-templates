# Helm templates

Helm charts used to deploy **applications** onto a cluster — as opposed to
`cluster-templates/`, which provisions the clusters themselves.

## Layout

```
helm-templates/
└── charts/          # the generic web-service chart every registered app gets
```

## `charts/`

The default chart Konstruct copies into an application's repository when that
app is registered. It renders a standard web-service shape:

| Template | Renders |
|---|---|
| `deployment.yaml` | `Deployment` — image, replicas, probes, resources, env |
| `service.yaml` | `Service` |
| `ingress.yaml` | `Ingress` (when `ingress.enabled`) |
| `hpa.yaml` | `HorizontalPodAutoscaler` (when `autoscaling.enabled`) |
| `serviceaccount.yaml` | `ServiceAccount` (when `serviceAccount.create`) |
| `templates/tests/` | `helm test` connection check |

`values.yaml` carries the usual community-chart surface — `replicaCount`,
`image`, `service`, `ingress`, `resources`, `autoscaling`, `nodeSelector`,
`tolerations`, `affinity`, and the pod/container security contexts.

### The `<REPO_NAME>` token

`Chart.yaml` deliberately ships an unresolved token as its chart name:

```yaml
name: <REPO_NAME>
```

Konstruct replaces it with the application's repository name at registration
time, so each app ends up with a chart named after itself. This matters because
the chart's `_helpers.tpl` derives every resource name from `.Chart.Name` — so
the token drives the naming of the whole release, not just the chart metadata.

Two consequences worth knowing:

- `helm lint`/`helm template` against this directory as-is will name resources
  after the literal token. That is expected; it is not a broken chart.
- Do not "fix" the name to a real string. Doing so would give every application
  in the platform identically-named resources.

## Who consumes this

`helm-templates/charts` is a **hardcoded path** in two places, both of which
create a `HelmTemplate` CR pointing at it:

| Consumer | What it creates |
|---|---|
| `application-operator` | the cluster-wide `default` `HelmTemplate` installed by its chart |
| `konstruct-api` | the `default` `HelmTemplate` seeded into every new organization |

Renaming this directory breaks both at runtime — they resolve the path against a
clone of this repo at the ref in `KONSTRUCT_VERSION`, so nothing fails at build
time.

## Adding a chart

Additional application chart shapes (worker, cronjob, statefulset) belong here
as sibling directories. Keep `<REPO_NAME>` as the chart name so the registration
flow can claim it, and verify the chart renders before committing:

```bash
helm lint helm-templates/<chart>
helm template test helm-templates/<chart>
```
