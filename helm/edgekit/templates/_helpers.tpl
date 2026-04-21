{{/*
Expand the name of the chart.
*/}}
{{- define "edgekit.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
*/}}
{{- define "edgekit.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "edgekit.labels" -}}
helm.sh/chart: {{ include "edgekit.chart" . }}
{{ include "edgekit.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "edgekit.selectorLabels" -}}
app.kubernetes.io/name: {{ include "edgekit.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Chart label
*/}}
{{- define "edgekit.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Server full name
*/}}
{{- define "edgekit.server.fullname" -}}
{{- printf "%s-server" (include "edgekit.fullname" .) | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Client full name
*/}}
{{- define "edgekit.client.fullname" -}}
{{- printf "%s-client" (include "edgekit.fullname" .) | trunc 63 | trimSuffix "-" }}
{{- end }}
