# 多机多卡 GPU 训练使用说明

> **适用集群**：雄安院 K8s（`yw-k8s`）  
> **日期**：2026-06-28

---

## 1. 概述

集群按 **整卡** 调度 GPU（`nvidia.com/gpu`）。多机多卡分布式训练应使用 **Job**（或本仓库 [`xay-ai-dist-train`](../charts/xay-ai-dist-train/) Chart），**不宜**通过调大 [`xay-ai`](../charts/xay-ai/) Deployment 的 `Replicas` 实现——多个 Deployment 副本彼此独立，不会自动组成 `torchrun` 进程组。

**单机开发 vs 多机训练**（Deployment / Job 选型、gpu-gc、训练完成后数据复用）见 **[`gpu-workload-scenarios.md`](gpu-workload-scenarios.md)**。

> **术语说明**：**DeepSpeed** 是微软开源的分布式训练加速库（常与 `torchrun` 联用），与 **DeepSeek**（大模型品牌）无关；文档中的 DeepSpeed 均指训练框架。

| 场景 | 是否推荐 | 示例 |
|------|----------|------|
| 多台 H200 协同训练 | ✅ | [`job-multinode-h200-2nodes-8gpu.yaml`](../examples/raw-yaml/job-multinode-h200-2nodes-8gpu.yaml) |
| 多台 RTX 5090 协同训练 | ✅ | [`job-multinode-5090-2nodes-8gpu.yaml`](../examples/raw-yaml/job-multinode-5090-2nodes-8gpu.yaml) |
| H200 与 5090 同一 NCCL 任务 | ❌ | 见 [`job-multinode-h200-5090-separate.yaml`](../examples/raw-yaml/job-multinode-h200-5090-separate.yaml) |

---

## 2. 训练中是否需要 Service？

**取决于 workload 类型，不要与 SSH/Web 用的 Service 混淆。**

| Service 类型 | 训练是否需要 | 作用 |
|--------------|--------------|------|
| **Headless Service**（`clusterIP: None`） | **多机训练需要** | 为 Job Pod 提供 DNS，解析 `MASTER_ADDR`（如 `dist-train-h200-0.dist-train-h200`），供 `torchrun` / NCCL 组网 |
| **ClusterIP Service**（`xay-ai` 默认 SSH/Web） | **训练一般不需要** | 暴露 22、7860 等端口，供开发调试或 Web 推理访问 |
| **HTTPRoute** | **训练不需要** | 公网 HTTPS 入口 |

结论：

- **单机 8 卡训练**：不需要 Headless Service；使用 `xay-ai` Deployment 即可。
- **多机多卡训练**：需要 **Headless Service**（本仓库示例与 `xay-ai-dist-train` Chart 已包含）；**不需要** 对外 ClusterIP/HTTPRoute，除非同时要 SSH 进某个 Pod 调试。

Headless Service **不对外提供访问入口**，仅在集群内做 Pod 间 DNS 发现。

---

## 3. 基础规则

### 3.1 单 Pod 与 Deployment 的区别

| 维度 | 说明 |
|------|------|
| **单个 Pod** | 只能在一台 GPU 节点上；最多占满该节点全部 GPU（H200 / 多数 5090 为 **8 卡**，`yw-gpu-18` 为 **6 卡**） |
| **Deployment 多副本** | 副本可分布在多节点，但 **不会** 自动做分布式训练 |
| **Indexed Job** | 每个 Pod 获得 `JOB_COMPLETION_INDEX`（node rank），适合 `torchrun` |

### 3.2 GPU 节点与存储

| 节点组 | 可调度 GPU | 推荐共享存储 |
|--------|------------|--------------|
| H200（`yw-gpu-33`~`40`） | 8 卡/台 | `h3c-csi-sc-epc` 或 `h3c-csi-sc-nfs` |
| 5090（`yw-gpu-19`~`23`） | 8 卡/台 | `h3c-csi-sc-nfs` |
| 5090（`yw-gpu-18`） | **6 卡** | `h3c-csi-sc-nfs` |

5090 **不可** 使用 `h3c-csi-sc-epc`。

### 3.3 调度必备项

```yaml
tolerations:
  - key: nvidia.com/gpu
    operator: Exists
    effect: NoSchedule
nodeSelector:
  gpu-type: H200    # 或 "5090"
```

---

## 4. 多机多卡架构（Indexed Job + Headless Service）

```text
┌─────────────────────────────────────────────────────────────┐
│  Job: dist-train-h200  (completions=2, parallelism=2)       │
├──────────────────────────┬──────────────────────────────────┤
│  Pod dist-train-h200-0   │  Pod dist-train-h200-1           │
│  NODE_RANK=0             │  NODE_RANK=1                     │
│  8× H200                 │  8× H200                         │
└──────────────────────────┴──────────────────────────────────┘
         │                              │
         └──────── torchrun / NCCL ─────┘
              MASTER_ADDR=dist-train-h200-0.dist-train-h200
                    ↑ Headless Service DNS
```

---

## 5. 部署方式

### 5.1 Helm（推荐）

```bash
# 建议先从 2 节点 × 2 卡（共 4 卡）起步，再按需放大
cp examples/helm/values-dist-train-h200-2x2.yaml values-my-train.yaml
vi values-my-train.yaml

helm upgrade --install my-train ./charts/xay-ai-dist-train \
  -n your-namespace \
  -f values-my-train.yaml
```

