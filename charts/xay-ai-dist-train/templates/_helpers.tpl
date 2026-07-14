{{- define "xay-ai-dist-train.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "xay-ai-dist-train.namespace" -}}
{{- default .Release.Namespace .Values.NameSpace -}}
{{- end -}}

{{- define "xay-ai-dist-train.fullname" -}}
{{- $base := default "dist-train" .Values.BaseName -}}
{{- $name := printf "%s-%s" .Release.Name $base -}}
{{- default $name .Values.JobName | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "xay-ai-dist-train.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
  selectorLabels：写入 Headless Service.spec.selector、Job Pod 模板与 podAntiAffinity。
  须保持稳定且为各资源标签的子集；勿将用户自定义 Labels 并入此处。
*/}}
{{- define "xay-ai-dist-train.selectorLabels" -}}
app.kubernetes.io/name: {{ include "xay-ai-dist-train.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{/*
  labels：通用标签（含 selectorLabels），用于 Job/Service/PVC 等 metadata 与 Pod 模板。
*/}}
{{- define "xay-ai-dist-train.labels" -}}
helm.sh/chart: {{ include "xay-ai-dist-train.chart" . }}
{{ include "xay-ai-dist-train.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: xay-ai-dist-train
app.kubernetes.io/component: {{ default "dist-train" .Values.BaseName }}
{{- with .Values.Labels }}
{{ toYaml . }}
{{- end }}
{{- end -}}

{{- define "xay-ai-dist-train.containerName" -}}
{{- default (include "xay-ai-dist-train.name" .) .Values.ContainerName | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "xay-ai-dist-train.workspaceClaimName" -}}
{{- $namespace := include "xay-ai-dist-train.namespace" . -}}
{{- $defaultName := printf "pvc-workspace-%s-%s" $namespace (include "xay-ai-dist-train.fullname" .) -}}
{{- default $defaultName .Values.Workspace.claimName | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "xay-ai-dist-train.masterAddr" -}}
{{- printf "%s-0.%s" (include "xay-ai-dist-train.fullname" .) (include "xay-ai-dist-train.fullname" .) -}}
{{- end -}}
