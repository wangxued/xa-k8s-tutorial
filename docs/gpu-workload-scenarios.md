# GPU 工作负载场景选型：单机开发 vs 多机训练

> **适用集群**：雄安院 K8s（`yw-k8s`）  
> **日期**：2026-06-28

---

## 1. 一句话怎么选

| 目标 | 使用 | Chart / 资源类型 |
|------|------|------------------|
| SSH 进容器写代码、单机调试、Jupyter、长期占 1～8 卡 | **单机开发** | [`xay-ai`](../charts/xay-ai/) → **Deployment** |
| 跨多台 GPU 节点跑 `torchrun` / DeepSpeed 分布式训练 | **多机训练** | [`xay-ai-dist-train`](../charts/xay-ai-dist-train/) → **Indexed Job** |

**不宜**通过把 Deployment 的 `Replicas` 调大来做多机训练——各副本彼此独立，不会自动组成分布式进程组。

---

## 2. 对比表

| 维度 | 单机开发（Deployment） | 多机训练（Job） |
|------|------------------------|-----------------|
| Chart | `xay-ai` | `xay-ai-dist-train` |
| 典型用途 | 交互开发、推理服务、单机 8 卡训练 | 2+ 节点协同训练 |
| Pod 生命周期 | **常驻**（如 `sleep` / SSH） | 训练结束 → **Completed** |
| 多机组网 | ❌ 不支持 | ✅ `torchrun` + Headless Service |
| SSH / Web | ✅ 可选 Service / HTTPRoute | ❌ 一般不需要 |
| GPU 空闲回收（gpu-gc） | ✅ 支持缩容 Deployment | ❌ 当前不回收 Job（训练结束应自行退出） |
| 示例 values | `values-h200-epc.yaml` | `values-dist-train-h200-2x2.yaml` |

详细多机说明见 [`multinode-gpu-training.md`](multinode-gpu-training.md)。

---

## 3. 部署命令

### 3.1 单机开发

```bash
cp examples/helm/values-h200-epc.yaml values-my-dev.yaml
vi values-my-dev.yaml   # 填写 NameSpace、镜像等

helm upgrade --install my-dev ./charts/xay-ai \
  -n your-namespace \
  -f values-my-dev.yaml

kubectl exec -it deploy/<deployment-name> -- bash
```

### 3.2 多机训练

```bash
cp examples/helm/values-dist-train-h200-2x2.yaml values-my-train.yaml
vi values-my-train.yaml

helm upgrade --install my-train ./charts/xay-ai-dist-train \
  -n your-namespace \
  -f values-my-train.yaml

kubectl get job,pod -n your-namespace -l app.kubernetes.io/instance=my-train -o wide
kubectl logs -n your-namespace -l app.kubernetes.io/instance=my-train --tail=100
```

---

## 4. Job 完成后的自动清理（ttlSecondsAfterFinished）

多机训练 Job 默认设置：

```yaml
ttlSecondsAfterFinished: 86400   # 完成后保留 24 小时，再自动删除 Job 及 Completed Pod
```

含义：

- 训练 **Succeeded / Failed** 后，Job 与 Pod 仍保留一段时间，便于查日志、短暂进容器核对文件。
- 超过 TTL 后，控制面 **自动删除 Job 和 Pod**，**GPU 随之释放**。
- **不会删除 PVC**：写入共享工作目录（`/workspace`）的数据仍保留在 PVC 中。

调整方式（Helm values）：

```yaml
ttlSecondsAfterFinished: 86400    # 默认 24h
# ttlSecondsAfterFinished: 172800 # 改为 48h
# ttlSecondsAfterFinished: 3600   # 改为 1h，更快释放 GPU
```

原生 YAML 示例中已包含同名字段。

---

## 5. 训练完成后如何查看与复用数据

### 5.1 原则：产物写共享 PVC，不要只写在 Pod 内

| 存储位置 | Job Pod 被 TTL 删除后 |
|----------|----------------------|
| **`/workspace`（NFS/EPC 共享 PVC）** | ✅ **数据仍在**，可挂载到新任务 |
| **`/scratch`（local-path）** | ❌ 随 Pod/节点绑定，**不可依赖** |
| **容器内未挂载路径**（如 `/tmp`） | ❌ **随 Pod 删除而丢失** |

