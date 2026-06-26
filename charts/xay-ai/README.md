# xay-ai Helm Chart

`xay-ai` 用于在雄安院 K8s 集群的个人 namespace 中部署 AI 训练、推理、Notebook 或 Web 服务工作负载。

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

## 必填字段

```yaml
NameSpace: your-namespace
BaseName: train
ContainerImage: harbor.xa.hqzyai.com:19443/llm-course/lab:v2
GPU: H200
```

字段说明：

- `NameSpace`：个人 namespace，可在华清云 SaaS 查看；须与 `helm -n` 一致。
- `BaseName`：任务基础名称，用于生成资源名。
- `ContainerImage`：容器镜像地址。示例默认镜像为 `llm-course/lab:v2`；自定义任务 push 到个人 Harbor 项目后替换。
- `GPU`：GPU 类型，当前可选 `5090` 或 `H200`。

Harbor 镜像与个人项目用法见 [`../../docs/harbor-images.md`](../../docs/harbor-images.md)。

## GPU 与资源配置

```yaml
Limits:
  CPU: "8"
  memory: 32Gi
  GPU: 1
```

说明：

- `Limits.GPU` 为申请的 GPU 卡数。
- `Limits.CPU` 和 `Limits.memory` 同时作为 requests 和 limits。
- 总资源不能超过个人 namespace 的 quota。
- GPU 任务默认带有 `nvidia.com/gpu=true:NoSchedule` toleration，并按 `gpu-type` 标签调度到对应节点。

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

Chart 内置保护：当 `GPU: 5090` 且 `Workspace.storageClassName: h3c-csi-sc-epc` 时，Helm 渲染会直接失败，避免创建无法挂载的工作负载。

## 工作目录 PVC

```yaml
Workspace:
  enabled: true
  create: true
  claimName: ""
  storageClassName: h3c-csi-sc-epc
  size: 200Gi
  accessModes:
    - ReadWriteMany
  mountPath: /workspace
  readOnly: false
```

使用方式：

- `create: true`：Chart 创建新 PVC。
- `create: false` + `claimName`：复用已有 PVC。
- 5090 节点必须使用 `h3c-csi-sc-nfs`。
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

普通用户通常只需要设置 `GPU: 5090` 或 `GPU: H200`。Chart 会根据该字段生成当前集群已存在的 `gpu-type` 节点选择条件，并自动添加 GPU 节点所需 toleration。

不建议自行填写 `NodeSelector`、`Tolerations`、`Affinity`。当前集群未提供面向普通用户的 `accelerator`、`dedicated` 等自定义调度标签；随意添加不存在的 label 会导致 Pod 一直处于 `Pending`。

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

## 注意事项

- 5090 节点只能使用 `h3c-csi-sc-nfs`。
- H200 节点可使用 `h3c-csi-sc-nfs` 或 `h3c-csi-sc-epc`。
- 删除 Helm release 会删除 Chart 创建的 scratch PVC。
- 公共模型权重建议只读挂载。
- HTTPRoute 域名需先按平台规则申请。
