# xay-ai Helm Chart

`xay-ai` 用于在雄安院 K8s 集群的个人 namespace 中部署 AI 训练、推理、Notebook 或 Web 服务工作负载。

> **场景选型**：交互式单机开发、SSH 常驻任务使用本 Chart（**Deployment**）。跨多台 GPU 节点的 `torchrun` / DeepSpeed 分布式训练请使用 [`xay-ai-dist-train`](../xay-ai-dist-train/)（**Job**）。对照说明见 [`docs/gpu-workload-scenarios.md`](../../docs/gpu-workload-scenarios.md)。
>
> **空闲回收**：本 Chart 创建的是 Deployment，GPU 持续空闲可能被平台缩容。规则见 [`docs/gpu-idle-gc.md`](../../docs/gpu-idle-gc.md)。
>
> **用卡前预热**：不占卡但要挂 EPC / 在 GPU 节点配环境，见 [`values-h200-epc-cpu-prep.yaml`](../../examples/helm/values-h200-epc-cpu-prep.yaml)（CPU ≤ 16、内存 ≤ 64Gi）。
>
> **警告：`helm uninstall` 会删除本 Chart 创建的 workspace PVC，`/workspace` 里已传入的数据会一起丢失。** 预热完成后只能 `helm upgrade` 切到占卡 values，禁止 uninstall 后再新建；`NameSpace`、`BaseName`、Helm release 名必须与预热时完全一致。
>
> **新增卡型**：集群已开放 1 台 H20 节点（8 × H20-3e），设置 `GPU: H20` 即可使用，存储只能选 `h3c-csi-sc-nfs`。详见 [`docs/h20-node-usage.md`](../../docs/h20-node-usage.md)。

Chart 会创建：

- `Deployment`：实际运行的容器任务。
- `Service`：集群内访问容器端口。
- `PersistentVolumeClaim`：可选工作目录 PVC 和临时 scratch PVC。
- `HTTPRoute`：可选 Web 域名访问入口。

## 快速开始

复制示例 values：

```bash
cp examples/helm/values-h200-epc.yaml values-my-task.yaml
vi values-my-task.yaml
```

部署前必须处理工作目录（默认安全模式 **不会** 新建 PVC）：

- 已有 PVC：把 `Workspace.claimName` 改成 `kubectl get pvc` 看到的名称。
- 需要 Chart 新建：注释掉 `create: false` 整段，解开示例里 `create: true` 整段。**`helm uninstall` 会删除新建的 PVC。**
- 不需要 `/workspace`：设 `Workspace.enabled: false`。

未填 `claimName` 且 `create: false` 时 Helm 会直接失败。

部署：

```bash
helm upgrade --install my-task ./charts/xay-ai \
  -n <namespace> \
  -f values-my-task.yaml
```

查看资源：

```bash
kubectl get pod,svc,pvc
```

进入容器：

```bash
kubectl exec -it deploy/<deployment-name> -- bash
```

删除：

```bash
helm uninstall my-task -n <namespace>
```

> **警告：仅当 `Workspace.create: true` 时，`helm uninstall` 才会删除 workspace PVC。** 默认安全模式为 `create: false`（复用已有 PVC，uninstall 不删该盘）。scratch PVC 只要 Chart 创建了，uninstall 仍会删除。预热后切占卡请用 `helm upgrade`，并保持 release 名与 `BaseName` 不变。

## 必填字段

```yaml
NameSpace: your-namespace
BaseName: train
ContainerImage: harbor.xa.hqzyai.com:19443/llm-course/lab:v2
GPU: H200
Workspace:
  claimName: pvc-workspace-your-existing
```

字段说明：

- `NameSpace`：个人 namespace，可在华清云 SaaS 查看；须与 `helm -n` 一致。
- `BaseName`：任务基础名称，用于生成资源名。
- `ContainerImage`：容器镜像地址。示例默认镜像为 `llm-course/lab:v2`；自定义任务 push 到个人 Harbor 项目后替换。
- `GPU`：GPU 类型，当前可选 `5090`、`H200` 或 `H20`。
- `Workspace.claimName`：默认 `create: false`，必须填写已有 PVC。没有现成盘时解开示例中 `create: true` 整段。

