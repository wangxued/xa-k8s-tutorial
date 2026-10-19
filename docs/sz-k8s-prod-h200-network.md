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
| `harbor.sz-prod.hqzyai.com` | 本集群镜像仓库，走集群内入口 |

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
    value: "localhost,127.0.0.1,::1,10.244.0.0/16,10.96.0.0/12,.svc,.cluster.local,cluster.local,harbor.sz-prod.hqzyai.com"
  - name: NO_PROXY
    value: "localhost,127.0.0.1,::1,10.244.0.0/16,10.96.0.0/12,.svc,.cluster.local,cluster.local,harbor.sz-prod.hqzyai.com"
```

可以直接复制 [`examples/helm/values-sz-k8s-prod-h200.yaml`](../examples/helm/values-sz-k8s-prod-h200.yaml)，里面已经写好这组变量。其余磁盘字段按 [`sz-k8s-prod-pod.md`](sz-k8s-prod-pod.md) 填写，然后升级：

```bash
helm upgrade --install my-task ./charts/xay-ai \
  -n <namespace> \
  -f values-my-sz-prod.yaml
```

升级会重建 Pod。还没写进 PVC 的文件会消失，先把要留的数据放到 `/workspace`。

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
              value: "localhost,127.0.0.1,::1,10.244.0.0/16,10.96.0.0/12,.svc,.cluster.local,cluster.local,harbor.sz-prod.hqzyai.com"
            - name: NO_PROXY
              value: "localhost,127.0.0.1,::1,10.244.0.0/16,10.96.0.0/12,.svc,.cluster.local,cluster.local,harbor.sz-prod.hqzyai.com"
```

已经在跑的 Deployment 可以用命令补上，效果和改 YAML 后再 `kubectl apply` 相同，Pod 会滚动重建：

```bash
kubectl -n <namespace> set env deployment/<name> \
  http_proxy=http://33.1.42.5:8888 \
  https_proxy=http://33.1.42.5:8888 \
  HTTP_PROXY=http://33.1.42.5:8888 \
  HTTPS_PROXY=http://33.1.42.5:8888 \
  no_proxy=localhost,127.0.0.1,::1,10.244.0.0/16,10.96.0.0/12,.svc,.cluster.local,cluster.local,harbor.sz-prod.hqzyai.com \
  NO_PROXY=localhost,127.0.0.1,::1,10.244.0.0/16,10.96.0.0/12,.svc,.cluster.local,cluster.local,harbor.sz-prod.hqzyai.com
```

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

没有这组变量时，同一个地址会解析失败或一直等到超时。本集群 Harbor `harbor.sz-prod.hqzyai.com` 在 `no_proxy` 里，容器访问它不经过代理。
