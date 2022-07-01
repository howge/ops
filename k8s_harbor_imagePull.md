# 设置默认SA从harbor拉取镜像
>前置条件
已经docker login 到harbor

```console
# kubectl create secret generic regcred --from-file=.dockerconfigjson=/root/.docker/config.json --type=kubernetes.io/dockerconfigjson -n your-namespace
# kubectl patch serviceaccount default -p '{"imagePullSecrets": [{"name": "regcred"}]}' -n your-namespace
# kubectl  get sa default -n your-namespace -o yaml
apiVersion: v1
imagePullSecrets:
- name: regcred
kind: ServiceAccount
metadata:
  creationTimestamp: "2022-06-30T07:17:16Z"
  name: default
  namespace: dev
  resourceVersion: "5406041"
  uid: bbefd6ff-d915-4797-b04a-729b96f7c831
secrets:
- name: default-token-zvvbb
```
