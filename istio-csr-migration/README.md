## Migration Istio CA to istio-csr

### Deploy Istio with custom certificate

1. Create root certificate:
```shell
wget https://raw.githubusercontent.com/istio/istio/release-1.21/tools/certs/common.mk -O common.mk
wget https://raw.githubusercontent.com/istio/istio/release-1.21/tools/certs/Makefile.selfsigned.mk -O Makefile.selfsigned.mk
make -f Makefile.selfsigned.mk \
  ROOTCA_CN="East Root CA" \
  ROOTCA_ORG=my-company.org \
  root-ca
make -f Makefile.selfsigned.mk \
  INTERMEDIATE_CN="istio-ca" \
  INTERMEDIATE_ORG="cluster.local" \
  istiod-cacerts
```

2. Create cacert secret:
```shell
kubectl create namespace istio-system
kubectl create secret generic cacerts -n istio-system \
  --from-file=root-cert.pem=istiod/root-cert.pem \
  --from-file=ca-cert.pem=istiod/ca-cert.pem \
  --from-file=ca-key.pem=istiod/ca-key.pem \
  --from-file=cert-chain.pem=istiod/cert-chain.pem
```

3. Install Istio:
```shell
istioctl install -y
```

4. Deploy apps:
```shell
kubectl label namespace default istio-injection=enabled
kubectl apply -f https://raw.githubusercontent.com/istio/istio/release-1.20/samples/sleep/sleep.yaml
kubectl apply -f https://raw.githubusercontent.com/istio/istio/release-1.20/samples/httpbin/httpbin.yaml
```

### Install istio-csr and configure Istio:

1. Create a secret with self-signed root-certificate:
```shell
kubectl create secret generic -n istio-system selfsigned-issuer --from-file=ca.crt=root-cert.pem --from-file=tls.crt=root-cert.pem --from-file=tls.key=root-key.pem
```

2. Install cert-manager:
```shell
helm install cert-manager jetstack/cert-manager \
  --namespace cert-manager \
  --create-namespace \
  --version v1.15.2 \
  --set crds.enabled=true
```

3. Create Certificate and Issuers:
```
kubectl apply -f - <<EOF
# SelfSigned issuers are useful for creating root certificates
apiVersion: cert-manager.io/v1
kind: Issuer
metadata:
  name: selfsigned
  namespace: istio-system
spec:
  ca:
    secretName: selfsigned-issuer
---
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: istio-ca
  namespace: istio-system
spec:
  isCA: true
  duration: 87600h # 10 years
  secretName: istio-ca
  commonName: istio-ca
  privateKey:
    algorithm: ECDSA
    size: 256
  subject:
    organizations:
    - cluster.local
  issuerRef:
    name: selfsigned
    kind: Issuer
    group: cert-manager.io
---
# Create a CA issuer using our root. This will be the Issuer which istio-csr will use.
apiVersion: cert-manager.io/v1
kind: Issuer
metadata:
  name: istio-ca
  namespace: istio-system
spec:
  ca:
    secretName: istio-ca
EOF
```

4. Install istio-csr:
```shell
helm upgrade cert-manager-istio-csr jetstack/cert-manager-istio-csr \
  --install \
  --namespace cert-manager \
  --wait
```

5. Configure Istio to rely on istio-csr:
```shell
istioctl install -y -f - <<EOF
apiVersion: install.istio.io/v1alpha1
kind: IstioOperator
spec:
  values:
    global:
      # Change certificate provider to cert-manager istio agent for istio agent
      caAddress: cert-manager-istio-csr.cert-manager.svc:443
  components:
    pilot:
      k8s:
        env:
          # Disable istiod CA Sever functionality
        - name: ENABLE_CA_SERVER
          value: "false"
EOF
```

6. Remove cacerts secret:
```shell
kubectl delete secret cacerts -n istio-system
```


