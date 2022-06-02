# 如何暴露prometheus 到k8s集群外部
>前置条件
1. k8s 集群安装完毕 (略) v1.23
2. nginx ingress 安装完毕（略）
3. [项目地址](https://github.com/prometheus-operator/kube-prometheus/blob/main/docs/customizations/exposing-prometheus-alertmanager-grafana-ingress.md)
>安装prometheus

```console
# unzip v0.10.0.zip #根据集群版本选择相应的版本
# cd kube-prometheus-0.10.0/
# kubectl apply --server-side -f manifests/setup
# kubectl apply -f manifests/
```
>删除prometheus（如果需要）
```console
# kubectl delete --ignore-not-found=true -f manifests/ -f manifests/setup
```
>检查安装结果，如果中途有image拉不下来，可以从自己的harbor下载，结果如下:
```console
# kubectl get pods -n monitoring
NAME                                   READY   STATUS    RESTARTS   AGE
alertmanager-main-0                    2/2     Running   0          5h38m
alertmanager-main-1                    2/2     Running   0          5h38m
alertmanager-main-2                    2/2     Running   0          5h38m
blackbox-exporter-6b79c4588b-6xhxb     3/3     Running   0          5h38m
grafana-7fd69887fb-rj59t               1/1     Running   0          5h38m
kube-state-metrics-55f67795cd-pw5cq    3/3     Running   0          5h38m
node-exporter-mr44f                    2/2     Running   0          5h38m
node-exporter-nb7cz                    2/2     Running   0          5h38m
node-exporter-v7jx6                    2/2     Running   0          5h38m
prometheus-adapter-85664b6b74-mwcql    1/1     Running   0          5h38m
prometheus-adapter-85664b6b74-zzsf2    1/1     Running   0          5h38m
prometheus-k8s-0                       2/2     Running   0          5h38m
prometheus-k8s-1                       2/2     Running   0          5h38m
prometheus-operator-6dc9f66cb7-wxglp   2/2     Running   0          5h38m

# kubectl get svc  -n monitoring 
NAME                    TYPE        CLUSTER-IP        EXTERNAL-IP   PORT(S)                      AGE
alertmanager-main       ClusterIP   192.168.100.142   <none>        9093/TCP,8080/TCP            5h40m
alertmanager-operated   ClusterIP   None              <none>        9093/TCP,9094/TCP,9094/UDP   5h40m
blackbox-exporter       ClusterIP   192.168.100.15    <none>        9115/TCP,19115/TCP           5h40m
grafana                 ClusterIP   192.168.100.158   <none>        3000/TCP                     5h40m
kube-state-metrics      ClusterIP   None              <none>        8443/TCP,9443/TCP            5h40m
node-exporter           ClusterIP   None              <none>        9100/TCP                     5h40m
prometheus-adapter      ClusterIP   192.168.100.123   <none>        443/TCP                      5h40m
prometheus-k8s          ClusterIP   192.168.100.199   <none>        9090/TCP,8080/TCP            5h40m
prometheus-operated     ClusterIP   None              <none>        9090/TCP                     5h40m
prometheus-operator     ClusterIP   None              <none>        8443/TCP                     5h40m
```
>生成ingress文件
- 安装&设置go
```console
# cd kube-prometheus-0.10.0
# yum install golang -y
# yum install httpd-tools #install htpasswd
# export GOPROXY=https://goproxy.cn #基于国内环境设置代理
# go install github.com/brancz/gojsontoyaml@latest # 
# go install github.com/google/go-jsonnet/cmd/jsonnet@latest
# htpasswd -c auth <username> #username http basi cauth 用户名
```
- 修改生成ingress文件
```console
# >example.jsonnet
# cp  example/ingress.jsonnet example.jsonnet
# vim example.jsonnet #修改如下内容
```
```code
local ingress(name, namespace, rules) = {
  apiVersion: 'networking.k8s.io/v1',
  kind: 'Ingress',
  metadata: {
    name: name,
    namespace: namespace,
    annotations: {
      'nginx.ingress.kubernetes.io/auth-type': 'basic',
      'nginx.ingress.kubernetes.io/auth-secret': 'basic-auth',
      'nginx.ingress.kubernetes.io/auth-realm': 'Authentication Required',
    },
  },
  spec: { rules: rules },
};

local kp =
  //(import 'kube-prometheus/main.libsonnet') +
  (import './jsonnet/kube-prometheus/main.libsonnet') +
  {
    values+:: {
      common+: {
        namespace: 'monitoring',
      },
      grafana+:: {
        config+: {
          sections+: {
            server+: {
              root_url: 'http://grafana.example.com/', //自定义暴露的url 下同
            },
          },
        },
      },
    },
    // Configure External URL's per application
    alertmanager+:: {
      alertmanager+: {
        spec+: {
          externalUrl: 'http://alertmanager.example.com', 
        },
      },
    },
    prometheus+:: {
      prometheus+: {
        spec+: {
          externalUrl: 'http://prometheus.example.com',
        },
      },
    },
    // Create ingress objects per application
    ingress+:: {
      'alertmanager-main': ingress(
        'alertmanager-main',
        $.values.common.namespace,
        [{
          host: 'alertmanager.example.com',
          http: {
            paths: [{
              path: '/',
              pathType: 'Prefix',
              backend: {
                service: {
                  name: 'alertmanager-main',
                  port: {
                    name: 'web',
                  },
                },
              },
            }],
          },
        }]
      ),
      grafana: ingress(
        'grafana',
        $.values.common.namespace,
        [{
          host: 'grafana.example.com',
          http: {
            paths: [{
              path: '/',
              pathType: 'Prefix',
              backend: {
                service: {
                  name: 'grafana',
                  port: {
                    name: 'http',
                  },
                },
              },
            }],
          },
        }],
      ),
      'prometheus-k8s': ingress(
        'prometheus-k8s',
        $.values.common.namespace,
        [{
          host: 'prometheus.example.com',
          http: {
            paths: [{
              path: '/',
              pathType: 'Prefix',
              backend: {
                service: {
                  name: 'prometheus-k8s',
                  port: {
                    name: 'web',
                  },
                },
              },
            }],
          },
        }],
      ),
    },
  } + {
    // Create basic auth secret - replace 'auth' file with your own
    ingress+:: {
      'basic-auth-secret': {
        apiVersion: 'v1',
        kind: 'Secret',
        metadata: {
          name: 'basic-auth',
          namespace: $.values.common.namespace,
        },
        data: { auth: std.base64(importstr 'auth') },
        type: 'Opaque',
      },
    },
  };

{ [name + '-ingress']: kp.ingress[name] for name in std.objectFields(kp.ingress) }
```

- 生成最终文件
```console
# ./build.sh example.jsonnet
+ set -o pipefail
++ pwd
+ PATH=/root/kube-prometheus-0.10.0/tmp/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/root/bin
+ rm -rf manifests
+ mkdir -p manifests/setup
+ xargs '-I{}' sh -c 'cat {} | gojsontoyaml > {}.yaml' -- '{}'
+ jsonnet -J vendor -m manifests example.jsonnet
+ find manifests -type f '!' -name '*.yaml' -delete
+ rm -f kustomization
# cd manifests/
# ls
alertmanager-main-ingress.yaml  basic-auth-secret-ingress.yaml  grafana-ingress.yaml  prometheus-k8s-ingress.yaml  setup
# cat prometheus-k8s-ingress.yaml
```
```code
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  annotations:
    kubernetes.io/ingress.class: nginx # 新增，不然会报错找到ingress class
    nginx.ingress.kubernetes.io/auth-realm: Authentication Required
    nginx.ingress.kubernetes.io/auth-secret: basic-auth
    nginx.ingress.kubernetes.io/auth-type: basic
  name: prometheus-k8s
  namespace: monitoring
spec:
  rules:
  - host: prometheus.example.com
    http:
      paths:
      - backend:
          service:
            name: prometheus-k8s
            port:
              name: web
        path: /
        pathType: Prefix
```
- 生效配置
```console
# kubectl apply -f <name>.yaml
```

- 检查配置
```console
# kubectl get  ing -n  monitoring
grafana          <none>   grafana.example.com      192.168.100.128   80      95m
prometheus-k8s   <none>   prometheus.example.com   192.168.100.128   80      6h7m
```

###### The End
