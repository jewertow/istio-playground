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
```
```shell
kind get kubeconfig --name west > west.kubeconfig
alias kwest="KUBECONFIG=west.kubeconfig kubectl"
```

4. Install MetalLB on and configure IP address pools:
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

5. Create cacert secrets:
```shell
keast create namespace istio-system
keast create secret generic cacerts -n istio-system \
      --from-file=east/ca-cert.pem \
      --from-file=east/ca-key.pem \
      --from-file=east/root-cert.pem \
      --from-file=east/cert-chain.pem
```
```shell
kwest create namespace istio-system
kwest create secret generic cacerts -n istio-system \
      --from-file=west/ca-cert.pem \
      --from-file=west/ca-key.pem \
      --from-file=west/root-cert.pem \
      --from-file=west/cert-chain.pem
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
kwest apply -f istio-eastwestgateway.yaml -n istio-system
```

8. Deploy client app on the east cluster and server on the west cluster:
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
> GET /headers HTTP/1.1
> Host: httpbin.httpbin.svc.cluster.local:8000
> User-Agent: curl/8.6.0
> Accept: */*
> 
< HTTP/1.1 200 OK
< server: envoy
< date: Wed, 06 Mar 2024 13:53:22 GMT
< content-type: application/json
< content-length: 546
< access-control-allow-origin: *
< access-control-allow-credentials: true
< x-envoy-upstream-service-time: 3
< 
{ [546 bytes data]
100   546  100   546    0     0  95538      0 --:--:-- --:--:-- --:--:--  106k
{
  "headers": {
    "Accept": "*/*", 
    "Host": "httpbin.httpbin.svc.cluster.local:8000", 
    "User-Agent": "curl/8.6.0", 
    "X-B3-Parentspanid": "2f7b11e676d289d4", 
    "X-B3-Sampled": "0", 
    "X-B3-Spanid": "146b4db5b0981355", 
    "X-B3-Traceid": "d4072422376ee5b02f7b11e676d289d4", 
    "X-Envoy-Attempt-Count": "1", 
    "X-Forwarded-Client-Cert": "By=spiffe://cluster.local/ns/httpbin/sa/httpbin;Hash=7b5033446e8c1efc7f50c75c2a1af0083abae6222e9351a0e3d7e0d726a62c00;Subject=\"\";URI=spiffe://cluster.local/ns/sleep/sa/sleep"
  }
}
```

### Notes / TODOs

1. `ServiceEntry` and `DestinationRule` from `import-httpbin.tmpl.yaml` could be managed by a federation controller.
2. How `west` cluster can manage exported services? It should be feasible with `AuthorizationPolicy`.
3. Is `ISTIO_META_DNS_AUTO_ALLOCATE` needed?
4. How to import a service, which has multiple ports?
