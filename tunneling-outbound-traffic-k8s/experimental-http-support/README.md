## Experimental tunneling outbound traffic to HTTP services

This is a proof of concept of tunneling outbound traffic to HTTP services
using intermediary UDS listener.

To test this experimental tunneling follow the steps from README in the parent directory
and then follow the steps below.

Create KinD cluster:
```shell
kind create cluster --name istio-tunneling-demo
```

Deploy Istio and observability stack:
```shell
istioctl install -y \
    --set profile=demo \
    --set meshConfig.accessLogFile=/dev/stdout \
    --set meshConfig.outboundTrafficPolicy.mode=REGISTRY_ONLY
kubectl apply -f https://raw.githubusercontent.com/istio/istio/release-1.15/samples/addons/prometheus.yaml
kubectl apply -f https://raw.githubusercontent.com/istio/istio/release-1.15/samples/addons/grafana.yaml
kubectl apply -f https://raw.githubusercontent.com/istio/istio/release-1.15/samples/addons/kiali.yaml
```

Deploy proxy:
```shell
kubectl create namespace external
ls ../external-forward-proxy | xargs -I{} oc apply -f ../external-forward-proxy/{} -n external
```

Deploy an app:
```shell
kubectl label namespace default istio-injection=enabled
kubectl apply -f sleep.yaml
```

Configure app's sidecar:
```shell
kubectl apply -f envoy-filter.yaml
kubectl apply -f originate-tls.yaml
```

Test connectivity with wikipedia:
```shell
kubectl exec $(kubectl get pods -l app=sleep -n default -o jsonpath='{.items[].metadata.name}') -n default -c sleep -- \
    curl -v http://www.wikipedia.org/ | grep -o "<title>.*</title>"
```

To collect some metrics, execute reqests in a loop:
```shell
while true; do kubectl exec $(kubectl get pods -l app=sleep -n default -o jsonpath='{.items[].metadata.name}') -n default -c sleep -- curl -v http://www.wikipedia.org/ | grep -o "<title>.*</title>"; sleep 1; done
```

Check metrics collected for proxy:
```shell
kubectl exec $(kubectl get pods -l app=sleep -n default -o jsonpath='{.items[].metadata.name}') -n default -c sleep -- \
    curl -v http://localhost:15000/stats/prometheus | grep external | grep http
```
Expected output:
```log
envoy_cluster_http1_dropped_headers_with_underscores{cluster_name="outbound|3128||external-forward-proxy.external.svc.cluster.local"} 0
envoy_cluster_http1_metadata_not_supported_error{cluster_name="outbound|3128||external-forward-proxy.external.svc.cluster.local"} 0
envoy_cluster_http1_requests_rejected_with_underscores_in_headers{cluster_name="outbound|3128||external-forward-proxy.external.svc.cluster.local"} 0
envoy_cluster_http1_response_flood{cluster_name="outbound|3128||external-forward-proxy.external.svc.cluster.local"} 0
envoy_cluster_upstream_cx_http1_total{cluster_name="outbound|3128||external-forward-proxy.external.svc.cluster.local"} 2
envoy_cluster_upstream_cx_http2_total{cluster_name="outbound|3128||external-forward-proxy.external.svc.cluster.local"} 0
envoy_cluster_upstream_cx_http3_total{cluster_name="outbound|3128||external-forward-proxy.external.svc.cluster.local"} 0
envoy_cluster_upstream_http3_broken{cluster_name="outbound|3128||external-forward-proxy.external.svc.cluster.local"} 0
```
Check metrics collected for wikipedia:
```shell
kubectl exec $(kubectl get pods -l app=sleep -n default -o jsonpath='{.items[].metadata.name}') -n default -c sleep -- \
    curl -v http://localhost:15000/stats/prometheus | grep istio_requests_total | grep wikipedia
```
Expected output:
```log
istio_requests_total{response_code="200",reporter="source",source_workload="sleep",source_workload_namespace="default",source_principal="unknown",source_app="sleep",source_version="unknown",source_cluster="Kubernetes",destination_workload="unknown",destination_workload_namespace="unknown",destination_principal="unknown",destination_app="unknown",destination_version="unknown",destination_service="www.wikipedia.org",destination_service_name="www.wikipedia.org",destination_service_namespace="unknown",destination_cluster="unknown",request_protocol="http",response_flags="-",grpc_response_status="",connection_security_policy="unknown",source_canonical_service="sleep",destination_canonical_service="unknown",source_canonical_revision="latest",destination_canonical_revision="latest"} 513
```
