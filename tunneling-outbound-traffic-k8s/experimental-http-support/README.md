## Experimental tunneling outbound traffic to HTTP services

This is a proof of concept of tunneling outbound traffic to HTTP services
using intermediate internal UDS listener.

To test this experimental tunneling follow the steps from README in the parent directory
and then follow the steps below.

Configure sidecar:
```shell
kubectl apply -f envoy-filter.yaml
kubectl apply -f originate-tls.yaml
```

Test connectivity with external service:
```shell
kubectl exec $(kubectl get pods -l app=sleep -n default -o jsonpath='{.items[].metadata.name}') -n default -c sleep -- \
    curl -v http://www.wikipedia.org/ | grep -o "<title>.*</title>"
```
To collect some metrics, execute reqests in a loop:
```shell
while true; do kubectl exec $(kubectl get pods -l app=sleep -n default -o jsonpath='{.items[].metadata.name}') -n default -c sleep -- curl -v http://www.wikipedia.org/ | grep -o "<title>.*</title>"; sleep 1; done
```

```shell
kubectl exec $(kubectl get pods -l app=sleep -n default -o jsonpath='{.items[].metadata.name}') -n default -c sleep -- \
    while true; do curl -v http://www.wikipedia.org/ | grep -o "<title>.*</title>"; sleep 1; done
```