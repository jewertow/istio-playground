## Mesh federation

### Setup clusters

1. Create 2 KinD clusters:
```shell
kind create cluster --name east --config=<<EOF
apiVersion: kind.x-k8s.io/v1alpha4
kind: Cluster
networking:
  podSubnet: "10.10.0.0/16"
  serviceSubnet: "10.255.10.0/24"
EOF
```
```shell
kind create cluster --name west --config=<<EOF
apiVersion: kind.x-k8s.io/v1alpha4
kind: Cluster
networking:
  podSubnet: "10.30.0.0/16"
  serviceSubnet: "10.255.30.0/24"
EOF
```

2. Setup contexts:
```shell
kind get kubeconfig --name east > east.kubeconfig
alias keast="KUBECONFIG=$(pwd)/east.kubeconfig kubectl"
kind get kubeconfig --name west > west.kubeconfig
alias kwest="KUBECONFIG=$(pwd)/west.kubeconfig kubectl"
```

3. Install MetalLB on and configure IP address pools:
```shell
keast apply -f https://raw.githubusercontent.com/metallb/metallb/v0.13.7/config/manifests/metallb-native.yaml
kwest apply -f https://raw.githubusercontent.com/metallb/metallb/v0.13.7/config/manifests/metallb-native.yaml
```
Before creating `IPAddressPool`, define CIDR based on kind network:
```shell
docker network inspect -f '{{.IPAM.Config}}' kind
```
Define east/west CIDRs as subnets of the `kind` network, e.g. if `kind` subnet is `172.18.0.0/16`,
east network could be `172.18.64.0/18` and west could be `172.18.128.0/18`, which will not overlap with node IPs.

CIDRs must have escaped slash before the network mask to make it usable with `sed`, e.g. `172.18.64.0\/18`.
```shell
export EAST_CLUSTER_CIDR="172.18.64.0\/18"
```
```shell
export WEST_CLUSTER_CIDR="172.18.128.0\/18"
```
```shell
sed "s/{{.cidr}}/$EAST_CLUSTER_CIDR/g" ip-address-pool.tmpl.yaml | keast apply -n metallb-system -f -
sed "s/{{.cidr}}/$WEST_CLUSTER_CIDR/g" ip-address-pool.tmpl.yaml | kwest apply -n metallb-system -f -
```

### Trust model

1. Download tools for certificate generation:
```shell
wget https://raw.githubusercontent.com/istio/istio/release-1.21/tools/certs/common.mk
wget https://raw.githubusercontent.com/istio/istio/release-1.21/tools/certs/Makefile.selfsigned.mk
```

#### Common root

1. Generate certificates for east and west clusters:
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

2. Create `cacert` secrets:
```shell
keast create namespace istio-system
keast create secret generic cacerts -n istio-system \
  --from-file=root-cert.pem=east/root-cert.pem \
  --from-file=ca-cert.pem=east/ca-cert.pem \
  --from-file=ca-key.pem=east/ca-key.pem \
  --from-file=cert-chain.pem=east/cert-chain.pem
```
```shell
kwest create namespace istio-system
kwest create secret generic cacerts -n istio-system \
  --from-file=root-cert.pem=west/root-cert.pem \
  --from-file=ca-cert.pem=west/ca-cert.pem \
  --from-file=ca-key.pem=west/ca-key.pem \
  --from-file=cert-chain.pem=west/cert-chain.pem
```

#### Different roots

1. Generate certificates for east and west clusters:
```shell
make -f Makefile.selfsigned.mk \
  ROOTCA_CN="East Root CA" \
  ROOTCA_ORG=my-company.org \
  root-ca
make -f Makefile.selfsigned.mk \
  INTERMEDIATE_CN="East Intermediate CA" \
  INTERMEDIATE_ORG=my-company.org \
  east-cacerts
make -f common.mk clean
make -f Makefile.selfsigned.mk \
  ROOTCA_CN="West Root CA" \
  ROOTCA_ORG=my-company.org \
  root-ca
make -f Makefile.selfsigned.mk \
  INTERMEDIATE_CN="West Intermediate CA" \
  INTERMEDIATE_ORG=my-company.org \
  west-cacerts
make -f common.mk clean
cat east/root-cert.pem >> trust-bundle.pem
cat west/root-cert.pem >> trust-bundle.pem
```

2. Create `cacert` secrets:
```shell
keast create namespace istio-system
keast create secret generic cacerts -n istio-system \
  --from-file=root-cert.pem=trust-bundle.pem \
  --from-file=ca-cert.pem=east/ca-cert.pem \
  --from-file=ca-key.pem=east/ca-key.pem \
  --from-file=cert-chain.pem=east/cert-chain.pem
```
```shell
kwest create namespace istio-system
kwest create secret generic cacerts -n istio-system \
  --from-file=root-cert.pem=trust-bundle.pem \
  --from-file=ca-cert.pem=west/ca-cert.pem \
  --from-file=ca-key.pem=west/ca-key.pem \
  --from-file=cert-chain.pem=west/cert-chain.pem
```

