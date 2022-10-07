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
    curl -v http://external-app.corp.net:8080
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
    --cert /etc/pki/tls/client-crt.pem \
    --key /etc/pki/tls/client-key.pem \
    https://external-app.corp.net
```

6. Get logs from egress gateways and verify if traffic was routed via egress gateways
   and tunneled via forward proxy:
```sh
kubectl logs -l app=sleep -c istio-proxy --tail=3
vagrant ssh external-proxy -c 'tail -n 3 -f /var/log/envoy/https-access.log'
```

Output should be similar to the following logs:
```
# sidecar proxy
[2022-03-15T12:50:25.456Z] "- - -" 0 - - - "-" 94 859 12 - "-" "-" "-" "-" "192.168.56.20:3443" outbound|3443|external-app-80|external-forward-proxy.corp.net 10.244.0.8:33790 192.168.56.30:8080 10.244.0.8:33072 - -
[2022-03-15T12:50:44.439Z] "- - -" 0 - - - "-" 759 2077 10 - "-" "-" "-" "-" "192.168.56.20:3443" outbound|3443|external-app-443|external-forward-proxy.corp.net 10.244.0.8:33946 192.168.56.30:443 10.244.0.8:33892 external-app.corp.net -
[2022-03-15T12:51:10.133Z] "- - -" 0 - - - "-" 1742 2176 10 - "-" "-" "-" "-" "192.168.56.20:3443" outbound|3443|external-app-8443|external-forward-proxy.corp.net 10.244.0.8:34164 192.168.56.30:443 10.244.0.8:34110 external-app.corp.net -
# forward proxy
[2022-03-15T12:50:25.679Z] 192.168.56.10:59332 "CONNECT 192.168.56.30:80 - HTTP/1.1" - 200 - DC
[2022-03-15T12:50:44.653Z] 192.168.56.10:19111 "CONNECT 192.168.56.30:443 - HTTP/1.1" - 200 - DC
[2022-03-15T12:51:10.333Z] 192.168.56.10:58909 "CONNECT 192.168.56.30:8443 - HTTP/1.1" - 200 - DC
```
