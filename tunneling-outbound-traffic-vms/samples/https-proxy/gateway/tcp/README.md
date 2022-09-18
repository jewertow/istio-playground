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
vagrant ssh external-proxy -c 'tail -n 3 -f /var/log/envoy/https-access.log'
```
Output should be similar to the following logs:
```
# egress gateway
[2022-03-15T12:11:50.124Z] "- - -" 0 - - - "-" 977 812 180031 - "-" "-" "-" "-" "192.168.56.20:3443" outbound|3443|external-app-80|external-forward-proxy.corp.net 10.244.0.6:57308 10.244.0.6:8080 10.244.0.7:58774 - -
[2022-03-15T12:17:05.961Z] "- - -" 0 - - - "-" 907 2065 9 - "-" "-" "-" "-" "192.168.56.20:3443" outbound|3443|external-app-443|external-forward-proxy.corp.net 10.244.0.6:59844 10.244.0.6:8443 10.244.0.7:57220 - -
[2022-03-15T12:17:42.545Z] "- - -" 0 - - - "-" 1890 2164 12 - "-" "-" "-" "-" "192.168.56.20:3443" outbound|3443|external-app-8443|external-forward-proxy.corp.net 10.244.0.6:60148 10.244.0.6:8443 10.244.0.7:57524 - -
# forward proxy
[2022-03-14T20:56:26.964Z] 192.168.56.10:25556 "CONNECT 192.168.56.30:80 - HTTP/1.1" - 200 - -
[2022-03-14T21:00:44.530Z] 192.168.56.10:56290 "CONNECT 192.168.56.30:443 - HTTP/1.1" - 200 - DC 
[2022-03-14T21:01:34.601Z] 192.168.56.10:54434 "CONNECT 192.168.56.30:8443 - HTTP/1.1" - 200 - DC
```
