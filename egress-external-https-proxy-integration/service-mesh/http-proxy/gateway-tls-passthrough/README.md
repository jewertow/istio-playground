### TLS pass through Gateway - HTTP forward proxy
1. Apply Istio resources:
```sh
kubectl apply -f virtual-service.yaml
kubectl apply -f gateway.yaml
```

2. Test TCP connection:
```sh
kubectl apply -f destination-rule-80.yaml
kubectl exec $(kubectl get pods -l app=sleep -o jsonpath='{.items[].metadata.name}') -c sleep -- \
    curl -v http://external-app.corp.net
```

3. Test TLS connection:
```sh
kubectl apply -f destination-rule-443.yaml
kubectl exec $(kubectl get pods -l app=sleep -o jsonpath='{.items[].metadata.name}') -c sleep -- \
    curl -v --insecure https://external-app.corp.net
```

4. Test mTLS connection:
```sh
kubectl apply -f destination-rule-8443.yaml
kubectl exec $(kubectl get pods -l app=sleep -o jsonpath='{.items[].metadata.name}') -c sleep -- \
    curl -v --insecure \
    --cert /etc/pki/tls/certs/client-crt.pem \
    --key /etc/pki/tls/private/client-key.pem \
    https://external-app.corp.net
```

6. Then verify if request was routed via forward proxy:
```sh
vagrant ssh external-proxy -c 'tail -f /var/log/envoy/http-access.log'
# output should be similar to the following logs:
[2022-03-09T14:51:18.359Z] 192.168.56.10:39809 "CONNECT 192.168.56.30:80 - HTTP/1.1" - 200 - -
[2022-03-09T15:06:22.647Z] 192.168.56.10:36748 "CONNECT 192.168.56.30:443 - HTTP/1.1" - 200 - DC
[2022-03-09T16:43:58.611Z] 192.168.56.10:1346 "CONNECT 192.168.56.30:8443 - HTTP/1.1" - 200 - DC
```

### TODO
Test HTTP/2
