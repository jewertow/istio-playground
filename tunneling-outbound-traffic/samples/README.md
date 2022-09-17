### Create common resources

1. Enable Istio sidecar injection:
```sh
kubectl label namespace default istio-injection=enabled
```

2. Deploy "sleep" client app:
```sh
kubectl apply -f sleep-client-cert-configmap.yaml
kubectl apply -f sleep.yaml
```

3. Create service entries for external services:
```sh
kubectl apply -f service-entries.yaml
```
