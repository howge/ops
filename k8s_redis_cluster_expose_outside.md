## k8s(v1.23) 部署redis集群，借助redis-cluster-proxy 暴露服务到集群外部
> 安装nfs server和客户端工具
```console
# yum install nfs-utils -y # 集群内部节点都需要安装，不然容器启动报错
# systemctl enable rpcbind
# vim  /etc/exports # 

/data/redis/redis-cluster0     10.0.0.0/24(rw,sync,no_root_squash,no_all_squash)
/data/redis/redis-cluster1     10.0.0.0/24(rw,sync,no_root_squash,no_all_squash)
/data/redis/redis-cluster2     10.0.0.0/24(rw,sync,no_root_squash,no_all_squash)
/data/redis/redis-cluster3     10.0.0.0/24(rw,sync,no_root_squash,no_all_squash)
/data/redis/redis-cluster4     10.0.0.0/24(rw,sync,no_root_squash,no_all_squash)
/data/redis/redis-cluster5     10.0.0.0/24(rw,sync,no_root_squash,no_all_squash)
# sevice nfs restart
```
> 创建PV(redis-cluster-pv.yaml)
```console
# cat redis-cluster-pv.yaml
# kubectl apply -f redis-cluster-pv.yaml
apiVersion: v1
kind: PersistentVolume
metadata:
  name: nfs-pv0
  labels:
    pv: nfs-pv0
spec:
  capacity:
    storage: 1Gi
  accessModes:
    - ReadWriteMany
  nfs:
    server:  10.0.0.87
    path: /data/redis/redis-cluster0

---
apiVersion: v1
kind: PersistentVolume
metadata:
  name: nfs-pv1
  labels:
    pv: nfs-pv1
spec:
  capacity:
    storage: 1Gi
  accessModes:
    - ReadWriteMany
  nfs:
    server:  10.0.0.87
    path: /data/redis/redis-cluster1

---
apiVersion: v1
kind: PersistentVolume
metadata:
  name: nfs-pv2
  labels:
    pv: nfs-pv2
spec:
  capacity:
    storage: 1Gi
  accessModes:
    - ReadWriteMany
  nfs:
    server:  10.0.0.87
    path: /data/redis/redis-cluster2

---
apiVersion: v1
kind: PersistentVolume
metadata:
  name: nfs-pv3
  labels:
    pv: nfs-pv3
spec:
  capacity:
    storage: 1Gi
  accessModes:
    - ReadWriteMany
  nfs:
    server:  10.0.0.87
    path: /data/redis/redis-cluster3

---
apiVersion: v1
kind: PersistentVolume
metadata:
  name: nfs-pv4
  labels:
    pv: nfs-pv4
spec:
  capacity:
    storage: 1Gi
  accessModes:
    - ReadWriteMany
  nfs:
    server:  10.0.0.87
    path: /data/redis/redis-cluster4

---
apiVersion: v1
kind: PersistentVolume
metadata:
  name: nfs-pv5
  labels:
    pv: nfs-pv5
spec:
  capacity:
    storage: 1Gi
  accessModes:
    - ReadWriteMany
  nfs:
    server:  10.0.0.87
    path: /data/redis/redis-cluster5
```
> 集群配置文件（redis-cluster-config.yaml）
```console
# cat redis-cluster-config.yaml
# kubectl apply -f redis-cluster-config.yaml
apiVersion: v1
kind: ConfigMap
metadata:
 name: redis-config
 namespace: dev
data:
 update-node.sh: |
  #!/bin/sh
  REDIS_NODES="/data/nodes.conf"
  sed -i -e "/myself/ s/[0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}/${MY_POD_IP}/" ${REDIS_NODES}
  exec "$@"
 redis.conf: |+
  port 7001
  protected-mode no
  cluster-enabled yes
  cluster-config-file nodes.conf
  cluster-node-timeout 15000
  #cluster-announce-ip ${MY_POD_IP}
  #cluster-announce-port 7001
  #cluster-announce-bus-port 17001
  logfile "/data/redis.log"
```
>集群部署文件(redis-cluster.yaml)
```console
# cat redis-cluster.yaml
# kubectl apply -f redis-cluster.yaml
---
apiVersion: apps/v1
kind: StatefulSet
metadata:
  labels:
    app: redis-cluster
  name: redis-cluster
  namespace: dev
spec:
  replicas: 6
  selector:
    matchLabels:
      app: redis-cluster
  serviceName: redis-cluster
  template:
    metadata:
      labels:
        app: redis-cluster
    spec:
      containers:
        - command: 
            ["/bin/bash", "/usr/local/etc/redis/update-node.sh", "redis-server", "/usr/local/etc/redis/redis.conf"]
          #args:
          #  - /usr/local/etc/redis/redis.conf
          #  - --cluster-announce-ip
          #  - "$(MY_POD_IP)"
          env:
            - name: MY_POD_IP
              valueFrom:
                fieldRef:
                  fieldPath: status.podIP
            - name: TZ
              value: Asia/Shanghai
          image: 10.0.0.87/system/redis:6.0.10
          imagePullPolicy: IfNotPresent
          name: redis
          ports:
            - containerPort: 7001
              name: redis-port
              protocol: TCP
          volumeMounts:
            - mountPath: /data
              name: redis-cluster-data
              subPath: data
              readOnly: false
            - mountPath: /usr/local/etc/redis
              name: redis-config
              readOnly: false
      dnsPolicy: ClusterFirst
      volumes:
        - name: redis-config
          configMap:
           name: redis-config
  volumeClaimTemplates:  #PVC模板
  - metadata:
      name: redis-cluster-data
      namespace: dev
    spec:
      accessModes: [ "ReadWriteMany" ]
      resources:
        requests:
          storage: 1Gi

---
apiVersion: v1
kind: Service
metadata:
  labels:
    app: redis-cluster
  name: redis-cluster
  namespace: dev 
spec:
  ports:
    - name: redis-port
      port: 7001
      protocol: TCP
      targetPort: 7001
  selector:
    app: redis-cluster
  type: ClusterIP
  clusterIP: None
```
> [redis-cluster-proxy](https://github.com/RedisLabs/redis-cluster-proxy) 是一个不太成熟的代理工具，**生产环境慎用**,目前官方没有image需要自己手动做镜像
```console
# git clone -b 1.0 https://github.com/artix75/redis-cluster-proxy
# yum install scl-utils
# yum install devtoolset-8
# scl enable devtoolset-8 bash # 编译安装需要gcc 4.9+
# cd redis-cluster-proxy && make && make  PREFIX=/some/other/directory install #将编译好的文件放在指定目录
# vim Dockerfile
FROM centos:7
WORKDIR /data
ADD redis-cluster-proxy /usr/local/bin/
EXPOSE 7777
# docker build . -t redis-cluster-proxy:v1.0.0
```

>redis-cluster-proxy配置，先上配置文件（redis-cluster-proxy-config.yaml）
```console
# cat redis-cluster-proxy-config.yaml
# kubectl apply -f  redis-cluster-proxy-config.yaml
---
# Redis-Proxy Config
apiVersion: v1
kind: ConfigMap
metadata:
  name: redis-proxy
  namespace: dev
data:
  proxy.conf: |
    cluster redis-cluster:7001    # 配置为Redis Cluster Service
    bind 0.0.0.0
    port 7777   # redis-cluster-proxy 对外暴露端口
    threads 8   # 线程数量
    daemonize no  
    enable-cross-slot yes    
    #auth P@ssw0rd     # 配置Redis Cluster 认证密码  
    log-level error
```
>redis-cluster-proxy 部署（redis-cluster-proxy.yaml）
```console
# cat redis-cluster-proxy.yaml
# kubectl apply -f  redis-cluster-proxy.yaml
---
# Redis-Proxy NodePort
apiVersion: v1
kind: Service
metadata:
  name: redis-proxy
  namespace: dev
spec:
  type: NodePort # 对K8S外部提供服务
  ports:
  - name: redis-proxy
    nodePort: 30001   # 对外提供的端口
    port: 7777
    protocol: TCP
    targetPort: 7777
  selector:
    app: redis-proxy
---
# Redis-Proxy Deployment
apiVersion: apps/v1
kind: Deployment
metadata:
  name: redis-proxy
  namespace: dev
spec:
  replicas: 1
  selector:
    matchLabels:
      app: redis-proxy
  template:
    metadata:
      labels:
        app: redis-proxy
    spec:
      containers:
        - name: redis-proxy
          image: 10.0.0.87/system/redis-cluster-proxy:v1.0.0
          imagePullPolicy: Always
          command: ["redis-cluster-proxy"]
          args:
            - -c
            - /data/proxy.conf   # 指定启动配置文件
          ports:
            - name: redis-7777
              containerPort: 7777
              protocol: TCP
          volumeMounts:
            - name: redis-proxy-conf
              mountPath: /data/
      volumes:   # 挂载proxy配置文件
        - name: redis-proxy-conf
          configMap:
            name: redis-proxy
```

