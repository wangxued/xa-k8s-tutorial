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

{{- define "xay-ai.labels" -}}
app.kubernetes.io/name: {{ include "xay-ai.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: xay-ai
{{- end -}}

{{- define "xay-ai.selectorLabels" -}}
app.kubernetes.io/name: {{ include "xay-ai.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
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
