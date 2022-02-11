## Gateway with TLS listner and MUTUAL_ISTIO ignores TLS routes

### How to reproduce this issue

1. Run kind:
```sh
kind create cluster --name tls-listener-mutual-istio
```

2. Install Istio with egress gateway:
```sh
istioctl install -y \
    --set profile=demo \
    --set meshConfig.accessLogFile=/dev/stdout \
    --set meshConfig.outboundTrafficPolicy.mode=REGISTRY_ONLY
```

3. Apply gateway and virtual service:
```sh
kubectl apply -f virtual-service.yaml
kubectl apply -f gateway.yaml
```

4. Check istiod logs. There should be the following information:
```
warn    no virtual service bound to gateway: default/istio-egressgateway
info    gateway omitting listener "0.0.0.0_8443" due to: must have more than 0 chains in listner "0.0.0.0_8443"
```

5. Check egress gateway listeners:
```sh
istioctl pc listeners deploy/istio-egressgateway.istio-system
```
The output should be:
```
ADDRESS PORT  MATCH DESTINATION
0.0.0.0 15021 ALL   Inline Route: /healthz/ready*
0.0.0.0 15090 ALL   Inline Route: /stats/prometheus*
```

6. Apply a workaround with tcp rules instead of tls matching rules:
```sh
kubectl apply -f virtual-service-workaround.yaml
```
Now istiod shouldn't log that egress gateway is omitting listener "0.0.0.0_8443".

Get listners once again:
```
istioctl pc listeners deploy/istio-egressgateway.istio-system
```
and verify if there is TLS listner:
```
ADDRESS PORT  MATCH                DESTINATION
0.0.0.0 8443  SNI: www.example.com Cluster: outbound|443||www.example.com
0.0.0.0 15021 ALL                  Inline Route: /healthz/ready*
0.0.0.0 15090 ALL                  Inline Route: /stats/prometheus*
```

7. Cleanup environment:
```
kind delete cluster --name tls-listener-mutual-istio
```
