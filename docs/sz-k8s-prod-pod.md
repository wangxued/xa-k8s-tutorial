# 新深圳集群 sz-k8s-prod：创建 Pod

这是 5 台 H800 的新集群，不是 4 台公网 H200 的临时集群。临时集群仍用 [`sz-k8s-hostpath.md`](sz-k8s-hostpath.md)，那篇里的 hostPath 不能用到这里。

| 项 | 值 |
|---|---|
| API | `https://sz-prod.hqzyai.com:6443` |
| 镜像仓库 | `https://harbor.sz-prod.hqzyai.com:8443/` |
| GPU 节点 | `sz-h800-6`、`sz-h800-7`、`sz-h800-8`、`sz-h800-10`、`sz-h800-13`，每台 8 张 H800 |
| 节点标签 | `gpu-type=H800` |
| 工作盘 | 存储类 `local-path-data1`，落在调度到的那台机器的 `/data1`（3.5T） |
| 临时盘 | 存储类 `local-path`，落在同一台机器的 `/data`（另一块 3.5T） |

kubeconfig 和 namespace 从华清云获取。下面的命令都在自己的 namespace 里执行。

## 先记住这几条

- 用户命名空间里不能挂 hostPath，包括 `/data` 和 `/data1`。持久数据用 PVC。
- 两块盘都在单台机器上。Pod 第一次调度到哪台，卷就留在哪台。换节点看不到原来的文件。五台之间没有共享盘，所以这次不提供多机训练示例。
- 存储类上填写的容量不是硬盘配额。同一块盘上的多个 PVC 会一起把盘写满。
- 访问模式写 `ReadWriteOnce`。这里没有跨节点的 `ReadWriteMany`。
- 申请 GPU 时，`requests` 和 `limits` 都要写 `nvidia.com/gpu`。只写 request 会被拒绝。
- 占卡任务由 Chart 或下面的 Deployment 自动加上 `nvidia.com/gpu` 的污点容忍。不写容忍、又不申请 GPU 的 Pod，不会调度到这五台。
- 不占卡、却用节点名钉在 `sz-h800-*` 上时，CPU request 合计不能超过 16 核，内存 request 合计不能超过 64Gi。
- 不挂卷时，容器里对 `/` 执行 `df` 看到的是大约 880G 的容器盘。Pod 删除后，写在容器根目录和 `emptyDir` 里的文件会消失。检查点和数据集放到 `/workspace`。
- 大镜像推到 `https://harbor.sz-prod.hqzyai.com:8443/` 的个人项目。不要从 `harbor.xa.hqzyai.com:19443` 现场拉十几 GB。

`helm uninstall` 会删除本 Chart 新建的 workspace PVC 和 scratch PVC，`/workspace` 里的数据会一起没掉。要保留数据时只做 `helm upgrade`，不要卸载后再装一个新名字。

## Helm

复制 [`examples/helm/values-sz-k8s-prod-h800.yaml`](../examples/helm/values-sz-k8s-prod-h800.yaml)，改 namespace 和镜像。

```bash
cp examples/helm/values-sz-k8s-prod-h800.yaml values-my-sz-prod.yaml
vi values-my-sz-prod.yaml

helm upgrade --install my-task ./charts/xay-ai \
  -n <namespace> \
  -f values-my-sz-prod.yaml
```

`GPU` 必须是 `H800`。Chart 会选择 `gpu-type=H800`，并加上 GPU 污点容忍。`Workspace` 使用 `local-path-data1`，挂到 `/workspace`。`Scratch` 使用 `local-path`，挂到 `/scratch`。示例里这两块盘都由 Chart 创建，卸载时会删掉。

已经有 PVC 时，把 `Workspace.create` 改为 `false`，`claimName` 写成 `kubectl get pvc` 里的名字。这块卷必须和 Pod 在同一台 H800 上，否则会一直 Pending。

## 自己写 Deployment

不使用 Helm 时，应用 [`examples/raw-yaml/deployment-sz-k8s-prod-h800.yaml`](../examples/raw-yaml/deployment-sz-k8s-prod-h800.yaml)。先把里面的 `your-namespace` 和镜像地址改掉。

```bash
kubectl apply -f examples/raw-yaml/deployment-sz-k8s-prod-h800.yaml
kubectl -n <namespace> get pod,pvc -o wide
```

这个文件会创建两块 PVC 和一个 Deployment：

| 资源 | 存储类 | 容器里的路径 |
|---|---|---|
| `sz-h800-workspace` | `local-path-data1` | `/workspace` |
| `sz-h800-scratch` | `local-path` | `/scratch` |
| Deployment `sz-h800-workload` | — | 1 张 H800，`gpu-type=H800` |

删掉 Deployment 不会删 PVC。数据还在第一次调度到的那台机器上。确认不再需要之后，再删 PVC，目录会一起消失。