训练脚本请将 checkpoint、日志、导出权重写入 **`Workspace.mountPath`**（默认 `/workspace`）。

### 5.2 Job 仍为 Completed 时（TTL 窗口内）

```bash
# 查看 Job / Pod 状态
kubectl get job,pod -n your-namespace -l app.kubernetes.io/instance=my-train

# 查看训练日志（Pod 名以实际为准）
kubectl logs -n your-namespace <pod-name> --tail=200

# 列出 rank 0 Pod 内工作目录（Completed Pod 在 TTL 内通常仍可 exec）
kubectl exec -n your-namespace <pod-name> -- ls -la /workspace

# 从 Pod 拷出单个文件到本机（可选）
kubectl cp your-namespace/<pod-name>:/workspace/output ./output
```

多个 rank Pod 写入同一共享 PVC 时，**只需查看 rank 0 或任意一个 Pod**，文件系统内容一致。

### 5.3 Job 已被 TTL 删除后（推荐做法）

Pod 消失后，**共享 PVC 中的数据不受影响**。复用方式：

**方式 A：新的单机开发任务挂载同一 PVC**

```yaml
# xay-ai values 片段
Workspace:
  enabled: true
  create: false
  claimName: pvc-workspace-your-namespace-my-train-dist-h200-2x2   # 上一任务创建的 PVC 名
  mountPath: /workspace
```

```bash
helm upgrade --install my-inspect ./charts/xay-ai \
  -n your-namespace \
  -f values-reuse-workspace.yaml

kubectl exec -it deploy/<新-deployment名> -- bash
ls /workspace
```

**方式 B：新的训练 Job 挂载同一 PVC**

```yaml
Workspace:
  enabled: true
  create: false
  claimName: pvc-workspace-your-namespace-my-train-dist-h200-2x2
  mountPath: /workspace
```

**方式 C：查 PVC 名称**

```bash
kubectl get pvc -n your-namespace
# 查找 app.kubernetes.io/instance=<release名> 或名称含 dist-train 的 workspace PVC
```

Helm release 创建的 workspace PVC 默认命名规则：`pvc-workspace-<namespace>-<release名>-<BaseName>`（见 Chart 模板）。

### 5.4 从共享卷拷数据到本机（Pod 已删时）

临时起一个无 GPU 的调试 Pod 挂载 PVC（示例）：

```bash
kubectl run pvc-inspect -n your-namespace --rm -it \
  --image=harbor.xa.hqzyai.com:19443/llm-course/lab:v2 \
  --overrides='{
    "spec": {
      "containers": [{
        "name": "pvc-inspect",
        "image": "harbor.xa.hqzyai.com:19443/llm-course/lab:v2",
        "command": ["bash"],
        "stdin": true,
        "tty": true,
        "volumeMounts": [{"name": "data", "mountPath": "/workspace"}]
      }],
      "volumes": [{
        "name": "data",
        "persistentVolumeClaim": {"claimName": "<your-pvc-name>"}
      }]
    }
  }' -- bash
```

在容器内查看 `/workspace`，另开终端执行 `kubectl cp` 拷出所需文件。

---

## 6. 平台 GPU 空闲回收（gpu-gc）说明

- **Deployment**（`xay-ai`）：GPU 持续空闲超过约 2 小时可能被平台 **缩容至 0**。
- **Job**（`xay-ai-dist-train`）：当前 **不在 gpu-gc 回收范围内**；应在训练脚本正常退出，依赖 Job 完成 + `ttlSecondsAfterFinished` 释放 GPU。

若在 Job 内长期运行 `sleep infinity` 占卡，GPU 不会被 gpu-gc 自动回收。

---

## 7. 相关文档

| 文档 | 说明 |
|------|------|
| [`multinode-gpu-training.md`](multinode-gpu-training.md) | 多机架构、Headless Service、H200/5090 |
| [`charts/xay-ai/README.md`](../charts/xay-ai/README.md) | 单机 Deployment 参数 |
| [`charts/xay-ai-dist-train/README.md`](../charts/xay-ai-dist-train/README.md) | 多机 Job 参数 |
| [`examples/README.md`](../examples/README.md) | values 与 YAML 索引 |

---

## 8. 变更记录

| 日期 | 说明 |
|------|------|
| 2026-06-28 | 初版：单机/多机选型、TTL、Completed 数据复用 |
