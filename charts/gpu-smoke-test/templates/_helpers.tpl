{{- define "gpu-smoke-test.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "gpu-smoke-test.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 45 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name (include "gpu-smoke-test.name" .) | trunc 45 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}

{{- define "gpu-smoke-test.labels" -}}
app.kubernetes.io/name: {{ include "gpu-smoke-test.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}

{{- define "gpu-smoke-test.selectorLabels" -}}
app.kubernetes.io/name: {{ include "gpu-smoke-test.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{/* Same reason as the gate chart: a Job spec is immutable, so a changed setting
     has to produce a new Job rather than a failed patch. */}}
{{- define "gpu-smoke-test.configHash" -}}
{{- printf "%s:%s|%s|%s|%v"
      .Values.image.repository
      .Values.image.tag
      .Values.gpu.pool
      .Values.gpu.resource
      .Values.gpu.count | sha256sum | trunc 8 -}}
{{- end -}}
