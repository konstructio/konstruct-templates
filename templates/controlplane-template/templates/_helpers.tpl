{{/*
Returns the ClusterSecretStore name to reference from ExternalSecrets.
Defaults to konstruct-aws-ssm for back-compat. For vault, uses
vault-kv-secret which matches the name set up by the bootstrap terraform.
*/}}
{{- define "controlplane.secretStoreName" -}}
{{- if eq .Values.secretStore.provider "vault" -}}
{{- default "vault-kv-secret" .Values.secretStore.name -}}
{{- else -}}
{{- default "konstruct-aws-ssm" .Values.secretStore.name -}}
{{- end -}}
{{- end -}}

{{/*
Returns the leading-slash convention for remoteRef.key on the configured
backend. SSM Parameter Store paths are absolute (leading "/"); Vault KV
paths are relative (no leading slash — ESO adds the data/ segment for KV v2).
*/}}
{{- define "controlplane.secretKeyPrefix" -}}
{{- if eq .Values.secretStore.provider "vault" -}}{{- else -}}/{{- end -}}
{{- end -}}

{{/*
Render a backend-aware remote key. Pass a string starting without a leading
slash, e.g. (include "controlplane.secretKey" (dict "Values" .Values "key" "argocd/repo-credentials-template/foo")).
*/}}
{{- define "controlplane.secretKey" -}}
{{- $prefix := include "controlplane.secretKeyPrefix" . -}}
{{- printf "%s%s" $prefix (trimPrefix "/" .key) -}}
{{- end -}}
