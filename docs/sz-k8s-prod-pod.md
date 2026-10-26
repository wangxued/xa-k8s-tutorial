# 新深圳集群 sz-k8s-prod：创建 Pod

这是新深圳集群上创建开发 Pod 的说明，不是 4 台公网 H200 的临时集群。工作台训练的共同步骤见 [`gpu-queue-scheduling.md`](gpu-queue-scheduling.md)，深圳队列的机器、Scratch 和代理见 [`sz-k8s-prod-queue-usage.md`](sz-k8s-prod-queue-usage.md)。临时集群仍用 [`sz-k8s-hostpath.md`](sz-k8s-hostpath.md)，那篇里的 hostPath 不能用到这里。H200 上的容器访问公网要单独配代理，见 [`sz-k8s-prod-h200-network.md`](sz-k8s-prod-h200-network.md)。

| 项 | 值 |
|---|---|
| API | 请通过华清云平台获取对应集群 API 地址 |
| 镜像仓库 | `https://harbor.sz-prod.hqzyai.com:8443/` |
| 开发用的 H200 | `sz-h200-2`、`sz-h200-3`、`sz-h200-4`、`sz-h200-5`、`sz-h200-6`、`sz-h200-7`、`sz-h200-8`、`sz-h200-11`、`sz-h200-12`、`sz-h200-13`、`sz-h200-14`、`sz-h200-15`、`sz-h200-16`、`sz-h200-17`，每台 8 张。不要写死节点名，尤其不要写训练用的 `sz-h200-9`、`sz-h200-10` |
| H800 | 正在调整机柜，现在调度不到。下面的 H800 示例先不要用 |
| 节点标签 | 开发任务使用 `gpu-type=H200` |
| 工作盘 | 存储类 `local-path-data1`，落在调度到的那台机器的 `/data1`。H200 这块盘大约 3.5T |
| 临时盘 | 存储类 `local-path`，落在同一台机器的 `/data`。H200 大约 2.5T |

kubeconfig 和 namespace 从华清云获取。下面的命令都在自己的 namespace 里执行。

## 先记住这几条

- 用户命名空间里不能挂 hostPath，包括 `/data` 和 `/data1`。持久数据用 PVC。
- 两块盘都在单台机器上。Pod 第一次调度到哪台，卷就留在哪台。换节点看不到原来的文件。各台 GPU 机器之间没有共享盘，所以这次不提供多机训练示例。
- 存储类上填写的容量不是硬盘配额。同一块盘上的多个 PVC 会一起把盘写满。
- 访问模式写 `ReadWriteOnce`。这里没有跨节点的 `ReadWriteMany`。
- 申请 GPU 时，`requests` 和 `limits` 都要写 `nvidia.com/gpu`。只写 request 会被拒绝。
- 占卡任务由 Chart 或下面的 Deployment 自动加上 `nvidia.com/gpu` 的污点容忍。不写容忍、又不申请 GPU 的 Pod，不会调度到这些 GPU 节点。
- 不占卡、却用节点名钉在 `sz-h800-*` 或 `sz-h200-*` 上时，CPU request 合计不能超过 16 核，内存 request 合计不能超过 64Gi。
- 不挂卷时，容器里对 `/` 执行 `df` 看到的是大约 880G 的容器盘。Pod 删除后，写在容器根目录和 `emptyDir` 里的文件会消失。检查点和数据集放到 `/workspace`。
- 大镜像推到 `https://harbor.sz-prod.hqzyai.com:8443/` 的个人项目。不要从 `harbor.xa.hqzyai.com:19443` 现场拉十几 GB。
- 现在不要选择 H800。调度到 H200 时，容器里访问公网要写代理 `http://33.1.42.5:8888`。写法见 [`sz-k8s-prod-h200-network.md`](sz-k8s-prod-h200-network.md)。

`helm uninstall` 会删除本 Chart 新建的 workspace PVC 和 scratch PVC，`/workspace` 里的数据会一起没掉。要保留数据时只做 `helm upgrade`，不要卸载后再装一个新名字。

## Helm

现在复制 H200 示例 [`examples/helm/values-sz-k8s-prod-h200.yaml`](../examples/helm/values-sz-k8s-prod-h200.yaml)，代理已经写在 `ExtraEnv` 里。改 namespace 和镜像。H800 示例 [`examples/helm/values-sz-k8s-prod-h800.yaml`](../examples/helm/values-sz-k8s-prod-h800.yaml) 先不要用，这些机器当前调度不到。

```bash
cp examples/helm/values-sz-k8s-prod-h200.yaml values-my-sz-prod.yaml
vi values-my-sz-prod.yaml

helm upgrade --install my-task ./charts/xay-ai \
  -n <namespace> \
  -f values-my-sz-prod.yaml
```

`GPU` 写 `H200`。Chart 会选择对应的 `gpu-type`，并加上 GPU 污点容忍。`Workspace` 使用 `local-path-data1`，挂到 `/workspace`。`Scratch` 使用 `local-path`，挂到 `/scratch`。示例里这两块盘都由 Chart 创建，卸载时会删掉。

已经有 PVC 时，把 `Workspace.create` 改为 `false`，`claimName` 写成 `kubectl get pvc` 里的名字。这块卷必须和 Pod 在同一台机器上，否则会一直 Pending。H200 上访问公网还要保留示例里的 `ExtraEnv`，见 [`sz-k8s-prod-h200-network.md`](sz-k8s-prod-h200-network.md)。

## 自己写 Deployment

不使用 Helm 时，先复制 [`examples/raw-yaml/deployment-sz-k8s-prod-h800.yaml`](../examples/raw-yaml/deployment-sz-k8s-prod-h800.yaml)，再改自己的副本。仓库里的这份文件仍是 H800 示例，直接 apply 会选中现在调度不到的机器。把 `your-namespace`、镜像地址和 `gpu-type` 改成 H200，并按 [`sz-k8s-prod-h200-network.md`](sz-k8s-prod-h200-network.md) 加上代理环境变量，然后再 apply。

```bash
cp examples/raw-yaml/deployment-sz-k8s-prod-h800.yaml deployment-my-h200.yaml
vi deployment-my-h200.yaml
kubectl apply -f deployment-my-h200.yaml
kubectl -n <namespace> get pod,pvc -o wide
```

改完之后，这份副本会创建两块 PVC 和一个 Deployment：

| 资源 | 存储类 | 容器里的路径 |
|---|---|---|
| workspace PVC | `local-path-data1` | `/workspace` |
| scratch PVC | `local-path` | `/scratch` |
| Deployment | — | 1 张 H200，`gpu-type=H200` |

删掉 Deployment 不会删 PVC。数据还在第一次调度到的那台机器上。确认不再需要之后，再删 PVC，目录会一起消失。
