### Managing services in mesh federation

This is a PoC of managing service discovery with `ServiceEntry` in a mesh federation.
For simplicity, both meshes use the same root certificate and the same trust domain.
Different root certificates and trust domains will be addressed in another document.

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
alias keast="KUBECONFIG=east.kubeconfig kubectl"
kind get kubeconfig --name west > west.kubeconfig
alias kwest="KUBECONFIG=west.kubeconfig kubectl"
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

4. Create cacert secrets:
```shell
keast create namespace istio-system
keast create secret generic cacerts -n istio-system \
      --from-file=tls.crt=east/ca-cert.pem \
      --from-file=tls.key=east/ca-key.pem \
      --from-file=ca.crt=east/root-cert.pem
```
```shell
kwest create namespace istio-system
kwest create secret generic cacerts -n istio-system \
      --from-file=tls.crt=west/ca-cert.pem \
      --from-file=tls.key=west/ca-key.pem \
      --from-file=ca.crt=west/root-cert.pem
```

5. Deploy trust bundle SDS:
```shell
cat east/root-cert.pem >> trust-bundle.pem
cat west/root-cert.pem >> trust-bundle.pem
keast create cm trust-bundle -n istio-system --from-file trust-bundle.pem
kwest create cm trust-bundle -n istio-system --from-file trust-bundle.pem 
keast apply -f trust-bundle-sds.yaml -n istio-system
kwest apply -f trust-bundle-sds.yaml -n istio-system
```

6. Deploy Istio on both clusters:
```shell
istioctl --kubeconfig=east.kubeconfig install -f istio-east.yaml -y
```
```shell
istioctl --kubeconfig=west.kubeconfig install -f istio-west.yaml -y
```

7. Deploy east-west gateway in the west cluster:
```shell
kwest apply -f custom-bootstrap.yaml -n istio-system
kwest apply -f istio-eastwestgateway.yaml -n istio-system
```

8. Deploy client app on the east cluster and server on the west cluster:
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

9. Enable mTLS in both clusters:
```shell
keast apply -f mtls.yaml -n istio-system
kwest apply -f mtls.yaml -n istio-system
```

10. Create ServiceEntry for httpbin in the east cluster:
```shell
EAST_WEST_GW_IP=$(kwest get svc -l istio=eastwestgateway -n istio-system -o jsonpath='{.items[0].status.loadBalancer.ingress[0].ip}')
sed "s/{{.eastwestGatewayIP}}/$EAST_WEST_GW_IP/g" import-httpbin.tmpl.yaml | keast -n sleep apply -f -
```

11. Check endpoints in sleep's istio-proxy:
```shell
istioctl --kubeconfig=east.kubeconfig pc endpoints deploy/sleep -n sleep | grep httpbin
```

12. Test a request from sleep to httpbin:
```shell
SLEEP_POD_NAME=$(keast get pods -l app=sleep -n sleep -o jsonpath='{.items[0].metadata.name}')
keast exec $SLEEP_POD_NAME -n sleep -c sleep -- curl -v httpbin.httpbin.svc.cluster.local:8000/headers
```
Expected output should be similar to:
```
* IPv6: (none)
* IPv4: 240.240.192.41
*   Trying 240.240.192.41:8000...
* Connected to httpbin.httpbin.svc.cluster.local (240.240.192.41) port 8000
> GET /headers HTTP/1.1
> Host: httpbin.httpbin.svc.cluster.local:8000
> User-Agent: curl/8.6.0
> Accept: */*
> 
{
  "headers": {
    "Accept": "*/*", 
    "Host": "httpbin.httpbin.svc.cluster.local:8000", 
    "User-Agent": "curl/8.6.0", 
    "X-B3-Parentspanid": "f99d7760907a6cb4", 
    "X-B3-Sampled": "0", 
    "X-B3-Spanid": "b15e6d1c6121ae72", 
    "X-B3-Traceid": "16faac5574babfcaf99d7760907a6cb4", 
    "X-Envoy-Attempt-Count": "1", 
    "X-Forwarded-Client-Cert": "By=spiffe://west.local/ns/httpbin/sa/httpbin;Hash=9cde21f457a154ebef77190033ed2288df1d2f469a86c5ce37e98563d86b609b;Subject=\"\";URI=spiffe://east.local/ns/sleep/sa/sleep"
  }
}
< HTTP/1.1 200 OK
< server: envoy
< date: Wed, 13 Mar 2024 14:13:48 GMT
< content-type: application/json
< content-length: 540
< access-control-allow-origin: *
< access-control-allow-credentials: true
< x-envoy-upstream-service-time: 8
< 
{ [540 bytes data]
100   540  100   540    0     0  49001      0 --:--:-- --:--:-- --:--:-- 54000
* Connection #0 to host httpbin.httpbin.svc.cluster.local left intact
```

### Notes / TODOs

1. `ServiceEntry` and `DestinationRule` from `import-httpbin.tmpl.yaml` could be managed by a federation controller.
2. How `west` cluster can manage exported services? It should be feasible with `AuthorizationPolicy`.
3. Is `ISTIO_META_DNS_AUTO_ALLOCATE` needed?
4. How to import a service, which has multiple ports?
5. Why the outbound listeners are in the draining state?
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