Harbor 镜像与个人项目用法见 [`../../docs/harbor-images.md`](../../docs/harbor-images.md)。

## GPU 与资源配置

```yaml
Limits:
  CPU: "8"
  memory: 32Gi
  GPU: 1
```

说明：

- 顶层 `GPU` 是卡型（`5090` / `H200` / `H20`），`Limits.GPU` 是申请的卡数，两者不要混用。
- `Limits.GPU` 为申请的 GPU 卡数。大于 `0` 时才会写入 `nvidia.com/gpu`，并自动加上 GPU 节点的 `nodeSelector` 与 toleration。
- **`Limits.GPU: 0` 默认不会进入 GPU 节点**（不申请卡、也不带 selector/toleration），Pod 通常落到非 GPU 节点。例外：`ScheduleOnGPUNode: true`，或 Workspace 使用 `h3c-csi-sc-epc`（自动钉到 H200）。详见下方「调度说明」。
- `Limits.CPU` 和 `Limits.memory` 同时作为 requests 和 limits。
- 总资源不能超过个人 namespace 的 quota。
- GPU 任务（`Limits.GPU` > 0）默认带有 `nvidia.com/gpu=true:NoSchedule` toleration，并按 `gpu-type` 标签调度到对应节点。

## Deployment 更新策略

默认使用 Kubernetes 标准滚动更新（`RollingUpdate`）：

```yaml
Strategy:
  type: RollingUpdate
  rollingUpdate:
    maxSurge: 25%
    maxUnavailable: 25%
```

单机多卡（如 H200 整节点 8 卡）、或同时挂载 `local-path` scratch 卷时，建议改为 `Recreate`：

```yaml
Strategy:
  type: Recreate
```

### 为何单机多卡建议 Recreate

滚动更新期间，新旧 Pod 可能短暂并存。若新 Pod 申请的 GPU 数接近或等于单节点总量，且 scratch 卷已通过 `local-path` 绑定到某一节点，则新 Pod 只能调度到该节点；旧 Pod 未释放 GPU 时，新 Pod 会长期 `Pending`。`Recreate` 会先终止旧 Pod、再创建新 Pod，从而释放 GPU 与节点-local 卷绑定。

### Recreate 风险说明

| 风险 | 说明 |
|------|------|
| 服务中断 | 升级过程中旧 Pod 被删除后、新 Pod 就绪前，存在无实例可用的时间窗口 |
| 任务中断 | 正在运行的训练、推理或 Notebook 进程会被强制终止；未写入持久卷（如 `/workspace`）或未 checkpoint 的进度可能丢失 |
| 不适合 Web 常驻服务 | 需要对外持续提供 HTTP/SSH 且期望零停机的多副本服务，应保留 `RollingUpdate` |
| 多副本同时重建 | `Replicas` 大于 1 时，所有副本会在同一轮更新中依次替换，整体容量会短暂降为零 |

建议：

- 单机占满 GPU、一次性训练/压测任务：使用 `Recreate`（示例见 `examples/helm/values-h200-8gpu-train.yaml`）。
- 长期在线 Web 或 SSH 开发环境：保持默认 `RollingUpdate`，并将 `Replicas` 设为 1 且 GPU 占用小于单节点总量，以便滚动替换。
- 升级前将关键数据保存至 `/workspace` 等持久卷，或确认任务可安全重跑。

## StorageClass 支持矩阵

| GPU 类型 | `h3c-csi-sc-nfs` | `h3c-csi-sc-epc` | 推荐场景 |
|----------|------------------|------------------|----------|
| 5090 | 支持 | 不支持 | 使用 NFS 共享数据 |
| H200 | 支持 | 支持 | 通用共享用 NFS，高性能共享用 EPC |
| H20 | 支持 | 不支持 | 使用 NFS 共享数据 |

Chart 内置保护：当 `GPU` 为 `5090` 或 `H20`，且 `Workspace.storageClassName` 设为 `h3c-csi-sc-epc` 时，Helm 渲染会直接失败，避免创建无法挂载的工作负载。

## 工作目录 PVC

```yaml
Workspace:
  enabled: true
  create: false
  claimName: pvc-workspace-your-existing
  storageClassName: h3c-csi-sc-epc
  mountPath: /workspace
  readOnly: false
```

