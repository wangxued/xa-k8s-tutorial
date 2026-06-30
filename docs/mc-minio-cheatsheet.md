# mc 命令速查：上传 / 下载（文件与目录）

> 适用：云网 data-export MinIO 中转。  
> 使用前：`mc alias set <别名> <endpoint> "$AWS_ACCESS_KEY_ID" "$AWS_SECRET_ACCESS_KEY"`

## cp 与 mirror 怎么选？

| 命令 | 适用对象 | 作用 |
|------|----------|------|
| **`mc cp`** | **单个文件**，或加 **`--recursive`** 的**目录** | 复制一次；目录递归复制 |
| **`mc mirror --retry`** | **仅目录 ↔ 目录** | 同步两侧目录；已一致文件可跳过；失败自动重试 |

**结论**：

- **`mc cp` 既能传文件也能传目录**（目录须加 `--recursive`）。
- **`mc mirror` 只能用于目录**（源、目标都应是目录路径，通常以 `/` 结尾）；不适合单个文件。
- **推荐**：单文件用 `mc cp`；整目录批量传输用 `mc mirror --retry`（断点友好、可跳过已完成文件）。

---

## 配置 alias

**Pod 内（集群内 HTTP）**：

```bash
export NO_PROXY='localhost,127.0.0.1,.svc,.svc.cluster.local,.cluster.local,10.96.0.0/12,10.63.252.0/24,10.60.0.0/24'
mc alias set data-minio http://data-minio-hl.data-export-minio.svc.cluster.local:9000 \
  "$AWS_ACCESS_KEY_ID" "$AWS_SECRET_ACCESS_KEY"
```

**办公网本机（公网 HTTPS）**：

```bash
mc alias set data-minio https://minio-data.xa.hqzyai.com:9443 \
  "$AWS_ACCESS_KEY_ID" "$AWS_SECRET_ACCESS_KEY"
```

---

## 上传

| 对象 | 命令 |
|------|------|
| **单个文件** | `mc cp /path/to/file.bin data-minio/export/<用户名>/<任务名>/file.bin` |
| **整个目录** | `mc cp --recursive /path/to/dir/ data-minio/export/<用户名>/<任务名>/` |
| **整个目录（推荐批量）** | `mc mirror --retry /path/to/dir/ data-minio/export/<用户名>/<任务名>/` |

---

## 下载

| 对象 | 命令 |
|------|------|
| **单个文件** | `mc cp data-minio/export/<用户名>/<任务名>/file.bin ./downloads/file.bin` |
| **整个目录** | `mc cp --recursive data-minio/export/<用户名>/<任务名>/ ./downloads/` |
| **整个目录（推荐批量）** | `mc mirror --retry data-minio/export/<用户名>/<任务名>/ ./downloads/` |

---

## 列举与删除

```bash
mc ls data-minio/export/<用户名>/<任务名>/
mc ls --recursive data-minio/export/<用户名>/<任务名>/
mc rm data-minio/export/<用户名>/<任务名>/single-file.bin
mc rm --recursive --force data-minio/export/<用户名>/<任务名>/
```

---

## 与辅助脚本的对应关系

| 场景 | 脚本 | 底层 mc |
|------|------|---------|
| Pod 上传文件/目录 | `scripts/minio/pod-upload-to-minio.sh` | `mc cp --recursive` |
| Pod 下载文件/目录 | `scripts/minio/pod-download-from-minio.sh` | 单文件 `mc cp`；目录 `mc mirror --retry` |
| 本机公网上传 | `scripts/minio/local-upload-to-minio.sh` | 单文件 `mc cp`；目录 `mc mirror --retry` |
| 本机公网下载 | `scripts/minio/local-download-from-minio.sh` | 单文件 `mc cp`；目录 `mc mirror --retry` |

---

## 常见误区

1. **`mc mirror` 不能传单个文件** — 单文件请用 `mc cp`。
2. **`mc cp` 传目录必须加 `--recursive`** — 否则无法递归复制目录内容。
3. **路径末尾 `/`** — 目录建议写成 `localdir/` 与 `alias/bucket/prefix/`。
4. **单个大文件无字节级断点续传** — 中断后重跑 `mc cp` 会重新传；目录用 `mirror --retry` 可跳过已完成文件。

更多场景说明见 [data-export-minio-usage.md](data-export-minio-usage.md)。
