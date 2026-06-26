# Web 服务 HTTPRoute 配置与访问

雄安院 K8s 集群使用 Gateway API `HTTPRoute` 暴露用户 Web 服务。用户只需要在个人 namespace 内创建 `Service` 和 `HTTPRoute`，外部通过 `https://<域名>:9443/` 访问。

## 访问链路

```text
浏览器
  -> https://<子域名>.xa.hqzyai.com:9443/
  -> 集群公网入口
  -> 平台预置 Gateway
  -> HTTPRoute
  -> Service
  -> Pod 内 Web 端口
```

示例：

```text
域名：demo.xa.hqzyai.com
容器端口：7860
外部访问地址：https://demo.xa.hqzyai.com:9443/
```

注意：外部访问端口是 `9443`，不是容器端口 `7860`。

## 前置条件

1. 已配置本机 kubeconfig。
2. 已切换到个人 namespace。
3. Web 程序在容器内监听 `0.0.0.0:<端口>`，不能只监听 `127.0.0.1`。
4. 域名已按平台规则申请或分配。

## Helm Chart 方式

使用 `xay-ai` Chart 时，在 values 中设置：

```yaml
ExtraPort: 7860

HTTPRoute:
  enabled: true
  host: demo.xa.hqzyai.com
  parentRef:
    name: yunwang-public
    namespace: envoy-gateway-system
    sectionName: https-wildcard-8443
  servicePort: 7860
  pathPrefix: /
```

启动命令示例：

```yaml
Command: '["bash", "-lc", "--"]'
Args: '["python app.py --host 0.0.0.0 --port 7860"]'
```

部署：

```bash
helm upgrade --install web-demo ./charts/xay-ai \
  -n <namespace> \
  -f values-web.yaml
```

访问：

```text
https://demo.xa.hqzyai.com:9443/
```

## 原生 YAML 方式

### Service

```yaml
apiVersion: v1
kind: Service
metadata:
  name: web-demo
  namespace: your-namespace
spec:
  type: ClusterIP
  selector:
    app: web-demo
  ports:
    - name: http
      port: 7860
      targetPort: 7860
      protocol: TCP
```

### HTTPRoute

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: web-demo
  namespace: your-namespace
spec:
  parentRefs:
    - name: yunwang-public
      namespace: envoy-gateway-system
      sectionName: https-wildcard-8443
  hostnames:
    - demo.xa.hqzyai.com
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /
      backendRefs:
        - name: web-demo
          port: 7860
```

应用：

```bash
kubectl apply -f service-web.yaml
kubectl apply -f httproute-web.yaml
```

## 验证命令

查看 Service：

```bash
kubectl get svc
kubectl describe svc web-demo
```

查看 HTTPRoute：

```bash
kubectl get httproute
kubectl describe httproute web-demo
```

检查 Pod 是否监听端口：

```bash
kubectl get pod -l app=web-demo
kubectl logs <pod-name> --tail=100
kubectl exec -it <pod-name> -- ss -lntp
```

本地访问验证：

```bash
curl -kI https://demo.xa.hqzyai.com:9443/
```

## 常见问题

### 访问 404

常见原因：

- `HTTPRoute.hostnames` 与浏览器访问域名不一致。
- `parentRef.sectionName` 填错。
- `Service` 名称或端口与 `backendRefs` 不一致。

### 访问 503 或 502

常见原因：

- Service 没有 endpoints，Pod 标签与 Service selector 不匹配。
- Pod 未启动或 readiness 未通过。
- 容器内程序未监听对应端口。

检查：

```bash
kubectl get endpoints web-demo
kubectl describe pod <pod-name>
```

### 浏览器无法打开

常见原因：

- 域名未按平台规则申请或未解析到集群入口。
- URL 未带端口 `9443`。
- 容器程序只监听了 `127.0.0.1`。

正确访问格式：

```text
https://<子域名>.xa.hqzyai.com:9443/
```

## 注意事项

- `parentRef` 指向平台预置 Gateway，普通用户不要修改。
- 当前用户 Web 服务统一使用 HTTPS `9443` 入口。
- 不需要创建 Ingress，也不需要自行配置 TLS Secret。
- 域名和对外访问策略以平台分配为准。
