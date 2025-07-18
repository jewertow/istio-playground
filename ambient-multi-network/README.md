## Ambient multi-cluster

### Download Istio 1.27

```shell
container_id=$(docker create gcr.io/istio-testing/istioctl:1.27-dev)
docker cp $container_id:/usr/local/bin/istioctl .
docker rm $container_id
```

### Setup clusters

```shell
curl -s https://raw.githubusercontent.com/istio/istio/refs/heads/release-1.26/samples/kind-lb/setupkind.sh | sh -s -- --cluster-name east --ip-space 254
curl -s https://raw.githubusercontent.com/istio/istio/refs/heads/release-1.26/samples/kind-lb/setupkind.sh | sh -s -- --cluster-name west --ip-space 255
```

```shell
kind get kubeconfig --name east > east.kubeconfig
alias keast="KUBECONFIG=$(pwd)/east.kubeconfig kubectl"
alias istioctl-east="KUBECONFIG=$(pwd)/east.kubeconfig $(pwd)/istioctl"
kind get kubeconfig --name west > west.kubeconfig
alias kwest="KUBECONFIG=$(pwd)/west.kubeconfig kubectl"
alias istioctl-west="KUBECONFIG=$(pwd)/west.kubeconfig $(pwd)/istioctl"
```

### Configure certificates

```shell
wget https://raw.githubusercontent.com/istio/istio/release-1.21/tools/certs/common.mk -O common.mk
wget https://raw.githubusercontent.com/istio/istio/release-1.21/tools/certs/Makefile.selfsigned.mk -O Makefile.selfsigned.mk
```

```shell
make -f Makefile.selfsigned.mk \
  ROOTCA_CN="Root CA" \
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

### Demo

1. Install control planes:

```shell
istioctl-east install -f iop-east.yaml -y
istioctl-west install -f iop-west.yaml -y
keast label namespace istio-system topology.istio.io/network=east-network
kwest label namespace istio-system topology.istio.io/network=west-network
```

1. Deploy gateways:

```shell
keast apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.3.0/standard-install.yaml
kwest apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.3.0/standard-install.yaml
keast apply -f ew-gateway-east.yaml
kwest apply -f ew-gateway-west.yaml
```

1. Enable endpoint discovery:

```shell
EAST_API_SERVER_IP=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' east-control-plane)
istioctl-east create-remote-secret --name=east --server=https://$EAST_API_SERVER_IP:6443 | kwest apply -f -
```

```shell
WEST_API_SERVER_IP=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' west-control-plane)
istioctl-west create-remote-secret --name=west --server=https://$WEST_API_SERVER_IP:6443 | keast apply -f -
```

1. Deploy apps in the east cluster:

```shell
keast label namespace default istio.io/dataplane-mode=ambient
keast apply -f https://raw.githubusercontent.com/istio/istio/refs/heads/release-1.26/samples/sleep/sleep.yaml
keast apply -f https://raw.githubusercontent.com/istio/istio/refs/heads/release-1.26/samples/httpbin/httpbin.yaml
keast label svc httpbin istio.io/global="true"
```

1. Deploy apps in the west cluster:

```shell
kwest label namespace default istio.io/dataplane-mode=ambient
kwest apply -f https://raw.githubusercontent.com/istio/istio/refs/heads/release-1.26/samples/httpbin/httpbin.yaml
kwest label svc httpbin istio.io/global="true"
```

1. Enable mTLS:

```shell
keast apply -f mtls.yaml
kwest apply -f mtls.yaml
```

1. Test connectivity:

```shell
keast exec deploy/sleep -c sleep -- curl -v httpbin:8000/headers
```
