# 运行中 Pod 原地扩缩 CPU / 内存

> **适用集群**：雄安院 K8s（API：`https://k8s-yw.hqzyai.com:6443`）  
> **日期**：2026-07-28（北京时间，UTC+8）

本文说明如何在本机终端对**正在运行**的 Pod 调大或调小 CPU / 内存，且**不重启容器、不改变 GPU 占用**。

---

## 1. 功能说明

集群支持 **In-Place Pod Resize**（原地垂直扩缩容）：直接修改当前 Pod 实例的 CPU / 内存 `requests` 与 `limits`，容器进程不中断，已占用的 GPU 不会释放。

```text
  改 Helm values / Deployment          原地 resize（本文）
  ┌─────────────────────┐             ┌─────────────────────┐
  │ 修改模板资源         │             │ patch 单个 Pod      │
  │        ↓             │             │        ↓            │
  │ 滚动重建 Pod         │             │ 容器不重启          │
  │ GPU 可能需重新调度   │             │ GPU / 节点不变      │
  └─────────────────────┘             └─────────────────────┘
```

**典型场景**

- 开发 Pod CPU 或内存跑满，重启后可能无法再次调度到 GPU；
- 调试过程中需临时加大内存，希望保留容器内已有环境；
- 仅调整**某一个 Pod 实例**，暂不修改 Helm Chart。

---

## 2. 适用边界

| 支持 | 不支持 |
|------|--------|
| 调大 / 调小 **CPU**、**内存** | 修改 **GPU 数量**（`nvidia.com/gpu`） |
| Deployment 管理的 Pod | 用 `kubectl edit deployment` 改资源（会重建 Pod） |
| 裸 Pod（`kubectl apply` 直接创建的 Pod） | 替代 namespace **ResourceQuota** 上限 |
| 本机 `kubectl patch` | 在节点资源已满时立即生效（见 §7.1） |

**Pod 类型说明**

| Pod 类型 | 是否可用 |
|----------|----------|
| `xay-ai` Deployment 下的 Pod | ✅ |
| 裸 Pod（无 Deployment 所有者） | ✅ |
| 多机训练 Job 运行中的 Pod | ✅（训练进行中可试；Completed 后无意义） |
| 节点静态 Pod（Static Pod） | ❌ 不适用 |

**持久化说明**

- 原地 resize **只影响当前 Pod 实例**。
- Deployment 管理的 Pod：滚动更新或删除重建后，会回到 Helm / Deployment 中的**原始规格**。
- 裸 Pod：删除后不会自动重建；若用旧 YAML 再次创建，规格以 YAML 为准。

---

## 3. 前置准备

### 3.1 本机 kubectl

1. 已在华清云 SaaS 下载 kubeconfig，并完成 [`kubeconfig-local-setup.md`](kubeconfig-local-setup.md) 中的配置。
2. 以下命令默认 kubeconfig 已指向雄安院集群。若使用独立配置文件，请在每条命令前加：

```bash
kubectl --kubeconfig ~/.kube/xay-config ...
```

3. 验证可访问个人 namespace：

```bash
kubectl get pods -n <NS>
```

### 3.2 权限

需要对目标 Pod 执行 `patch`（`resize` 子资源）。若命令返回 `Forbidden`，请联系平台管理员协助。

### 3.3 开始前需确认的信息

| 变量 | 含义 | 获取方式 |
|------|------|----------|
| `NS` | namespace | 华清云 SaaS 平台查看 |
| `POD` | Pod 名称 | `kubectl get pods -n "$NS"` |
| `CTR` | 容器名（**不是** Pod 名） | 见 §4.1 一键查询 |
| 目标 CPU / 内存 | 期望新规格 | 结合 quota 与业务需求 |

---

## 4. 一键查询当前规格

执行 patch 前，先设置 namespace 与 Pod 名，并拉取当前资源：

```bash
NS=<你的-namespace>
POD=<Pod-名称>

# 容器名（patch JSON 中 name 字段须与此一致）
CTR=$(kubectl -n "$NS" get pod "$POD" -o jsonpath='{.spec.containers[0].name}')
echo "container=$CTR"

# 当前资源与运行状态
kubectl -n "$NS" get pod "$POD" -o jsonpath='
node={.spec.nodeName}
restart={.status.containerStatuses[0].restartCount}
requests={.spec.containers[0].resources.requests}
limits={.spec.containers[0].resources.limits}
allocated={.status.containerStatuses[0].allocatedResources}
'
```

**查看 namespace 配额余量：**

```bash
kubectl -n "$NS" get resourcequota
kubectl -n "$NS" describe resourcequota
```

---

## 5. 命令与参数说明

### 5.1 命令结构

**预检（推荐，不真正生效）：**

