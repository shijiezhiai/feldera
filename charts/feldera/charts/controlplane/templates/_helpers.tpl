{{/*
Control plane chart helpers.
*/}}
{{- define "controlplane.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "controlplane.fullname" -}}
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

{{- define "controlplane.labels" -}}
app.kubernetes.io/name: {{ include "controlplane.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/part-of: feldera
{{- end }}

{{/*
Turns a scheduling value into a YAML map.

The value may be a map already (`kubernetes.io/os: linux`) or a list of
`key=value` strings, which is what the manager's flags want and therefore the
shape the Bilibili overlay uses for the same setting in two places. A list
entry without an `=` fails the render instead of producing a selector with an
empty key, which the API server would reject at apply time with a message that
does not name the values file.

Usage: {{ include "controlplane.pairsToMap" .Values.nodeSelectors.controlPlane }}
*/}}
{{- define "controlplane.pairsToMap" -}}
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
