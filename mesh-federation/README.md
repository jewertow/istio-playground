## Mesh federation

### Setup clusters

```shell
curl -s https://raw.githubusercontent.com/istio/istio/refs/heads/release-1.26/samples/kind-lb/setupkind.sh | sh -s -- --cluster-name east --ip-space 254
curl -s https://raw.githubusercontent.com/istio/istio/refs/heads/release-1.26/samples/kind-lb/setupkind.sh | sh -s -- --cluster-name west --ip-space 255
```

```shell
kind get kubeconfig --name east > east.kubeconfig
alias keast="KUBECONFIG=$(pwd)/east.kubeconfig kubectl"
alias istioctl-east="KUBECONFIG=$(pwd)/east.kubeconfig istioctl"
alias helm-east="KUBECONFIG=$(pwd)/east.kubeconfig helm"
kind get kubeconfig --name west > west.kubeconfig
alias kwest="KUBECONFIG=$(pwd)/west.kubeconfig kubectl"
alias istioctl-west="KUBECONFIG=$(pwd)/west.kubeconfig istioctl"
alias helm-west="KUBECONFIG=$(pwd)/west.kubeconfig helm"
```

### Setup certificates

```shell
wget https://raw.githubusercontent.com/istio/istio/release-1.21/tools/certs/common.mk -O common.mk
wget https://raw.githubusercontent.com/istio/istio/release-1.21/tools/certs/Makefile.selfsigned.mk -O Makefile.selfsigned.mk
```

```shell
make -f Makefile.selfsigned.mk \
  ROOTCA_CN="East Root CA" \
  ROOTCA_ORG=my-company.org \
  root-ca
make -f Makefile.selfsigned.mk \
  INTERMEDIATE_CN="East Intermediate CA" \
  INTERMEDIATE_ORG=my-company.org \
  east-cacerts
make -f Makefile.selfsigned.mk \
  INTERMEDIATE_CN="West Intermediate CA" \
  INTERMEDIATE_ORG=my-company.org \
  west-cacerts
make -f common.mk clean
```

```shell
keast create namespace istio-system
keast create secret generic cacerts -n istio-system \
  --from-file=root-cert.pem=east/root-cert.pem \
  --from-file=ca-cert.pem=east/ca-cert.pem \
  --from-file=ca-key.pem=east/ca-key.pem \
  --from-file=cert-chain.pem=east/cert-chain.pem
kwest create namespace istio-system
kwest create secret generic cacerts -n istio-system \
  --from-file=root-cert.pem=west/root-cert.pem \
  --from-file=ca-cert.pem=west/ca-cert.pem \
  --from-file=ca-key.pem=west/ca-key.pem \
  --from-file=cert-chain.pem=west/cert-chain.pem
```

### Install Kubernetes Gateway API

```shell
keast apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.3.0/standard-install.yaml
keast apply -f https://raw.githubusercontent.com/kubernetes-sigs/gateway-api/refs/tags/v1.3.0/config/crd/experimental/gateway.networking.k8s.io_tlsroutes.yaml
kwest apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.3.0/standard-install.yaml
```

### Demo

```shell
istioctl-east install -y -f templates/istio.yaml \
  --set values.global.meshID=east-mesh \
  --set values.global.network=east-network \
  --set values.global.multiCluster.clusterName=east-cluster
```
```shell
istioctl-west install -y -f templates/istio.yaml \
  --set values.global.meshID=west-mesh \
  --set values.global.network=west-network \
  --set values.global.multiCluster.clusterName=west-cluster
```

1. Enable mTLS, deploy `sleep` the east cluster and `httpbin` in the west cluster and export `httpbin`:
```shell
# mTLS
keast apply -f mtls.yaml -n istio-system
kwest apply -f mtls.yaml -n istio-system
# sleep
keast create namespace sleep
keast label namespace sleep istio-injection=enabled
keast apply -f https://raw.githubusercontent.com/istio/istio/release-1.20/samples/sleep/sleep.yaml -n sleep
kwest create namespace sleep
kwest label namespace sleep istio-injection=enabled
kwest apply -f https://raw.githubusercontent.com/istio/istio/release-1.20/samples/sleep/sleep.yaml -n sleep
# httpbin
keast create namespace httpbin
keast label namespace httpbin istio-injection=enabled
keast apply -f https://raw.githubusercontent.com/istio/istio/release-1.20/samples/httpbin/httpbin.yaml -n httpbin
kwest create namespace httpbin
kwest label namespace httpbin istio-injection=enabled
kwest apply -f https://raw.githubusercontent.com/istio/istio/release-1.20/samples/httpbin/httpbin.yaml -n httpbin
```

1. Create service entry for httpbin:
```shell
keast apply -n httpbin -f - <<EOF
apiVersion: networking.istio.io/v1
kind: ServiceEntry
metadata:
  name: httpbin-mesh-global
spec:
  hosts: 
  - httpbin.mesh.global
  ports:
  - number: 8000
    targetPort: 80
    name: http
    protocol: HTTP
  resolution: STATIC
  location: MESH_INTERNAL
  workloadSelector:
    labels:
      app: httpbin
EOF
```
```shell
kwest apply -n httpbin -f - <<EOF
apiVersion: networking.istio.io/v1
kind: ServiceEntry
metadata:
  name: httpbin-mesh-global
spec:
  hosts: 
  - httpbin.mesh.global
  ports:
  - number: 8000
    targetPort: 80
    name: http
    protocol: HTTP
  resolution: STATIC
  location: MESH_INTERNAL
  workloadSelector:
    labels:
      app: httpbin
EOF
```

