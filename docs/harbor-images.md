# Harbor 镜像使用说明

新 K8s 集群从雄安 Harbor 拉取镜像。Harbor 地址与个人账号见华清云 SaaS。

| 项 | 值 |
|----|-----|
| Harbor 地址 | `https://harbor.xa.hqzyai.com:19443/` |
| Registry 主机名（K8s / Docker） | `harbor.xa.hqzyai.com:19443` |
| 示例默认镜像 | `harbor.xa.hqzyai.com:19443/llm-course/lab:v2` |

## 账号与项目

登录华清云 SaaS 后可查看：

- Harbor 用户名与密码（或 Robot 凭据，以 SaaS 展示为准）
- 个人 Harbor 项目名称，通常为 `cs-<用户名>`（如 `cs-wangxuedong`）

镜像按 **项目 / 仓库名 : 标签** 组织，完整路径示例：

```text
harbor.xa.hqzyai.com:19443/cs-<username>/my-app:v1
```

| 项目类型 | 命名示例 | 权限 |
|----------|----------|------|
| 平台示例 | `llm-course/lab:v2` | 仅 pull |
| 个人项目 | `cs-<username>/...` | pull / push（以 SaaS 分配为准） |

## 本机登录与镜像操作

```bash
docker login harbor.xa.hqzyai.com:19443
# 按 SaaS 提示输入用户名与密码

# 拉取平台示例镜像
docker pull harbor.xa.hqzyai.com:19443/llm-course/lab:v2

# 构建并 push 到个人项目
docker tag my-app:latest harbor.xa.hqzyai.com:19443/cs-<username>/my-app:v1
docker push harbor.xa.hqzyai.com:19443/cs-<username>/my-app:v1
```

## 在 K8s / Helm 中使用

个人 namespace 通常已配置 `imagePullSecret`，Pod 内无需重复 `docker login`。部署时填写 **完整镜像路径**：

Helm values：

```yaml
ContainerImage: harbor.xa.hqzyai.com:19443/llm-course/lab:v2
# 自定义任务：
# ContainerImage: harbor.xa.hqzyai.com:19443/cs-<username>/my-app:v1
```

原生 Deployment：

```yaml
image: harbor.xa.hqzyai.com:19443/cs-<username>/my-app:v1
```

Dockerfile：

```dockerfile
FROM harbor.xa.hqzyai.com:19443/llm-course/lab:v2
```

Chart 与 [`examples/helm/`](../examples/helm/) 下示例默认使用 `llm-course/lab:v2`。自定义业务镜像 push 到个人项目后，替换 `ContainerImage` 即可。

## 外部镜像纳入 Harbor 的推荐方式

若 Dockerfile 或任务依赖 Docker Hub、GHCR 等外部 Registry 镜像，建议在有出网条件的构建机上拉取原始镜像，**retag 并 push 到个人 Harbor 项目**，再在集群中使用个人项目路径：

```bash
docker pull python:3.12-slim
docker tag python:3.12-slim \
  harbor.xa.hqzyai.com:19443/cs-<username>/python:3.12-slim
docker push harbor.xa.hqzyai.com:19443/cs-<username>/python:3.12-slim
```

部署：

```yaml
ContainerImage: harbor.xa.hqzyai.com:19443/cs-<username>/python:3.12-slim
```

## 常见问题

**镜像拉取 `not found`**

- 核对 Registry 主机名为 `harbor.xa.hqzyai.com:19443`（不是 `9443`）。
- 核对项目名、仓库名与 tag 是否与 Harbor UI 一致。
- 个人项目镜像须已完成 `docker push`。
- 确认 namespace 的 `imagePullSecret` 有效（SaaS 侧 Harbor 账号变更后可能需更新 kubeconfig / secret）。

**`ImagePullBackOff`**

- 优先在 Harbor Web UI 确认 tag 是否存在。
- 大镜像首次拉取耗时较长，可通过 `kubectl describe pod` 查看事件是否仍在 `Pulling`。
- 若长期失败，核对镜像路径与个人项目权限。

**`Unauthorized` / 认证失败**

- 本机重新 `docker login harbor.xa.hqzyai.com:19443`。
- 集群内问题联系平台管理员核对 namespace 的 `imagePullSecret` 是否与当前 Harbor 账号一致。
