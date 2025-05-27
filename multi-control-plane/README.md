1. Create KinD cluster:

```shell
kind create cluster --name test
```

2. Create different root certificates:

```shell
wget https://raw.githubusercontent.com/istio/istio/release-1.26/tools/certs/common.mk -O common.mk
wget https://raw.githubusercontent.com/istio/istio/release-1.26/tools/certs/Makefile.selfsigned.mk -O Makefile.selfsigned.mk
```

```shell
make -f Makefile.selfsigned.mk \
  ROOTCA_CN="Root CA 1" \
  ROOTCA_ORG=my-company.org \
  root-ca
make -f Makefile.selfsigned.mk \
  INTERMEDIATE_CN="Intermediate CA 1" \
  INTERMEDIATE_ORG=my-company.org \
  ca1-cacerts
make -f common.mk clean
```
```shell
make -f Makefile.selfsigned.mk \
  ROOTCA_CN="Root CA 2" \
  ROOTCA_ORG=my-company.org \
  root-ca
make -f Makefile.selfsigned.mk \
  INTERMEDIATE_CN="Intermediate CA 2" \
  INTERMEDIATE_ORG=my-company.org \
  ca2-cacerts
make -f common.mk clean
```

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

3. Install control planes:

```shell
{
cat <<EOF
apiVersion: install.istio.io/v1alpha1
kind: IstioOperator
spec:
  profile: minimal
  revision: mesh-1
  values:
    global:
      istioNamespace: istio-system-1
  meshConfig:
    accessLogFile: /dev/stdout
    defaultConfig:
      proxyMetadata:
        PROXY_CONFIG_XDS_AGENT: "true"
    discoverySelectors:
    - matchLabels:
        mesh: istio-system-1
    - matchLabels:
        mesh: istio-system-2
    caCertificates:
    - pem: |
EOF
sed 's/^/        /' ca1/root-cert.pem
} > iop-1.yaml
istioctl install -n istio-system-1 -f iop-1.yaml -y
```

```shell
{
cat <<EOF
apiVersion: install.istio.io/v1alpha1
kind: IstioOperator
spec:
  profile: minimal
  revision: mesh-2
  values:
    global:
      istioNamespace: istio-system-2
  meshConfig:
    accessLogFile: /dev/stdout
    defaultConfig:
      proxyMetadata:
        PROXY_CONFIG_XDS_AGENT: "true"
    discoverySelectors:
    - matchLabels:
        mesh: istio-system-1
    - matchLabels:
        mesh: istio-system-2
    caCertificates:
    - pem: |
EOF
sed 's/^/        /' ca2/root-cert.pem
} > iop-2.yaml
istioctl install -n istio-system-2 -f iop-2.yaml -y
```

4. Deploy apps:

```shell
# mesh 1
# server
kubectl create namespace server
kubectl label namespace server mesh=istio-system-1
kubectl label namespace server istio.io/rev=mesh-1
kubectl apply -f https://raw.githubusercontent.com/istio/istio/release-1.26/samples/httpbin/httpbin.yaml -n server
# client 1
kubectl create namespace client-1
kubectl label namespace client-1 mesh=istio-system-1
kubectl label namespace client-1 istio.io/rev=mesh-1
kubectl apply -f https://raw.githubusercontent.com/istio/istio/release-1.26/samples/sleep/sleep.yaml -n client-1
```

```shell
# mesh 2
# client 2
kubectl create namespace client-2
kubectl label namespace client-2 mesh=istio-system-2
kubectl label namespace client-2 istio.io/rev=mesh-2
kubectl apply -f https://raw.githubusercontent.com/istio/istio/release-1.25/samples/sleep/sleep.yaml -n client-2
```

5. Enable strict mTLS:

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

6. Test connectivity:

```shell
kubectl exec deploy/sleep -n client-1 -- curl -v httpbin.server:8000/ip
```
```shell
kubectl exec deploy/sleep -n client-2 -- curl -v httpbin.server:8000/ip
```
