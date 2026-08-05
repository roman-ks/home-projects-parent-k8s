{{/* Release-scoped name so multiple targets (one release per bucket) coexist. */}}
{{- define "kopia.fullname" -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "kopia.labels" -}}
app.kubernetes.io/name: kopia
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}

{{- define "kopia.selectorLabels" -}}
app.kubernetes.io/name: kopia
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}
