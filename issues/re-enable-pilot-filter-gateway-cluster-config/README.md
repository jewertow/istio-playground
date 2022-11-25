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
for x in {0..9}
do
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

### Workaround 1 - does not work

The first and the simples approach tries to update gateway configuration by updating a virtual service
so that it does not remove the old host, but switch traffic to the new host without removing the old one.

A potential cause of getting 503 is that routes are switched to new clusters immediately,
so new clusters may not be [warmed](https://www.envoyproxy.io/docs/envoy/latest/intro/arch_overview/upstream/cluster_manager) yet.

```shell
export RED="\033[0;31m"
export RESET="\033[0m"

for i in {1..100}
do
  prev=$((8080 + (i-1)%10))
  curr=$((8080 + i%10))

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
        host: test-app-$curr.default.svc.cluster.local
        port:
          number: 5678
EOF

  gateway_err_count=$(cat output.log | grep 503 | wc -l)
  if [[ $gateway_err_count -gt 0 ]]
  then
    echo "${RED}update [$prev, $curr] - errors: $gateway_err_count.${RESET}"
  else
    echo "update [$prev, $curr] - no errors"
  fi
done
```

### Workaround 2 - does not work

This workaround updates configuration in 2 steps:
1. New route is added, but traffic is not routed there.
   The goal is to push clusters by CDS, warm them by Envoy and make them available for routes.
   Additionally, test requests are sent to make sure that the new route is ready to serve traffic.
2. Remove old route and switch traffic to the new one.

This approach may seem to solve the problem, because before removal of the old route,
health check and test request were performed, but even though 503 are still returned.
The reason of the gateway error may be that active connections to an old cluster exist
and in case of removal of that cluster, 503 is returned until route switched to a new cluster.

```shell
export RED="\033[0;31m"
export RESET="\033[0m"

for i in {1..100}
do
  prev=$((8080 + (i-1)%10))
  curr=$((8080 + i%10))

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
        warming:
          exact: "true"
    route:
    - destination:
        host: test-app-$curr.default.svc.cluster.local
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
  gateway_err_count=$(cat output.log | grep 503 | wc -l)
  if [[ $gateway_err_count -gt 0 ]]
  then
    echo "${RED}1st update [$prev, $curr] - errors: $gateway_err_count.${RESET}"
  else
    echo "1st update [$prev, $curr] - no errors."
  fi

  # Verify health of the new cluster test-app-$i until it's healthy.
  # Successful health check means that cluster was warmed,
  # i.e. initial DNS resolution and health check succeeded.
  while [ "$(kubectl exec $(kubectl get pods -l istio=ingressgateway -n istio-system -o jsonpath='{.items[].metadata.name}') -n istio-system -c istio-proxy -- curl localhost:15000/clusters | grep test-app-$curr | grep -q healthy)" -eq "1" ]
  do
    echo "cluster test-app-$curr is not healthy" >> health-checks.log
    sleep 1
  done
  
  # Additionally try to connect to the new host.
  # Even if cluster was warmed by cluster manager, listener may not be warmed yet.
  # This step verifies that the route is ready to serve traffic.
  until curl -s -f -o /dev/null -H "Host: test-echo.com" -H "warming: true" http://localhost:8080/
  do
    echo "Warming test-app-$curr..." >> warming.log
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
        host: test-app-$curr.default.svc.cluster.local
        port:
          number: 5678
EOF

  gateway_err_count=$(cat output.log | grep 503 | wc -l)
  if [[ $gateway_err_count -gt 0 ]]
  then
    echo "${RED}2nd update [$prev, $curr] - errors: $gateway_err_count.${RESET}"
  else
    echo "2nd update [$prev, $curr] - no errors."
  fi
done
```

### Workaround 3

This workaround updates configuration in 3 steps:
1. New route is added, but traffic is not routed there.
   The goal is to push clusters by CDS, warm them by Envoy and make them available for routes.
   Additionally, test requests are sent to make sure that the new route is ready to serve traffic.
2. Switch traffic from the old route to the new one without removing unused route.
   The old route will not be removed until active connections exist.
3. Remove unused route.

In contrary to the previous approach, this solution does not remove unused host immediately,
but only after switching traffic to a new host and ensuring that there is no active connection
to the old host.

This approach makes update work and gateway errors no longer occur.

```shell
export RED="\033[0;31m"
export RESET="\033[0m"

for i in {1..100}
do
  prev=$((8080 + (i-1)%10))
  curr=$((8080 + i%10))

  # 1st update - add new route to the configuration, but don't serve traffic.
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
  # The new host should not receive traffic, but is added to the configuration to be warmed.
  - match:
    - headers:
        warming:
          exact: "true"
    route:
    - destination:
        host: test-app-$curr.default.svc.cluster.local
        port:
          number: 5678
  # Route all remaining traffic to the old host.
  # The old host should receive traffic until the new one is warmed.
  - route:
    - destination:
        host: test-app-$prev.default.svc.cluster.local
        port:
          number: 5678
EOF

  gateway_err_count=$(cat output.log | grep 503 | wc -l)
  if [[ $gateway_err_count -gt 0 ]]
  then
    echo "${RED}1st update [$prev, $curr] - errors: $gateway_err_count.${RESET}"
  else
    echo "1st update [$prev, $curr] - no errors."
  fi

  # Verify health of the new cluster test-app-$i until it's healthy.
  # Successful health check means that cluster was warmed,
  # i.e. initial DNS resolution and health check succeeded.
  while [ "$(kubectl exec $(kubectl get pods -l istio=ingressgateway -n istio-system -o jsonpath='{.items[].metadata.name}') -n istio-system -c istio-proxy -- curl localhost:15000/clusters | grep test-app-$curr | grep -q healthy)" -eq "1" ]
  do
    echo "cluster test-app-$curr is not healthy" >> health-check.log
    sleep 1
  done

  # Additionally try to connect to the new host.
  # Even if cluster was warmed by cluster manager, listener may not be warmed yet.
  # This step verifies that the route is ready to serve traffic.
  until curl -s -f -o /dev/null -H "Host: test-echo.com" -H "warming: true" http://localhost:8080/
  do
    echo "Warming test-app-$curr..." >> warming.log
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
        host: test-app-$curr.default.svc.cluster.local
        port:
          number: 5678
EOF

  gateway_err_count=$(cat output.log | grep 503 | wc -l)
  if [[ $gateway_err_count -gt 0 ]]
  then
    echo "${RED}2nd update [$prev, $curr] - errors: $gateway_err_count.${RESET}"
  else
    echo "2nd update [$prev, $curr] - no errors."
  fi
  
  # Wait for deactivating connections to the previous cluster.
  while [ "$(kubectl exec $(kubectl get pods -l istio=ingressgateway -n istio-system -o jsonpath='{.items[].metadata.name}') -n istio-system -c istio-proxy -- curl localhost:15000/clusters | grep test-app-$prev | grep -q cx_active::0)" -eq "1" ]
  do
    echo "Waiting for deactivating connections to the previous cluster" >> cx_active.log
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
        host: test-app-$curr.default.svc.cluster.local
        port:
          number: 5678
EOF

  gateway_err_count=$(cat output.log | grep 503 | wc -l)
  if [[ $gateway_err_count -gt 0 ]]
  then
    echo "${RED}3rd update [$prev, $curr] - errors: $gateway_err_count.${RESET}"
  else
    echo "3rd update [$prev, $curr] - no errors."
  fi
done
sleep 1
cat output.log | grep 503 | wc -l
```
