## Tunneling through a TLS ISTIO_MUTUAL gateway

Traffic being sent to port 8080 won't be encrypted when leaving gateway,
because the destination rule applied in this example originates mTLS
only between a sidecar proxy and an egress gateway listening
in **ISTIO_MUTUAL** mode which terminates connection and then forwards as is.

```shell
kubectl apply -f gateway.yaml
kubectl apply -f virtual-service.yaml
kubectl apply -f mtls.yaml
```

To make sure that origination of mTLS was applied you can execute the following command:
```shell
istioctl pc clusters deploy/sleep.default | grep egress
```
and expected result is as below:
```shell
istio-egressgateway.istio-system.svc.cluster.local 80  - outbound    EDS  originate-mtls-for-egress-gateway.default
istio-egressgateway.istio-system.svc.cluster.local 443 - outbound    EDS  originate-mtls-for-egress-gateway.default
```

Cleanup resources:
```shell
kubectl delete -f gateway.yaml
kubectl delete -f virtual-service.yaml
kubectl delete -f mtls.yaml
```
