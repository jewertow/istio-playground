### HTTP traffic

1. Configure external-app to use HTTP/1.1
```sh
vagrant ssh external-app -c 'sudo ln -sfn /etc/nginx/http.conf /etc/nginx/nginx.conf; sudo systemctl restart nginx'
```

2. Apply Istio resources:
```sh
kubectl apply -f virtual-service.yaml
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
kubectl logs -l app=sleep -c istio-proxy --tail=3
```

Output should be similar to the following logs:
```
# sidecar proxy
[2022-03-14T21:37:52.222Z] "GET / HTTP/1.1" 200 - via_upstream - "-" 0 612 1 0 "-" "curl/7.82.0-DEV" "cadb8fe8-abf5-9b74-b075-9df6ef8d7b1a" "external-app.corp.net" "192.168.56.30:80" outbound|80||external-app.corp.net 10.244.0.11:47300 192.168.56.30:80 10.244.0.11:47298 - default
[2022-03-14T21:38:11.565Z] "- - -" 0 - - - "-" 759 2077 13 - "-" "-" "-" "-" "192.168.56.20:3080" outbound|3080|external-app-443|external-forward-proxy.corp.net 10.244.0.11:45090 192.168.56.30:443 10.244.0.11:36298 external-app.corp.net -
[2022-03-14T21:38:41.207Z] "- - -" 0 - - - "-" 1742 2176 9 - "-" "-" "-" "-" "192.168.56.20:3080" outbound|3080|external-app-8443|external-forward-proxy.corp.net 10.244.0.11:45340 192.168.56.30:443 10.244.0.11:36548 external-app.corp.net -
# forward proxy
[2022-03-14T21:30:36.984Z] 192.168.56.10:58270 "CONNECT 192.168.56.30:80 - HTTP/1.1" - 200 - -
[2022-03-14T21:38:11.567Z] 192.168.56.10:20535 "CONNECT 192.168.56.30:443 - HTTP/1.1" - 200 - DC
[2022-03-14T21:38:41.209Z] 192.168.56.10:63789 "CONNECT 192.168.56.30:8443 - HTTP/1.1" - 200 - DC
```
