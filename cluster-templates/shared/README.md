# Shared template snippets

Token-based manifests that are **not** part of any single cluster template tree.
Konstruct's operators fetch these directly, at the ref pinned by
`KONSTRUCT_VERSION`, and perform token replacement themselves.

| File | Consumer | Tokens replaced by the consumer |
|---|---|---|
| `45-environment.yaml` | `workloadcluster-operator` — `getEnvironmentTemplate` | `<ENV_NAME>` (the operator also relies on `<WORKLOAD_CLUSTER_NAME>` / `<TEAM_GITOPS_REPO_URL>` being detokenized downstream) |

Do not convert these to Helm templates: the consumers read the raw file over
HTTP and substitute tokens with `strings.ReplaceAll`, so Helm directives would
be written into the customer's gitops repo verbatim.
