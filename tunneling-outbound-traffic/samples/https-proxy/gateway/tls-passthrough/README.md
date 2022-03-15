### Tunneling traffic through TLS `PASSTHROUGH` egress gateway

Istio Gateway listening in TLS `PASSTHROUGH` mode cannot be integrated with external HTTPS proxy,
because TLS origination couldn't be applied to TLS `PASSTHROUGH` listeners.
On the other hand, it can't work without TLS origination, because TLS `PASSTHROUGH`
passes an incoming request as is to a destination, so when a request is routed via
another intermediate proxy, the TLS handshake will always fail.

A workaround is to apply an EnvoyFilter that applies `UpstreamTlsContext` to forward-proxy cluster.
```json
{
   "cluster": {
      "transport_socket": {
         "name": "envoy.transport_sockets.tls",
         "typed_config": {
            "@type": "type.googleapis.com/envoy.extensions.transport_sockets.tls.v3.UpstreamTlsContext"
         }
      }
   }
}
```

1. Configure external-app to listen on HTTP/1.1: (TODO: explain why)
```sh
vagrant ssh external-app -c 'sudo ln -sfn /etc/nginx/http.conf /etc/nginx/nginx.conf; sudo systemctl restart nginx'
```

2. Apply Istio resources:
```sh
kubectl apply -f virtual-service.yaml
kubectl apply -f gateway.yaml
kubectl apply -f envoy-filter.yaml
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
vagrant ssh external-proxy -c 'tail -n 2 -f /var/log/envoy/https-access.log'
```

Output should be similar to the following logs:
```
# egress gateway
[2022-03-15T11:57:53.133Z] "- - -" 0 - - - "-" 759 2077 8 - "-" "-" "-" "-" "192.168.56.20:3443" outbound|3443|external-app-443|external-forward-proxy.corp.net 10.244.0.6:50560 10.244.0.6:8443 10.244.0.7:47936 external-app.corp.net -
[2022-03-15T11:59:30.497Z] "- - -" 0 - - - "-" 1742 2176 12 - "-" "-" "-" "-" "192.168.56.20:3443" outbound|3443|external-app-8443|external-forward-proxy.corp.net 10.244.0.6:51356 10.244.0.6:8443 10.244.0.7:48732 external-app.corp.net -
# forward proxy
[2022-03-15T11:57:53.875Z] 192.168.56.10:23826 "CONNECT 192.168.56.30:443 - HTTP/1.1" - 200 - DC
[2022-03-15T11:59:31.240Z] 192.168.56.10:15822 "CONNECT 192.168.56.30:8443 - HTTP/1.1" - 200 - DC
```
