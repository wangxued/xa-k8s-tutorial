# 雄安院 K8s 用户教程

本仓库提供面向用户的雄安院 K8s 集群终端使用教程。平台侧账号、namespace、kubeconfig、Harbor 账号和资源管理入口统一通过华清云 SaaS 提供；本仓库重点说明如何在本机终端使用 `kubeconfig`、`kubectl`、`helm` 和示例 YAML 管理个人 namespace 内的 K8s 资源。

## 重要入口

| 系统 | 地址 | 用途 |
|------|------|------|
| 华清云 SaaS | <https://xaai.hqzyai.com:19443/> | 统一登录、查看 namespace、下载 kubeconfig、查看 Harbor 账号、平台侧资源管理 |
| SaaS 帮助文档 | <https://saasdoc.xa.hqzyai.com:19443/> | 平台侧功能说明 |
| K8s API | `https://k8s-yw.hqzyai.com:6443` | kubeconfig 访问集群 API |
| Harbor | <https://harbor.xa.hqzyai.com:19443/> | 私有镜像仓库；示例默认镜像 `llm-course/lab:v2`，详见 [`docs/harbor-images.md`](docs/harbor-images.md) |

## 使用边界

华清云 SaaS 负责账号和资源入口：

- 查看专属 namespace。
- 下载专属 kubeconfig。
- 查看 Harbor 专属账号。
- 在平台侧创建和管理资源。
- 查看平台侧操作说明。

本仓库负责本机终端使用教程：

- 安装 `kubectl` 和 `helm`。
- 配置 kubeconfig。
- 在本机终端访问个人 namespace。
- 使用 Helm Chart 或原生 YAML 部署工作负载。
- 使用 VS Code 连接 K8s 资源进行开发和调试。

## 快速开始

1. 联系平台管理员创建账号。
2. 使用账号登录华清云 SaaS。
3. 在 SaaS 平台查看专属 namespace，并下载 kubeconfig。
4. 按 [`docs/kubeconfig-local-setup.md`](docs/kubeconfig-local-setup.md) 配置本机 kubeconfig。
5. 使用 `kubectl` 验证访问：

```bash
kubectl get pods
kubectl get pvc
```

6. 使用 `xay-ai` Helm Chart 部署任务：

```bash
cp examples/helm/values-h200-epc.yaml values-my-task.yaml
vi values-my-task.yaml

helm upgrade --install my-task ./charts/xay-ai \
  -n <namespace> \
  -f values-my-task.yaml
```

详细参数见 [`charts/xay-ai/README.md`](charts/xay-ai/README.md)。Harbor 镜像与个人项目说明见 [`docs/harbor-images.md`](docs/harbor-images.md)。

## 单机开发 vs 多机训练

| 场景 | Chart | 资源类型 |
|------|-------|----------|
| SSH 进容器写代码、单机调试、Jupyter、长期占 1～8 卡 | [`xay-ai`](charts/xay-ai/) | **Deployment** |
| 跨多台 GPU 节点跑 `torchrun` / DeepSpeed | [`xay-ai-dist-train`](charts/xay-ai-dist-train/) | **Indexed Job** |

完整对照（gpu-gc 回收、`ttlSecondsAfterFinished`、训练完成后如何复用 PVC 数据）见 **[GPU 工作负载场景选型](docs/gpu-workload-scenarios.md)**。

## 多机多卡训练（传送门）

单机 1~8 卡开发/训练继续使用 [`xay-ai`](charts/xay-ai/)。**跨多台 GPU 节点的分布式训练**（PyTorch `torchrun`、DeepSpeed 等）请使用专用 Job 方案：

| 入口 | 说明 |
|------|------|
| **[GPU 工作负载场景选型](docs/gpu-workload-scenarios.md)** | **单机 Deployment vs 多机 Job**、TTL、Completed 后数据复用 |
| **[多机多卡训练使用说明](docs/multinode-gpu-training.md)** | 原理、Headless Service 说明、H200/5090/混合场景、排障 |
| [`charts/xay-ai-dist-train/`](charts/xay-ai-dist-train/) | 多机多卡 Helm Chart（Indexed Job + Headless Service） |
| [`examples/helm/values-dist-train-h200-2x2.yaml`](examples/helm/values-dist-train-h200-2x2.yaml) | 2×H200×2 卡（4 卡，推荐起步） |
| [`examples/helm/values-dist-train-5090-2x2.yaml`](examples/helm/values-dist-train-5090-2x2.yaml) | 2×5090×2 卡（4 卡，推荐起步） |
| [`examples/helm/values-dist-train-h200-2x8.yaml`](examples/helm/values-dist-train-h200-2x8.yaml) | 2×H200×8 卡（16 卡，需 quota≥16） |
| [`examples/helm/values-dist-train-5090-2x8.yaml`](examples/helm/values-dist-train-5090-2x8.yaml) | 2×5090×8 卡（16 卡，需 quota≥16） |
| [`examples/raw-yaml/job-multinode-h200-2nodes-8gpu.yaml`](examples/raw-yaml/job-multinode-h200-2nodes-8gpu.yaml) | H200 原生 YAML |
| [`examples/raw-yaml/job-multinode-5090-2nodes-8gpu.yaml`](examples/raw-yaml/job-multinode-5090-2nodes-8gpu.yaml) | 5090 原生 YAML |
| [`examples/raw-yaml/job-multinode-h200-5090-separate.yaml`](examples/raw-yaml/job-multinode-h200-5090-separate.yaml) | H200 + 5090 分阶段（两个独立 Job） |

