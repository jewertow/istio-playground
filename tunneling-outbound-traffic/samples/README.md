### Create common resources

1. Enable Istio sidecar injection:
```sh
kubectl label namespace default istio-injection=enabled
```

2. Create config maps with SSL keys:
```sh
(cd ../ssl-certificates; ./generate.sh)
./ssl-configmap.sh ../ssl-certificates
```

3. Deploy sleep app:
```sh
kubectl apply -f sleep.yaml
```

4. Create service entries for external services:
```sh
kubectl apply -f service-entries.yaml
```