1. Create E/W gateway in the west cluster:
```shell
kwest apply -n istio-system -f - <<EOF
apiVersion: gateway.networking.k8s.io/v1beta1
kind: Gateway
metadata:
  name: eastwestgateway
  labels:
    topology.istio.io/network: west-network
spec:
  gatewayClassName: istio
  listeners:
  - name: cross-network
    hostname: "*.local"
    port: 15443
    protocol: TLS
    tls:
      mode: Passthrough
      options:
        gateway.istio.io/listener-protocol: auto-passthrough
---
apiVersion: networking.istio.io/v1beta1
kind: Gateway
metadata:
  name: eastwestgateway
spec:
  selector:
    gateway.networking.k8s.io/gateway-name: eastwestgateway
  servers:
  - port:
      number: 15443
      name: tls
      protocol: TLS
    hosts:
    - "httpbin.mesh.global"
    tls:
      mode: AUTO_PASSTHROUGH
EOF
```

1. Create remote gateway in the east cluster
```shell
REMOTE_INGRESS_IP=$(kwest get svc -l gateway.networking.k8s.io/gateway-name=eastwestgateway -n istio-system -o jsonpath='{.items[0].status.loadBalancer.ingress[0].ip}')
keast apply -n istio-system -f - <<EOF
apiVersion: gateway.networking.k8s.io/v1beta1
kind: Gateway
metadata:
  name: remote-gateway-west-network
  labels:
    topology.istio.io/network: west-network
spec:
  gatewayClassName: istio-remote
  addresses:
  - value: $REMOTE_INGRESS_IP
  listeners:
  - name: cross-network
    port: 15443
    protocol: TLS
    tls:
      mode: Passthrough
      options:
        gateway.istio.io/listener-protocol: auto-passthrough
EOF
```

1. Add remote instance to the imported httpbin.mesh.global

```shell
keast apply -n httpbin -f - <<EOF
apiVersion: networking.istio.io/v1
kind: WorkloadEntry
metadata:
  name: httpbin-west
  labels:
    app: httpbin
    security.istio.io/tlsMode: istio
    topology.istio.io/cluster: west-cluster
spec:
  network: west-network
EOF
```

### With egress gateway

1. Create backend for remote ingress (TLSRoute does not support ServiceEntry, so a headless Service must be created instead):

```shell
apiVersion: networking.istio.io/v1beta1
kind: ServiceEntry
metadata:
  name: ingress-west-cluster
  namespace: istio-system
spec:
  exportTo:
  - "."
  hosts:
  - ingress.west.global
  ports:
  - number: 15443
    name: auto-passthrough-tls
    protocol: TLS
  resolution: STATIC
  location: MESH_INTERNAL
  endpoints:
  - address: $REMOTE_INGRESS_IP
    network: west-network
```

```shell
REMOTE_INGRESS_IP=$(kwest get svc -l gateway.networking.k8s.io/gateway-name=eastwestgateway -n istio-system -o jsonpath='{.items[0].status.loadBalancer.ingress[0].ip}')
keast apply -n istio-system -f - <<EOF
apiVersion: v1
kind: Service
metadata:
  name: ingress-west-cluster
spec:
  clusterIP: None
  ports:
  - name: tls
    port: 15443
    targetPort: 15443
    protocol: TCP
---
apiVersion: discovery.k8s.io/v1
kind: EndpointSlice
metadata:
  name: ingress-west-cluster
  labels:
    kubernetes.io/service-name: ingress-west-cluster
addressType: IPv4
endpoints:
- addresses:
  - $REMOTE_INGRESS_IP
ports:
- name: tls
  port: 15443
  protocol: TCP
EOF
```

```shell
keast apply -f - <<EOF
apiVersion: gateway.networking.k8s.io/v1beta1
kind: Gateway
metadata:
  name: egress-gateway
  namespace: istio-system
  annotations:
    networking.istio.io/service-type: ClusterIP
spec:
  gatewayClassName: istio
  listeners:
  - name: tls
    port: 15443
    protocol: TLS
    tls:
      mode: Passthrough
---
apiVersion: gateway.networking.k8s.io/v1alpha2
kind: TLSRoute
metadata:
  name: egress-gateway-tls
  namespace: istio-system
spec:
  hostnames:
  - "*.httpbin.mesh.global"
  parentRefs:
  - name: egress-gateway
    kind: Gateway
    sectionName: tls
  rules:
  - backendRefs:
    - name: ingress-west-cluster
      port: 15443
EOF
```

1. Update the remote gateway in the east cluster:
```shell
keast apply -n istio-system -f - <<EOF
apiVersion: gateway.networking.k8s.io/v1beta1
kind: Gateway
metadata:
  name: remote-gateway-west-network
  labels:
    topology.istio.io/network: west-network
spec:
  gatewayClassName: istio-remote
  addresses:
  - value: egress-gateway-istio.istio-system.svc.cluster.local
    type: Hostname
  listeners:
  - name: cross-network
    port: 15443
    protocol: TLS
    tls:
      mode: Passthrough
      options:
        gateway.istio.io/listener-protocol: auto-passthrough
EOF
```