```bash
kubectl -n "$NS" patch pod "$POD" \
  --subresource resize \
  --type strategic \
  --dry-run=server \
  -p '<JSON补丁>'
```

**正式执行（去掉 `--dry-run=server`）：**

```bash
kubectl -n "$NS" patch pod "$POD" \
  --subresource resize \
  --type strategic \
  -p '<JSON补丁>'
```

| 参数 | 说明 |
|------|------|
| `-n "$NS"` | Pod 所在 namespace |
| `patch pod "$POD"` | 仅修改**这一个** Pod |
| `--subresource resize` | **必填**。使用 resize 子资源；省略则无法正确原地扩缩 |
| `--type strategic` | 按容器 `name` 合并 `resources` 字段 |
| `--dry-run=server` | 服务端预检；通过后再正式执行 |
| `-p '...'` | JSON 补丁，见 §5.2 |

### 5.2 JSON 补丁格式

```json
{
  "spec": {
    "containers": [
      {
        "name": "<容器名，与 CTR 变量一致>",
        "resources": {
          "requests": {
            "cpu": "<目标CPU>",
            "memory": "<目标内存>"
          },
          "limits": {
            "cpu": "<目标CPU>",
            "memory": "<目标内存>"
          }
        }
      }
    ]
  }
}
```

| 字段 | 写法示例 | 说明 |
|------|----------|------|
| `cpu` | `"32"`、`"500m"` | 整数为核数；`500m` = 0.5 核 |
| `memory` | `"256Gi"`、`"64Gi"` | 推荐使用 `Gi` / `Mi` |

**注意**

- patch 中**只改 CPU / 内存**；**不要**写入或修改 `nvidia.com/gpu`，集群会保留原有 GPU 申请。
- 建议 `requests` 与 `limits` 设为相同值，避免 QoS 行为变化。
- 若 Pod 原本声明了 `ephemeral-storage` 等资源，扩缩容时可一并带上原值（先用 §4 命令查看 `requests` / `limits`）。

---

## 6. 操作步骤

### 步骤 1：设置变量并记录基线

```bash
NS=<你的-namespace>
POD=<Pod-名称>
CTR=$(kubectl -n "$NS" get pod "$POD" -o jsonpath='{.spec.containers[0].name}')

kubectl -n "$NS" get pod "$POD" -o jsonpath='
restart={.status.containerStatuses[0].restartCount}
allocated={.status.containerStatuses[0].allocatedResources}
'
```

记下 `restart` 与 `allocated`，供步骤 4 验收对比。

### 步骤 2：预检

将 `<目标CPU>`、`<目标内存>` 替换为实际值后执行：

```bash
kubectl -n "$NS" patch pod "$POD" \
  --subresource resize --type strategic --dry-run=server \
  -p '{"spec":{"containers":[{"name":"'"$CTR"'","resources":{"requests":{"cpu":"<目标CPU>","memory":"<目标内存>"},"limits":{"cpu":"<目标CPU>","memory":"<目标内存>"}}}]}}'
```

- 成功：输出 `pod/<POD> patched`（尚未真正生效）
- 失败：见 §7（quota 不足、权限不足等）

### 步骤 3：正式执行

去掉 `--dry-run=server`，其余不变：

```bash
kubectl -n "$NS" patch pod "$POD" \
  --subresource resize --type strategic \
  -p '{"spec":{"containers":[{"name":"'"$CTR"'","resources":{"requests":{"cpu":"<目标CPU>","memory":"<目标内存>"},"limits":{"cpu":"<目标CPU>","memory":"<目标内存>"}}}]}}'
```

### 步骤 4：验收

```bash
kubectl -n "$NS" get pod "$POD" -o wide

kubectl -n "$NS" get pod "$POD" -o jsonpath='
restart={.status.containerStatuses[0].restartCount}
allocated={.status.containerStatuses[0].allocatedResources}
gpu={.status.containerStatuses[0].allocatedResources.nvidia\.com/gpu}
'

kubectl -n "$NS" get events \
  --field-selector "involvedObject.name=$POD" \
  --sort-by='.lastTimestamp' | tail -10
```

| 检查项 | 期望 |
|--------|------|
| STATUS | `Running`，READY 正常 |
| RESTARTS | 与步骤 1 相同 |
| allocated | CPU / 内存已达目标值 |
| gpu | 与变更前相同 |
| Events | `ResizeStarted` → `ResizeCompleted` |

---

## 7. 示例

以下示例沿用 §6 中的 `NS`、`POD`、`CTR` 变量。执行前先完成 §4 的查询，确认当前 CPU / 内存后再替换目标值。

### 7.1 仅扩大 CPU

