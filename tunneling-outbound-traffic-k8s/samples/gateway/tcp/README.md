## Tunneling through a TCP gateway

```shell
kubectl apply -f gateway.yaml -n default
kubectl apply -f virtual-service.yaml -n default
```

Cleanup:
```shell
kubectl delete -f gateway.yaml -n default
kubectl delete -f virtual-service.yaml -n default
```
