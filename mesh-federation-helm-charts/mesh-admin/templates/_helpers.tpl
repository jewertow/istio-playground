{{/*
  Transforms hostname and port into $first-label-$port.$dnsSuffix.
  Example: httpbin.mesh.global and 80 will result in httpbin-80.mesh.global.
*/}}
{{- define "hostname.withPort" -}}
{{- $h := printf "%s" (required "hostname is required" .hostname) -}}
{{- $p := printf "%v" (required "port is required" .port) -}}

{{/* split hostname into labels */}}
{{- $parts := splitList "." $h -}}
{{- if lt (len $parts) 2 }}
    {{- fail (printf "hostname.withPort: '%s' must contain at least one dot" $h) }}
{{- end }}

{{- $first := index $parts 0 -}}
{{- $rest  := join "." (slice $parts 1) -}}

{{- printf "%s-%s.%s" $first $p $rest -}}
{{- end }}
