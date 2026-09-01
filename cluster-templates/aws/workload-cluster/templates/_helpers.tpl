{{/*
Apps domain: the DNS zone app hostnames on this cluster live under.
Theme clusters serve Foreman apps at <app>.<cluster>.apps.<domainName>;
plain workload clusters use the platform-injected external-dns domain.
*/}}
{{- define "aws-workload-cluster.appsDomain" -}}
{{- if .Values.theme -}}
{{ .Values.workloadClusterName }}.apps.{{ .Values.domainName }}
{{- else -}}
{{ .Values.workloadExternalDnsDomainName }}
{{- end -}}
{{- end -}}
