### Tunneling traffic through TCP egress gateway

1. Configure external-app to listen on http2: (TODO: explain why)
```sh
vagrant ssh external-app -c 'sudo ln -sfn /etc/nginx/http2.conf /etc/nginx/nginx.conf; sudo systemctl restart nginx'
```

2. Apply Istio resources:
```sh
kubectl apply -f virtual-service.yaml
kubectl apply -f gateway.yaml
```

3. Test TCP connection:
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
vagrant ssh external-proxy -c 'tail -n 3 -f /var/log/envoy/http-access.log'
```
Output should be similar to the following logs:
```
# egress gateway
[2022-03-14T20:56:26.963Z] "- - -" 0 - - - "-" 976 812 180055 - "-" "-" "-" "-" "192.168.56.20:3080" outbound|3080|external-app-80|external-forward-proxy.corp.net 10.244.0.9:56306 10.244.0.9:8080 10.244.0.11:39124 - -
[2022-03-14T21:00:44.512Z] "- - -" 0 - - - "-" 907 2065 28 - "-" "-" "-" "-" "192.168.56.20:3080" outbound|3080|external-app-443|external-forward-proxy.corp.net 10.244.0.9:58374 10.244.0.9:8443 10.244.0.11:57010 - -
[2022-03-14T21:01:34.600Z] "- - -" 0 - - - "-" 1890 2164 10 - "-" "-" "-" "-" "192.168.56.20:3080" outbound|3080|external-app-8443|external-forward-proxy.corp.net 10.244.0.9:58792 10.244.0.9:8443 10.244.0.11:57428 - -
# forward proxy
[2022-03-14T20:56:26.964Z] 192.168.56.10:25556 "CONNECT 192.168.56.30:80 - HTTP/1.1" - 200 - -
[2022-03-14T21:00:44.530Z] 192.168.56.10:56290 "CONNECT 192.168.56.30:443 - HTTP/1.1" - 200 - DC 
[2022-03-14T21:01:34.601Z] 192.168.56.10:54434 "CONNECT 192.168.56.30:8443 - HTTP/1.1" - 200 - DC
```