使用方式（**默认安全模式是 `create: false`**，示例里 `create: true` 整段默认注释掉）：

| 配置 | 效果 | `helm uninstall` |
|------|------|------------------|
| `enabled: true` + `create: false` + `claimName`（**默认**） | 挂载已有 PVC，Chart 不创建 | **不删除**该 PVC |
| `enabled: true` + `create: true`（需解开注释） | Chart 新建 PVC 并挂到 `/workspace` | **删除该 PVC，数据丢失** |
| `enabled: false` | **不挂载** `/workspace` | 无此 PVC |

复用已有 PVC 时**不要**把 `enabled` 设为 `false`，否则容器里没有 `/workspace`。须填写已存在的 `claimName`（`kubectl get pvc`）。`create: false` 但未填 `claimName` 时 Helm 渲染会失败。

预热 values 与随后的占卡 values 必须使用同一套 Workspace 配置（同 `create` / 同 `claimName`）。

- 5090 与 H20 节点必须使用 `h3c-csi-sc-nfs`。
- H200 节点可使用 `h3c-csi-sc-nfs` 或 `h3c-csi-sc-epc`。

### accessModes 说明

| accessModes | 含义 | 当前建议 |
|-------------|------|----------|
| `ReadWriteOnce` | 单个节点读写挂载 | 适合 `local-path` 临时盘、单副本缓存；不适合作为多节点共享目录 |
| `ReadWriteMany` | 多个节点读写挂载 | H3C NFS/EPC 共享存储推荐使用，适合工作目录、数据集、模型缓存等共享数据 |
| `ReadOnlyMany` | 多个节点只读挂载 | 适合公共模型权重、公共数据集等只读分发场景；是否可用取决于平台提供的 PVC/PV 配置 |

`h3c-csi-sc-nfs` 和 `h3c-csi-sc-epc` 面向共享文件存储，示例默认使用 `ReadWriteMany`。`local-path` 是节点本地存储，通常使用 `ReadWriteOnce`，不应作为跨节点共享目录。

## 临时 scratch PVC

```yaml
Scratch:
  enabled: true
  storageClassName: local-path
  size: 100Gi
  mountPath: /scratch
```

`/scratch` 适合放临时缓存、构建中间文件、短期 checkpoint。删除 Helm release 会删除该 PVC，不要把长期数据只保存在 `/scratch`。

## 共享内存

```yaml
UseShm: true
ShmSize: 16Gi
```

训练框架、推理服务、浏览器渲染或多进程 DataLoader 需要较大 `/dev/shm` 时建议开启。

## EGL

```yaml
UseEGL: true
EGLImage: harbor.xa.hqzyai.com:19443/infra/nvidia-egl-libs:latest
```

开启后 Chart 会通过 initContainer 注入 EGL 相关库，并设置 `NVIDIA_DRIVER_CAPABILITIES`、`__EGL_VENDOR_LIBRARY_DIRS`、`LD_LIBRARY_PATH`。仅在渲染、仿真、图形相关任务确实需要时启用。

## 公共模型权重

```yaml
SharedModels:
  enabled: true
  claimName: pvc-shared-models
  mountPath: /models
  readOnly: true
```

公共模型权重默认只读挂载。当前 Chart 仅提供挂载能力，不会自动创建公共模型 PVC。只有在平台已提供公共模型 PVC，或项目管理员明确告知 `claimName` 后，才开启该配置。

当前集群存储层支持 RWX 的 NFS/EPC PVC，但是否存在“公共模型权重”这类平台级共享 PVC，取决于平台侧是否已创建和授权。未拿到明确 PVC 名称时保持 `SharedModels.enabled: false`。

## 公共读写目录

```yaml
SharedWritable:
  enabled: false
  claimName: ""
  mountPath: /shared
  readOnly: false
```

公共读写目录默认关闭。当前 Chart 仅提供复用已有 PVC 的挂载能力，不会自动创建公共读写 PVC。启用前需确认平台侧已验证：

- 多用户权限隔离。
- namespace quota 与容量回收策略。
- 文件属主和权限继承。
- 并发写入和误删恢复流程。

