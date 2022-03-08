### TLS pass through Gateway - HTTP forward proxy
1. Apply Istio resources:
```sh
kubectl apply -f virtual-service.yaml
kubectl apply -f destination-rule.yaml
kubectl apply -f gateway.yaml
```

2. Test TLS connection:
```sh
kubectl exec $(kubectl get pods -l app=sleep -o jsonpath='{.items[].metadata.name}') -c sleep -- \
    curl -v --insecure https://external-app.corp.net
```

3. Then verify if request was routed via forward proxy:
```sh
vagrant ssh external-proxy -c 'tail -f /var/log/envoy/http-access.log'
# output should be similar to the following:
[2022-03-08T19:02:36.661Z] 192.168.56.10:36902 "CONNECT 192.168.56.30:443 - HTTP/1.1" - 200 - DC
```

4. TODO - Test TCP connection:
5. TODO - Test mTLS connection:
