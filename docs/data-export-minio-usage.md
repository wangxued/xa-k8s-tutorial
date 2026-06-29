> **适用集群**：雄安院 K8s（`yw-k8s`）  
> **日期**：2026-06-29

# 数据导出 MinIO 使用说明

新集群提供 **data-export MinIO** 作为临时数据中转：在 Pod 内上传结果，在办公网本机下载。数据默认 **14 天** 自动清理，不用于长期归档。

## 入口信息

| 项 | 值 |
|---|---|
| 集群内上传（S3 API） | `http://data-minio-hl.data-export-minio.svc.cluster.local:9000` |
| 本机下载（公网） | `https://minio-data.xa.hqzyai.com:9443` |
| Bucket | `export` |
| 路径规范 | `<用户名>/<任务名>/`（避免与其他用户混放） |

账号由管理员单独发放（**`data-export-user`**，仅 S3 读写）：

```bash
export AWS_ACCESS_KEY_ID='...'
export AWS_SECRET_ACCESS_KEY='...'
```

5090 / H200 用户 Pod 均可经**集群内地址**上传；MinIO 服务运行在 H200 节点，与上传 Pod 所在节点无关。

> **Console 说明**：Web 控制台 `https://minio-data-console.xa.hqzyai.com:9443` 仅供运维，请用管理员账号 `dataExportAdmin` 登录。`data-export-user` 在 Console 中权限不足（如 `/quota` 403、Object Browser 异常）。**日常上传/下载请用 `mc`，不要用 Console。**

## 1. Pod 内上传

Pod 内需要 `mc`（MinIO Client）。未安装时可临时安装或使用示例 Pod。

### 容器内安装 mc

```bash
curl -fsSL https://dl.min.io/client/mc/release/linux-amd64/mc -o /usr/local/bin/mc
chmod +x /usr/local/bin/mc
```

### 上传命令

```bash
export AWS_ACCESS_KEY_ID='<管理员发放>'
export AWS_SECRET_ACCESS_KEY='<管理员发放>'
export MINIO_ENDPOINT='http://data-minio-hl.data-export-minio.svc.cluster.local:9000'
export MINIO_BUCKET='export'
export NO_PROXY='localhost,127.0.0.1,.svc,.svc.cluster.local,.cluster.local,10.96.0.0/12,10.63.252.0/24,10.60.0.0/24'

mc alias set data-minio "$MINIO_ENDPOINT" "$AWS_ACCESS_KEY_ID" "$AWS_SECRET_ACCESS_KEY"
mc cp --recursive /path/to/data data-minio/export/<用户名>/<任务名>/
```

集群内为 **HTTP**（Pod 网络内可达即可）；公网经 Envoy Gateway **HTTPS :9443** 暴露。

### 使用临时 mc Pod（不改业务镜像）

```bash
kubectl apply -f examples/raw-yaml/minio-client-pod.yaml
kubectl exec -it minio-client -- sh
# 在容器内设置凭据与 NO_PROXY 后执行 mc cp
```

## 2. 本机下载

本机安装 `mc` 后：

```bash
# macOS Apple Silicon 示例
curl -fsSL https://dl.min.io/client/mc/release/darwin-arm64/mc -o mc
chmod +x mc

export AWS_ACCESS_KEY_ID='<管理员发放>'
export AWS_SECRET_ACCESS_KEY='<管理员发放>'

./mc alias set data-minio https://minio-data.xa.hqzyai.com:9443 \
  "$AWS_ACCESS_KEY_ID" "$AWS_SECRET_ACCESS_KEY"

./mc mirror --retry data-minio/export/<用户名>/<任务名>/ ./downloads/
```

目录下载推荐使用 `mc mirror --retry`：已完整落盘且大小一致的文件会跳过，失败项自动重试。

**断点续传说明**：单个大文件不支持字节级续传；中断后需重新下载该文件。目录批量下载时，`mirror --retry` 可跳过已完成的文件。

## 3. 检查与清理

```bash
mc ls --recursive data-minio/export/<用户名>/<任务名>/
mc rm --recursive --force data-minio/export/<用户名>/<任务名>/
```

## 4. 与其他存储的分工

| 场景 | 推荐方式 |
|------|----------|
| 编译缓存、短期 scratch | `local-path` scratch PVC |
| 5090 共享训练数据 | `h3c-csi-sc-nfs` |
| H200 共享权重 / checkpoint | `h3c-csi-sc-nfs` 或 `h3c-csi-sc-epc` |
| **导出结果到办公网** | **data-export MinIO**（本文） |

MinIO 中转面向「集群 → 办公网」临时导出；集群内长期数据仍应使用个人 NFS/EPC PVC。详见 [GPU 工作负载场景选型](gpu-workload-scenarios.md)。

## 注意事项

- 仅用于临时中转，文件 14 天后自动过期。
- Pod 内访问集群内 S3 时，`NO_PROXY` 须包含 `.svc.cluster.local`。
- 公网下载地址端口为 **9443**（Envoy Gateway），格式：`https://<子域名>.xa.hqzyai.com:9443/`。
- 集群内 S3 为 **HTTP**；勿对集群内地址使用 `mc --insecure` 以外的 HTTPS URL。
