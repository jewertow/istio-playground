## Prerequisites

1. Download istioctl:
```shell
docker pull quay.io/jewertow/istioctl:istio-io-rev-annotation
container_id=$(docker create quay.io/jewertow/istioctl:istio-io-rev-annotation)
docker cp "$container_id:/usr/local/bin/istioctl" ./istioctl
docker rm "$container_id"
```

2. Download my Istio fork:
```
git clone https://github.com/jewertow/upstream-istio.git
pushd upstream-istio
git checkout istio-io-rev-annotation
popd
```

## How to test istio.io/rev annotation

```shell
kind create cluster --name test
```

Install Istio with default revision
```shell
# check annotation on default gateways
./istioctl install -y \
    --set hub=quay.io/jewertow \
    --set tag=istio-io-rev-annotation \
    --set profile=demo

# check annotation on sidecars
kubectl create namespace httpbin
kubectl label namespace httpbin istio-injection=enabled
kubectl apply -f https://raw.githubusercontent.com/istio/istio/release-1.17/samples/httpbin/httpbin.yaml -n httpbin

# check annotation on gateway installed with helm chart
kubectl create namespace istio-ingress
helm install istio-ingressgateway ./upstream-istio/manifests/charts/gateway -n istio-ingress

# check annotation on injected gateway
kubectl create namespace gateway-injection
kubectl apply -f ingress-gateway-injection.yaml -n gateway-injection
```

Install Istio with custom revision
```
# revision 1-17
./istioctl install -y -f - <<EOF
apiVersion: install.istio.io/v1alpha1
kind: IstioOperator
metadata:
  name: control-plane-1-17
spec:
  hub: quay.io/jewertow
  tag: istio-io-rev-annotation
  profile: minimal
  revision: 1-17
  components:
    ingressGateways:
    - name: ingress-gw-1-17
      namespace: istio-system
      enabled: true
EOF

# sidecar revision 1-17
kubectl create namespace sleep
istioctl x revision tag set canary --revision 1-17
kubectl label namespace sleep istio.io/rev=canary
kubectl apply -f https://raw.githubusercontent.com/istio/istio/release-1.17/samples/sleep/sleep.yaml -n sleep

# gateway installed with helm
kubectl create namespace istio-ingress-canary
helm install istio-ingressgateway ./upstream-istio/manifests/charts/gateway -n istio-ingress-canary --set revision=canary

# injected gateway 1-17
kubectl create namespace gateway-injection-canary
kubectl apply -f ingress-gateway-injection-canary.yaml -n gateway-injection-canary
```
