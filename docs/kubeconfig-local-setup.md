# 本机 kubeconfig 配置与多集群管理

本文说明如何在本机终端配置雄安院 K8s 集群 kubeconfig，并处理本机已有多套 kubeconfig 的情况。

## 前置条件

- 已联系平台管理员创建账号。
- 已登录华清云 SaaS：<https://xaai.hqzyai.com:19443/>
- 已在 SaaS 平台查看个人 namespace，并下载专属 kubeconfig。
- 本机已安装 `kubectl`。

## 推荐目录

建议将雄安院 kubeconfig 单独保存为独立文件，不直接覆盖默认 `~/.kube/config`。

```bash
mkdir -p ~/.kube
cp ~/Downloads/kubeconfig ~/.kube/xay-config
chmod 600 ~/.kube/xay-config
```

验证文件可读取：

```bash
kubectl --kubeconfig ~/.kube/xay-config config get-contexts
```

## 方案一：单次命令指定 kubeconfig

适合临时访问或脚本中使用，不修改本机默认配置。

```bash
kubectl --kubeconfig ~/.kube/xay-config get pods
kubectl --kubeconfig ~/.kube/xay-config get pvc
```

优点：

- 不影响本机已有 K8s 配置。
- 不依赖 Shell 环境变量。

缺点：

- 每条命令都需要带 `--kubeconfig`。

## 方案二：使用 KUBECONFIG 环境变量

适合日常终端使用。当前终端会默认使用雄安院 kubeconfig。

```bash
export KUBECONFIG=$HOME/.kube/xay-config
kubectl get pods
```

如需长期生效，可写入 `~/.zshrc`：

```bash
echo 'export KUBECONFIG=$HOME/.kube/xay-config' >> ~/.zshrc
source ~/.zshrc
```

## 方案三：运行时合并多套 kubeconfig

本机已有多个集群时，推荐使用 `KUBECONFIG` 运行时合并。该方式不会修改原始文件。

```bash
export KUBECONFIG=$HOME/.kube/xay-config:$HOME/.kube/config
kubectl config get-contexts
kubectl config use-context <context-name>
```

说明：

- macOS / Linux 使用冒号 `:` 分隔多个 kubeconfig 文件。
- 多个文件中如果存在重名 `context`、`cluster`、`user`，左侧文件优先。
- 执行 `kubectl config set-context` 等写操作时，默认写入最左侧文件。

如需长期使用，可写入 `~/.zshrc`：

```bash
echo 'export KUBECONFIG=$HOME/.kube/xay-config:$HOME/.kube/config' >> ~/.zshrc
source ~/.zshrc
```

## 方案四：合并到默认 ~/.kube/config

只有在确实希望所有集群集中在一个默认文件中时，才使用该方案。操作前必须备份。

### 正确做法

先备份：

```bash
cp ~/.kube/config ~/.kube/config.backup.$(date +%Y%m%d-%H%M%S)
```

输出到临时文件：

```bash
KUBECONFIG=$HOME/.kube/config:$HOME/.kube/xay-config \
  kubectl config view --flatten > ~/.kube/config.merged
```

验证临时文件：

```bash
kubectl --kubeconfig ~/.kube/config.merged config get-contexts
```

确认 context 都存在后再替换：

```bash
mv ~/.kube/config.merged ~/.kube/config
chmod 600 ~/.kube/config
```

### 不要使用追加

不要执行：

```bash
kubectl config view --flatten >> ~/.kube/config
```

`>>` 会把一份完整 kubeconfig 追加到另一份完整 kubeconfig 文件末尾，容易产生重复的顶层配置结构。`kubectl` 在某些情况下仍能解析，但 Lens、VS Code Kubernetes 插件等工具可能会把同一 context 展示成多份。

### 不要直接覆盖正在读取的文件

不要执行：

```bash
KUBECONFIG=$HOME/.kube/config:$HOME/.kube/xay-config \
  kubectl config view --flatten > ~/.kube/config
```

如果 `~/.kube/config` 同时也是输入文件，Shell 会先清空输出目标，再启动 `kubectl` 读取输入，导致原有 context 丢失。

## 设置默认 namespace

登录 SaaS 平台查看专属 namespace 后，将下面命令中的 `<namespace>` 替换为实际名称：

```bash
kubectl config set-context --current --namespace=<namespace>
```

验证当前 namespace：

```bash
kubectl config view --minify --output 'jsonpath={..namespace}{"\n"}'
```

验证访问权限：

```bash
kubectl get pods
kubectl get pvc
kubectl auth can-i create deployment
kubectl auth can-i create pvc
```

## Lens / VS Code 重复显示 context

如果 Lens 或 VS Code Kubernetes 插件里同一集群显示两份，常见原因是同一集群被从多个来源加载：

- 独立 kubeconfig 文件，例如 `~/.kube/xay-config`。
- 合并后的默认文件 `~/.kube/config`。
- 曾经使用 `>> ~/.kube/config` 追加过完整 kubeconfig。

建议只添加一种来源：

- 要么添加独立的 `~/.kube/xay-config`。
- 要么添加合并后的 `~/.kube/config`。

不要同时添加两者。

## 常用命令

查看当前使用的 context：

```bash
kubectl config current-context
```

查看所有 context：

```bash
kubectl config get-contexts
```

切换 context：

```bash
kubectl config use-context <context-name>
```

查看当前 kubeconfig 中的 namespace：

```bash
kubectl config view --minify
```

指定 kubeconfig 查看资源：

```bash
kubectl --kubeconfig ~/.kube/xay-config get pods -n <namespace>
```
