### Different roots with trust bundle SDS

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

4. Deploy trust bundle SDS:
```shell
keast create cm trust-bundle -n istio-system --from-file trust-bundle.pem
kwest create cm trust-bundle -n istio-system --from-file trust-bundle.pem 
keast apply -f https://raw.githubusercontent.com/jewertow/trust-bundle-sds/master/deploy/sds-server.yaml -n istio-system
kwest apply -f https://raw.githubusercontent.com/jewertow/trust-bundle-sds/master/deploy/sds-server.yaml -n istio-system
```

5. Install Istio:
```shell
keast apply -f custom-bootstrap.yaml -n istio-system
helm template -s templates/istio.yaml .. \
  --set localCluster=east \
  --set remoteCluster=west \
  --set sdsRootCaEnabled=true \
  | istioctl --kubeconfig=../east.kubeconfig install -y -f -
```
```shell
kwest apply -f custom-bootstrap.yaml -n istio-system
helm template -s templates/istio.yaml .. \
  --set localCluster=west \
  --set remoteCluster=east \
  --set sdsRootCaEnabled=true \
  | istioctl --kubeconfig=../west.kubeconfig install -y -f -
```

6. Configure east-west gateway and enable mtls:
```shell
keast apply -f ../auto-passthrough-gateway.yaml -n istio-system
kwest apply -f ../auto-passthrough-gateway.yaml -n istio-system
keast apply -f ../mtls.yaml -n istio-system
kwest apply -f ../mtls.yaml -n istio-system
```

7. Deploy client app on the east cluster and server on the west cluster:
```shell
keast create namespace sleep
keast label namespace sleep istio-injection=enabled
keast apply -f https://raw.githubusercontent.com/istio/istio/release-1.20/samples/sleep/sleep.yaml -n sleep
keast apply -f custom-bootstrap.yaml -n sleep
keast patch deployments sleep -n sleep --type='json' -p='[{"op":"add","path":"/spec/template/metadata/annotations","value":{}},{"op":"add","path":"/spec/template/metadata/annotations/sidecar.istio.io~1bootstrapOverride","value":"custom-bootstrap-for-trust-bundle-federation"}]'
```
```shell
kwest create namespace httpbin
kwest label namespace httpbin istio-injection=enabled
kwest apply -f https://raw.githubusercontent.com/istio/istio/release-1.20/samples/httpbin/httpbin.yaml -n httpbin
kwest apply -f custom-bootstrap.yaml -n httpbin
kwest patch deployments httpbin  -n httpbin --type='json' -p='[{"op":"add","path":"/spec/template/metadata/annotations","value":{}},{"op":"add","path":"/spec/template/metadata/annotations/sidecar.istio.io~1bootstrapOverride","value":"custom-bootstrap-for-trust-bundle-federation"}]'
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
Output should be similar to:
```
* Host httpbin.httpbin.svc.cluster.local:8000 was resolved.
* IPv6: (none)
* IPv4: 240.240.192.41
*   Trying 240.240.192.41:8000...
* Connected to httpbin.httpbin.svc.cluster.local (240.240.192.41) port 8000
> GET /headers HTTP/1.1
> Host: httpbin.httpbin.svc.cluster.local:8000
> User-Agent: curl/8.7.1
> Accept: */*
> 
* Request completely sent off
< HTTP/1.1 200 OK
< server: envoy
< date: Fri, 29 Mar 2024 11:27:43 GMT
< content-type: application/json
< content-length: 540
< access-control-allow-origin: *
< access-control-allow-credentials: true
< x-envoy-upstream-service-time: 1
< 
{ [540 bytes data]
100   540  100   540    0     0   198k      0 --:--:-- --:--:-- --:--:--  263k
* Connection #0 to host httpbin.httpbin.svc.cluster.local left intact
{
  "headers": {
    "Accept": "*/*", 
    "Host": "httpbin.httpbin.svc.cluster.local:8000", 
    "User-Agent": "curl/8.7.1", 
    "X-B3-Parentspanid": "e38ed3bf0951aae6", 
    "X-B3-Sampled": "0", 
    "X-B3-Spanid": "169269256bc9c891", 
    "X-B3-Traceid": "c9a7812097b14ca6e38ed3bf0951aae6", 
    "X-Envoy-Attempt-Count": "1", 
    "X-Forwarded-Client-Cert": "By=spiffe://west.local/ns/httpbin/sa/httpbin;Hash=288bf34f51d164836f08a834d887b8a4bebd9db59a9f0b4504d9735a63cfcbd0;Subject=\"\";URI=spiffe://east.local/ns/sleep/sa/sleep"
  }
}
```

#### TODO

1. Why the outbound listeners are in the draining state? It only happens in the custom-sds patch.
```
ENDPOINT                                                STATUS       OUTLIER CHECK     CLUSTER
10.244.0.3:53                                           DRAINING     OK                outbound|53||kube-dns.kube-system.svc.cluster.local
10.244.0.3:9153                                         DRAINING     OK                outbound|9153||kube-dns.kube-system.svc.cluster.local
10.244.0.4:53                                           DRAINING     OK                outbound|53||kube-dns.kube-system.svc.cluster.local
10.244.0.4:9153                                         DRAINING     OK                outbound|9153||kube-dns.kube-system.svc.cluster.local
10.244.0.5:9443                                         DRAINING     OK                outbound|443||webhook-service.metallb-system.svc.cluster.local
10.244.0.6:15012                                        DRAINING     OK                outbound|15012||trust-bundle-sds.istio-system.svc.cluster.local
10.244.0.7:15010                                        DRAINING     OK                outbound|15010||istiod.istio-system.svc.cluster.local
10.244.0.7:15012                                        DRAINING     OK                outbound|15012||istiod.istio-system.svc.cluster.local
10.244.0.7:15014                                        DRAINING     OK                outbound|15014||istiod.istio-system.svc.cluster.local
10.244.0.7:15017                                        DRAINING     OK                outbound|443||istiod.istio-system.svc.cluster.local
10.244.0.9:80                                           DRAINING     OK                outbound|80||sleep.sleep.svc.cluster.local
10.96.240.104:15012                                     DRAINING     OK                trust-bundle-sds
127.0.0.1:15000                                         DRAINING     OK                prometheus_stats
127.0.0.1:15020                                         DRAINING     OK                agent
172.18.0.2:6443                                         DRAINING     OK                outbound|443||kubernetes.default.svc.cluster.local
172.18.128.1:15443                                      DRAINING     OK                outbound|8000||httpbin.httpbin.svc.cluster.local
unix://./etc/istio/proxy/XDS                            DRAINING     OK                xds-grpc
unix://./var/run/secrets/workload-spiffe-uds/socket     DRAINING     OK                sds-grpc
```
