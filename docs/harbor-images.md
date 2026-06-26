# Harbor 镜像使用说明

云网 K8s 集群优先从雄安 Harbor 拉取镜像。Harbor 地址与 SaaS 分配的账号见华清云 SaaS。

| 项 | 值 |
|----|-----|
| Harbor 地址 | `https://harbor.xa.hqzyai.com:19443/` |
| 示例默认镜像 | `harbor.xa.hqzyai.com:19443/llm-course/lab:v2` |

## 示例默认镜像

Chart 与示例默认使用 `llm-course/lab:v2`：

```yaml
ContainerImage: harbor.xa.hqzyai.com:19443/llm-course/lab:v2
```

业务镜像 push 到 SaaS 分配的个人 Harbor 项目（如 `cs-<用户名>`）后，替换 `ContainerImage` 即可。

## 本机拉取与推送

```bash
docker login harbor.xa.hqzyai.com:19443
docker pull harbor.xa.hqzyai.com:19443/llm-course/lab:v2
docker tag my-app:latest harbor.xa.hqzyai.com:19443/cs-<username>/my-app:v1
docker push harbor.xa.hqzyai.com:19443/cs-<username>/my-app:v1
```

K8s 部署时在 values 或 YAML 中填写完整镜像路径；namespace 已配置 `imagePullSecret` 时，Pod 内无需重复登录。

## 镜像代理项目

雄安 Harbor 提供 Proxy Cache 项目，按需缓存外部 Registry 镜像。Pod 与 Dockerfile 统一使用 **`harbor.xa.hqzyai.com:19443/<代理项目>/...`** 路径。

| 代理项目 | 对应上游 | 路径示例 |
|----------|----------|----------|
| `dockerhub-proxy` | Docker Hub | `harbor.xa.hqzyai.com:19443/dockerhub-proxy/library/python:3.12-slim` |
| `ghcr-proxy` | `ghcr.io` | `harbor.xa.hqzyai.com:19443/ghcr-proxy/<org>/<repo>:<tag>` |
| `quay-proxy` | `quay.io` | `harbor.xa.hqzyai.com:19443/quay-proxy/<path>:<tag>` |
| `registry-k8s-proxy` | `registry.k8s.io` | `harbor.xa.hqzyai.com:19443/registry-k8s-proxy/<path>:<tag>` |
| `nvcr-proxy` | `nvcr.io` | `harbor.xa.hqzyai.com:19443/nvcr-proxy/<path>:<tag>` |

代理项目为**只读**，不支持 push。

### 路径换算规则

**Docker Hub（`dockerhub-proxy`）**

Docker Hub 官方镜像（无组织前缀）须加 `library/`：

| 上游写法 | Harbor 路径 |
|----------|-------------|
| `python:3.12-slim` | `harbor.xa.hqzyai.com:19443/dockerhub-proxy/library/python:3.12-slim` |
| `busybox:1.36` | `harbor.xa.hqzyai.com:19443/dockerhub-proxy/library/busybox:1.36` |
| `grafana/grafana:12.3.0` | `harbor.xa.hqzyai.com:19443/dockerhub-proxy/grafana/grafana:12.3.0` |

**GHCR（`ghcr-proxy`）**

去掉 `ghcr.io/` 前缀，其余路径不变：

| 上游 | Harbor 路径 |
|------|-------------|
| `ghcr.io/org/app:v1` | `harbor.xa.hqzyai.com:19443/ghcr-proxy/org/app:v1` |

**registry.k8s.io（`registry-k8s-proxy`）**

去掉 `registry.k8s.io/` 前缀：

| 上游 | Harbor 路径 |
|------|-------------|
| `registry.k8s.io/pause:3.10` | `harbor.xa.hqzyai.com:19443/registry-k8s-proxy/pause:3.10` |
| `registry.k8s.io/coredns/coredns:v1.12.4` | `harbor.xa.hqzyai.com:19443/registry-k8s-proxy/coredns/coredns:v1.12.4` |

**NVIDIA NGC（`nvcr-proxy`）**

去掉 `nvcr.io/` 前缀：

| 上游 | Harbor 路径 |
|------|-------------|
| `nvcr.io/nvidia/pytorch:24.01-py3` | `harbor.xa.hqzyai.com:19443/nvcr-proxy/nvidia/pytorch:24.01-py3` |

**Quay（`quay-proxy`）**

去掉 `quay.io/` 前缀：

| 上游 | Harbor 路径 |
|------|-------------|
| `quay.io/prometheus/node-exporter:v1.8.0` | `harbor.xa.hqzyai.com:19443/quay-proxy/prometheus/node-exporter:v1.8.0` |

## 在 K8s / Helm 中使用

Helm values：

```yaml
ContainerImage: harbor.xa.hqzyai.com:19443/dockerhub-proxy/library/python:3.12-slim
```

原生 Deployment：

```yaml
image: harbor.xa.hqzyai.com:19443/dockerhub-proxy/library/python:3.12-slim
```

Dockerfile：

```dockerfile
FROM harbor.xa.hqzyai.com:19443/dockerhub-proxy/library/python:3.12-slim
```

## 个人项目：固定版本镜像

如需长期固定某版本、减少重复拉取，可将代理镜像 retag 后 push 到个人项目：

```bash
docker pull harbor.xa.hqzyai.com:19443/dockerhub-proxy/library/python:3.12-slim
docker tag harbor.xa.hqzyai.com:19443/dockerhub-proxy/library/python:3.12-slim \
  harbor.xa.hqzyai.com:19443/cs-<username>/python:3.12-slim
docker push harbor.xa.hqzyai.com:19443/cs-<username>/python:3.12-slim
```

## 常见问题

**镜像拉取 `not found`**

- 核对代理项目名称、路径与 tag。
- Docker Hub 官方镜像是否遗漏 `library/`。
- 确认代理项目类型为 Proxy Cache，且已绑定对应仓库目标。
- 确认 `imagePullSecret` 有效（个人项目 pull 时）。

**`ImagePullBackOff`**

- Registry 须为 `harbor.xa.hqzyai.com:19443`（不是 `9443`）。
- 代理项目首次拉取需等待缓存完成，大镜像耗时较长属正常现象。
- 优先核对镜像 tag 是否存在（例如 `pause:3.9` 等旧 tag 可能已不可用，可换用较新版本）。

**业务镜像与代理镜像的区别**

| 类型 | 项目 | 操作 |
|------|------|------|
| 业务镜像 | `cs-*`、`llm-course` 等 | 可 push / pull |
| 代理镜像 | `*-proxy` | 仅 pull（只读缓存） |
