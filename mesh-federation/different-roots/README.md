### Different roots

1. Download tools for certificate generation:
```shell
wget https://raw.githubusercontent.com/istio/istio/release-1.21/tools/certs/common.mk
wget https://raw.githubusercontent.com/istio/istio/release-1.21/tools/certs/Makefile.selfsigned.mk
```

2. Generate certificates for east and west clusters:
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

3. Create `cacert` secrets:
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

4. Install Istio:
```shell
helm template -s templates/istio.yaml .. \
  --set localCluster=east \
  --set remoteCluster=west \
  --set sdsRootCaEnabled=false \
  | istioctl --kubeconfig=../east.kubeconfig install -y -f -
```
```shell
helm template -s templates/istio.yaml .. \
  --set localCluster=west \
  --set remoteCluster=east \
  --set sdsRootCaEnabled=false \
  | istioctl --kubeconfig=../west.kubeconfig install -y -f -
```

5. Configure east-west gateway and enable mtls:
```shell
keast apply -f ../auto-passthrough-gateway.yaml -n istio-system
kwest apply -f ../auto-passthrough-gateway.yaml -n istio-system
keast apply -f ../mtls.yaml -n istio-system
kwest apply -f ../mtls.yaml -n istio-system
```

6. Deploy client app on the east cluster and server on the west cluster:
```shell
keast create namespace sleep
keast label namespace sleep istio-injection=enabled
keast apply -f https://raw.githubusercontent.com/istio/istio/release-1.20/samples/sleep/sleep.yaml -n sleep
```
```shell
kwest create namespace httpbin
kwest label namespace httpbin istio-injection=enabled
kwest apply -f https://raw.githubusercontent.com/istio/istio/release-1.20/samples/httpbin/httpbin.yaml -n httpbin
```

7. Import httpbin from west cluster to east cluster:
```shell
EAST_WEST_GW_IP=$(kwest get svc -l istio=eastwestgateway -n istio-system -o jsonpath='{.items[0].status.loadBalancer.ingress[0].ip}')
sed "s/{{.eastwestGatewayIP}}/$EAST_WEST_GW_IP/g" ../import-httpbin.tmpl.yaml | keast -n sleep apply -f -
```

8. Check endpoints in sleep's istio-proxy:
```shell
istioctl --kubeconfig=../east.kubeconfig pc endpoints deploy/sleep -n sleep | grep httpbin
```

9. Test a request from sleep to httpbin:
```shell
SLEEP_POD_NAME=$(keast get pods -l app=sleep -n sleep -o jsonpath='{.items[0].metadata.name}')
keast exec $SLEEP_POD_NAME -n sleep -c sleep -- curl -v httpbin.httpbin.svc.cluster.local:8000/headers
```
