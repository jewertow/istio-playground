## Re-enable PILOT_FILTER_GATEWAY_CLUSTER_CONFIG #29131

### Setup environment

1. Create KinD cluster with MetalLB:

    ```shell
    curl -s https://raw.githubusercontent.com/istio/istio/refs/heads/release-1.26/samples/kind-lb/setupkind.sh | sh -s -- --cluster-name test
    ```

### Reproduce issue

1. Install Istio:

   ```shell
   kubectl label namespace default istio-injection=enabled
   istioctl install -y -n istio-system -f - <<EOF
   apiVersion: install.istio.io/v1alpha1
   kind: IstioOperator
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

1. Create 10 services:

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

1. Create an ingress gateway:

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
   ```

1. Send requests in a loop:

   ```shell
   INGRESS_IP=$(kubectl get svc istio-ingressgateway -n istio-system -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
   while true;
   do
     curl -s -o /dev/null -w "%{http_code}\n" -H "Host: test-echo.com" "http://$INGRESS_IP:80/" >> output.log
   done
   ```

1. Update virtual services in a loop:

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

Output should be greater than 0. Otherwise, run the loop again.

## Background

When `PILOT_FILTER_GATEWAY_CLUSTER_CONFIG` is enabled and a VirtualService is changed
so that it updates a destination of a route that wasn't referenced from that configuration,
a gateway may return 503 for a short period of time. Such a downtime is caused by lack of Envoy cluster
of the new destination or the cluster is not [warmed](https://www.envoyproxy.io/docs/envoy/latest/intro/arch_overview/upstream/cluster_manager) yet.

Istio enforces the following order of XDS updates: CDS -> EDS -> LDS -> RDS.

Taking the above into account, I expected that updating VirtualServices in a way that
does not remove and add clusters in a single operation should reduce risk of returning 503,
because clusters will be sent first to a proxy and there will be no scenario that
a route references a non-existing cluster.

### Workaround 1 - does not work

This workaround updates configuration in 2 steps:
1. Add a new route and add a matching rule that will exclude the old route from receiving traffic.
2. Remove the old route after verification that the new route serves requests.

To make this solution reliable and reduce risk of removing a cluster in use, health checks
and verification of receiving traffic by the new cluster are performed between the steps.

The first step is safe in theory, because the [documentation](https://www.envoyproxy.io/docs/envoy/latest/api-docs/xds_protocol#eventual-consistency-considerations)
says that if the updates of XDS are performed as expected,  i.e. CDS -> EDS -> LDS -> RDS,
the traffic will not be dropped. Istio enforces this order, so I assume this condition has been met.

It's also important to note that there is no risk in switching traffic from cluster A to B immediately,
because CDS pauses XDS stream until clusters are not [warmed](https://www.envoyproxy.io/docs/envoy/latest/intro/arch_overview/upstream/cluster_manager),
so cluster warming is not a user's concern.

This approach may seem to solve the problem, because before removal of the old route,
receiving traffic by the new clusters is verified, so theoretically
there is no risk to remove the old one, but even though 503 are returned.

Error returned by the script below:
```log
1st update [8081, 8082] - errors: 1.
```
Log of the ingress gateway:
```log
[2022-11-27T19:22:57.243Z] "GET / HTTP/1.1" 200 - via_upstream - "-" 0 3 0 0 "10.244.0.6" "curl/7.79.1" "90fb5aeb-6f90-41a3-a2bb-c3200708ddfb" "test-echo.com" "10.244.0.8:5678" outbound|5678||test-app-8081.default.svc.cluster.local 10.244.0.6:48344 127.0.0.1:8080 127.0.0.1:55646 - -
[2022-11-27T19:22:57.252Z] "GET / HTTP/1.1" 503 NC cluster_not_found - "-" 0 0 0 - "10.244.0.6" "curl/7.79.1" "0c6108bd-0988-46c6-adfe-d8ba399682b4" "test-echo.com" "-" - - 127.0.0.1:8080 127.0.0.1:55662 - -
[2022-11-27T19:22:57.273Z] "GET / HTTP/1.1" 200 - via_upstream - "-" 0 3 3 3 "10.244.0.6" "curl/7.79.1" "7540afac-43d1-4b84-a552-348a39c48c52" "test-echo.com" "10.244.0.9:5678" outbound|5678||test-app-8082.default.svc.cluster.local 10.244.0.6:46844 127.0.0.1:8080 127.0.0.1:55686 - -
```
This error means that traffic was dropped after adding the new route,
so removal of clusters is not a problem in this case.

Potential reasons:
1. Istio does not enforce expected order of XDS updates.
2. Envoy does not suspend receiving XDS updates during cluster warming. (This option implies the first one).

```shell
export RED="\033[0;31m"
export RESET="\033[0m"

for i in {1..100}
do
  prev=$((8080 + (i-1)%10))
  curr=$((8080 + i%10))

  # 1st update - add a new cluster and switch traffic to it.
  # The old cluster is not removed until the new one serves traffic.
  # A new route should not be loaded until CDS response is processed
  # and the new cluster is warmed.
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
  # Match an unused header and route traffic to the old host to effectively disable
  # it without removing it from the proxy configuration.
  # The old host should not receive traffic after loading this route configuration.
  - match:
    - headers:
        foo:
          exact: "bar"
    route:
    - destination:
        host: test-app-$prev.default.svc.cluster.local
        port:
          number: 5678
  # Route all remaining traffic to the new host.
  - route:
    - destination:
        host: test-app-$curr.default.svc.cluster.local
        port:
          number: 5678
EOF

  # Verify health of the new cluster test-app-$i until it's healthy.
  # Successful health check means that cluster was warmed,
  # i.e. initial DNS resolution and internal health check succeeded.
  until $(kubectl exec $(kubectl get pods -l istio=ingressgateway -n istio-system -o jsonpath='{.items[].metadata.name}') -n istio-system -c istio-proxy -- curl localhost:15000/clusters | grep test-app-$curr | grep -q healthy)
  do
    echo "Waiting until cluster test-app-$curr is healthy" >> health-checks.log
    sleep 1
  done

  # Verify that traffic is already served by the new cluster,
  # to make sure that the old cluster is no longer needed.
  until $(kubectl logs -l istio=ingressgateway -n istio-system -c istio-proxy --tail=3 | grep -q test-app-$curr)
  do
    echo "Waiting until traffic is served by the cluster test-app-$curr" >> cluster-traffic.log
    sleep 1
  done
  
  gateway_err_count=$(cat output.log | grep 503 | wc -l)
  if [[ $gateway_err_count -gt 0 ]]
  then
    echo "${RED}1st update [$prev, $curr] - errors: $gateway_err_count.${RESET}"
    sleep 3600
  else
    echo "1st update [$prev, $curr] - no errors."
  fi

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

  # Wait until the old cluster is removed
  while $(kubectl exec $(kubectl get pods -l istio=ingressgateway -n istio-system -o jsonpath='{.items[].metadata.name}') -n istio-system -c istio-proxy -- curl localhost:15000/clusters | grep -q test-app-$prev);
  do
    echo "Waiting until cluster test-app-$prev is removed" >> prev-cluster.log
    sleep 1
  done
  
  gateway_err_count=$(cat output.log | grep 503 | wc -l)
  if [[ $gateway_err_count -gt 0 ]]
  then
    echo "${RED}2nd update [$prev, $curr] - errors: $gateway_err_count.${RESET}"
    sleep 3600
  else
    echo "2nd update [$prev, $curr] - no errors."
  fi
done
```

### Workaround 2

This workaround updates configuration in 3 steps:
1. Add a new route with a matching rule for header "warming: true".
   The goal is to push clusters by CDS, warm them by Envoy and make them available for routes.
   Additionally, test requests are sent to make sure that the new route is ready to serve traffic.
2. Switch traffic from an old route to the new one without removing unused route.
   The old route will not be removed until it receives traffic.
3. Remove the old route.

In contrary to the previous approach, this solution does not switch traffic to the new cluster immediately.
This solution manually warms cluster and ensure that the new cluster serves requests and then removes the old cluster.

I never got error using this workaround.

```shell
export RED="\033[0;31m"
export RESET="\033[0m"
export INGRESS_IP=$(kubectl get svc istio-ingressgateway -n istio-system -o jsonpath='{.status.loadBalancer.ingress[0].ip}')

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
  until $(kubectl exec $(kubectl get pods -l istio=ingressgateway -n istio-system -o jsonpath='{.items[].metadata.name}') -n istio-system -c istio-proxy -- curl localhost:15000/clusters | grep test-app-$curr | grep -q healthy)
  do
    echo "cluster test-app-$curr is not healthy" >> health-check.log
    sleep 1
  done

  # Additionally try to connect to the new host.
  # Even if cluster was warmed by cluster manager, listener may not be warmed yet.
  # This step verifies that the route is ready to serve traffic.
  until curl -s -f -o /dev/null -H "Host: test-echo.com" -H "warming: true" "http://$INGRESS_IP:80/"
  do
    echo "Warming test-app-$curr..." >> warming.log
    sleep 1
  done
  
  # Verify that the previous cluster still receives traffic - it's necessary to not make next check false-positive.
  until $(kubectl logs -l istio=ingressgateway -n istio-system -c istio-proxy --tail=1 | grep -q test-app-$prev)
  do
    echo "Waiting until traffic is served by the cluster test-app-$prev" >> cluster-traffic.log
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

  # Verify that the new cluster receives traffic.
  until $(kubectl logs -l istio=ingressgateway -n istio-system -c istio-proxy --tail=1 | grep -q test-app-$curr)
  do
    echo "Waiting until traffic is served by the cluster test-app-$curr" >> cluster-traffic.log
    sleep 1
  done

  gateway_err_count=$(cat output.log | grep 503 | wc -l)
  if [[ $gateway_err_count -gt 0 ]]
  then
    echo "${RED}2nd update [$prev, $curr] - errors: $gateway_err_count.${RESET}"
  else
    echo "2nd update [$prev, $curr] - no errors."
  fi

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
