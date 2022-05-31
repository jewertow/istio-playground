## Tunneling outbound traffic with Istio inside k8s

1. Enable Istio sidecar injection:
```sh
kubectl label namespace default istio-injection=enabled
```

2. Deploy sleep app:
```sh
kubectl apply -f https://raw.githubusercontent.com/istio/istio/release-1.13/samples/sleep/sleep.yaml
```

3. Create namespace for "external" workloads:
```shell
kubectl create namespace external
```

4. Deploy Envoy acting as a forward proxy:
```shell
kubectl apply -f external-forward-proxy/ssl-certificate.yaml -n external
kubectl apply -f external-forward-proxy/ssl-private-key.yaml -n external
kubectl apply -f external-forward-proxy/envoy-config.yaml -n external
kubectl apply -f external-forward-proxy/deployment.yaml -n external
kubectl apply -f external-forward-proxy/service.yaml -n external
```

5. Deploy target server:
```shell
kubectl apply -f external-app/ssl-certificate.yaml -n external
kubectl apply -f external-app/ssl-private-key.yaml -n external
kubectl apply -f external-app/nginx-config.yaml -n external
kubectl apply -f external-app/deployment.yaml -n external
kubectl apply -f external-app/service.yaml -n external
```

Cleanup:
```shell
kubectl delete -f external-forward-proxy/service.yaml -n external
kubectl delete -f external-forward-proxy/deployment.yaml -n external
kubectl delete -f external-forward-proxy/ssl-certificate.yaml -n external
kubectl delete -f external-forward-proxy/ssl-private-key.yaml -n external
kubectl delete -f external-forward-proxy/envoy-config.yaml -n external

kubectl delete -f external-app/service.yaml -n external
kubectl delete -f external-app/deployment.yaml -n external
kubectl delete -f external-app/nginx-config.yaml -n external
kubectl delete -f external-app/ssl-certificate.yaml -n external
kubectl delete -f external-app/ssl-private-key.yaml -n external

kubectl delete -f https://raw.githubusercontent.com/istio/istio/release-1.13/samples/sleep/sleep.yaml
```
