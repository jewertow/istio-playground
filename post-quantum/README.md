# Post-quantum key agreement in Istio

1. Install Istio 1.26 - the first version that supports `X25519MLKEM768` algorithm for key agreement:
```shell
curl -L https://istio.io/downloadIstio | ISTIO_VERSION=1.26.0-beta.0 sh -
```

2. Create KinD cluster:
```shell
kind create cluster --name test
```

3. Deploy MetalLB and configure an IP address pool:
```shell
kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/v0.13.7/config/manifests/metallb-native.yaml
```
Inspect docker network created for KinD:
```shell
docker network inspect -f '{{.IPAM.Config}}' kind
```
and set a subset for MetalLB:
```shell
export CLUSTER_CIDR="172.18.64.0\/18"
```
```shell
cat <<EOF > ip-address-pool.yaml
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: lb-address-pool
spec:
  addresses:
  - "{{.cidr}}"
  avoidBuggyIPs: true
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: empty
EOF
sed "s/{{.cidr}}/$CLUSTER_CIDR/g" ip-address-pool.yaml | kubectl apply -n metallb-system -f -
```

3. Deploy Istio:
```shell
cat <<EOF > istio.yaml
apiVersion: install.istio.io/v1alpha1
kind: IstioOperator
spec:
  meshConfig:
    accessLogFile: /dev/stdout
    tlsDefaults:
      ecdhCurves:
      - X25519MLKEM768
EOF
./istio-1.26.0-beta.0/bin/istioctl install -f istio.yaml -y
```

4. [Generate client and server certificates and keys](https://istio.io/latest/docs/tasks/traffic-management/ingress/secure-ingress/#generate-client-and-server-certificates-and-keys).

5. Deploy a gateway:
```shell
kubectl create -n istio-system secret tls httpbin-credential \
  --key=example_certs1/httpbin.example.com.key \
  --cert=example_certs1/httpbin.example.com.crt
```
```shell
kubectl apply -f - <<EOF
apiVersion: networking.istio.io/v1
kind: Gateway
metadata:
  name: mygateway
spec:
  selector:
    istio: ingressgateway
  servers:
  - port:
      number: 443
      name: https
      protocol: HTTPS
    tls:
      mode: SIMPLE
      credentialName: httpbin-credential
    hosts:
    - httpbin.example.com
---
apiVersion: networking.istio.io/v1
kind: VirtualService
metadata:
  name: httpbin
spec:
  hosts:
  - "httpbin.example.com"
  gateways:
  - mygateway
  http:
  - route:
    - destination:
        port:
          number: 8000
        host: httpbin
EOF
```

6. Deploy httpbin server:
```shell
kubectl label namespace default istio-injection=enabled
kubectl apply -f https://raw.githubusercontent.com/istio/istio/release-1.24/samples/httpbin/httpbin.yaml
```

7. Send a request to the server from OQS curl:
```shell
INGRESS_IP=$(kubectl get svc istio-ingressgateway -n istio-system -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
docker run \
    --network kind \
    -v ./example_certs1/example.com.crt:/etc/example_certs1/example.com.crt \
    --rm -it openquantumsafe/curl \
    curl -v \
    --curves X25519MLKEM768 \
    --cacert /etc/example_certs1/example.com.crt \
    -H "Host: httpbin.example.com" \
    --resolve "httpbin.example.com:443:$INGRESS_IP" \
    "https://httpbin.example.com:443/status/200"
```
The request should succeed with the following output:
```
* Added httpbin.example.com:443:172.18.64.1 to DNS cache
* Hostname httpbin.example.com was found in DNS cache
*   Trying 172.18.64.1:443...
* ALPN: curl offers http/1.1
* TLSv1.3 (OUT), TLS handshake, Client hello (1):
*  CAfile: /etc/example_certs1/example.com.crt
*  CApath: none
* TLSv1.3 (IN), TLS handshake, Server hello (2):
* TLSv1.3 (IN), TLS change cipher, Change cipher spec (1):
* TLSv1.3 (IN), TLS handshake, Encrypted Extensions (8):
* TLSv1.3 (IN), TLS handshake, Certificate (11):
* TLSv1.3 (IN), TLS handshake, CERT verify (15):
* TLSv1.3 (IN), TLS handshake, Finished (20):
* TLSv1.3 (OUT), TLS change cipher, Change cipher spec (1):
* TLSv1.3 (OUT), TLS handshake, Finished (20):
* SSL connection using TLSv1.3 / TLS_AES_256_GCM_SHA384 / X25519MLKEM768 / RSASSA-PSS
* ALPN: server accepted http/1.1
* Server certificate:
*  subject: CN=httpbin.example.com; O=httpbin organization
*  start date: Apr 23 13:10:53 2025 GMT
*  expire date: Apr 23 13:10:53 2026 GMT
*  common name: httpbin.example.com (matched)
*  issuer: O=example Inc.; CN=example.com
*  SSL certificate verify ok.
*   Certificate level 0: Public key type RSA (2048/112 Bits/secBits), signed using sha256WithRSAEncryption
*   Certificate level 1: Public key type RSA (2048/112 Bits/secBits), signed using sha256WithRSAEncryption
* Connected to httpbin.example.com (172.18.64.1) port 443
* using HTTP/1.x
> GET /status/200 HTTP/1.1
> Host: httpbin.example.com
> User-Agent: curl/8.11.1
> Accept: */*
> 
* Request completely sent off
* TLSv1.3 (IN), TLS handshake, Newsession Ticket (4):
* TLSv1.3 (IN), TLS handshake, Newsession Ticket (4):
< HTTP/1.1 200 OK
< access-control-allow-credentials: true
< access-control-allow-origin: *
< content-type: text/plain; charset=utf-8
< date: Wed, 23 Apr 2025 13:25:28 GMT
< content-length: 0
< x-envoy-upstream-service-time: 4
< server: istio-envoy
< 
* Connection #0 to host httpbin.example.com left intact
```
