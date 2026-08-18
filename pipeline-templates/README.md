# Pipeline templates

CI/CD workflow templates copied into an application's repository when that
application is registered with Konstruct. These build and publish the app, then
hand off to the gitops repo — they never deploy to a cluster directly.

## Layout

```
pipeline-templates/
├── workflows/          # default set, installed at app registration
│   ├── publish.yaml        # build + push image and chart → ECR
│   ├── ghcr-publish.yaml   # build + push image and chart → GHCR
│   ├── deploy.yaml         # trigger a deploy to an environment
│   └── gitlab/             # GitLab CI equivalents of publish + deploy
└── promotion/          # opt-in environment promotion / release workflows
```

## `workflows/`

The default pipeline set. All three GitHub Actions files are written to
`.github/workflows/` in the customer's app repo:

| File | Workflow name | Purpose |
|---|---|---|
| `publish.yaml` | Publish image and helm chart to ECR | Build the container image and package the Helm chart, push both to ECR |
| `ghcr-publish.yaml` | Publish image and helm chart to GHCR | Same, targeting GitHub Container Registry |
| `deploy.yaml` | Deploy to Environments | Manually dispatched per environment; dispatches `update-environment.yaml` in the gitops repo (passing environment, app name and version) which performs the actual update |

`gitlab/` holds the GitLab CI equivalents of `publish.yaml` and `deploy.yaml`.
`application-operator` copies that directory's contents into the app repo root
instead of the Actions files when the app's `GitAccount.Spec.Provider` is
`gitlab`. See [`workflows/gitlab/README.md`](workflows/gitlab/README.md) for the
resulting layout.

## `promotion/`

A richer release flow — version bumping and environment-by-environment
promotion, all `workflow_dispatch`-triggered so a human decides when code moves
forward:

| File | Workflow name |
|---|---|
| `bump-version.yaml` | Bump Version (takes a `bump` input) |
| `publish-dev.yaml` | Publish Dev (also runs on push) |
| `promote-test.yaml` | Promote Test |
| `promote-staging.yaml` | Promote Staging |
| `release-prod.yaml` | Release Prod |
| `hotfix.yaml` | Hotfix (takes a `tag` input) |

Unlike `workflows/`, this set is **not** wired to any default `PipelineTemplate`.
Nothing installs it automatically — register it as a custom pipeline template
(path `pipeline-templates/promotion`) to use it.

## Tokens

These files are copied, not Helm-rendered, so configurable values are
`<TOKEN_NAME>` placeholders that Konstruct substitutes at registration time. The
current set is:

`<ORG_NAME>`, `<GITOPS_REPO_NAME>`, `<APP_NAME>`, `<ENVIRONMENT>`,
`<AWS_REGION>`, `<ROLE_ARN>`

Keep the `<CONTEXT_VARIABLE_NAME>` convention when adding new ones, and make
sure anything new is actually supplied by the registration flow before relying
on it.

## Who consumes this

`pipeline-templates/workflows` is a **hardcoded path** in two places, both of
which create a `PipelineTemplate` CR pointing at it:

| Consumer | What it creates |
|---|---|
| `application-operator` | the cluster-wide `default` `PipelineTemplate` installed by its chart |
| `konstruct-api` | the `gh-actions` `PipelineTemplate` seeded into every new organization |

Both resolve the path against a clone of this repo at the ref in
`KONSTRUCT_VERSION`, so renaming this directory breaks app registration at
runtime rather than at build time.

## Adding a workflow

Drop it in `workflows/` to have it installed for every new app, or in
`promotion/` (or a new sibling directory) to keep it opt-in. Validate the YAML
and check that every token you introduce is one the registration flow provides:

```bash
yamllint pipeline-templates/<dir>/<file>.yaml
grep -ro '<[A-Z_]*>' pipeline-templates/<dir>/ | sort -u
```