当前内存不变，仅将 CPU 的 requests / limits 改为 `"90"`（内存 `"256Gi"` 须与当前 allocated 一致）：

```bash
# 假设当前 allocated 为 cpu=64, memory=256Gi，目标 CPU=90
kubectl -n "$NS" patch pod "$POD" \
  --subresource resize --type strategic --dry-run=server \
  -p '{"spec":{"containers":[{"name":"'"$CTR"'","resources":{"requests":{"cpu":"90","memory":"256Gi"},"limits":{"cpu":"90","memory":"256Gi"}}}]}}'
```

### 7.2 仅扩大内存

CPU 不变，仅将内存改为 `"96Gi"`（CPU 值须与当前 allocated 一致）：

```bash
# 假设当前 allocated 为 cpu=8, memory=64Gi，目标 memory=96Gi
kubectl -n "$NS" patch pod "$POD" \
  --subresource resize --type strategic --dry-run=server \
  -p '{"spec":{"containers":[{"name":"'"$CTR"'","resources":{"requests":{"cpu":"8","memory":"96Gi"},"limits":{"cpu":"8","memory":"96Gi"}}}]}}'
```

### 7.3 同时扩大 CPU 与内存

```bash
# 目标：32 核 / 256Gi
kubectl -n "$NS" patch pod "$POD" \
  --subresource resize --type strategic --dry-run=server \
  -p '{"spec":{"containers":[{"name":"'"$CTR"'","resources":{"requests":{"cpu":"32","memory":"256Gi"},"limits":{"cpu":"32","memory":"256Gi"}}}]}}'
```

预检通过后，去掉 `--dry-run=server` 再次执行即正式生效。

---

## 8. 常见问题

### 8.1 `ResizeDeferred` / `PodResizePending`

**现象**：patch 成功，但 `allocated` 仍是旧值；Events 出现 `ResizeDeferred`。

**原因**：Pod 所在物理节点的 CPU 或 memory requests 合计暂时放不下本次增量。

**处理建议**

1. 适当**降低目标规格**后重新 patch（例如 128Gi 改为 96Gi）；
2. 等待同节点其它任务结束；集群会在资源释放后**自动重试**，一般无需重复 patch；
3. 若持续 Deferred，请联系平台管理员协助排查节点负载。

### 8.2 `exceeded quota`

**现象**：预检或 patch 报 `exceeded quota`。

**原因**：namespace 的 ResourceQuota 剩余额度不足。

**处理建议**：在华清云 SaaS 申请提高 quota，或释放本 namespace 内其它 Pod 的资源占用。

### 8.3 扩了 CPU 但利用率仍不高

原地 resize 仅扩大 cgroup 上限。应用侧需相应调整并行度（如 `torchrun --nproc_per_node`、DataLoader `num_workers`、OpenMP 线程数等）才会使用更多 CPU。

### 8.4 `/dev/shm` 与 memory requests

部分 GPU Pod 通过 emptyDir 挂载 `/dev/shm`（共享内存），例如 Helm values 中的 `shmSize: 128Gi`。

| 问题 | 说明 |
|------|------|
| shm 会额外占 memory requests 吗？ | **不会**。调度只看 `resources.requests.memory` |
| shm 占物理内存吗？ | **使用时**占，且与进程内存**共用** Pod 的 memory limit |
| 能否通过缩小 shm「换出」memory requests？ | **不能** |
| 运行中能否改 shm 大小？ | Pod volume 不可变；原地 resize **不会**自动放大 `/dev/shm` |

### 8.5 与 Helm 的关系

| 操作 | 影响 |
|------|------|
| `patch --subresource resize` | 仅当前 Pod 实例 |
| `helm upgrade` 修改 resources | 触发滚动更新，**会重建 Pod** |
| Pod 删除后由 Deployment 重建 | 回到 Helm values 中的原始规格 |

若需长期固定新规格，应修改 Helm values 并评估重建对 GPU 调度的影响；短期应急优先使用原地 resize。

---

## 9. 缩容（调小 CPU / 内存）

命令格式与扩容相同，将目标值改小即可。建议先预检，并在容器内确认实际用量：

```bash
kubectl -n "$NS" exec "$POD" -- free -h
kubectl -n "$NS" exec "$POD" -- nproc
```

内存下调后，若进程实际使用超过新 limit，可能触发 OOM，建议在业务低峰操作。

---

## 10. 相关文档

- [`kubeconfig-local-setup.md`](kubeconfig-local-setup.md) — 本机 kubeconfig 配置
- [`gpu-workload-scenarios.md`](gpu-workload-scenarios.md) — 单机 Deployment vs 多机 Job 选型
- [`charts/xay-ai/README.md`](../charts/xay-ai/README.md) — Helm 部署与 resources 参数
