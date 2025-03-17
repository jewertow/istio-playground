# Multi-tenant Istio deployment with Sail Operator

## Install Istio CNI

```shell
kubectl create namespace istio-cni
kubectl apply -f - <<EOF
apiVersion: sailoperator.io/v1
kind: IstioCNI
metadata:
  name: default
spec:
  version: v1.24.3
  namespace: istio-cni
EOF
```

## Certificates

1. Download tools:
```shell
wget https://raw.githubusercontent.com/istio/istio/release-1.22/tools/certs/common.mk -O common.mk
wget https://raw.githubusercontent.com/istio/istio/release-1.22/tools/certs/Makefile.selfsigned.mk -O Makefile.selfsigned.mk
```

2. Generate certificates:
```shell
make -f Makefile.selfsigned.mk \
  ROOTCA_CN="Root CA" \
  ROOTCA_ORG=my-company.org \
  root-ca
make -f Makefile.selfsigned.mk \
  INTERMEDIATE_CN="Intermediate CA 1" \
  INTERMEDIATE_ORG=my-company.org \
  ca1-cacerts
make -f Makefile.selfsigned.mk \
  INTERMEDIATE_CN="Intermediate CA 2" \
  INTERMEDIATE_ORG=my-company.org \
  ca2-cacerts
make -f common.mk clean
```

3. Create secrets:
```shell
# mesh 1
kubectl create namespace istio-system-1
kubectl create secret generic cacerts -n istio-system-1 \
  --from-file=root-cert.pem=ca1/root-cert.pem \
  --from-file=ca-cert.pem=ca1/ca-cert.pem \
  --from-file=ca-key.pem=ca1/ca-key.pem \
  --from-file=cert-chain.pem=ca1/cert-chain.pem
# mesh 2
kubectl create namespace istio-system-2
kubectl create secret generic cacerts -n istio-system-2 \
  --from-file=root-cert.pem=ca2/root-cert.pem \
  --from-file=ca-cert.pem=ca2/ca-cert.pem \
  --from-file=ca-key.pem=ca2/ca-key.pem \
  --from-file=cert-chain.pem=ca2/cert-chain.pem
```

## Deploy Istio control planes

```shell
kubectl apply -f - <<EOF
apiVersion: sailoperator.io/v1
kind: Istio
metadata:
  name: mesh-1
spec:
  namespace: istio-system-1
  updateStrategy:
    type: RevisionBased
  version: v1.24.3
  values:
    meshConfig:
      accessLogFile: /dev/stdout
      discoverySelectors:
      - matchLabels:
          mesh: istio-system-1
EOF
kubectl apply -f - <<EOF
apiVersion: sailoperator.io/v1
kind: Istio
metadata:
  name: mesh-2
spec:
  namespace: istio-system-2
  updateStrategy:
    type: RevisionBased
  version: v1.24.3
  values:
    meshConfig:
      accessLogFile: /dev/stdout
      discoverySelectors:
      - matchLabels:
          mesh: istio-system-2
EOF
```

## Deploy apps, enabled mTLS and configure authorization policies

1. Mesh 1:
```shell
# server
kubectl create namespace server
kubectl label namespace server mesh=istio-system-1
kubectl label namespace server istio.io/rev=mesh-1-v1-24-3
kubectl apply -f https://raw.githubusercontent.com/istio/istio/release-1.25/samples/httpbin/httpbin.yaml -n server
# client 1
kubectl create namespace client-1
kubectl label namespace client-1 mesh=istio-system-1
kubectl label namespace client-1 istio.io/rev=mesh-1-v1-24-3
kubectl apply -f https://raw.githubusercontent.com/istio/istio/release-1.25/samples/sleep/sleep.yaml -n client-1
```

2. Mesh 2:
```shell
# client 2
kubectl create namespace client-2
kubectl label namespace client-2 mesh=istio-system-2
kubectl label namespace client-2 istio.io/rev=mesh-2-v1-24-3
kubectl apply -f https://raw.githubusercontent.com/istio/istio/release-1.25/samples/sleep/sleep.yaml -n client-2
```

3. Enable strict mTLS:
```shell
cat <<EOF > mtls.yaml
apiVersion: security.istio.io/v1beta1
kind: PeerAuthentication
metadata:
  name: default
spec:
  mtls:
    mode: STRICT
EOF
kubectl apply -f mtls.yaml -n istio-system-1
kubectl apply -f mtls.yaml -n istio-system-2
```

4. Configure authorization policy:
```shell
kubectl apply -f - <<EOF
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
 name: deny-all-by-default
 namespace: istio-system-1
spec:
  {}
---
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
 name: httpbin
 namespace: server
spec:
  selector:
    matchLabels:
      app: httpbin
  action: ALLOW
  rules:
  - from:
    - source:
        namespaces: ["client-1"]
  - from:
    - source:
        namespaces: ["client-2"]
    to:
    - operation:
        paths: ["/ip"]
EOF
```

## Test authz policies

1. client-1 -> server:
```shell
kubectl exec deploy/sleep -n client-1 -- curl -v httpbin:8000/ip
```
```shell
kubectl exec deploy/sleep -n client-1 -- curl -v httpbin:8000/headers
```

2. client-2 -> server:
```shell
kubectl exec deploy/sleep -n client-2 -- curl -v httpbin:8000/ip
```
```shell
kubectl exec deploy/sleep -n client-1 -- curl -v httpbin:8000/headers
```
```shell
kubectl exec deploy/sleep -n client-1 -- curl -v httpbin:8000/user-agent
```
