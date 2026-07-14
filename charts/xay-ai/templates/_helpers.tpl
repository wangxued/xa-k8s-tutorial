{{- define "xay-ai.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "xay-ai.namespace" -}}
{{- default .Release.Namespace .Values.NameSpace -}}
{{- end -}}

{{- define "xay-ai.fullname" -}}
{{- $base := default "ai-workload" .Values.BaseName -}}
{{- $name := printf "%s-%s" .Release.Name $base -}}
{{- default $name .Values.DeployName | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "xay-ai.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
  selectorLabels：写入 Deployment.spec.selector、Service.spec.selector 与 Pod 模板。
  须保持稳定且为各资源标签的子集；勿将用户自定义 Labels 并入此处。
*/}}
{{- define "xay-ai.selectorLabels" -}}
app.kubernetes.io/name: {{ include "xay-ai.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app: {{ include "xay-ai.fullname" . }}
{{- end -}}

{{/*
  labels：通用标签（含 selectorLabels），用于 Deployment/Service/PVC 等 metadata 与 Pod 模板。
*/}}
{{- define "xay-ai.labels" -}}
helm.sh/chart: {{ include "xay-ai.chart" . }}
{{ include "xay-ai.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: xay-ai
app.kubernetes.io/component: {{ default "ai-workload" .Values.BaseName }}
{{- with .Values.Labels }}
{{ toYaml . }}
{{- end }}
{{- end -}}

{{- define "xay-ai.containerName" -}}
{{- default (include "xay-ai.name" .) .Values.ContainerName | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "xay-ai.workspaceClaimName" -}}
{{- $namespace := include "xay-ai.namespace" . -}}
{{- $defaultName := printf "pvc-workspace-%s-%s" $namespace (include "xay-ai.fullname" .) -}}
{{- default $defaultName .Values.Workspace.claimName | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "xay-ai.scratchClaimName" -}}
{{- printf "pvc-scratch-%s" (include "xay-ai.fullname" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}
