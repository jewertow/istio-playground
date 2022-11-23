## Re-enable PILOT_FILTER_GATEWAY_CLUSTER_CONFIG #29131

### Reproduce issue

1. Create test kubernetes cluster:
```shell
kind create cluster --name test
```

2. Install Istio:
```shell
kubectl label namespace default istio-injection=enabled
istioctl install -y -n istio-system -f - <<EOF
apiVersion: install.istio.io/v1alpha1
kind: IstioOperator
metadata:
  name: test
spec:
  profile: default
  components:
    pilot:
      k8s:
        env:
        - name: PILOT_FILTER_GATEWAY_CLUSTER_CONFIG
          value: "true"
  meshConfig:
    accessLogFile: /dev/stdout
EOF
```

3. Create 10 services:
```shell
for i in {8080..8089}
do
  kubectl apply -n default -f - <<EOF
kind: Pod
apiVersion: v1
metadata:
  name: test-app-$i
  labels:
    app: test-app-$i
spec:
  containers:
  - name: test-app
    image: hashicorp/http-echo
    args:
    - "-text=OK"
---
kind: Service
apiVersion: v1
metadata:
  name: test-app-$i
spec:
  selector:
    app: test-app-$i
  ports:
  - port: 5678
EOF
done
```

4. Create ingress gateway and expose its port to localhost:
```shell
kubectl apply -n default -f - <<EOF
apiVersion: networking.istio.io/v1beta1
kind: Gateway
metadata:
  name: http-echo-gateway
spec:
  selector:
    istio: ingressgateway
  servers:
  - hosts:
    - test-echo.com
    port:
      name: http
      number: 80
      protocol: HTTP
EOF
kubectl apply -n default -f - <<EOF
apiVersion: networking.istio.io/v1beta1
kind: VirtualService
metadata:
  name: http-echo-ingress
spec:
  gateways:
  - http-echo-gateway
  hosts:
  - test-echo.com
  http:
  - route:
    - destination:
        host: test-app-8080.default.svc.cluster.local
        port:
          number: 5678
EOF
kubectl port-forward service/istio-ingressgateway -n istio-system 8080:80
```

5. Run requests in a loop:
```shell
while true;
do
  curl -s -o /dev/null -w "%{http_code}\n" -H "Host: test-echo.com" http://localhost:8080/ >> output.log
done
```

6. Update virtual services in a loop:
```shell
for i in {8080..8089}
do
  kubectl apply -n default -f - <<EOF
apiVersion: networking.istio.io/v1beta1
kind: VirtualService
metadata:
  name: http-echo-ingress
spec:
  gateways:
  - http-echo-gateway
  hosts:
  - test-echo.com
  http:
  - route:
    - destination:
        host: test-app-$i.default.svc.cluster.local
        port:
          number: 5678
EOF
done
cat output.log | grep 503 | wc -l
```
Output should be greater than 0. Otherwise, run update loop again.

### Workaround 1 - does not work

Workarounds below try to update virtual services without removing old hosts,
so that proxy is never in a situation that it lacks a cluster or an endpoint
and does not return 503.

Both workarounds do not solve the problem. Outputs show that 503 is still returned.

A potential cause of getting 503 is that routes are switched to new clusters immediately,
so new clusters may not be [warmed](https://www.envoyproxy.io/docs/envoy/latest/intro/arch_overview/upstream/cluster_manager) yet.

Outputs usually contain 1-2 "503", so the downtime is ~2%.

#### Workaround with matching rule:
```shell
for x in {0..10}
do
  for i in {8081..8089}
  do
    prev=$((i-1))
    kubectl apply -n default -f - <<EOF
apiVersion: networking.istio.io/v1beta1
kind: VirtualService
metadata:
  name: http-echo-ingress
spec:
  gateways:
  - http-echo-gateway
  hosts:
  - test-echo.com
  http:
  # Match an unused header and route traffic to an old host.
  # Effectively the old host should no longer be used. 
  - match:
    - headers:
        foo:
          exact: "bar"
    route:
    - destination:
        host: test-app-$prev.default.svc.cluster.local
        port:
          number: 5678
  # Route all remaining traffic to the a new endpoint.
  # Effectively only the new host should be used.
  - route:
    - destination:
        host: test-app-$i.default.svc.cluster.local
        port:
          number: 5678
EOF
  done
done
cat output.log | grep 503 | wc -l
```

#### Workaround with weighted destinations:
```shell
for x in {0..10}
do
  for i in {8081..8089}
  do
    prev=$((i-1))
    kubectl apply -n default -f - <<EOF
apiVersion: networking.istio.io/v1beta1
kind: VirtualService
metadata:
  name: http-echo-ingress
spec:
  gateways:
  - http-echo-gateway
  hosts:
  - test-echo.com
  http:
  - route:
    # Route 100% of traffic to a new host.
    - destination:
        host: test-app-$i.default.svc.cluster.local
        port:
          number: 5678
      weight: 100
    # Route 0% of traffic to an old host.
    - destination:
        host: test-app-$prev.default.svc.cluster.local
        port:
          number: 5678
      weight: 0
EOF
  done
done
cat output.log | grep 503 | wc -l
```
