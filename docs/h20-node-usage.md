# H20 节点使用说明

集群已新增 1 台 NVIDIA H20 GPU 节点，即日起面向所有用户开放，使用方式与现有 5090、H200 节点一致。

## 1. 节点规格

| 项目 | 参数 |
|------|------|
| GPU | 8 × NVIDIA H20（`H20-3e`，单卡显存 141 GB HBM3e） |
| CPU | 192 核 |
| 内存 | 约 1.5 TB |
| 共享存储 | `h3c-csi-sc-nfs` |
| 本地临时盘 | `local-path` |
| 驱动 / CUDA | 595.71.05 / CUDA 13.2 |
| 调度标签 | `gpu-type: H20` |
| 节点数量 | 1 台 |

## 2. 与现有卡型的差异

| 对比项 | 5090 | H200 | H20 |
|--------|------|------|-----|
| 单节点卡数 | 6～8 | 8 | 8 |
| `h3c-csi-sc-nfs` | 支持 | 支持 | 支持 |
| `h3c-csi-sc-epc` | 不支持 | 支持 | **不支持** |
| 多机多卡训练 | 支持 | 支持 | **不支持**（仅 1 台节点） |

两点需要特别留意：

- **共享存储只能用 `h3c-csi-sc-nfs`。** H20 节点未接入 EPC 存储，填写 `h3c-csi-sc-epc` 的 PVC 无法在该节点挂载。
- **仅适用于单机任务。** H20 目前只有 1 台，跨节点分布式训练请继续使用 H200 或 5090。

## 3. 使用 Helm Chart（推荐）

在 [`charts/xay-ai`](../charts/xay-ai/) 的 values 中将 `GPU` 设为 `H20` 即可，其余参数与其他卡型相同。

复制示例：

```bash
cp examples/helm/values-h20-nfs.yaml values-my-task.yaml
vi values-my-task.yaml
```

关键字段：

```yaml
NameSpace: your-namespace
BaseName: train-h20-nfs
GPU: H20

Limits:
  CPU: "16"
  memory: 64Gi
  GPU: 1

Workspace:
  enabled: true
  create: true
  storageClassName: h3c-csi-sc-nfs
  size: 200Gi
  accessModes:
    - ReadWriteMany
  mountPath: /workspace
```

部署：

```bash
helm upgrade --install my-task ./charts/xay-ai \
  -n <namespace> \
  -f values-my-task.yaml
```

Chart 会自动生成 `gpu-type: H20` 的 nodeSelector 和 GPU 节点所需的 toleration，无需手动填写调度字段。当 `GPU: H20` 且 `Workspace.storageClassName` 设为 `h3c-csi-sc-epc` 时，Helm 渲染会直接报错，提示改用 NFS。

完整参数说明见 [`charts/xay-ai/README.md`](../charts/xay-ai/README.md)。

## 4. 使用原生 YAML

不使用 Helm 时，在 Pod 模板中加入以下两段配置：

```yaml
      nodeSelector:
        gpu-type: H20
      tolerations:
        - key: nvidia.com/gpu
          operator: Exists
          effect: NoSchedule
```

GPU 卡数通过 `resources.limits` 申请：

```yaml
          resources:
            limits:
              nvidia.com/gpu: 1
```

共享目录 PVC 的 `storageClassName` 使用 `h3c-csi-sc-nfs`，可参考 [`examples/raw-yaml/pvc-ultrastor-nfs.yaml`](../examples/raw-yaml/pvc-ultrastor-nfs.yaml)。

## 5. 验证

```bash
kubectl get pod -n <namespace> -o wide
kubectl exec -it -n <namespace> <pod-name> -- nvidia-smi
kubectl exec -it -n <namespace> <pod-name> -- df -h /workspace
```

`nvidia-smi` 输出中显示 `NVIDIA H20-3e` 即表示已调度到 H20 节点。

## 6. 注意事项

- **不要在工作负载中写死 `spec.nodeName`。** 这样会绕过调度器：节点资源不足或条件不匹配时，Pod 会被节点直接拒绝，并由控制器不断重建，短时间内产生大量失败 Pod，同时占用他人排队资源。指定节点范围请统一使用 `nodeSelector` 的 `gpu-type` 标签，或 Chart 的 `GPU` 字段。
- **不要沿用 H200 配置中的 `nvidia.com/gpu.product`。** 该标签在 H20 节点上的取值为 `NVIDIA-H20-3e`，与 H200 的 `NVIDIA-H200`、5090 的 `NVIDIA-GeForce-RTX-5090` 均不同。从其他卡型的 YAML 复制后未修改，会导致 Pod 被 kubelet 以 `NodeAffinity` 原因拒绝。
- **不要在 H20 上使用 `h3c-csi-sc-epc`。** 该节点未接入 EPC 存储，PVC 会挂载失败。
- 申请的 CPU、内存、GPU、存储总量不能超过个人 namespace quota。
- `/scratch` 为节点本地临时目录，任务删除后数据一并清除；需要保留的数据请写入 `/workspace`。

## 7. 相关文档

| 文档 | 用途 |
|------|------|
| [`charts/xay-ai/README.md`](../charts/xay-ai/README.md) | Chart 完整参数说明 |
| [`examples/helm/values-h20-nfs.yaml`](../examples/helm/values-h20-nfs.yaml) | H20 + NFS values 示例 |
| [`docs/gpu-workload-scenarios.md`](gpu-workload-scenarios.md) | 单机 Deployment 与多机 Job 的选型 |
| [`docs/harbor-images.md`](harbor-images.md) | 自定义镜像 push 到个人 Harbor 项目 |
| [`docs/kubeconfig-local-setup.md`](kubeconfig-local-setup.md) | 本机 kubeconfig 配置 |
