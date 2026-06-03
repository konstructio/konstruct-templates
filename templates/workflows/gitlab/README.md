# GitLab CI workflow templates

GitLab CI equivalents of the GitHub Actions templates in `../publish.yaml`
and `../deploy.yaml`. `application-operator` copies the contents of this
directory into the customer's app repo root at provisioning time when the
target `GitAccount.Spec.Provider == "gitlab"`. The layout is:

```
<customer-app-repo>/
├── .gitlab-ci.yml        # root entry — include:s the per-stage job files
└── gitlab/
    ├── deploy.yml        # manual UI/API-triggered deploy → GitOps trigger
    └── publish.yml       # push-to-main / manual: image + helm push to GitLab registry
```

## What's different from the GitHub version

- **Artifact destination is GitLab's own registry**, not AWS ECR. The
  GitHub workflow uses OIDC + AWS STS + ECR; on GitLab we use the
  built-in `$CI_JOB_TOKEN` (`$CI_REGISTRY_USER`/`$CI_REGISTRY_PASSWORD`
  injected automatically) and push to `$CI_REGISTRY_IMAGE`. No IAM trust
  policy, no AWS region, no cross-cloud auth.
- **Cross-repo dispatch** uses GitLab's pipeline-trigger API rather than
  GitHub's `createWorkflowDispatch`. Requires a project-scoped trigger
  token on the GitOps repo (provisioned as `GITOPS_TRIGGER_TOKEN`).

## Tokens detokenised by the operator

These bracketed placeholders are replaced when the operator clones and
writes into the customer repo:

| Token | Source |
|---|---|
| `<ENVIRONMENT>` | YAML list rendered from `Application.Spec.ReleaseStages` |
| `<APP_NAME>` | `Application.Name` |
| `<ORG_NAME>` | `GitAccount.Spec.OrgName` (full group path on GitLab) |
| `<GITOPS_REPO_NAME>` | `GitAccount.Spec.RepoName` |

`<AWS_REGION>` and `<ROLE_ARN>` from the GitHub flow are unused here —
GitLab CI pushes to the GitLab registry and doesn't need AWS credentials.

## CI variables provisioned by the operator

The operator POSTs this to `POST /projects/:id/variables` via the GitLab
API at the same point GitHub flows call `AddRepoSecret`:

| Variable | Masked | Protected | Type | Source |
|---|---|---|---|---|
| `GITOPS_TRIGGER_TOKEN` | ✓ | ✓ | env_var | Pipeline trigger token on the GitOps project (created via Settings → CI/CD → Pipeline trigger tokens). Used by `deploy.yml` to kick the cross-repo update. |

Everything else (`$CI_REGISTRY_*`, `$CI_PROJECT_*`, etc.) is supplied by
GitLab Runner automatically — no extra variables required.
