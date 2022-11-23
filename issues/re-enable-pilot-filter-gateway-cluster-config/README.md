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

## Background

When `PILOT_FILTER_GATEWAY_CLUSTER_CONFIG` is enabled and a VirtualService is changed
so that it updates a destination of a route that wasn't referenced from that configuration,
a gateway may return 503 for a short period of time. Such a downtime is caused by lack of Envoy cluster
of the new destination or the cluster is not [warmed](https://www.envoyproxy.io/docs/envoy/latest/intro/arch_overview/upstream/cluster_manager) yet.

Istio enforces the following order of XDS updates: CDS -> EDS -> LDS -> RDS.

Taking the above into account, I expected that updating VirtualServices in a way that does not replace
destinations in one operation should avoid 503s, because clusters will be sent first to a proxy
and there will be no scenario in which a route references a cluster that it does not know.

Unfortunately this assumption didn't fix the problem and 503s are still returned during updates.

None of the workarounds below solve gateway errors.

### Workaround 1

The first and the simples approach tries to update gateway configuration by updating a virtual service
so that it does not remove the old host, but switch traffic to the new host without removing the old one.

Both workarounds do not solve the problem. Outputs show that 503 is still returned.

A potential cause of getting 503 is that routes are switched to new clusters immediately,
so new clusters may not be [warmed](https://www.envoyproxy.io/docs/envoy/latest/intro/arch_overview/upstream/cluster_manager) yet.

Outputs usually contain 1-2 "503" per 100 updates, so ~2% of updates cause gateway errors.

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

### Workaround 2 - does not work

These workarounds update configurations in 3 steps:
1. New route or destination is added, but traffic is not routed there
   to push clusters by CDS, warm them by Envoy and make them available for routes.
2. Switch traffic from old cluster to the new one without removing unused routes or destinations.
3. Remove unused routes or destinations.

Between the steps above, health checks are performed to make sure that updated
cluster is marked by Envoy as healthy.

This approach does not work too. Outputs show that 503 is still returned.

Outputs usually contain 1-2 "503" per 100 updates, so ~2% of updates cause gateway errors.

#### Workaround with matching rule:
```shell
for x in {0..10}
do
  for i in {8081..8089}
  do
    prev=$((i-1))

    # 1st update - add new destination to the configuration, but use only the old one.
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
  # Match an unused header and route traffic to a new host.
  # The new host should not receive traffic, but is added to the configuration to be warmed.
  - match:
    - headers:
        foo:
          exact: "bar"
    route:
    - destination:
        host: test-app-$i.default.svc.cluster.local
        port:
          number: 5678
  # Route all remaining traffic to the an old host.
  # The old host should receive traffic until the new one is warmed.
  - route:
    - destination:
        host: test-app-$prev.default.svc.cluster.local
        port:
          number: 5678
EOF

    # Verify health of the new cluster test-app-$i until it's healthy.
    while [ "$(kubectl exec $(kubectl get pods -l istio=ingressgateway -n istio-system -o jsonpath='{.items[].metadata.name}') -n istio-system -c istio-proxy -- curl localhost:15000/clusters | grep test-app-$i | grep -q healthy)" -eq "1" ]
    do
      echo "cluster test-app-$i is not healthy" >> update.log
      sleep 1
    done

    # 2nd update - route traffic only to the new host.
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
  # Match an unused header and route traffic to the old host to effectively disable it.
  - match:
    - headers:
        foo:
          exact: "bar"
    route:
    - destination:
        host: test-app-$prev.default.svc.cluster.local
        port:
          number: 5678
  # Route all remaining traffic to the new host that should already be warmed and ready.
  - route:
    - destination:
        host: test-app-$i.default.svc.cluster.local
        port:
          number: 5678
EOF

    # Verify health of the new cluster test-app-$i until it's healthy.
    while [ "$(kubectl exec $(kubectl get pods -l istio=ingressgateway -n istio-system -o jsonpath='{.items[].metadata.name}') -n istio-system -c istio-proxy -- curl localhost:15000/clusters | grep test-app-$i | grep -q healthy)" -eq "1" ]
    do
      echo "cluster test-app-$i is not healthy" >> update.log
      sleep 1
    done

    # 3rd update - remove old host from the configuration.
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

    # 1st update - add new destination to the configuration, but use only the old one.
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
    # Route 100% of traffic to the old host.
    - destination:
        host: test-app-$prev.default.svc.cluster.local
        port:
          number: 5678
      weight: 100
    # Route 0% of traffic to the old host.
    # The new host should not receive traffic, but is added to the configuration to be warmed.
    - destination:
        host: test-app-$i.default.svc.cluster.local
        port:
          number: 5678
      weight: 0
EOF

    # Verify health of the new cluster test-app-$i until it's healthy.
    while [ "$(kubectl exec $(kubectl get pods -l istio=ingressgateway -n istio-system -o jsonpath='{.items[].metadata.name}') -n istio-system -c istio-proxy -- curl localhost:15000/clusters | grep test-app-$i | grep -q healthy)" -eq "1" ]
    do
      echo "cluster test-app-$i is not healthy" >> update.log
      sleep 1
    done

    # 2nd update - route traffic only to the new host.
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
    # Route 100% of traffic to the new host that should already be warmed and ready.
    - destination:
        host: test-app-$i.default.svc.cluster.local
        port:
          number: 5678
      weight: 100
    # Route 0% of traffic to the old host.
    - destination:
        host: test-app-$prev.default.svc.cluster.local
        port:
          number: 5678
      weight: 0
EOF

    # Verify health of the new cluster test-app-$i until it's healthy.
    while [ "$(kubectl exec $(kubectl get pods -l istio=ingressgateway -n istio-system -o jsonpath='{.items[].metadata.name}') -n istio-system -c istio-proxy -- curl localhost:15000/clusters | grep test-app-$i | grep -q healthy)" -eq "1" ]
    do
      echo "cluster test-app-$i is not healthy" >> update.log
      sleep 1
    done

    # 3rd update - remove old host from the configuration.
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
    # Route 100% of traffic to the new host that should already be warmed and ready.
    - destination:
        host: test-app-$i.default.svc.cluster.local
        port:
          number: 5678
      weight: 100
EOF
  done
done
cat output.log | grep 503 | wc -l
```

### Workaround 3 - does not work

These workarounds update configurations in 2 steps:
1. New route or destination is added, but traffic is not routed there
   to push clusters by CDS, warm them by Envoy and make them available for routes.
2. Switch traffic from old route/destination to the new one and remove the old one. 

As in the previous workaround, health checks are performed between updates
to make sure that updated cluster is marked by Envoy as healthy.

The surprising difference is that this approach is much worse than the previous approach - outputs contain 5-8 "503".

#### Workaround with matching rule:
```shell
for x in {0..10}
do
  for i in {8081..8089}
  do
    prev=$((i-1))

    # 1st update - add new destination to the configuration, but use only the old one.
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
  # Match an unused header and route traffic to a new host.
  # The new host should not receive traffic, but is added to the configuration to be warmed.
  - match:
    - headers:
        foo:
          exact: "bar"
    route:
    - destination:
        host: test-app-$i.default.svc.cluster.local
        port:
          number: 5678
  # Route all remaining traffic to an old host.
  # The old host should receive traffic until the new one is warmed.
  - route:
    - destination:
        host: test-app-$prev.default.svc.cluster.local
        port:
          number: 5678
EOF

    # Verify health of the new cluster test-app-$i until it's healthy.
    while [ "$(kubectl exec $(kubectl get pods -l istio=ingressgateway -n istio-system -o jsonpath='{.items[].metadata.name}') -n istio-system -c istio-proxy -- curl localhost:15000/clusters | grep test-app-$i | grep -q healthy)" -eq "1" ]
    do
      echo "cluster test-app-$i is not healthy" >> update.log
      sleep 1
    done

    # 2nd update - switch traffic to the new host and remove the old one.
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

    # 1st update - add new destination to the configuration, but use only the old one.
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
    # Route 100% of traffic to the old host.
    - destination:
        host: test-app-$prev.default.svc.cluster.local
        port:
          number: 5678
      weight: 100
    # Route 0% of traffic to the new host.
    # The new host should not receive traffic, but is added to the configuration to be warmed.
    - destination:
        host: test-app-$i.default.svc.cluster.local
        port:
          number: 5678
      weight: 0
EOF

    # Verify health of the new cluster test-app-$i until it's healthy.
    while [ "$(kubectl exec $(kubectl get pods -l istio=ingressgateway -n istio-system -o jsonpath='{.items[].metadata.name}') -n istio-system -c istio-proxy -- curl localhost:15000/clusters | grep test-app-$i | grep -q healthy)" -eq "1" ]
    do
      echo "cluster test-app-$i is not healthy" >> update.log
      sleep 1
    done

    # 2nd update - switch traffic to the new host and remove old host from the configuration.
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
    # Route 100% of traffic to the new host that should already be warmed and ready.
    - destination:
        host: test-app-$i.default.svc.cluster.local
        port:
          number: 5678
      weight: 100
EOF
  done
done
cat output.log | grep 503 | wc -l
```