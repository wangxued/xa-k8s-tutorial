# 深圳临时集群 sz-k8s 部署示例

这是 4 台公网 H200 的临时集群（`sz-gpu-10/13/14/18`，`harbor.sz.hqzyai.com`）。新集群 `sz-k8s-prod`（5 台 H800）不要用这篇，也不要挂 hostPath。请看 [`sz-k8s-prod-pod.md`](sz-k8s-prod-pod.md)。

临时集群用 [`examples/helm/values-sz-h200-hostpath.yaml`](../examples/helm/values-sz-h200-hostpath.yaml)。复制后改 namespace、节点、目录名和镜像。

```bash
cp examples/helm/values-sz-h200-hostpath.yaml values-my-sz.yaml
vi values-my-sz.yaml

helm upgrade --install my-task ./charts/xay-ai \
  -n <namespace> \
  -f values-my-sz.yaml
```

`NodeSelector` 必须和 hostPath 目录在同一台机器上。换节点等于换盘。

优先选 **10GbE 网口** 的节点（`sz-gpu-13` / `sz-gpu-14` / `sz-gpu-18`）。`sz-gpu-10` 是 **1GbE 网口**，拉大镜像会慢。

## 镜像

深圳仓：`https://harbor.sz.hqzyai.com/`。项目和账号由华清云自动创建，登录 SaaS 查看个人项目名（一般是 `cs-<用户名>`）和凭据后再 push：

```bash
docker login harbor.sz.hqzyai.com
docker push harbor.sz.hqzyai.com/cs-<username>/lab:v1
```

把 `ContainerImage` 改成这张镜像。大镜像请推深圳仓，不要从云网 `harbor.xa.hqzyai.com:19443` 现场拉十几 GB。公司公共仓仍可用 `harbor.hqzyai.com`。
