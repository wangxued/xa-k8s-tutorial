# 平台 GPU 空闲回收说明

> **适用集群**：雄安院 K8s（`yw-k8s`）  
> **日期**：2026-08-13（北京时间，UTC+8）

平台已启用 GPU 空闲巡检与自动释放，用于回收长时间占卡但几乎没有实际计算的资源。本文说明当前规则、影响范围，以及被标记或缩容后如何恢复。

**一句话**：不是「空闲 1 小时就清理」，而是「最近连续 2 小时 GPU 利用率峰值始终低于 5%，且下一轮巡检仍然如此，才会释放」。

---

## 1. 适用范围

| 工作负载 | Chart / 典型场景 | gpu-gc 是否回收 |
|----------|------------------|-----------------|
| **Deployment** | [`xay-ai`](../charts/xay-ai/)：SSH、Jupyter、推理、长期占卡开发 | **会**。持续空闲后缩容（常见为副本数变为 `0`，Pod 消失） |
| **StatefulSet** | 自行创建的有状态 GPU 服务 | **会**。同样按空闲副本缩容 |
| **裸 Pod** | 无 Deployment/Job 归属的 `kubectl run` 等 | **会**。确认空闲后**删除 Pod** |
| **Job** | [`xay-ai-dist-train`](../charts/xay-ai-dist-train/)：多机训练 | **不会**。训练应自行退出；完成后靠 `ttlSecondsAfterFinished` 清理 |
| **DaemonSet** | 节点级组件 | **不会** |

`xay-ai` 创建的是 Deployment，是用户侧最常见的回收对象。

Job 与 gpu-gc 是两套机制：

| 机制 | 作用对象 | 何时释放 GPU |
|------|----------|--------------|
| **gpu-gc**（本文） | 仍在运行、但 GPU 几乎不用的 Deployment 等 | 持续空闲并经两阶段确认后 |
| **Job TTL** | 已 Succeeded / Failed 的 Job | `ttlSecondsAfterFinished` 到期后（默认 24 小时） |

若在 Job 内长期运行 `sleep infinity` 占卡，gpu-gc **不会**回收该 Job，GPU 会一直被占用，直到手动删除或 TTL 在 Job 完成后生效。多机训练请让脚本正常退出。

---

## 2. 释放规则

- 系统大约每 **30 分钟**巡检一次占用 GPU 的 Pod。
- 判定依据是 **GPU 利用率**，看的是**最近 2 小时内的峰值**，不是 2 小时平均值。
- 最近连续 2 小时内利用率峰值始终低于 **5%**，判定为「持续空闲」。
- **第一次**判定为空闲时只打标记，**不立即释放**。
- **下一轮**巡检仍满足空闲条件，才执行缩容或删除。

时间线示意：

```text
        |<-------- 最近 2 小时 GPU 利用率峰值 < 5% -------->|
        |                                                  |
占用 GPU 但几乎无计算 ...          第 1 轮巡检：只打标
                                             约 30 分钟后
                                   第 2 轮巡检仍空闲：才缩容 / 删除
```

因此：

- 不会因为「刚空闲了 30 分钟或 1 小时」就被直接释放。
- 实际释放时刻通常**晚于**「刚满 2 小时」，而不是提前到 1 小时左右。
- 这 2 小时里只要 GPU 曾经明显使用过（峰值达到或超过 5%），即使只是短时间拉高，通常也不会被判定为空闲。
- 容器一直在、进程没退出，但最近 2 小时几乎没有实际 GPU 计算，仍可能被纳入释放范围。

---

## 3. 保护机制

- **两阶段**：先标记、后释放，避免单次误判立刻清理。
- **新 Pod 保护**：手动把副本重新拉起后，系统检测到有**新启动的 Pod**，会跳过本轮回收并清掉待回收标记，避免刚启动又被缩回去。
- **恢复活跃即撤标**：打标之后如果 GPU 又被真正用起来，待回收标记会被清除，本轮不会释放。

打标时，工作负载（或裸 Pod）上会出现注解，例如：

| 注解 | 含义 |
|------|------|
| `gpu.gc/candidate=true` | 已进入待回收确认，下一轮仍空闲才会释放 |
| `gpu.gc/candidate-at` | 打标时间（UTC） |

