{{/*
Shared library — standard health probes
*/}}
{{- define "jol-library.livenessProbe" -}}
httpGet:
  path: /health
  port: {{ .port }}
initialDelaySeconds: 30
periodSeconds: 10
timeoutSeconds: 5
failureThreshold: 3
{{- end }}

{{- define "jol-library.readinessProbe" -}}
httpGet:
  path: /health
  port: {{ .port }}
initialDelaySeconds: 5
periodSeconds: 5
timeoutSeconds: 3
failureThreshold: 3
{{- end }}
