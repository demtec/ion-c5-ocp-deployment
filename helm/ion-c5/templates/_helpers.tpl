{{- define "ion-c5.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end }}

{{- define "ion-c5.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- $name := default .Chart.Name .Values.nameOverride -}}
{{- if contains $name .Release.Name -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}
{{- end }}

{{- define "ion-c5.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 }}
app.kubernetes.io/name: {{ include "ion-c5.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{- define "ion-c5.serviceAccountName" -}}
{{- if .Values.serviceAccount.create -}}
{{- default (include "ion-c5.fullname" .) .Values.serviceAccount.name -}}
{{- else -}}
{{- default "default" .Values.serviceAccount.name -}}
{{- end -}}
{{- end }}

{{/*
Rendered config.ini shared by the runtime ConfigMap and the setup-hook ConfigMap.
discover_host / validator_host default to the in-chart Services (port 80).
*/}}
{{- define "ion-c5.configIni" -}}
{{- $cfg := deepCopy .Values.config -}}
{{- if not (hasKey $cfg "discover_host") -}}
{{- $_ := set $cfg "discover_host" (printf "%s-discover" (include "ion-c5.fullname" .)) -}}
{{- end -}}
{{- if not (hasKey $cfg "validator_host") -}}
{{- $_ := set $cfg "validator_host" (printf "%s-docval" (include "ion-c5.fullname" .)) -}}
{{- end -}}
[c5]
{{- range $k, $v := $cfg }}
{{ $k }}={{ $v }}
{{- end }}
{{- end }}
