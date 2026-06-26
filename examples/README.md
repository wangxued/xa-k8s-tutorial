# 示例目录

本目录包含两类示例：

- [`helm/`](helm/)：配合 `charts/xay-ai` 使用的 values 文件。
- [`raw-yaml/`](raw-yaml/)：不使用 Helm 时可参考的原生 Kubernetes YAML。

## Helm values

| 文件 | 适用场景 |
|------|----------|
| `values-5090-nfs.yaml` | 5090 节点，使用 `h3c-csi-sc-nfs` |
| `values-h200-nfs.yaml` | H200 节点，使用 `h3c-csi-sc-nfs` |
| `values-h200-epc.yaml` | H200 节点，使用 `h3c-csi-sc-epc` |
| `values-web-httproute.yaml` | 需要通过 HTTPRoute 暴露 Web 服务 |
| `values-shared-models.yaml` | 只读挂载公共模型权重 |

默认镜像为 `harbor.xa.hqzyai.com:19443/llm-course/lab:v2`。外部 Registry 镜像经雄安 Harbor 代理项目拉取，路径规则见 [`../docs/harbor-images.md`](../docs/harbor-images.md)。

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

## 原生 YAML

| 文件 | 说明 |
|------|------|
| `pvc-ultrastor-nfs.yaml` | NFS 共享 PVC |
| `pvc-ultrastor-epc-h200.yaml` | H200 可用的 EPC 共享 PVC |
| `deployment-gpu-workload.yaml` | GPU Deployment 示例 |
| `service-web.yaml` | Web Service 示例 |
| `httproute-web.yaml` | Gateway API HTTPRoute 示例 |

应用前请替换 `NameSpace`、按需替换 `ContainerImage`、域名和 PVC 名称。

Web 服务外部访问配置详见 [`../docs/web-httproute-guide.md`](../docs/web-httproute-guide.md)，访问格式为 `https://<子域名>.xa.hqzyai.com:9443/`。

## StorageClass 注意事项

- 5090 节点仅支持 `h3c-csi-sc-nfs`。
- H200 节点支持 `h3c-csi-sc-nfs` 和 `h3c-csi-sc-epc`。
- 不要将 `h3c-csi-sc-epc` 用于 5090 节点。
