# OCP dashboards for service mesh

## Monitoring

1. Enable monitoring for user workloads:

```shell
oc apply -f - <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: cluster-monitoring-config
  namespace: openshift-monitoring
data:
  config.yaml: |
    enableUserWorkload: true
EOF
```

## Service Mesh

1. Install CNI:

```shell
oc new-project istio-cni
oc apply -f - <<EOF
apiVersion: sailoperator.io/v1
kind: IstioCNI
metadata:
  name: default
spec:
  version: v1.26.4
  namespace: istio-cni
EOF
```

1. Install control plane:

```shell
oc new-project istio-system
oc apply -f - <<EOF
apiVersion: sailoperator.io/v1
kind: Istio
metadata:
  name: default
spec:
  version: v1.26.4
  namespace: istio-system
  updateStrategy:
    type: InPlace
  values:
    meshConfig:
      accessLogFile: /dev/stdout
EOF
```

1. Deploy app and gateway:

```shell
oc label ns default istio-injection=enabled
oc apply -n default -f https://raw.githubusercontent.com/istio/istio/release-1.26/samples/httpbin/httpbin.yaml
oc apply -f - <<EOF
apiVersion: gateway.networking.k8s.io/v1beta1
kind: Gateway
metadata:
  name: httpbin-gateway
  namespace: default
spec:
  gatewayClassName: istio
  listeners:
  - name: http
    protocol: HTTP
    port: 80
    allowedRoutes:
      namespaces:
        from: Same
---
apiVersion: gateway.networking.k8s.io/v1beta1
kind: HTTPRoute
metadata:
  name: httpbin-route
  namespace: default
spec:
  parentRefs:
  - name: httpbin-gateway
  rules:
  - backendRefs:
    - name: httpbin
      port: 8000
EOF
```

1. Generate some traffic to collect metrics:

```shell
HOSTNAME=$(kubectl get svc httpbin-gateway-istio -n default -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
while true; do curl -v http://$HOSTNAME/headers > /dev/null; sleep 2; done
```

1. Configure monitoring:

```shell
oc apply -f - <<EOF
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: istiod-monitor
  namespace: istio-system 
spec:
  targetLabels:
  - app
  selector:
    matchLabels:
      istio: pilot
  endpoints:
  - port: http-monitoring
    interval: 30s
EOF
oc apply -f pod-monitor.yaml
```

1. Configure dashboards:

```shell
oc apply -f istio-pilot-dashboard.yaml
oc apply -f istio-mesh-dashboard.yaml
```
