### Tunneling traffic through TLS ISTIO_MUTUAL egress gateway

1. Configure external-app to listen on http2: (TODO: explain why)
```sh
vagrant ssh external-app -c 'sudo ln -sfn /etc/nginx/http2.conf /etc/nginx/nginx.conf; sudo systemctl restart nginx'
```

2. Apply Istio resources:
```sh
kubectl apply -f originate-tls.yaml
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
vagrant ssh external-proxy -c 'tail -n 3 -f /var/log/envoy/http-access.log'
```

Output should be similar to the following logs:
```
# egress gateway
[2022-03-14T21:26:47.519Z] "- - -" 0 - - - "-" 978 795 158381 - "-" "-" "-" "-" "192.168.56.20:3080" outbound|3080|external-app-80|external-forward-proxy.corp.net 10.244.0.9:42680 10.244.0.9:8080 10.244.0.11:53730 external-app.corp.net -
[2022-03-14T21:31:06.095Z] "- - -" 0 - - - "-" 907 2065 10 - "-" "-" "-" "-" "192.168.56.20:3080" outbound|3080|external-app-443|external-forward-proxy.corp.net 10.244.0.9:44796 10.244.0.9:8443 10.244.0.11:43432 external-app.corp.net -
[2022-03-14T21:31:46.216Z] "- - -" 0 - - - "-" 1890 2164 11 - "-" "-" "-" "-" "192.168.56.20:3080" outbound|3080|external-app-8443|external-forward-proxy.corp.net 10.244.0.9:45126 10.244.0.9:8443 10.244.0.11:43762 external-app.corp.net -
# forward proxy
[2022-03-14T21:26:47.521Z] 192.168.56.10:21486 "CONNECT 192.168.56.30:80 - HTTP/1.1" - 200 - DC
[2022-03-14T21:31:06.097Z] 192.168.56.10:25849 "CONNECT 192.168.56.30:443 - HTTP/1.1" - 200 - DC
[2022-03-14T21:31:46.218Z] 192.168.56.10:23018 "CONNECT 192.168.56.30:8443 - HTTP/1.1" - 200 - DC
```
