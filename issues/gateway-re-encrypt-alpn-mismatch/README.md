#### Steps to reproduce

1. Create KinD cluster:
```shell
kind create cluster --name test
```

2. Install Istio:
```shell
istioctl install -y --set meshConfig.accessLogFile=/dev/stdout
```

3. Deploy an app:
```shell
curl https://raw.githubusercontent.com/jewertow/openssl-cert-gen/master/tls.sh | sh -s - --subject="app.com"
kubectl create configmap app-key --from-file=app.com.key
kubectl create configmap app-crt --from-file=app.com.crt
kubectl create configmap app-conf --from-file=nginx.conf
kubectl label namespace default istio-injection=enabled
kubectl apply -f app.yaml
```

4. Apply Istio configs:
```shell
kubectl create secret tls -n istio-system app-cert --key=app.com.key --cert=app.com.crt
kubectl apply -f istio-configs.yaml
```

5. Send a test request:
```shell
kubectl port-forward service/istio-ingressgateway -n istio-system 8443:443
curl -v https://app.com:8443/test/ --resolve app.com:8443:127.0.0.1 --insecure
```
It will fail and you should get the following output:
```
* Added app.com:8443:127.0.0.1 to DNS cache
* Hostname app.com was found in DNS cache
*   Trying 127.0.0.1:8443...
* Connected to app.com (127.0.0.1) port 8443 (#0)
* ALPN, offering h2
* ALPN, offering http/1.1
* successfully set certificate verify locations:
*  CAfile: /etc/pki/tls/certs/ca-bundle.crt
*  CApath: none
* TLSv1.3 (OUT), TLS handshake, Client hello (1):
* TLSv1.3 (IN), TLS handshake, Server hello (2):
* TLSv1.3 (IN), TLS handshake, Encrypted Extensions (8):
* TLSv1.3 (IN), TLS handshake, Certificate (11):
* TLSv1.3 (IN), TLS handshake, CERT verify (15):
* TLSv1.3 (IN), TLS handshake, Finished (20):
* TLSv1.3 (OUT), TLS change cipher, Change cipher spec (1):
* TLSv1.3 (OUT), TLS handshake, Finished (20):
* SSL connection using TLSv1.3 / TLS_AES_256_GCM_SHA384
* ALPN, server accepted to use h2
* Server certificate:
*  subject: CN=app.com
*  start date: Jun  9 13:57:44 2023 GMT
*  expire date: Jun  8 13:57:44 2024 GMT
*  issuer: CN=ca.app.com
*  SSL certificate verify result: unable to get local issuer certificate (20), continuing anyway.
* Using HTTP2, server supports multiplexing
* Connection state changed (HTTP/2 confirmed)
* Copying HTTP/2 data in stream buffer to connection buffer after upgrade: len=0
* Using Stream ID: 1 (easy handle 0x562798ae2e00)
> GET /test/ HTTP/2
> Host: app.com:8443
> user-agent: curl/7.79.1
> accept: */*
> 
* TLSv1.3 (IN), TLS handshake, Newsession Ticket (4):
* TLSv1.3 (IN), TLS handshake, Newsession Ticket (4):
* old SSL session ID is stale, removing
* Connection state changed (MAX_CONCURRENT_STREAMS == 2147483647)!
< HTTP/2 503 
< content-length: 95
< content-type: text/plain
< date: Fri, 09 Jun 2023 22:27:01 GMT
< server: istio-envoy
< 
* Connection #0 to host app.com left intact
upstream connect error or disconnect/reset before headers. reset reason: connection termination
```

6. Disable Istio mTLS between gateway and app as a workaround:
```shell
kubectl apply -f disable-istio-mtls-for-app.yaml
```
Now HTTPS requests should succeed and return 200.