| 规模 | H200 values | 5090 values |
|------|-------------|-------------|
| 2 节点 × 2 卡（推荐起步） | [`values-dist-train-h200-2x2.yaml`](../examples/helm/values-dist-train-h200-2x2.yaml) | [`values-dist-train-5090-2x2.yaml`](../examples/helm/values-dist-train-5090-2x2.yaml) |
| 2 节点 × 8 卡（占满单 namespace 16 卡 quota） | [`values-dist-train-h200-2x8.yaml`](../examples/helm/values-dist-train-h200-2x8.yaml) | [`values-dist-train-5090-2x8.yaml`](../examples/helm/values-dist-train-5090-2x8.yaml) |

Chart 参数详见 [`charts/xay-ai-dist-train/README.md`](../charts/xay-ai-dist-train/README.md)。

Job 默认在完成后 **24 小时** 自动清理（`ttlSecondsAfterFinished: 86400`）；checkpoint 须写入共享 PVC（`/workspace`），Pod 删除后仍可通过新 Deployment/Job 挂载同一 PVC 复用。详见 [`gpu-workload-scenarios.md`](gpu-workload-scenarios.md) §4–§5。

### 5.2 原生 YAML

```bash
# 替换 YAML 中 your-namespace 后执行
kubectl apply -f examples/raw-yaml/job-multinode-h200-2nodes-8gpu.yaml
kubectl get pods -n your-namespace -l app=dist-train-h200 -o wide
kubectl logs -n your-namespace dist-train-h200-0 -f
```

---

## 6. 场景说明

### 6.1 多台 H200（2 节点 × 8 卡 = 16 卡）

- 共享 checkpoint 优先 `h3c-csi-sc-epc`
- 调整规模：修改 `completions` / `Distributed.nodes` 与 `NNODES`

### 6.2 多台 5090

- 必须使用 `h3c-csi-sc-nfs`
- 排除 `yw-gpu-18` 或改为 6 卡/request（见 [`values-dist-train-5090-2x8.yaml`](../examples/helm/values-dist-train-5090-2x8.yaml) 注释）

### 6.3 H200 与 5090 同时使用

**同一 torchrun 任务不可跨 H200 与 5090。**

推荐：H200 Job 完成预训练 → 导出权重到 NFS → 5090 Job 微调。示例见 [`job-multinode-h200-5090-separate.yaml`](../examples/raw-yaml/job-multinode-h200-5090-separate.yaml)。

---

## 7. torchrun 启动参考

```bash
node_rank="${JOB_COMPLETION_INDEX:-0}"
torchrun \
  --nnodes="${NNODES}" \
  --nproc_per_node="${NPROC_PER_NODE}" \
  --node_rank="${node_rank}" \
  --master_addr="${MASTER_ADDR}" \
  --master_port="${MASTER_PORT}" \
  /workspace/train.py
```

DeepSpeed 用户可替换为：

```bash
deepspeed --num_nodes="${NNODES}" \
  --num_gpus="${NPROC_PER_NODE}" \
  --master_addr="${MASTER_ADDR}" \
  --master_port="${MASTER_PORT}" \
  --node_rank="${JOB_COMPLETION_INDEX}" \
  /workspace/train.py
```

---

## 8. 常见问题

| 现象 | 可能原因 | 处理 |
|------|----------|------|
| Pod Pending | GPU 不足或 anti-affinity 无足够节点 | 减少节点数或释放 GPU |
| PVC 无法挂载 | 5090 误用 EPC | 改为 `h3c-csi-sc-nfs` |
| NCCL 超时 | DNS / 网络 | 确认 Headless Service 存在；设置 `NCCL_DEBUG=INFO` |
| 仅 rank 0 运行 | 未用 torchrun | 勿直接 `python train.py` |
| GPU 被回收 | 长期低利用率 | 见平台 GPU 空闲回收策略 |

---

## 9. 与单机训练的选型

详见 **[`gpu-workload-scenarios.md`](gpu-workload-scenarios.md)**（对照表、gpu-gc、`ttlSecondsAfterFinished`、Completed Pod 数据复用）。

| 需求 | 推荐 |
|------|------|
| 单机 1~8 卡，SSH 开发 | [`xay-ai`](../charts/xay-ai/) + [`values-h200-epc.yaml`](../examples/helm/values-h200-epc.yaml) |
| 单机 8 卡训练 | [`xay-ai`](../charts/xay-ai/) + `Limits.GPU: 8` + `Strategy.type: Recreate` |
| 多机多卡训练 | [`xay-ai-dist-train`](../charts/xay-ai-dist-train/) 或本文 Job YAML |

---

## 10. 相关文档

| 文档 | 说明 |
|------|------|
| [`gpu-workload-scenarios.md`](gpu-workload-scenarios.md) | 单机 vs 多机、TTL、Completed 数据复用 |
| [`charts/xay-ai-dist-train/README.md`](../charts/xay-ai-dist-train/README.md) | Helm Chart 参数 |
| [`examples/README.md`](../examples/README.md) | 全部示例索引 |
| [`README.md`](../README.md) | 仓库总览与快速入口 |

---

## 11. 变更记录

| 日期 | 说明 |
|------|------|
| 2026-06-28 | 补充 TTL、Completed 数据复用；交叉引用 gpu-workload-scenarios |
