# 示例目录

本目录包含两类示例：

- [`helm/`](helm/)：配合 `charts/xay-ai` 或 `charts/xay-ai-dist-train` 使用的 values 文件。
- [`raw-yaml/`](raw-yaml/)：不使用 Helm 时可参考的原生 Kubernetes YAML。

多机多卡训练总览见 [`../docs/multinode-gpu-training.md`](../docs/multinode-gpu-training.md)。**单机 Deployment vs 多机 Job**、TTL、Completed 后数据复用见 [`../docs/gpu-workload-scenarios.md`](../docs/gpu-workload-scenarios.md)。

## Helm values

| 文件 | 适用场景 |
|------|----------|
| `values-5090-nfs.yaml` | 5090 节点，使用 `h3c-csi-sc-nfs` |
| `values-h200-nfs.yaml` | H200 节点，使用 `h3c-csi-sc-nfs` |
| `values-h200-epc.yaml` | H200 节点，使用 `h3c-csi-sc-epc` |
| `values-egl-8-h200.yaml` | **单机 8 卡 H200 + EGL 渲染**（预留节点 `yw-gpu-33`） |
| `values-web-httproute.yaml` | 需要通过 HTTPRoute 暴露 Web 服务 |
| `values-shared-models.yaml` | 只读挂载公共模型权重 |
| `values-dist-train-h200-2x2.yaml` | **多机多卡**：2×H200×2 卡（推荐起步） |
| `values-dist-train-5090-2x2.yaml` | **多机多卡**：2×5090×2 卡（推荐起步） |
| `values-dist-train-h200-2x8.yaml` | **多机多卡**：2×H200×8 卡（占满 16 卡 quota） |
| `values-dist-train-5090-2x8.yaml` | **多机多卡**：2×5090×8 卡（占满 16 卡 quota） |

默认镜像为 `harbor.xa.hqzyai.com:19443/llm-course/lab:v2`。自定义镜像 push 至个人 Harbor 项目后替换 `ContainerImage`，详见 [`../docs/harbor-images.md`](../docs/harbor-images.md)。

### 部署前必填项

| 字段 | 说明 |
|------|------|
| `NameSpace` | 须与 `helm -n <namespace>` 一致 |
| `ContainerImage` | 默认 `llm-course/lab:v2`；自定义任务改为个人 Harbor 项目下的镜像 |
| `SharedModels.claimName` | 仅平台已创建并授权的公共模型 PVC 可填 |
| `HTTPRoute.host` | 须先按平台规则申请子域名 |

部署示例：

```bash
helm upgrade --install my-task ./charts/xay-ai \
  -n your-namespace \
  -f examples/helm/values-h200-epc.yaml
```

多机多卡训练（Indexed Job）：

```bash
helm upgrade --install my-dist-train ./charts/xay-ai-dist-train \
  -n your-namespace \
  -f examples/helm/values-dist-train-h200-2x2.yaml
```

## 原生 YAML

| 文件 | 说明 |
|------|------|
| `pvc-ultrastor-nfs.yaml` | NFS 共享 PVC |
| `pvc-ultrastor-epc-h200.yaml` | H200 可用的 EPC 共享 PVC |
| `deployment-gpu-workload.yaml` | GPU Deployment 示例（单机） |
| `job-multinode-h200-2nodes-8gpu.yaml` | 多机多卡 H200 Job + Headless Service（含 `ttlSecondsAfterFinished: 86400`） |
| `job-multinode-5090-2nodes-8gpu.yaml` | 多机多卡 5090 Job + Headless Service（含 `ttlSecondsAfterFinished: 86400`） |
| `job-multinode-h200-5090-separate.yaml` | H200 / 5090 分阶段两个独立 Job（含 TTL） |
| `minio-client-pod.yaml` | 临时 MinIO 客户端 Pod（云网集群内上传/下载） |
| `liantai-yunwang-minio-secret.example.yaml` | 联泰侧云网 MinIO 凭据 Secret 模板（占位符） |
| `liantai-changcan22-gpfshome-export-pod.yaml` | 联泰 GPFS → 云网 MinIO 导出 Pod（changcan22 已验证示例）；**部署前必改项见** [`data-export-minio-usage.md` §5](../docs/data-export-minio-usage.md#5-联泰-gpfs-历史数据迁入云网已验证示例) |
| `service-web.yaml` | Web Service 示例 |
| `httproute-web.yaml` | Gateway API HTTPRoute 示例 |

应用前请替换 `NameSpace`、按需替换 `ContainerImage`、域名和 PVC 名称。

Web 服务外部访问配置详见 [`../docs/web-httproute-guide.md`](../docs/web-httproute-guide.md)，访问格式为 `https://<子域名>.xa.hqzyai.com:9443/`。

## StorageClass 注意事项

- 5090 节点仅支持 `h3c-csi-sc-nfs`。
- H200 节点支持 `h3c-csi-sc-nfs` 和 `h3c-csi-sc-epc`。
- 不要将 `h3c-csi-sc-epc` 用于 5090 节点。

## MinIO 中转脚本

[`../scripts/minio/`](../scripts/minio/) 提供 Pod/本机双向上传下载脚本，用法见 [`../docs/data-export-minio-usage.md`](../docs/data-export-minio-usage.md)。
