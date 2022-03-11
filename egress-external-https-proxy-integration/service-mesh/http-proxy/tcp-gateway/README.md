### HTTP traffic

1. Apply Istio resources:
```sh
kubectl apply -f virtual-service.yaml
kubectl apply -f destination-rule.yaml
kubectl apply -f gateway.yaml
```

2. Test TCP connection:
```sh
kubectl exec $(kubectl get pods -l app=sleep -o jsonpath='{.items[].metadata.name}') -c sleep -- \
    curl -v http://external-app.corp.net
```

3. Test TLS connection:
```sh
kubectl exec $(kubectl get pods -l app=sleep -o jsonpath='{.items[].metadata.name}') -c sleep -- \
    curl -v --insecure https://external-app.corp.net
```

4. Test mTLS connection:
```sh
# This requires to apply subset external-app-8443 for external-forward-proxy
kubectl exec $(kubectl get pods -l app=sleep -o jsonpath='{.items[].metadata.name}') -c sleep -- \
    curl -v --insecure \
    --cert /etc/pki/tls/certs/client-crt.pem \
    --key /etc/pki/tls/private/client-key.pem \
    https://external-app.corp.net
```