快速部署：

```bash
cp examples/helm/values-dist-train-h200-2x2.yaml values-my-dist-train.yaml
vi values-my-dist-train.yaml

helm upgrade --install my-dist-train ./charts/xay-ai-dist-train \
  -n your-namespace \
  -f values-my-dist-train.yaml
```

> **说明**：多机训练需要集群内 **Headless Service** 做节点 DNS 发现（`MASTER_ADDR`），与 SSH/Web 用的 ClusterIP Service 不同。详见 [多机多卡训练使用说明 — 训练中是否需要 Service？](docs/multinode-gpu-training.md#2-训练中是否需要-service)。

## 存储选择

| 场景 | 推荐方式 | 说明 |
|------|----------|------|
| 临时缓存、编译中间文件、短期 checkpoint | `local-path` scratch PVC | 节点本地存储，适合单任务临时数据，不作为长期保存位置 |
| **任务结果导出到办公网** | **data-export MinIO** | 临时 S3 中转（Pod 上传 → 本机下载），14 天自动清理 |
| **办公网数据导入 Pod** | **data-export MinIO** | 临时 S3 中转（本机上传 → Pod 下载），见 [data-export-minio-usage.md](docs/data-export-minio-usage.md) |
| 5090 节点共享数据 | `h3c-csi-sc-nfs` | 5090 节点仅支持该共享 StorageClass |
| H200 节点共享数据 | `h3c-csi-sc-nfs` 或 `h3c-csi-sc-epc` | H200 支持 NFS 和 EPC |

StorageClass 支持矩阵：

| GPU 类型 | `h3c-csi-sc-nfs` | `h3c-csi-sc-epc` |
|----------|------------------|------------------|
| 5090 | 支持 | 不支持 |
| H200 | 支持 | 支持 |

## 文档索引

| 文档 | 用途 |
|------|------|
| [`docs/kubeconfig-local-setup.md`](docs/kubeconfig-local-setup.md) | 本机 kubeconfig 配置、多集群管理、Lens/VS Code context 重复排查 |
| [`charts/xay-ai/README.md`](charts/xay-ai/README.md) | Helm Chart 参数、GPU/StorageClass、PVC、共享内存、HTTPRoute 配置 |
| [`docs/harbor-images.md`](docs/harbor-images.md) | Harbor 地址、个人项目、登录 push/pull、在 K8s 中使用 |
| [`docs/web-httproute-guide.md`](docs/web-httproute-guide.md) | Web 服务外部域名、HTTPRoute、`https://<域名>:9443/` 访问说明 |
| [`docs/data-export-minio-usage.md`](docs/data-export-minio-usage.md) | **数据导出 MinIO**：Pod ↔ 办公网双向中转、脚本与 NFS/EPC 分工 |
| [`docs/gpu-workload-scenarios.md`](docs/gpu-workload-scenarios.md) | **单机 vs 多机选型**、Job TTL、训练完成后数据复用 |
| [`docs/multinode-gpu-training.md`](docs/multinode-gpu-training.md) | **多机多卡训练**：Job、Headless Service、H200/5090 场景 |
| [`charts/xay-ai-dist-train/README.md`](charts/xay-ai-dist-train/README.md) | 多机多卡 Helm Chart 参数 |
| [`examples/README.md`](examples/README.md) | Helm values 和原生 YAML 示例说明 |

## 示例入口

| 目录 | 内容 |
|------|------|
| [`examples/helm/`](examples/helm/) | `xay-ai` / `xay-ai-dist-train` values：5090+NFS、H200+EPC、多机多卡、Web HTTPRoute |
| [`examples/raw-yaml/`](examples/raw-yaml/) | PVC、Deployment、多机 Job、HTTPRoute 等原生 YAML |

## 常用命令

```bash
kubectl get pod,svc,pvc
kubectl get events --sort-by=.lastTimestamp
kubectl describe pod <pod-name>
kubectl logs <pod-name> --tail=100
kubectl exec -it <pod-name> -- bash
kubectl exec -it <pod-name> -- nvidia-smi
kubectl exec -it <pod-name> -- df -h
```

## 注意事项

- 只在个人 namespace 中创建和管理资源。
- 申请的 CPU、内存、GPU、存储总量不能超过 namespace quota。
- 5090 节点不要使用 `h3c-csi-sc-epc`。
- `/scratch` 是临时数据目录，任务删除后对应 PVC 也会删除。
- Web 域名需要按平台规则申请后再写入 `HTTPRoute`，访问格式为 `https://<子域名>.xa.hqzyai.com:9443/`。
