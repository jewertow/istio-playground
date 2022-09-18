### Tunneling outbound traffic via HTTPS proxy

Apply the destination rules common for all samples in the `gateway` and `sidecars` directories:
```shell
kubectl apply -f destination-rules.yaml
```

### Important

Tunneling outbound traffic via HTTPS proxy requires to apply `UpstreamTlsContext` to the external-forward-proxy cluster:
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

There are 3 ways to do that:
1. DestinationRule:
```yaml
apiVersion: networking.istio.io/v1alpha3
kind: DestinationRule
metadata:
  name: originate-tls
spec:
  host: external-forward-proxy.corp.net
  trafficPolicy:
    portLevelSettings:
    - port:
        number: 3443
      tls:
        mode: SIMPLE
        sni: external-forward-proxy.corp.net
```

2. EnvoyFilter for gateway:
```yaml
apiVersion: networking.istio.io/v1alpha3
kind: EnvoyFilter
metadata:
  name: originate-tls-for-external-proxy
  namespace: istio-system
spec:
  workloadSelector:
    labels:
      app: istio-egressgateway
  configPatches:
  - applyTo: CLUSTER
    match:
      context: GATEWAY
    patch:
      operation: MERGE
      value:
        name: outbound|3443||external-forward-proxy.corp.net
        transport_socket:
          name: envoy.transport_sockets.tls
          typed_config:
            "@type": type.googleapis.com/envoy.extensions.transport_sockets.tls.v3.UpstreamTlsContext
```

3. EnvoyFilter for sidecar proxy:
```yaml
apiVersion: networking.istio.io/v1alpha3
kind: EnvoyFilter
metadata:
  name: originate-tls-for-external-proxy
spec:
  workloadSelector:
    labels:
      app: sleep
  configPatches:
  - applyTo: CLUSTER
    match:
      context: SIDECAR_OUTBOUND
    patch:
      operation: MERGE
      value:
        name: outbound|3443||external-forward-proxy.corp.net
        transport_socket:
          name: envoy.transport_sockets.tls
          typed_config:
            "@type": type.googleapis.com/envoy.extensions.transport_sockets.tls.v3.UpstreamTlsContext
```
