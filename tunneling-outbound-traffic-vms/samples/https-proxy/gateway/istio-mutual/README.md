### Tunneling traffic through TLS ISTIO_MUTUAL egress gateway

1. Configure external-app to listen on http2: (TODO: explain why)
```sh
vagrant ssh external-app -c 'sudo ln -sfn /etc/nginx/http2.conf /etc/nginx/nginx.conf; sudo systemctl restart nginx'
```

2. Apply Istio resources:
```sh
kubectl apply -f mtls.yaml
kubectl apply -f virtual-service.yaml
kubectl apply -f gateway.yaml
```

3. Test HTTP request:
```sh
kubectl exec $(kubectl get pods -l app=sleep -o jsonpath='{.items[].metadata.name}') -c sleep -- \
    curl -v http://external-app.corp.net
```

4. Test TLS connection:
```sh
kubectl exec $(kubectl get pods -l app=sleep -o jsonpath='{.items[].metadata.name}') -c sleep -- \
    curl -v --insecure https://external-app.corp.net
```

5. Test mTLS connection:
```sh
# This requires to apply subset external-app-8443 for external-forward-proxy
kubectl exec $(kubectl get pods -l app=sleep -o jsonpath='{.items[].metadata.name}') -c sleep -- \
    curl -v --insecure \
    --cert /etc/pki/tls/certs/client-crt.pem \
    --key /etc/pki/tls/private/client-key.pem \
    https://external-app.corp.net
```

6. Get logs from egress gateways and verify if traffic was routed via egress gateways
   and tunneled via forward proxy:
```sh
kubectl logs -l istio=egressgateway -n istio-system --tail=3
vagrant ssh external-proxy -c 'tail -n 3 -f /var/log/envoy/https-access.log'
```

Output should be similar to the following logs:
```
# egress gateway
[2022-03-15T12:31:33.876Z] "- - -" 0 - - - "-" 907 2065 26 - "-" "-" "-" "-" "192.168.56.20:3443" outbound|3443|external-app-443|external-forward-proxy.corp.net 10.244.0.6:38582 10.244.0.6:8443 10.244.0.7:35958 external-app.corp.net -
[2022-03-15T12:31:57.562Z] "- - -" 0 - - - "-" 1890 2164 12 - "-" "-" "-" "-" "192.168.56.20:3443" outbound|3443|external-app-8443|external-forward-proxy.corp.net 10.244.0.6:38782 10.244.0.6:8443 10.244.0.7:36158 external-app.corp.net -
[2022-03-15T12:31:08.248Z] "- - -" 0 - - - "-" 976 812 180049 - "-" "-" "-" "-" "192.168.56.20:3443" outbound|3443|external-app-80|external-forward-proxy.corp.net 10.244.0.6:38360 10.244.0.6:8080 10.244.0.7:39826 external-app.corp.net -
# forward proxy
[2022-03-15T12:31:34.620Z] 192.168.56.10:39763 "CONNECT 192.168.56.30:443 - HTTP/1.1" - 200 - DC 
[2022-03-15T12:31:58.305Z] 192.168.56.10:45464 "CONNECT 192.168.56.30:8443 - HTTP/1.1" - 200 - DC 
[2022-03-15T12:31:08.992Z] 192.168.56.10:31068 "CONNECT 192.168.56.30:80 - HTTP/1.1" - 200 - -
```
