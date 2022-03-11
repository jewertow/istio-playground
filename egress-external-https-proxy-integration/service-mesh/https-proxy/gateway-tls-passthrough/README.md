### TLS PASSTHROUGH Gateway - HTTPS forward proxy

#### Important
Istio Gateway listening in TLS PASSTHROUGH mode cannot be integrated with external HTTPS proxy,
because TLS origination does not apply to TLS PASSTHROUGH listeners.
On the other hand, it can't work without TLS origination, because TLS PASSTHROUGH
passes an incoming request as is to a destination, so when a request is routed via
another intermediate proxy, the TLS handshake will always fail.

A workaround is to apply an EnvoyFilter that applies UpstreamTlsContext to forward-proxy cluster.

1. Apply Istio resources:
```sh
kubectl apply -f virtual-service.yaml
kubectl apply -f destination-rule.yaml
kubectl apply -f gateway.yaml
kubectl apply -f envoy-filter.yaml
```

2. Test TLS connection:
```sh
kubectl exec $(kubectl get pods -l app=sleep -o jsonpath='{.items[].metadata.name}') -c sleep -- \
    curl -v --insecure https://external-app.corp.net
```

3. Then verify if request was routed via forward proxy:
```sh
vagrant ssh external-proxy -c 'tail -f /var/log/envoy/https-access.log'
# output should be similar to the following:
[2022-03-08T19:36:27.528Z] 192.168.56.10:15675 "CONNECT 192.168.56.30:443 - HTTP/1.1" - 200 - DC 
```

4. TODO - Test TCP connection:
5. TODO - Test mTLS connection:
