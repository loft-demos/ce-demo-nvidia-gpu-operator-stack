{{- define "stack-gate.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "stack-gate.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 45 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name (include "stack-gate.name" .) | trunc 45 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}

{{- define "stack-gate.labels" -}}
app.kubernetes.io/name: {{ include "stack-gate.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}

{{- define "stack-gate.selectorLabels" -}}
app.kubernetes.io/name: {{ include "stack-gate.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{- define "stack-gate.serviceAccountName" -}}
{{- if .Values.serviceAccount.create -}}
{{- default (include "stack-gate.fullname" .) .Values.serviceAccount.name -}}
{{- else -}}
{{- default "default" .Values.serviceAccount.name -}}
{{- end -}}
{{- end -}}

{{/* Extra contract keys, as the key=value lines the gate feeds to --from-env-file. */}}
{{- define "stack-gate.contractData" -}}
{{- if .Values.contract.name -}}
{{- $lines := list -}}
{{- range $k, $v := .Values.contract.data -}}
{{- $lines = append $lines (printf "%s=%v" $k $v) -}}
{{- end -}}
{{- join "\n" $lines -}}
{{- end -}}
{{- end -}}

{{/*
A Job spec is immutable. Without this suffix, changing any gate setting would make
Argo CD try to patch the existing Job and fail the sync. With it, a changed setting
produces a new Job and prune removes the old one, which also re-runs the gate.
*/}}
{{- define "stack-gate.configHash" -}}
{{- $sig := printf "%s|%s|%s|%s|%s|%v|%s|%s|%s|%s:%s"
      .Values.wait.resource
      .Values.wait.namespace
      .Values.wait.condition
      .Values.wait.timeout
      .Values.capacity.resource
      .Values.capacity.min
      .Values.capacity.nodeSelector
      .Values.contract.name
      (include "stack-gate.contractData" .)
      .Values.image.repository
      .Values.image.tag -}}
{{- $sig | sha256sum | trunc 8 -}}
{{- end -}}
