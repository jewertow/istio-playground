## Tunneling through a TLS PASSTHROUGH gateway

In this example traffic being sent to port 8080 is encrypted when leaving gateway,
because TLS PASSTHROUGH mode does not terminate traffic. It just forwards traffic as is.

This is the only setup where originating TLS or mTLS is possible together with tunneling.
In other cases, originating TLS or mTLS is only possible between a sidecar or a gateway
and an external proxy which performs tunneling. This limitation is a result of applying
tunneling for a proxy host, instead of a target server host.

```shell
kubectl apply -f gateway.yaml
kubectl apply -f virtual-service.yaml
kubectl apply -f originate-tls.yaml
```

Cleanup resources:
```shell
kubectl delete -f gateway.yaml
kubectl delete -f virtual-service.yaml
kubectl delete -f originate-tls.yaml
```