查看 Deployment 是否已被标记：

```bash
kubectl get deploy -n <namespace> <deployment-name> -o jsonpath='{.metadata.annotations}' ; echo
```

出现 `gpu.gc/candidate` 表示下一轮巡检仍空闲时可能被缩容。此时发起训练或推理、把 GPU 利用率打上去，通常即可避免释放。

---

## 4. 回收后保留什么、丢失什么

| 对象 | Deployment 被缩到 0 之后 |
|------|-------------------------|
| GPU | **已释放**，不再占用 quota 中的卡 |
| Pod / 容器内未挂载路径 | **消失**（含 `/tmp` 等） |
| `/scratch`（local-path） | **不可依赖**，随 Pod 删除 |
| `/workspace` 等共享 PVC | **仍在**，数据不随缩容删除 |
| Helm release | **仍在**；`helm list` 仍能看到，但 `kubectl get deploy` 副本数可能为 `0` |

裸 Pod 被删除时同样不删除 PVC；没有 PVC、只写在容器内的数据会丢失。

建议：需要保留的代码、checkpoint、日志写入 **`/workspace`**（或其它共享 PVC），不要只放在容器本地。

---

## 5. 被缩容后如何恢复

确认副本数：

```bash
kubectl get deploy -n <namespace>
kubectl get pod -n <namespace>
```

`READY` 为 `0/0` 或看不到 Pod，且 Deployment 仍存在时，一般是被 gpu-gc 缩容，而不是 Helm release 被卸载。

用 Helm 按原 values 重新拉起（推荐，与当初部署方式一致）：

```bash
helm upgrade --install my-task ./charts/xay-ai \
  -n <namespace> \
  -f values-my-task.yaml
```

或只把副本数改回 1：

```bash
kubectl scale deploy/<deployment-name> -n <namespace> --replicas=1
```

共享 PVC 仍在时，恢复后的容器可继续挂载原 `/workspace`。若当时未把数据写到 PVC，容器内文件无法找回。

---

## 6. 使用建议

- 交互开发、SSH 常驻请使用 `xay-ai`（Deployment）。暂时不用 GPU 但很快还要继续时，建议及时发起训练或推理，避免连续数小时利用率接近 0。
- 多机训练请使用 `xay-ai-dist-train`（Job），训练结束让进程退出；不要在 Job 里 `sleep infinity` 占卡。
- 确需长时间保留 GPU、且会有数小时无计算（例如隔夜挂着等数据、定时任务间隙），请提前与平台管理员说明场景，评估是否调整释放策略。用户侧**不能**通过自行删注解来永久关闭回收。
- **不占卡但钉在 GPU 节点上的预热 Pod**（`Limits.GPU: 0` + `ScheduleOnGPUNode` / EPC Workspace）没有 GPU 利用率指标，**不会**被 gpu-gc 回收。传完数据或配完环境后，应 `helm upgrade` 成占卡任务或删除预热 release，避免长期占用 GPU 节点的 CPU/内存。

---

## 7. 相关文档

| 文档 | 说明 |
|------|------|
| [`gpu-workload-scenarios.md`](gpu-workload-scenarios.md) | 单机 Deployment vs 多机 Job、Job TTL、训练完成后数据复用 |
| [`charts/xay-ai/README.md`](../charts/xay-ai/README.md) | 单机开发 Chart（会受 gpu-gc 影响）；含 CPU 预热 |
| [`../examples/helm/values-h200-epc-cpu-prep.yaml`](../examples/helm/values-h200-epc-cpu-prep.yaml) | 不占卡预热（H200 + EPC） |
| [`charts/xay-ai-dist-train/README.md`](../charts/xay-ai-dist-train/README.md) | 多机训练 Chart（不在 gpu-gc 范围内） |
| [`multinode-gpu-training.md`](multinode-gpu-training.md) | 多机训练原理与排障 |

---

## 8. 变更记录

| 日期 | 说明 |
|------|------|
| 2026-08-13 | 补充：CPU 预热 Pod 不会被 gpu-gc 回收 |
| 2026-08-13 | 初版：巡检周期、2 小时峰值阈值、两阶段确认、Deployment / Job 差异、缩容后恢复 |
