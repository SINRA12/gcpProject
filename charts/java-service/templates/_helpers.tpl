{{- define "java-service.name" -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/* The labels the Deployment, Service, PodMonitor and PDB use to find the pods */}}
{{- define "java-service.selectorLabels" -}}
app.kubernetes.io/name: {{ include "java-service.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{/* Pods also carry "app", the label the other demo apps in these clusters use */}}
{{- define "java-service.podLabels" -}}
{{ include "java-service.selectorLabels" . }}
app: {{ include "java-service.name" . }}
{{- end -}}

{{- define "java-service.labels" -}}
{{ include "java-service.podLabels" . }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version }}
{{- end -}}