如果只是个人任务的工作目录，优先使用 `Workspace` 创建个人 PVC；不要把 `SharedWritable` 当作默认工作目录。

## Web 服务和 HTTPRoute

容器内启动 Web 服务时，可设置 `ExtraPort` 和 `HTTPRoute`：

```yaml
ExtraPort: 7860

HTTPRoute:
  enabled: true
  host: demo.xa.hqzyai.com
  parentRef:
    name: yunwang-public
    namespace: envoy-gateway-system
    sectionName: https-wildcard-8443
  servicePort: 7860
  pathPrefix: /
```

说明：

- `host` 需要按平台规则申请后使用。示例中的 `demo.xa.hqzyai.com` 最终访问地址为 `https://demo.xa.hqzyai.com:9443/`。
- `servicePort` 通常与 `ExtraPort` 一致。
- HTTPRoute 只负责路由，容器内程序仍需监听 `0.0.0.0:<ExtraPort>`。
- `parentRef` 指向平台预置的集群入口网关，普通用户通常不要修改。
- 访问端口是公网 `9443`，不是容器端口 `7860`。访问链路为：浏览器 `https://<域名>:9443/` → 集群入口网关 → HTTPRoute → Service → Pod 的 `ExtraPort`。

更多手工配置说明见 [`../../docs/web-httproute-guide.md`](../../docs/web-httproute-guide.md)。

## 自定义启动命令

默认命令会让容器常驻：

```bash
while true; do sleep 3600; done
```

启动训练脚本示例：

```yaml
Command: '["bash", "-lc", "--"]'
Args: '["cd /workspace && python train.py"]'
```

启动 Web 服务示例：

```yaml
Command: '["bash", "-lc", "--"]'
Args: '["cd /workspace && python app.py --host 0.0.0.0 --port 7860"]'
ExtraPort: 7860
```

## 调度说明

普通用户通常只需要设置 `GPU: 5090`、`GPU: H200` 或 `GPU: H20`，并把 `Limits.GPU` 设为大于 `0` 的卡数。Chart 会根据卡型生成当前集群已存在的 `gpu-type` 节点选择条件，并自动添加 GPU 节点所需 toleration。

不要把顶层 `GPU` 写成 `0`。`GPU` 只接受卡型名称；卡数只能改 `Limits.GPU`。

### `Limits.GPU: 0` 默认不会进入 GPU 节点

把 `Limits.GPU` 设为 `0` 只会取消 GPU 卡申请。未打开下方开关、且 Workspace 不是 EPC 时，Chart 会同时省略 GPU 节点 selector 与污点容忍，Pod 通常落到非 GPU 节点。

| 项 | `Limits.GPU` > 0 | `Limits.GPU: 0`（默认） | `Limits.GPU: 0` 且钉到 GPU 节点 |
|----|------------------|-------------------------|--------------------------------|
| `nvidia.com/gpu` 资源 | 按卡数申请 | 不申请 | 不申请 |
| `nodeSelector: gpu-type: ...` | 自动写入 | 不写入 | 自动写入 |
| GPU NoSchedule toleration | 自动写入 | 不写入 | 自动写入 |

以下任一条件会把不占卡的 Pod **钉到**对应 GPU 节点（否则 EPC 无法挂载）：

- `ScheduleOnGPUNode: true`
- Workspace 使用 `h3c-csi-sc-epc`（仅 H200，Chart 自动钉上）

预热任务（不占卡且钉在 GPU 节点上）的资源上限：**CPU ≤ 16 核，内存 ≤ 64Gi**（`Limits.CPU` 须为整数核，`Limits.memory` 须带 `Gi` 后缀）。超限时 Helm 渲染失败。占卡任务不受此帽。

示例：[`values-h200-epc-cpu-prep.yaml`](../../examples/helm/values-h200-epc-cpu-prep.yaml)、[`values-5090-nfs-cpu-prep.yaml`](../../examples/helm/values-5090-nfs-cpu-prep.yaml)。

### 预热之后切到占卡

默认安全模式（`create: false`）下，预热与占卡都挂同一块已有 PVC，`helm uninstall` **不会**删除该盘。仍须保持 Helm **release 名**、**`BaseName`**、**`NameSpace`** 与 **`claimName`** 一致。

