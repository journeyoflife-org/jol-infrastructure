{{/*
Shared library — standard resource presets
*/}}
{{- define "jol-library.resources.small" -}}
requests:
  cpu: 100m
  memory: 128Mi
limits:
  cpu: 500m
  memory: 512Mi
{{- end }}

{{- define "jol-library.resources.medium" -}}
requests:
  cpu: 250m
  memory: 256Mi
limits:
  cpu: 1000m
  memory: 1Gi
{{- end }}

{{- define "jol-library.resources.large" -}}
requests:
  cpu: 500m
  memory: 512Mi
limits:
  cpu: 2000m
  memory: 2Gi
{{- end }}
