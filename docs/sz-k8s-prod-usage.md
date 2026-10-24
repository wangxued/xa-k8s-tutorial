# 新深圳集群 sz-k8s-prod：使用说明

这是新深圳集群，不是已经下架的 4 台公网 H200 临时集群。临时集群的 hostPath 不能用到这里，见 [`sz-k8s-hostpath.md`](sz-k8s-hostpath.md)。

训练和开发使用的机器不同。训练在华清云工作台提交，排队规则见 [`gpu-queue-scheduling.md`](gpu-queue-scheduling.md)。开发容器的创建步骤见 [`sz-k8s-prod-pod.md`](sz-k8s-prod-pod.md)。

> **日期**：2026-10-24

| 项 | 值 |
|---|---|
| API | 请通过华清云平台获取对应集群 API 地址 |
| 镜像仓库 | `https://harbor.sz-prod.hqzyai.com:8443/` |
| 工作台训练 | H200。机器是 `sz-h200-9`、`sz-h200-10`，每台 8 张，队列一共 16 张 |
| 开发 | 其余 14 台 H200：`sz-h200-2`、`sz-h200-3`、`sz-h200-4`、`sz-h200-5`、`sz-h200-6`、`sz-h200-7`、`sz-h200-8`、`sz-h200-11`、`sz-h200-12`、`sz-h200-13`、`sz-h200-14`、`sz-h200-15`、`sz-h200-16`、`sz-h200-17`，每台 8 张 |
| H800 | 正在调整机柜，现在调度不到 |
| 批量推理 | 还没有开放 |
| 工作盘 | 存储类 `local-path-data1`，大约 3.5T，在调度到的那台机器的 `/data1` |
| 临时盘 | 存储类 `local-path`，H200 大约 2.5T，在同一台机器的 `/data` |

kubeconfig 和 namespace 从华清云获取。工作台下拉里能否看到深圳集群，以页面上的实际选项为准。

## 先记住这几条

- 训练只在华清云工作台提交，卡型选 H200。用 `kubectl` 直接提交训练队列任务会被拒绝，原因是「队列任务只能通过华清云工作台提交」。
- 队列一共 16 张卡，分在两台机器上。单次任务落在一台机器上，最多申请 8 张。不要一次申请 16 张。
- 自己创建的开发容器不会调度到 `sz-h200-9` 和 `sz-h200-10`。不要写死 `spec.nodeName`，尤其不要写这两台的名字。
- 现在不要选择 H800，也不要照 H800 示例创建任务。
- 批量推理还没有开放。各台机器之间没有共享盘，这次不提供多机训练。
- 用户命名空间里不能挂 hostPath。工作数据用 `local-path-data1`，临时数据用 `local-path`。
- 申请 GPU 时，`requests` 和 `limits` 都要写 `nvidia.com/gpu`。

## 工作台训练

在华清云工作台提交 H200 训练。不用填写队列名称，也不用在表单里写环境变量。

容器里会自带这些变量：

| 变量 | 值 |
|---|---|
| `http_proxy`、`https_proxy`、`HTTP_PROXY`、`HTTPS_PROXY` | `http://33.1.42.5:8888` |
| `no_proxy`、`NO_PROXY` | `localhost,127.0.0.1,::1,10.244.0.0/16,10.96.0.0/12,.svc,.cluster.local,cluster.local,.hqzyai.com` |

代理地址是 HTTP，不要改成 `https://33.1.42.5:8888`。`.hqzyai.com` 不要走代理，前面的点要保留。

`sz-h200-9` 和 `sz-h200-10` 上已经有下面两张镜像。地址整行照抄，拉取策略用 `IfNotPresent`：

- `harbor.xa.hqzyai.com:19443/xuw/pytorch:v1.5`
- `harbor.xa.hqzyai.com:19443/llm-course/lab:v2`

其它大镜像推到 `https://harbor.sz-prod.hqzyai.com:8443/` 的个人项目，不要从 `harbor.xa.hqzyai.com:19443` 现场拉十几 GB。

## 自己创建开发容器

14 台开发用的 H200 按 [`sz-k8s-prod-pod.md`](sz-k8s-prod-pod.md) 用 Helm 或 Deployment 创建。复制 H200 示例 [`examples/helm/values-sz-k8s-prod-h200.yaml`](../examples/helm/values-sz-k8s-prod-h200.yaml)。H800 示例先不要用。

开发容器不会自动带上代理。调度到 H200 后，容器访问公网要自己写 `http://33.1.42.5:8888`，写法见 [`sz-k8s-prod-h200-network.md`](sz-k8s-prod-h200-network.md)。机器名单以本文为准。

开发容器若长期几乎不用卡，可能被平台缩容，说明见 [`gpu-idle-gc.md`](gpu-idle-gc.md)。工作台提交的训练任务不在这项回收里。

## 存储

- PVC 第一次调度到哪台机器，文件就留在哪台。换机器看不到原来的文件。
- 访问模式写 `ReadWriteOnce`。这里没有跨节点共享的盘。
- 存储类上填写的容量不是硬盘配额。同一块盘上的多个 PVC 会一起把盘写满。
- 检查点和数据集写到 `/workspace`。容器根目录和 `emptyDir` 里的文件会随 Pod 删除而消失。
- `helm uninstall` 会删除本 Chart 新建的 workspace PVC 和 scratch PVC。要保留数据时只做 `helm upgrade`，不要卸载后再装一个新名字。

## 常见问题

### 自己建的容器会不会跑到训练用的那两台上？

不会。`sz-h200-9` 和 `sz-h200-10` 只跑工作台提交的训练任务。开发容器请按 `gpu-type=H200` 调度，不要写节点名。

### 为什么用 kubectl 提交不了训练？

训练队列任务只能在华清云工作台提交。在自己的 namespace 里直接提交会被拒绝，原因是「队列任务只能通过华清云工作台提交」。

### 为什么选了 H800 一直起不来？

H800 正在调整机柜，现在调度不到。请改用 H200。开发用上面列出的 14 台，训练用工作台。

### 为什么工作台任务能访问公网，自己建的 Pod 会超时？

工作台提交的 H200 训练任务已经带上代理。自己创建的 H200 容器不会自动带上，需要按 [`sz-k8s-prod-h200-network.md`](sz-k8s-prod-h200-network.md) 写入 `http://33.1.42.5:8888`。

### 为什么不能做多机训练？

各台 GPU 机器之间没有共享盘，这次也不提供多机训练示例。单次训练最多使用一台机器上的 8 张卡。

### 为什么不能提交批量推理？

批量推理还没有开放。当前工作台只提交 H200 训练。

### 换了一台机器之后，原来 PVC 里的文件还在不在？

还在第一次调度到的那台机器上。新 Pod 若调度到别的机器，挂不上这块卷，会一直 Pending。要继续用这些文件，任务需要回到原来的机器；确认不再需要之后，再删除 PVC。
