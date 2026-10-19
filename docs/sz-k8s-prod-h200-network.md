# 新深圳集群 sz-k8s-prod：H200 访问公网

新深圳集群里有 8 台 H200。这 8 台上面的容器不能直接打开公网。要在 Pod 里写上集群提供的 HTTP 代理，容器里认这个变量的程序才能访问公网。

同一集群上的 H800 不需要这份配置，容器可以直接访问国内公网。节点和磁盘的其他约定见 [`sz-k8s-prod-pod.md`](sz-k8s-prod-pod.md)。临时集群 `sz-k8s` 的 4 台公网 H200 不使用本文。

| 项 | 值 |
|---|---|
| 集群 API | 请通过华清云平台获取对应集群 API 地址 |
| H200 节点 | `sz-h200-2`、`sz-h200-3`、`sz-h200-4`、`sz-h200-5`、`sz-h200-11`、`sz-h200-12`、`sz-h200-13`、`sz-h200-14` |
| 节点标签 | `gpu-type=H200` |
| 每台卡数 | 8 |
| 公网代理 | `http://33.1.42.5:8888` |

`http_proxy` 和 `https_proxy` 都写这个地址。`https://` 的网站也走这条 HTTP 代理，不要把代理地址写成 `https://33.1.42.5:8888`。

## 哪些访问要带代理

容器里的 `curl`、`wget`、`pip`、`apt`、`git`，以及会读取 `http_proxy` / `https_proxy` 的下载程序，都要带上这组变量。大小写两套都写上，有的程序只认其中一种。

下面这些不要走代理，写在 `no_proxy` 和 `NO_PROXY` 里：

| 要排除的地址 | 原因 |
|---|---|
| `localhost`、`127.0.0.1` | 容器自己 |
| `10.244.0.0/16` | Pod 网段 |
| `10.96.0.0/12` | Service 网段 |
| `.svc`、`.cluster.local` | 集群内域名 |
| `.hqzyai.com` | 这个后缀下的全部域名，含 `harbor.sz-prod.hqzyai.com`。前面加一个点，不要写成 `*.hqzyai.com` |

节点已经能替 Pod 拉取公网镜像。镜像地址写在 `image` 里即可，不用为了拉镜像再改 kubelet。容器启动之后，里面的程序访问公网仍然要靠下面的环境变量。

不读取这些变量、自己直接建立连接的程序，加上变量也到不了公网。

## Helm

在 values 里增加 `ExtraEnv`。`GPU` 写成 `H800` 的任务不要加这段。会调度到 `gpu-type=H200` 的任务要加。

```yaml
GPU: H200

ExtraEnv:
  - name: http_proxy
    value: "http://33.1.42.5:8888"
  - name: https_proxy
    value: "http://33.1.42.5:8888"
  - name: HTTP_PROXY
    value: "http://33.1.42.5:8888"
  - name: HTTPS_PROXY
    value: "http://33.1.42.5:8888"
  - name: no_proxy
    value: "localhost,127.0.0.1,::1,10.244.0.0/16,10.96.0.0/12,.svc,.cluster.local,cluster.local,.hqzyai.com"
  - name: NO_PROXY
    value: "localhost,127.0.0.1,::1,10.244.0.0/16,10.96.0.0/12,.svc,.cluster.local,cluster.local,.hqzyai.com"
```

新任务可以直接复制 [`examples/helm/values-sz-k8s-prod-h200.yaml`](../examples/helm/values-sz-k8s-prod-h200.yaml)，里面已经写好这组变量。其余磁盘字段按 [`sz-k8s-prod-pod.md`](sz-k8s-prod-pod.md) 填写：

```bash
helm upgrade --install my-task ./charts/xay-ai \
  -n <namespace> \
  -f values-my-sz-prod.yaml
```

已经在跑、并且占着卡的任务不要为了加上代理再执行 `helm upgrade`。模板一变就会新建 Pod。还没写进 PVC 的文件会消失。

## 自己写 Deployment

在容器的 `env` 里加上同样的变量。节点选择用 `gpu-type: H200`，并保留 GPU 污点容忍。`requests` 和 `limits` 都要写 `nvidia.com/gpu`。

```yaml
spec:
  template:
    spec:
      nodeSelector:
        gpu-type: H200
      tolerations:
        - key: nvidia.com/gpu
          operator: Equal
          value: "true"
          effect: NoSchedule
      containers:
        - name: workload
          env:
            - name: http_proxy
              value: "http://33.1.42.5:8888"
            - name: https_proxy
              value: "http://33.1.42.5:8888"
            - name: HTTP_PROXY
              value: "http://33.1.42.5:8888"
            - name: HTTPS_PROXY
              value: "http://33.1.42.5:8888"
            - name: no_proxy
              value: "localhost,127.0.0.1,::1,10.244.0.0/16,10.96.0.0/12,.svc,.cluster.local,cluster.local,.hqzyai.com"
            - name: NO_PROXY
              value: "localhost,127.0.0.1,::1,10.244.0.0/16,10.96.0.0/12,.svc,.cluster.local,cluster.local,.hqzyai.com"
```

已经占着卡的 Deployment 不要用 `kubectl set env` 或 `kubectl apply` 去补这组变量。环境变量写在 Pod 模板里，改模板一定会新建 Pod，正在跑的容器不会原地带上代理。

2026-10-19 取样，这个集群里申请了 GPU 的 Deployment 有 34 个，其中 32 个的更新策略是 `Recreate`。这种策略先删掉旧 Pod，卡立刻空出来，别的 Pending 任务可以排上去。节点故障后的绑回只认原来的 ReplicaSet；模板一变就是新的 ReplicaSet，不会把卡留给他。

副本数是 1、策略是 `RollingUpdate`、并且 `maxUnavailable` 算出来是 0 时，旧 Pod 会先留着。节点上没有空闲卡时，新 Pod 一直 Pending，旧进程继续占卡，代理也不会进到正在跑的容器里。节点上还有空闲卡时，新 Pod 起来之后旧 Pod 会被停掉，内存里的进度会丢。

要访问公网时，用带这组变量的新任务。已经在跑的任务继续跑，等用户自己停掉并重新提交之后再生效。

## 在容器里检查

新 Pod 起来之后：

```bash
kubectl -n <namespace> exec deployment/<name> -- \
  curl -fsS -o /dev/null -w "%{http_code}\n" --connect-timeout 15 http://www.baidu.com
```

打印 `200` 就是代理已经生效。镜像里没有 `curl` 时，用 Python：

```bash
kubectl -n <namespace> exec deployment/<name> -- python -c \
  'import urllib.request; print(urllib.request.urlopen("http://www.baidu.com", timeout=15).status)'
```

没有这组变量时，同一个地址会解析失败或一直等到超时。`.hqzyai.com` 会让 `harbor.sz-prod.hqzyai.com` 这类地址不走代理。`curl`、`pip` 和 Go 程序认的是前面这个点，不认 `*.hqzyai.com`。
