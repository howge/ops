## 在centos8(阿里云轻量服务器) 上二进制部署k8s v1.23

> 集群规划如下

|  ip地址   | 角色  | 主机名 |
|  ----  | ----  |----  |
| 172.17.27.17    | master,etcd-1,kube-apiserver,kube-controller-manage,kube-scheduler,kube-proxy,kubelet,kubectl | k8s-master |
| 172.17.27.18  | node,etcd-2,kubelet,kube-proxy | k8s-node-01 |
| 172.17.27.19  | node,etcd-3,kubelet,kube-proxy | k8s-node-02 |

## 前期准备工作

+ 下载文件
  - [calico](https://github.com/howge/ops/blob/main/calico.yaml)
  - [coredns](https://github.com/howge/ops/blob/main/coredns.yaml)
  - k8s二进制文件



+ 基础设置
  
  绑定/etc/hosts文件,增加如下配置
  ```console
  172.17.27.17    k8s-master
  172.17.27.18    k8s-node-01
  172.17.27.19    k8s-node-02
  ```

  aliyun 貌似需要安装
  ```console
  swapoff -a
  yum install conntrack-tools -y 
  ```

  修改内核参数
  ```cosnole
  cat > /etc/sysctl.d/k8s.conf << EOF
  net.ipv4.ip_forward = 1
  net.bridge.bridge-nf-call-ip6tables = 1
  net.bridge.bridge-nf-call-iptables = 1
  EOF

  ```
  生效配置
  ```console
  sysctl --system
  ```
  启动参数
  ```console
  modprobe -- ip_vs_wrr
  modprobe -- ip_vs_sh
  modprobe -- nf_conntrack_ipv4
  ```
  查看参数
  ```console
  lsmod | grep ip_vs
  ip_vs_sh               16384  0
  ip_vs_wrr              16384  0
  ip_vs_rr               16384  5
  ip_vs                 172032  11 ip_vs_rr,ip_vs_sh,ip_vs_wrr
  nf_defrag_ipv6         20480  2 nf_conntrack_ipv6,ip_vs
  nf_conntrack          155648  11    xt_conntrack,nf_conntrack_ipv6,nf_conntrack_ipv4,nf_nat,ip6t_MASQUERADE,nf_nat_ipv6,ipt_MASQUERADE,nf_nat_ipv4,xt_nat,nf_conntrack_netlink,ip_vs
  libcrc32c              16384  4 nf_conntrack,nf_nat,xfs,ip_vs
  ```
+ docker-ce 安装
  ```console
  wget https://mirrors.aliyun.com/docker-ce/linux/centos/docker-ce.repo -O /etc/yum.repos.d/docker-ce.repo && yum install -y docker-ce
  systemctl start docker
  systemctl enable docker
  ```
## 部署etcd集群 
 + 准备cfssl证书生成工具
    ```console
    mkdir cfssl && cd cfssl/
    wget https://pkg.cfssl.org/R1.2/cfssl_linux-amd64
    wget https://pkg.cfssl.org/R1.2/cfssljson_linux-amd64
    wget https://pkg.cfssl.org/R1.2/cfssl-certinfo_linux-amd64
    chmod +x cfssl_linux-amd64 cfssljson_linux-amd64 cfssl-certinfo_linux-amd64
    mv cfssl_linux-amd64 /usr/local/bin/cfssl
    mv cfssljson_linux-amd64 /usr/local/bin/cfssljson
    mv cfssl-certinfo_linux-amd64 /usr/bin/cfssl-certinfo
    ```
 
+ ETCD CA设置
    ```console
    mkdir -p ~/TLS/{etcd,k8s} && cd ~/TLS/etcd
    cat > ca-config.json << EOF
    {
        "signing": {
        "default": {
            "expiry": "87600h"
        },
        "profiles": {
            "www": {
            "expiry": "87600h",
            "usages": [
                "signing",
                "key encipherment",
                "server auth",
                "client auth"
            ]
            }
        }
        }
    }
    EOF
    
    cat > ca-csr.json << EOF
    {
        "CN": "etcd CA",
        "key": {
            "algo": "rsa",
            "size": 2048
        },
        "names": [
            {
                "C": "CN",
                "L": "Hubei",
                "ST": "Wuhan"
            }
        ]
    }
    EOF

    ```
+ 生成证书
    ```console
    cfssl gencert -initca ca-csr.json | cfssljson -bare ca - #会生成ca.pem ca-key.pem
    ```

+ etcd 节点部署(注意etcd节点ip)
    ```console
    cat > server-csr.json << EOF
    {
        "CN": "etcd",
        "hosts": [
        "172.17.27.17",
        "172.17.27.18",
        "172.17.27.19"
        ],
        "key": {
            "algo": "rsa",
            "size": 2048
        },
        "names": [
            {
                "C": "CN",
                "L": "Hubei",
                "ST": "Wuhan"
            }
        ]
    }
    EOF
    ```
+ 生成证书
    ```console
    cfssl gencert -ca=ca.pem -ca-key=ca-key.pem -config=ca-config.json -profile=www server-csr.json | cfssljson -bare server
    ```
+ 下载etcd
    ```console
    cd ~
    wget https://github.com/etcd-io/etcd/releases/download/v3.4.9/etcd-v3.4.9-linux-amd64.tar.gz
    ```
+ 解压&复制
    ```console
    tar xzvf etcd-v3.4.9-linux-amd64.tar.gz && cp etcd-v3.4.9-linux-amd64/etcd* /usr/local/bin
    ```

+ 创建etcd主目录,copy证书签名到指定路径
    ```console
    mkdir /etc/etcd/{cfg,ssl} -p
    cp ~/TLS/etcd/ca*pem ~/TLS/etcd/server*pem /etc/etcd/ssl/
    ```
+ 创建配置文件
  
  - etcd-1
  ```console
  cat > /etc/etcd/cfg/etcd.conf << EOF
  #[Member]
  ETCD_NAME="etcd-1"
  ETCD_DATA_DIR="/var/lib/etcd/default.etcd"
  ETCD_LISTEN_PEER_URLS="https://172.17.27.17:2380"
  ETCD_LISTEN_CLIENT_URLS="https://172.17.27.17:2379"

  #[Clustering]
  ETCD_INITIAL_ADVERTISE_PEER_URLS="https://172.17.27.17:2380"
  ETCD_ADVERTISE_CLIENT_URLS="https://172.17.27.17:2379"
  ETCD_INITIAL_CLUSTER="etcd-1=https://172.17.27.17:2380,etcd-2=https://172.17.27.18:2380,etcd-3=https://172.17.27.19:2380"
  ETCD_INITIAL_CLUSTER_TOKEN="etcd-cluster"
  ETCD_INITIAL_CLUSTER_STATE="new"
  EOF
  ```
  - etc-2
  ```console
  cat > /etc/etcd/cfg/etcd.conf << EOF
  #[Member]
  ETCD_NAME="etcd-2"
  ETCD_DATA_DIR="/var/lib/etcd/default.etcd"
  ETCD_LISTEN_PEER_URLS="https://172.17.27.18:2380"
  ETCD_LISTEN_CLIENT_URLS="https://172.17.27.18:2379"

  #[Clustering]
  ETCD_INITIAL_ADVERTISE_PEER_URLS="https://172.17.27.18:2380"
  ETCD_ADVERTISE_CLIENT_URLS="https://172.17.27.18:2379"
  ETCD_INITIAL_CLUSTER="etcd-1=https://172.17.27.17:2380,etcd-2=https://172.17.27.18:2380,etcd-3=https://172.17.27.19:2380"
  ETCD_INITIAL_CLUSTER_TOKEN="etcd-cluster"
  ETCD_INITIAL_CLUSTER_STATE="new"
  EOF
  ```
  - etcd-3
  ```console
  cat > /etc/etcd/cfg/etcd.conf << EOF
  #[Member]
  ETCD_NAME="etcd-3"
  ETCD_DATA_DIR="/var/lib/etcd/default.etcd"
  ETCD_LISTEN_PEER_URLS="https://172.17.27.19:2380"
  ETCD_LISTEN_CLIENT_URLS="https://172.17.27.19:2379"

  #[Clustering]
  ETCD_INITIAL_ADVERTISE_PEER_URLS="https://172.17.27.19:2380"
  ETCD_ADVERTISE_CLIENT_URLS="https://172.17.27.19:2379"
  ETCD_INITIAL_CLUSTER="etcd-1=https://172.17.27.17:2380,etcd-2=https://172.17.27.18:2380,etcd-3=https://172.17.27.19:2380"
  ETCD_INITIAL_CLUSTER_TOKEN="etcd-cluster"
  ETCD_INITIAL_CLUSTER_STATE="new"
  EOF
  ```

+ 创建service文件，每个节点都需配置

    ```console
    cat > /usr/lib/systemd/system/etcd.service << EOF
    [Unit]
    Description=Etcd Server
    After=network.target
    After=network-online.target
    Wants=network-online.target

    [Service]
    Type=notify
    EnvironmentFile=/etc/etcd/cfg/etcd.conf
    ExecStart=/usr/local/bin/etcd \
    --cert-file=/etc/etcd/ssl/server.pem \
    --key-file=/etc/etcd/ssl/server-key.pem \
    --peer-cert-file=/etc/etcd/ssl/server.pem \
    --peer-key-file=/etc/etcd/ssl/server-key.pem \
    --trusted-ca-file=/etc/etcd/ssl/ca.pem \
    --peer-trusted-ca-file=/etc/etcd/ssl/ca.pem \
    --logger=zap
    Restart=on-failure
    LimitNOFILE=65536

    [Install]
    WantedBy=multi-user.target
    EOF
    ```
+ 服务三连
    ```console
    systemctl daemon-reload
    systemctl start etcd
    systemctl enable etcd
    ```

+ 排错
    ```console
    journalctl -xe -u etcd
    ```
+ 验证集群
    ```console
    ETCDCTL_API=3  etcdctl --cacert=/etc/etcd/ssl/ca.pem --cert=/etc/etcd/ssl/server.pem --key=/etc/etcd/ssl/server-key.pem  --endpoints="https://172.17.27.17:2379,https://172.17.27.18:2379,https://172.17.27.19:2379" endpoint health --write-out=table
    ```
## K8s 集群部署
> kube-apisever部署
  + 集群CA，服务证书，签名设置 #10.0.0.1 default service,10.0.0.2 coredns ip
    ```console
    cd ~/TLS/k8s
    cat > ca-config.json << EOF
    {
        "signing": {
            "default": {
            "expiry": "87600h"
            },
            "profiles": {
            "kubernetes": {
                "expiry": "87600h",
                "usages": [
                    "signing",
                    "key encipherment",
                    "server auth",
                    "client auth"
                ]
            }
            }
        }
    }
    EOF
    cat > ca-csr.json << EOF
    {
        "CN": "kubernetes",
        "key": {
            "algo": "rsa",
            "size": 2048
        },
        "names": [
            {
                "C": "CN",
                "L": "Hubei",
                "ST": "Wuhan",
                "O": "k8s",
                "OU": "System"
            }
        ]
    }
    EOF
    
    cat > server-csr.json << EOF
    {
        "CN": "kubernetes",
        "hosts": [
        "172.17.27.17",
        "127.0.0.1",
        "10.0.0.1",
        "10.0.0.2",
        "kubernetes",
        "kubernetes.default",
        "kubernetes.default.svc",
        "kubernetes.default.svc.cluster",
        "kubernetes.default.svc.cluster.local"
        ],
        "key": {
            "algo": "rsa",
            "size": 2048
        },
        "names": [
            {
                "C": "CN",
                "L": "Hubei",
                "ST": "Wuhan",
                "O": "k8s",
                "OU": "System"
            }
        ]
    }
    EOF
    ```
+ 生成CA证书，给server签名
    ```console
        cfssl gencert -initca ca-csr.json | cfssljson -bare ca -
    cfssl gencert -ca=ca.pem -ca-key=ca-key.pem -config=ca-config.json -profile=kubernetes server-csr.json | cfssljson -bare server
    ```
   
+ 创建主目录，将可执行文件放到/usr/local/bin/
    ```console
        mkdir -p /opt/kubernetes/{cfg,ssl,logs}
    ``` 
+ 创建配置文件
    ```console
    cat > /opt/kubernetes/cfg/kube-apiserver.conf << EOF
    KUBE_APISERVER_OPTS="--enable-admission-plugins=NamespaceLifecycle,NodeRestriction,LimitRanger,ServiceAccount,DefaultStorageClass,ResourceQuota \\
    --anonymous-auth=false \\
    --bind-address=172.17.27.17 \\
    --secure-port=6443 \\
    --advertise-address=172.17.27.17 \\
    --insecure-port=0 \\
    --authorization-mode=Node,RBAC \\
    --runtime-config=api/all=true \\
    --enable-bootstrap-token-auth \\
    --service-cluster-ip-range=10.0.0.0/24 \\
    --token-auth-file=/opt/kubernetes/cfg/token.csv \\
    --service-node-port-range=30000-50000 \\
    --tls-cert-file=/opt/kubernetes/ssl/server.pem  \\
    --tls-private-key-file=/opt/kubernetes/ssl/server-key.pem \\
    --client-ca-file=/opt/kubernetes/ssl/ca.pem \\
    --kubelet-client-certificate=/opt/kubernetes/ssl/server.pem \\
    --kubelet-client-key=/opt/kubernetes/ssl/server-key.pem \\
    --service-account-key-file=/opt/kubernetes/ssl/ca-key.pem \\
    --service-account-signing-key-file=/opt/kubernetes/ssl/ca-key.pem  \\
    --service-account-issuer=https://kubernetes.default.svc.cluster.local \\
    --etcd-cafile=/etc/etcd/ssl/ca.pem \\
    --etcd-certfile=/etc/etcd/ssl/server.pem \\
    --etcd-keyfile=/etc/etcd/ssl/server-key.pem \\
    --etcd-servers=https://172.17.27.17:2379,https://172.17.27.18:2379,https://172.17.27.19:2379 \\
    --enable-swagger-ui=true \\
    --allow-privileged=true \\
    --apiserver-count=3 \\
    --audit-log-maxage=30 \\
    --audit-log-maxbackup=3 \\
    --audit-log-maxsize=100 \\
    --audit-log-path=/var/log/kube-apiserver-audit.log \\
    --event-ttl=1h \\
    --alsologtostderr=true \\
    --logtostderr=false \\
    --log-dir=/opt/kubernetes/logs 
    --v=4"
    EOF
    ```
+ copy证书签名到指定路径
    ```console
    cp ~/TLS/k8s/ca*pem ~/TLS/k8s/server*pem /opt/kubernetes/ssl/
    ```
+ 生成token
    ```console
    head -c 16 /dev/urandom | od -An -t x | tr -d ' '
    ```
+ 生成tokenfile
    ```console
    cat > /opt/kubernetes/cfg/token.csv << EOF
    c47ffb939f5ca36231d9e3121a252940,kubelet-bootstrap,10001,"system:node-bootstrapper"
    EOF
    ```
+ 生成service文件
    ```console
    cat > /lib/systemd/system/kube-apiserver.service << EOF
    [Unit]
    Description=Kubernetes API Server
    Documentation=https://github.com/kubernetes/kubernetes

    [Service]
    EnvironmentFile=/opt/kubernetes/cfg/kube-apiserver.conf
    ExecStart=/usr/local/bin/kube-apiserver $KUBE_APISERVER_OPTS
    Restart=on-failure

    [Install]
    WantedBy=multi-user.target
    EOF
    ```
    
+ 服务三连
    ```console
    systemctl daemon-reload
    systemctl start kube-apiserver 
    systemctl enable kube-apiserver
    ```
+ 排错
    ```console
    journalctl -xe -u kube-apiserver
    #or
    tail -f  /opt/kubernetes/logs/kube-apiserver.ERROR 
   ```
 
> kube-controller-manager部署
+ 创建配置文件
    ```console
    cat > /opt/kubernetes/cfg/kube-controller-manager.conf << EOF
    KUBE_CONTROLLER_MANAGER_OPTS="--port=0 \\
      --secure-port=10257 \\
      --bind-address=127.0.0.1 \\
      --kubeconfig=/opt/kubernetes/cfg/kube-controller-manager.kubeconfig \\
      --service-cluster-ip-range=10.0.0.0/24 \\
      --cluster-name=kubernetes \\
      --cluster-signing-cert-file=/opt/kubernetes/ssl/ca.pem \\
      --cluster-signing-key-file=/opt/kubernetes/ssl/ca-key.pem  \\
      --allocate-node-cidrs=true \\
      --cluster-cidr=10.244.0.0/16 \\
      --experimental-cluster-signing-duration=87600h \\
      --root-ca-file=/opt/kubernetes/ssl/ca.pem \\
      --service-account-private-key-file=/opt/kubernetes/ssl/ca-key.pem \\
      --leader-elect=true \
      --feature-gates=RotateKubeletServerCertificate=true \\
      --controllers=*,bootstrapsigner,tokencleaner \\
      --horizontal-pod-autoscaler-sync-period=10s \\
      --tls-cert-file=/opt/kubernetes/ssl/kube-controller-manager.pem \\
      --tls-private-key-file=/opt/kubernetes/ssl/kube-controller-manager-key.pem \\
      --use-service-account-credentials=true \\
      --alsologtostderr=true \\
      --logtostderr=false \\
      --log-dir=/var/log/kubernetes \\
      --v=2"
    EOF
+ 签名json
    ```console
    cd ~/TLS/k8s
    cat > kube-controller-manager-csr.json << EOF
    {
      "CN": "system:kube-controller-manager",
      "hosts": [],
      "key": {
        "algo": "rsa",
        "size": 2048
      },
      "names": [
        {
          "C": "CN",
          "L": "Hubei", 
          "ST": "Wuhan",
          "O": "system:masters",
          "OU": "System"
        }
      ]
    }
    EOF
    ```
+ 生成证书
    ```console
   cfssl gencert -ca=ca.pem -ca-key=ca-key.pem -config=ca-config.json -profile=kubernetes kube-controller-manager-csr.json | cfssljson -bare kube-controller-manager
   ```
+ 生成kubeconfig文件
    ```console
    KUBE_CONFIG="/opt/kubernetes/cfg/kube-controller-manager.kubeconfig"
    KUBE_APISERVER="https://172.17.27.17:6443"
    kubectl config set-cluster kubernetes \
    --certificate-authority=/opt/kubernetes/ssl/ca.pem \
    --embed-certs=true \
    --server=${KUBE_APISERVER} \
    --kubeconfig=${KUBE_CONFIG}

    kubectl config set-credentials kube-controller-manager \
    --client-certificate=./kube-controller-manager.pem \
    --client-key=./kube-controller-manager-key.pem \
    --embed-certs=true \
    --kubeconfig=${KUBE_CONFIG}

    kubectl config set-context default \
    --cluster=kubernetes \
    --user=kube-controller-manager \
    --kubeconfig=${KUBE_CONFIG}

    kubectl config use-context default --kubeconfig=${KUBE_CONFIG}
    ```
+ 生成service文件
    ```console
    cat > /lib/systemd/system/kube-controller-manager.service << EOF
    [Unit]
    Description=Kubernetes Controller Manager
    Documentation=https://github.com/kubernetes/kubernetes

    [Service]
    EnvironmentFile=/opt/kubernetes/cfg/kube-controller-manager.conf
    ExecStart=/usr/local/bin/kube-controller-manager $KUBE_CONTROLLER_MANAGER_OPTS
    Restart=on-failure

    [Install]
    WantedBy=multi-user.target
    EOF
    ```
+ 服务三连
    ```console
    systemctl daemon-reload
    systemctl start kube-controller-manager
    systemctl enable kube-controller-manager
    ```
> kube-scheduler部署
+ 生成配置文件
    ```console
    
    cat > /opt/kubernetes/cfg/kube-scheduler.conf << EOF
    KUBE_SCHEDULER_OPTS="--logtostderr=false \\
    --v=2 \\
    --log-dir=/opt/kubernetes/logs \\
    --leader-elect \\
    --kubeconfig=/opt/kubernetes/cfg/kube-scheduler.kubeconfig \\
    --bind-address=127.0.0.1"
    EOF
    ```
+ 签名json
    ```console
    cd ~/TLS/k8s
    cat > kube-scheduler-csr.json << EOF
    {
        "CN": "system:kube-scheduler",
        "hosts": [],
        "key": {
            "algo": "rsa",
            "size": 2048
    },
        "names": [
            {
            "C": "CN",
            "L": "Hubei",
            "ST": "Wuhan",
            "O": "system:masters",
            "OU": "System"
            }
        ]
    }
    EOF
    ```
+ 客户端工具安装
    ```console
    cd ~/TLS/k8s
    cat > admin-csr.json <<EOF
    {
        "CN": "admin",
        "hosts": [],
        "key": {
            "algo": "rsa",
            "size": 2048
    },
        "names": [
            {
            "C": "CN",
            "L": "Hubei",
            "ST": "Wuhan",
            "O": "system:masters",
            "OU": "System"
            }
        ]
    }
    EOF
    ```
+ 生成证书
    ```console
    cfssl gencert -ca=ca.pem -ca-key=ca-key.pem -config=ca-config.json -profile=kubernetes kube-scheduler-csr.json | cfssljson -bare kube-scheduler
    cfssl gencert -ca=ca.pem -ca-key=ca-key.pem -config=ca-config.json -profile=kubernetes admin-csr.json | cfssljson -bare admin
    ```
+ 生成kubeconfig文件
    ```console
    KUBE_CONFIG="/opt/kubernetes/cfg/kube-scheduler.kubeconfig"
    KUBE_APISERVER="https://172.17.27.17:6443"

    kubectl config set-cluster kubernetes \
    --certificate-authority=/opt/kubernetes/ssl/ca.pem \
    --embed-certs=true \
    --server=${KUBE_APISERVER} \
    --kubeconfig=${KUBE_CONFIG}

    kubectl config set-credentials kube-scheduler \
    --client-certificate=./kube-scheduler.pem \
    --client-key=./kube-scheduler-key.pem \
    --embed-certs=true \
    --kubeconfig=${KUBE_CONFIG}

    kubectl config set-context default \
    --cluster=kubernetes \
    --user=kube-scheduler \
    --kubeconfig=${KUBE_CONFIG}

    kubectl config use-context default --kubeconfig=${KUBE_CONFIG}
    ```
+ 生成kubeconfig文件
    ```console
    mkdir /root/.kube
    KUBE_CONFIG="/root/.kube/config"
    KUBE_APISERVER="https://172.17.27.17:6443"

    kubectl config set-cluster kubernetes \
    --certificate-authority=/opt/kubernetes/ssl/ca.pem \
    --embed-certs=true \
    --server=${KUBE_APISERVER} \
    --kubeconfig=${KUBE_CONFIG}

    kubectl config set-credentials cluster-admin \
    --client-certificate=./admin.pem \
    --client-key=./admin-key.pem \
    --embed-certs=true \
    --kubeconfig=${KUBE_CONFIG}

    kubectl config set-context default \
    --cluster=kubernetes \
    --user=cluster-admin \
    --kubeconfig=${KUBE_CONFIG}

    kubectl config use-context default --kubeconfig=${KUBE_CONFIG}
    ```

+ scheduler service 文件
    ```console
    cat > /usr/lib/systemd/system/kube-scheduler.service << EOF
    [Unit]
    Description=Kubernetes Scheduler
    Documentation=https://github.com/kubernetes/kubernetes

    [Service]
    EnvironmentFile=/opt/kubernetes/cfg/kube-scheduler.conf
    ExecStart=/usr/local/bin/kube-scheduler \$KUBE_SCHEDULER_OPTS
    Restart=on-failure

    [Install]
    WantedBy=multi-user.target
    EOF
    ```
+ 服务三连
    ```console
    systemctl daemon-reload
    systemctl start kube-scheduler
    systemctl enable kube-scheduler
    ```
+ 排错参考上文
+ 查看集群状态
    ```console
    [root@k8s-master k8s]# kubectl get cs
    Warning: v1 ComponentStatus is deprecated in v1.19+
    NAME                 STATUS    MESSAGE             ERROR
    etcd-1               Healthy   {"health":"true"}   
    etcd-0               Healthy   {"health":"true"}   
    scheduler            Healthy   ok                  
    etcd-2               Healthy   {"health":"true"}   
    controller-manager   Healthy   ok 
    ```

+ 授权kubelet-bootstrap用户允许请求证书
    ```console
    kubectl create clusterrolebinding kubelet-bootstrap \
    --clusterrole=system:node-bootstrapper \
    --user=kubelet-bootstrap
    ```
 
## 客户端部署
+ 创建工作目录
    ```console
    mkdir -p /opt/kubernetes/{cfg,ssl,logs}
    #在master将ca.pem, ca-key.pem同步到客户端相应目录
    scp ca.pem ca-key.pem root@k8s-node-01:/opt/kubernetes/ssl
    scp ca.pem ca-key.pem root@k8s-node-02:/opt/kubernetes/ssl
    ```

> kube-proxy部署

+ 生成配置文件
    ```console
    cat > /opt/kubernetes/cfg/kube-proxy.conf << EOF
    KUBE_PROXY_OPTS="--logtostderr=false \\
    --v=2 \\
    --log-dir=/opt/kubernetes/logs \\
    --config=/opt/kubernetes/cfg/kube-proxy-config.yml"
    EOF
    #kube-proxy-config.yml文件
    cat > /opt/kubernetes/cfg/kube-proxy-config.yml << EOF
    kind: KubeProxyConfiguration
    apiVersion: kubeproxy.config.k8s.io/v1alpha1
    bindAddress: 172.17.27.18
    metricsBindAddress: 172.17.27.18:10249
    healthzBindAddress: 172.17.27.18:10256
    clientConnection:
    kubeconfig: /opt/kubernetes/cfg/kube-proxy.kubeconfig
    hostnameOverride: k8s-node-01
    clusterCIDR: 10.244.0.0/16
    mode: "ipvs"
    EOF
    ```
+ 生成kube-proxy证书
    ```console
    cd ~/TLS/k8s
    cat > kube-proxy-csr.json << EOF
    {
        "CN": "system:kube-proxy",
        "hosts": [],
        "key": {
            "algo": "rsa",
            "size": 2048
        },
        "names": [
            {
            "C": "CN",
            "L": "Hubei",
            "ST": "Wuhan",
            "O": "k8s",
            "OU": "System"
            }
        ]
    }
    EOF
    ```
+ 签名
    ```console
    cfssl gencert -ca=ca.pem -ca-key=ca-key.pem -config=ca-config.json -profile=kubernetes kube-proxy-csr.json | cfssljson -bare kube-proxy
    ```
+ 生成kubeconfig文件
    ```console
    KUBE_CONFIG="/opt/kubernetes/cfg/kube-proxy.kubeconfig"
    KUBE_APISERVER="https://172.17.27.17:6443"

    kubectl config set-cluster kubernetes \
    --certificate-authority=/opt/kubernetes/ssl/ca.pem \
    --embed-certs=true \
    --server=${KUBE_APISERVER} \
    --kubeconfig=${KUBE_CONFIG}

    kubectl config set-credentials kube-proxy \
    --client-certificate=./kube-proxy.pem \
    --client-key=./kube-proxy-key.pem \
    --embed-certs=true \
    --kubeconfig=${KUBE_CONFIG}

    kubectl config set-context default \
    --cluster=kubernetes \
    --user=kube-proxy \
    --kubeconfig=${KUBE_CONFIG}

    kubectl config use-context default --kubeconfig=${KUBE_CONFIG}
    ```

+ systemd管理kube-proxy
    ```console
    cat > /usr/lib/systemd/system/kube-proxy.service << EOF
    [Unit]
    Description=Kubernetes Proxy
    After=network.target

    [Service]
    EnvironmentFile=/opt/kubernetes/cfg/kube-proxy.conf
    ExecStart=/usr/local/bin/kube-proxy \$KUBE_PROXY_OPTS
    Restart=on-failure
    LimitNOFILE=65536

    [Install]
    WantedBy=multi-user.target
    EOF
    ```

+ 服务三连
    ```console
    systemctl daemon-reload
    systemctl start kube-proxy
    systemctl enable kube-proxy
    ```
 
> kubelet 部署

+ kubeconfig文件生成(master执行，每台node节点都需此文件)
    ```console
    KUBE_CONFIG="/opt/kubernetes/cfg/bootstrap.kubeconfig"
    KUBE_APISERVER="https://172.17.27.17:6443"
    TOKEN="c47ffb939f5ca36231d9e3121a252940" # 与token.csv里保持一致

    # 生成 kubelet bootstrap kubeconfig 配置文件
    kubectl config set-cluster kubernetes \
    --certificate-authority=/opt/kubernetes/ssl/ca.pem \
    --embed-certs=true \
    --server=${KUBE_APISERVER} \
    --kubeconfig=${KUBE_CONFIG}
    kubectl config set-credentials "kubelet-bootstrap" \
    --token=${TOKEN} \
    --kubeconfig=${KUBE_CONFIG}
    kubectl config set-context default \
    --cluster=kubernetes \
    --user="kubelet-bootstrap" \
    --kubeconfig=${KUBE_CONFIG}
    kubectl config use-context default --kubeconfig=${KUBE_CONFIG}
    ```

+ 生成配置文件(centos8 注意--resolv-conf配制)
    ```console
    cat > /opt/kubernetes/cfg/kubelet.conf << EOF
    KUBELET_OPTS="--logtostderr=false \
    --v=2 \
    --log-dir=/opt/kubernetes/logs \
    --hostname-override=k8s-node-01 \
    --network-plugin=cni \
    --kubeconfig=/opt/kubernetes/cfg/kubelet.kubeconfig \
    --bootstrap-kubeconfig=/opt/kubernetes/cfg/bootstrap.kubeconfig \
    --config=/opt/kubernetes/cfg/kubelet-config.json \
    --resolv-conf=/run/systemd/resolve/resolv.conf \
    --cert-dir=/opt/kubernetes/ssl"
    EOF
    ```
+ kubelet-config.json配置
    ```console
    {
    "kind": "KubeletConfiguration",
    "apiVersion": "kubelet.config.k8s.io/v1beta1",
    "authentication": {
        "x509": {
        "clientCAFile": "/opt/kubernetes/ssl/ca.pem"
        },
        "webhook": {
        "enabled": true,
        "cacheTTL": "2m0s"
        },
        "anonymous": {
        "enabled": false
        }
    },
    "authorization": {
        "mode": "Webhook",
        "webhook": {
        "cacheAuthorizedTTL": "5m0s",
        "cacheUnauthorizedTTL": "30s"
        }
    },
    "address": "172.17.27.18",
    "port": 10250,
    "readOnlyPort": 10255,
    "cgroupDriver": "cgroupfs",
    "hairpinMode": "promiscuous-bridge",
    "serializeImagePulls": false,
    "clusterDomain": "cluster.local.",
    "clusterDNS": ["10.0.0.2"]
    }
    ````
+ sevice 文件
    ```console
    cat > /usr/lib/systemd/system/kubelet.service << EOF
    [Unit]
    Description=Kubernetes Kubelet
    After=docker.service

    [Service]
    EnvironmentFile=/opt/kubernetes/cfg/kubelet.conf
    ExecStart=/opt/kubernetes/bin/kubelet \$KUBELET_OPTS
    Restart=on-failure
    LimitNOFILE=65536

    [Install]
    WantedBy=multi-user.target
    EOF
    ```
+ 服务三连
    ```console
    systemctl daemon-reload
    systemctl start kubelet
    systemctl enable kubelet
    ```
+ 查看kubelet证书请求
    ```console
    kubectl get csr
    NAME                                                   AGE   SIGNERNAME                                    REQUESTOR           CONDITION
    node-csr-jaqXhwxFBnD-1ui9omPdF__0SGovk2ZRhszz_QMGJxI   62s   kubernetes.io/kube-apiserver-client-kubelet   kubelet-bootstrap   Pending
    ```
+ 批准申请
    ```console
    kubectl certificate approve node-csr-jaqXhwxFBnD-1ui9omPdF__0SGovk2ZRhszz_QMGJxI
    ```
+ 查看节点（由于网络插件还没有部署，节点会没有准备就绪 NotReady）
    ```console
    kubectl get node
    NAME          STATUS     ROLES    AGE   VERSION
    k8s-node-01   NotReady   <none>   7s    v1.23.6
    ```
+ kubectl 权限授予
    ```console
    cd ~
    cat > apiserver-to-kubelet-rbac.yaml << EOF
    apiVersion: rbac.authorization.k8s.io/v1
    kind: ClusterRole
    metadata:
    annotations:
        rbac.authorization.kubernetes.io/autoupdate: "true"
    labels:
        kubernetes.io/bootstrapping: rbac-defaults
    name: system:kube-apiserver-to-kubelet
    rules:
    - apiGroups:
        - ""
        resources:
        - nodes/proxy
        - nodes/stats
        - nodes/log
        - nodes/spec
        - nodes/metrics
        - pods/log
        verbs:
        - "*"
    ---
    apiVersion: rbac.authorization.k8s.io/v1
    kind: ClusterRoleBinding
    metadata:
    name: system:kube-apiserver
    namespace: ""
    roleRef:
    apiGroup: rbac.authorization.k8s.io
    kind: ClusterRole
    name: system:kube-apiserver-to-kubelet
    subjects:
    - apiGroup: rbac.authorization.k8s.io
        kind: User
        name: kubernetes
    EOF
    kubectl apply -f apiserver-to-kubelet-rbac.yaml
    ```
> 部署calico网络组件
+ 安装
    ```console
    kubectl apply -f  calico.yaml
    ```
+ 查看
    ```console
    kubectl get pods -n kube-system
    NAME                                       READY   STATUS    RESTARTS   AGE
    calico-kube-controllers-5cdd5b4947-7pn8k   1/1     Running   0          19h
    calico-node-8g6mh                          1/1     Running   0          19h
    calico-node-bbwgx                          1/1     Running   0          19h
    calico-node-hzkpt                          1/1     Running   0          19h
    coredns-66d5dc5c47-rwhwt                   1/1     Running   0          19h
    ```
+ 错误排查
    ```console
    kubectl describe pod calico-node-hzkpt -n kube-system
    kubectl logs -f calico-node-hzkpt -n kube-system
    ```
>部署coredns

+ 安装
    ```console
    kubectl apply -f coredns.yaml
    ```
+ 查看
    ```console
    kubectl describe pod coredns-66d5dc5c47-rwhwt -n kube-system
    ```
+ 验证
    ```console
    [root@k8s-master ~]# kubectl run -it --rm dns-test --image=busybox:1.28.4 sh
    If you don't see a command prompt, try pressing enter.
    / # ping www.baidu.com
    PING www.baidu.com (45.113.192.102): 56 data bytes
    64 bytes from 45.113.192.102: seq=0 ttl=56 time=0.909 ms
    ^C
    --- www.baidu.com ping statistics ---
    1 packets transmitted, 1 packets received, 0% packet loss
    round-trip min/avg/max = 0.909/0.909/0.909 ms
    / # ping kubernetes.default
    PING kubernetes.default (10.0.0.1): 56 data bytes
    64 bytes from 10.0.0.1: seq=0 ttl=64 time=0.049 ms
    64 bytes from 10.0.0.1: seq=1 ttl=64 time=0.089 ms
    ^C
    --- kubernetes.default ping statistics ---
    2 packets transmitted, 2 packets received, 0% packet loss
    round-trip min/avg/max = 0.049/0.069/0.089 ms
    / # ping apple-service.default
    PING apple-service.default (10.0.0.71): 56 data bytes
    64 bytes from 10.0.0.71: seq=0 ttl=64 time=0.049 ms
    ^C
    --- apple-service.default ping statistics ---
    1 packets transmitted, 1 packets received, 0% packet loss
    round-trip min/avg/max = 0.049/0.049/0.049 ms
    / #exit

    ```
+ Node节点目录
    ```console
    [root@k8s-node-01 kubernetes]# tree /opt/kubernetes/
    /opt/kubernetes/
    ├── cfg
    │   ├── bootstrap.kubeconfig
    │   ├── kubelet.conf
    │   ├── kubelet-config.json
    │   ├── kubelet-config.yml
    │   ├── kubelet.kubeconfig
    │   ├── kube-proxy.conf
    │   ├── kube-proxy-config.yml
    │   └── kube-proxy.kubeconfig
    ├── logs
    │   201958
    │   ├── kube-proxy.INFO -> kube-proxy.k8s-node-01.root.log.INFO.20220706-173505.204663
    │   ├── kube-proxy.k8s-node-01.root.log.ERROR.20220706-114031.30365
    │   ├── kube-proxy.k8s-node-01.root.log.ERROR.20220706-141726.30706
    │   └── kube-proxy.WARNING -> kube-proxy.k8s-node-01.root.log.WARNING.20220706-173457.201958
    └── ssl
        ├── ca-key.pem
        ├── ca.pem
        ├── kubelet-client-2022-07-06-14-36-18.pem
        ├── kubelet-client-current.pem -> /opt/kubernetes/ssl/kubelet-client-2022-07-06-14-36-18.pem
        ├── kubelet.crt
        └── kubelet.key

    ```
## 排错



