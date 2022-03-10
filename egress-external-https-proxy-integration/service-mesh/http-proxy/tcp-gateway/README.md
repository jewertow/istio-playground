### HTTP traffic
Plain HTTP requests don't match TCP routing rules and go directly to the requested server.

TODO: How to handle HTTP

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