若已解开 `create: true` 让 Chart 新建 PVC：

> **警告：禁止在预热与占卡之间执行 `helm uninstall`。** 新建的 workspace PVC 会随 release 删除，`/workspace` 数据丢失。

正确做法：同一 Helm release 先预热，再 `helm upgrade` 切到占卡 values：

```bash
helm upgrade --install my-task ./charts/xay-ai \
  -n <namespace> \
  -f examples/helm/values-h200-epc-cpu-prep.yaml

# 在 /workspace 传数据、安装依赖后再占卡
helm upgrade --install my-task ./charts/xay-ai \
  -n <namespace> \
  -f examples/helm/values-h200-epc.yaml
```

建议：预热结束后尽快 upgrade 成占卡任务。不占卡但钉在 GPU 节点上的 Pod 占用该节点 CPU/内存，且不会被 gpu-gc 按空闲 GPU 回收。不要用 `Workspace.enabled: false` 来「复用 PVC」——那会取消 `/workspace` 挂载。

不建议普通用户在其它场景自行填写 `NodeSelector`、`Tolerations`、`Affinity`。当前集群未提供面向普通用户的 `accelerator`、`dedicated` 等自定义调度标签；随意添加不存在的 label 会导致 Pod 一直处于 `Pending`。

另有两点需要避免：

- **不要在工作负载中写死 `spec.nodeName`。** 这样会绕过调度器，一旦节点资源不足或条件不匹配，Pod 会被直接拒绝并由控制器反复重建，短时间内产生大量无效 Pod。指定节点范围请使用 `GPU` 字段。
- **不要使用 `nvidia.com/gpu.product` 作为选择条件。** 该标签取值随卡型变化（如 `NVIDIA-H200`、`NVIDIA-H20-3e`、`NVIDIA-GeForce-RTX-5090`），从其他卡型的配置复制后容易忘记修改，导致 Pod 被 kubelet 以 `NodeAffinity` 拒绝。

## 常见排查

查看 Helm release：

```bash
helm list -n <namespace>
```

查看 Pod：

```bash
kubectl get pod -n <namespace> -o wide
```

查看事件：

```bash
kubectl describe pod -n <namespace> <pod-name>
```

查看日志：

```bash
kubectl logs -n <namespace> <pod-name> --tail=100
```

检查 GPU：

```bash
kubectl exec -it -n <namespace> <pod-name> -- nvidia-smi
```

检查挂载：

```bash
kubectl exec -it -n <namespace> <pod-name> -- df -h
kubectl exec -it -n <namespace> <pod-name> -- ls -lah /workspace /scratch /models
```

Deployment 副本变为 `0`、Pod 消失但 `helm list` 仍在时，可能是平台 GPU 空闲回收。查看待回收标记并恢复的步骤见 [`docs/gpu-idle-gc.md`](../../docs/gpu-idle-gc.md) §3、§5。

## 注意事项

- 5090 与 H20 节点只能使用 `h3c-csi-sc-nfs`。
- H200 节点可使用 `h3c-csi-sc-nfs` 或 `h3c-csi-sc-epc`。
- H20 当前只有 1 台（8 卡），仅适用于单机任务，不能用于多机训练。
- **警告：默认 `Workspace.create: false`（复用已有 PVC，须填 `claimName`）。** 仅当解开 `create: true` 时，`helm uninstall` 才会删除 workspace PVC。不要设 `Workspace.enabled: false` 来复用 PVC。预热后切占卡用 `helm upgrade`，且不得改 release 名 / `BaseName` / `NameSpace`。
- 公共模型权重建议只读挂载。
- HTTPRoute 域名需先按平台规则申请。
- **`Limits.GPU: 0` 默认不会进入 GPU 节点。** 预热请用 `ScheduleOnGPUNode` 或 EPC Workspace；CPU ≤ 16、内存 ≤ 64Gi。详见「调度说明」。
- GPU 最近连续约 2 小时几乎未使用时，平台可能将 Deployment 缩容（常见为副本数变为 `0`）；PVC 数据仍保留。完整规则与恢复方法见 [`docs/gpu-idle-gc.md`](../../docs/gpu-idle-gc.md)。
