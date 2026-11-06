{{/*
Compiler chart helpers.
*/}}
{{- define "compiler.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "compiler.fullname" -}}
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

{{- define "compiler.labels" -}}
app.kubernetes.io/name: {{ include "compiler.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/part-of: feldera
{{- end }}

{{/*
Turns a scheduling value into a YAML map.

Accepts a map (`kubernetes.io/os: linux`) or a list of `key=value` strings, and
fails the render on a list entry without an `=`: an empty key would be rejected
by the API server with a message that does not name the values file.

Usage: {{ include "compiler.pairsToMap" .Values.nodeSelector }}
*/}}
{{- define "compiler.pairsToMap" -}}
{{- $out := dict -}}
{{- if kindIs "map" . -}}
{{- $out = . -}}
{{- else -}}
{{- range . -}}
{{- $parts := splitList "=" . -}}
{{- if ne (len $parts) 2 -}}
{{- fail (printf "expected key=value, got %q" .) -}}
{{- end -}}
{{- $out = set $out (index $parts 0) (index $parts 1) -}}
{{- end -}}
{{- end -}}
{{- toYaml $out -}}
{{- end -}}
