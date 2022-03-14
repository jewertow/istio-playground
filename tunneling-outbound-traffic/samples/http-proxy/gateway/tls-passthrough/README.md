### Tunneling traffic through TLS PASSTHROUGH egress gateway

1. Configure external-app to listen on HTTP/1.1: (TODO: explain why)
```sh
vagrant ssh external-app -c 'sudo ln -sfn /etc/nginx/http.conf /etc/nginx/nginx.conf; sudo systemctl restart nginx'
```

2. Apply Istio resources:
```sh
kubectl apply -f virtual-service.yaml
kubectl apply -f gateway.yaml
```

3. Test TLS connection:
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
kubectl logs -l istio=egressgateway -n istio-system --tail=2
vagrant ssh external-proxy -c 'tail -n 3 -f /var/log/envoy/http-access.log'
```
Output should be similar to the following logs:
```
# egress gateway
[2022-03-14T21:21:25.656Z] "- - -" 0 - - - "-" 759 2077 6 - "-" "-" "-" "-" "192.168.56.20:3080" outbound|3080|external-app-443|external-forward-proxy.corp.net 10.244.0.9:40082 10.244.0.9:8443 10.244.0.11:38718 external-app.corp.net -
[2022-03-14T21:22:04.910Z] "- - -" 0 - - - "-" 1742 2176 10 - "-" "-" "-" "-" "192.168.56.20:3080" outbound|3080|external-app-8443|external-forward-proxy.corp.net 10.244.0.9:40412 10.244.0.9:8443 10.244.0.11:39048 external-app.corp.net -
# forward proxy
[2022-03-14T21:21:25.658Z] 192.168.56.10:54532 "CONNECT 192.168.56.30:443 - HTTP/1.1" - 200 - DC
[2022-03-14T21:22:04.911Z] 192.168.56.10:10473 "CONNECT 192.168.56.30:8443 - HTTP/1.1" - 200 - DC
```
