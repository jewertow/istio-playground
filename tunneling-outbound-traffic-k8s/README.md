## Tunneling outbound traffic with Istio inside k8s

1. Setup KinD with local registry and upload images:
```shell
curl https://raw.githubusercontent.com/kubernetes-sigs/kind/v0.14.0/site/static/examples/kind-with-registry.sh | sh -
docker images | grep tunnel-api | awk '{print $1":"$2}' | xargs kind load docker-image
$ISTIO_SRC/out/linux_amd64/istioctl install -y \
    --set profile=demo \
    --set meshConfig.accessLogFile=/dev/stdout \
    --set meshConfig.outboundTrafficPolicy.mode=REGISTRY_ONLY \
    --set hub="localhost:5000" \
    --set tag="tunnel-api"
```

3. Enable Istio sidecar injection:
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

6. Apply destination rules:
```shell
kubectl apply -f destination-rules.yaml -n external
```

7. Test connection:
```shell
kubectl exec $(kubectl get pods -l app=sleep -o jsonpath='{.items[].metadata.name}') -c sleep -- \
    curl -v http://external-app.external.svc.cluster.local:8080/test/1
kubectl exec $(kubectl get pods -l app=sleep -o jsonpath='{.items[].metadata.name}') -c sleep -- \
    curl -v --insecure https://external-app.external.svc.cluster.local/test/2
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
