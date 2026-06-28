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

{{- define "xay-ai-dist-train.labels" -}}
app.kubernetes.io/name: {{ include "xay-ai-dist-train.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: xay-ai-dist-train
{{- end -}}

{{- define "xay-ai-dist-train.selectorLabels" -}}
app.kubernetes.io/name: {{ include "xay-ai-dist-train.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
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