### Install Istio

```shell
helm template -s templates/istio.yaml . \
  --set localCluster=east \
  --set remoteCluster=west \
  --set sdsRootCaEnabled=false \
  | istioctl --kubeconfig=east.kubeconfig install -y -f -
```
```shell
helm template -s templates/istio.yaml . \
  --set localCluster=west \
  --set remoteCluster=east \
  --set sdsRootCaEnabled=false \
  | istioctl --kubeconfig=west.kubeconfig install -y -f -
```

### Configure routing

#### Ingress only (AUTO_PASSTHROUGH)

1. Configure east-west gateway and enable mtls:
```shell
keast apply -f auto-passthrough-gateway.yaml -n istio-system
kwest apply -f auto-passthrough-gateway.yaml -n istio-system
keast apply -f mtls.yaml -n istio-system
kwest apply -f mtls.yaml -n istio-system
```

#### Import remote service as local (*.cluster.local)

1. Deploy client app on the east cluster and server on the west cluster:
```shell
keast create namespace sleep
keast label namespace sleep istio-injection=enabled
keast apply -f https://raw.githubusercontent.com/istio/istio/release-1.20/samples/sleep/sleep.yaml -n sleep
kwest create namespace httpbin
kwest label namespace httpbin istio-injection=enabled
kwest apply -f https://raw.githubusercontent.com/istio/istio/release-1.20/samples/httpbin/httpbin.yaml -n httpbin
```

2. Import httpbin from west cluster to east cluster:
```shell
EAST_WEST_GW_IP=$(kwest get svc -l istio=eastwestgateway -n istio-system -o jsonpath='{.items[0].status.loadBalancer.ingress[0].ip}')
helm template -s templates/import-remote.yaml . \
  --set eastwestGatewayIP=$EAST_WEST_GW_IP \
  | keast apply -f -
```

3. Check endpoints in sleep's istio-proxy:
```shell
istioctl --kubeconfig=east.kubeconfig pc endpoints deploy/sleep -n sleep | grep httpbin
```

4. Test a request from sleep to httpbin:
```shell
SLEEP_POD_NAME=$(keast get pods -l app=sleep -n sleep -o jsonpath='{.items[0].metadata.name}')
keast exec $SLEEP_POD_NAME -n sleep -c sleep -- curl -v httpbin.httpbin.svc.cluster.local:8000/headers
```

5. Now deploy httpbin locally as well and test requests again. Traffic should be routed to both instances equally.
```shell
keast create namespace httpbin
keast label namespace httpbin istio-injection=enabled
keast apply -f https://raw.githubusercontent.com/istio/istio/release-1.20/samples/httpbin/httpbin.yaml -n httpbin
helm template -s templates/import-remote.yaml . \
  --set eastwestGatewayIP=$EAST_WEST_GW_IP \
  | keast delete -f -
helm template -s templates/import-as-local.yaml . \
  --set eastwestGatewayIP=$EAST_WEST_GW_IP \
  | keast apply -f -
```

#### Verify load balancing

1. Scale local deployment of httpbin:
```shell
keast scale deployment httpbin -n httpbin --replicas 2
```
Run a few requests and look at logs of httpbin:
```shell
while true
do
  keast exec $SLEEP_POD_NAME -n sleep -c sleep -- curl -v httpbin.httpbin.svc.cluster.local:8000/headers
  sleep 2
done
```
Sidecar of sleep app should have 3 endpoints and requests should be routed equally to all instances.

2. Scale remote deployment of httpbin:
```shell
kwest scale deployment httpbin -n httpbin --replicas 3
```
Run requests and look at logs again.

You should see that the new instances of httpbin in the west cluster do not receive traffic.

3. Scale sleep deployment:
```shell
keast scale deployment sleep -n sleep --replicas 10
```
```shell
cat <<EOF >> test-lb-for-different-clients.sh
#!/bin/bash
pod_names=$(KUBECONFIG=east.kubeconfig kubectl get pods -l app=sleep -n sleep -o jsonpath='{.items[*].metadata.name}')
for pod in $pod_names; do
  KUBECONFIG=east.kubeconfig kubectl exec $pod -n sleep -c sleep -- curl -v httpbin.httpbin.svc.cluster.local:8000/headers
done
EOF
bash test-lb-for-different-clients.sh
```
Now requests should be routed to different instances.

It's a known issue and as a workaround clients can always establish new TCP connection
or configure maxRequestsPerConnection to enforce establishing more connections.
* https://github.com/envoyproxy/envoy/issues/15071
* https://discuss.istio.io/t/need-help-understanding-load-balancing-between-clusters/9552

TODO: add examples with DestinationRule applied to east-west gateway with `maxRequestsPerConnection`.

#### Configuring locality load balancing

TODO: how to enable, how to disable, how to manage ratio

### Notes / TODOs

1. Is `ISTIO_META_DNS_AUTO_ALLOCATE` needed?
2. How to import a service, which has multiple ports?
3. What about east-west gateways with hostnames, e.g. AWS?
4. How to enforce load balancing for TLS passthrough?
