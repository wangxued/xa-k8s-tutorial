# xay-ai-dist-train Helm Chart

`xay-ai-dist-train` 用于在雄安院 K8s 集群的个人 namespace 中部署 **多机多卡分布式训练 Job**（PyTorch `torchrun` / DeepSpeed 等）。

与 `xay-ai`（Deployment，适合单机开发、推理、SSH 常驻任务）不同，本 Chart 创建：

- **Indexed Job**：每个节点一个 Pod，自动注入 `JOB_COMPLETION_INDEX` 作为 `node_rank`
- **Headless Service**：供各 Pod 通过 DNS 解析 `MASTER_ADDR`（多机训练节点发现）
- **PersistentVolumeClaim**：可选共享工作目录（checkpoint、数据集）

完整说明见 [`../../docs/multinode-gpu-training.md`](../../docs/multinode-gpu-training.md)。**单机 vs 多机选型、Job 完成后数据复用**见 [`../../docs/gpu-workload-scenarios.md`](../../docs/gpu-workload-scenarios.md)。

## 快速开始

```bash
cp examples/helm/values-dist-train-h200-2x8.yaml values-my-dist-train.yaml
vi values-my-dist-train.yaml   # 修改 NameSpace、镜像、trainScript

helm upgrade --install my-dist-train ./charts/xay-ai-dist-train \
  -n your-namespace \
  -f values-my-dist-train.yaml
```

查看 Job 与 Pod：

```bash
kubectl get job,pod -n your-namespace -l app.kubernetes.io/instance=my-dist-train -o wide
kubectl logs -n your-namespace job/my-dist-train-dist-h200-2x8-0 -f
```

删除：

```bash
helm uninstall my-dist-train -n your-namespace
```

## 必填字段

```yaml
NameSpace: your-namespace
BaseName: dist-h200-2x8
ContainerImage: harbor.xa.hqzyai.com:19443/llm-course/lab:v2
GPU: H200
Limits:
  GPU: 8
Distributed:
  nodes: 2
```

## 多机参数

| 字段 | 说明 |
|------|------|
| `Distributed.nodes` | 参与训练的节点数（Job `completions` / `parallelism`） |
| `Limits.GPU` | 每个 Pod 申请的 GPU 卡数（`NPROC_PER_NODE`） |
| `Distributed.masterPort` | torchrun 主端口，默认 `29500` |
| `Distributed.trainScript` | 训练入口脚本路径 |
| `Distributed.spreadAcrossNodes` | 是否强制各 Pod 调度到不同物理节点 |
| `HeadlessService.enabled` | 是否创建 Headless Service（多机训练建议 `true`） |
| `ttlSecondsAfterFinished` | Job 完成后保留时长（秒），默认 `86400`（24h），到期自动删除 Job/Pod；**不删除 PVC** |

总占用 GPU 卡数 = `Distributed.nodes` × `Limits.GPU`。须不超过个人 namespace quota。

## Job 完成后的清理与数据

- 训练 **Succeeded / Failed** 后，Pod 进入 **Completed**，在 `ttlSecondsAfterFinished` 窗口内可用 `kubectl logs` / `kubectl exec` 查看。
- TTL 到期后 Job 与 Pod 被删除，**GPU 释放**；写入 **`/workspace` 共享 PVC** 的 checkpoint **仍保留**。
- Pod 删除后复用数据：新建 `xay-ai` 或 `xay-ai-dist-train` release，设置 `Workspace.create: false` 与 `Workspace.claimName: <原 PVC 名>`。

操作示例见 [`../../docs/gpu-workload-scenarios.md`](../../docs/gpu-workload-scenarios.md) §4–§5。

## StorageClass

| GPU | 推荐 StorageClass |
|-----|-------------------|
| H200 | `h3c-csi-sc-epc` 或 `h3c-csi-sc-nfs` |
| 5090 | **`h3c-csi-sc-nfs` 仅** |

5090 使用 EPC 会导致 PVC 或挂载失败。

## Headless Service 是否必需？

多机 `torchrun` / NCCL 需要各 Pod 能解析 rank 0 的地址作为 `MASTER_ADDR`。Headless Service + Job `subdomain` 提供稳定 DNS（如 `my-job-0.my-job`）。

- **多机训练**：保持 `HeadlessService.enabled: true`
- **单机多卡**：不需要本 Chart；请使用 [`xay-ai`](../xay-ai/README.md) 并将 `Limits.GPU` 设为 8

## 示例 values

| 文件 | 场景 |
|------|------|
| [`values-dist-train-h200-2x8.yaml`](../../examples/helm/values-dist-train-h200-2x8.yaml) | 2×H200×8 卡，EPC |
| [`values-dist-train-5090-2x8.yaml`](../../examples/helm/values-dist-train-5090-2x8.yaml) | 2×5090×8 卡，NFS |

## 与 xay-ai Service 的区别

| 类型 | 用途 |
|------|------|
| `xay-ai` 的 ClusterIP Service | 对外暴露 SSH、Web 端口（开发/推理） |
| 本 Chart 的 Headless Service | **集群内 DNS**，供训练 Pod 互连，不用于浏览器或 SSH 访问 |

训练任务一般 **不需要** 可对外访问的 Service；Headless Service 仅用于分布式进程组网。
