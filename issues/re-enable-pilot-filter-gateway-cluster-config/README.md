## Re-enable PILOT_FILTER_GATEWAY_CLUSTER_CONFIG #29131

### Reproduce issue

1. Create test kubernetes cluster:
```shell
kind create cluster --name test
```

2. Install Istio:
```shell
istioctl install -y -n istio-system -f - <<EOF
apiVersion: install.istio.io/v1alpha1
kind: IstioOperator
metadata:
  name: test
spec:
  profile: minimal
  components:
    pilot:
      k8s:
        env:
        - name: PILOT_FILTER_GATEWAY_CLUSTER_CONFIG
          value: "true"
  meshConfig:
    accessLogFile: /dev/stdout
  values:
    global:
      proxy:
        tracer: none
EOF
```

3. Deploy custom ingress gateway:
```shell
kubectl apply -n istio-system -f - <<EOF
apiVersion: v1
kind: Service
metadata:
  name: istio-ingressgateway
spec:
 type: LoadBalancer
 selector:
   istio: ingressgateway
 ports:
 - port: 80
   name: http
 - port: 443
   name: https
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: istio-ingressgateway
spec:
  selector:
    matchLabels:
      istio: ingressgateway
  template:
    metadata:
      annotations:
        inject.istio.io/templates: gateway
        sidecar.istio.io/logLevel: debug
        sidecar.istio.io/rewriteAppHTTPProbers: "false"
      labels:
        istio: ingressgateway
        sidecar.istio.io/inject: "true"
    spec:
      containers:
      - name: istio-proxy
        image: auto 
EOF
```

5. Create 10 services:
```shell
kubectl label namespace default istio-injection=enabled
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

  sleep 1
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

### Debugging results

Logs from the moment when 503 was returned:
```log
2022-12-08T13:11:45.623044Z     debug   envoy client    [C5301] response complete
2022-12-08T13:11:45.623342Z     debug   envoy pool      [C5301] response complete
2022-12-08T13:11:45.623358Z     debug   envoy pool      [C5301] destroying stream: 0 remaining
2022-12-08T13:11:45.629521Z     debug   envoy connection        [C5215] remote close
2022-12-08T13:11:45.629549Z     debug   envoy connection        [C5215] closing socket: 0
2022-12-08T13:11:45.629612Z     debug   envoy conn_handler      [C5215] adding to cleanup list
2022-12-08T13:11:45.631468Z     debug   envoy config    Received gRPC message for type.googleapis.com/envoy.config.cluster.v3.Cluster at version 2022-12-08T13:11:45Z/222
2022-12-08T13:11:45.631489Z     debug   envoy config    Pausing discovery requests for type.googleapis.com/envoy.config.cluster.v3.Cluster (previous count 0)
2022-12-08T13:11:45.631750Z     debug   envoy config    Pausing discovery requests for type.googleapis.com/envoy.config.endpoint.v3.ClusterLoadAssignment (previous count 0)
2022-12-08T13:11:45.631758Z     debug   envoy config    Pausing discovery requests for type.googleapis.com/envoy.config.endpoint.v3.LbEndpoint (previous count 0)
2022-12-08T13:11:45.631759Z     debug   envoy config    Pausing discovery requests for type.googleapis.com/envoy.extensions.transport_sockets.tls.v3.Secret (previous count 0)
2022-12-08T13:11:45.631764Z     info    envoy upstream  cds: add 3 cluster(s), remove 5 cluster(s)
2022-12-08T13:11:45.631948Z     debug   envoy upstream  cds: add/update cluster 'outbound|5678||test-app-8087.default.svc.cluster.local' skipped
2022-12-08T13:11:45.632172Z     debug   envoy init      added shared target SdsApi default to init manager Cluster outbound|5678||test-app-8088.default.svc.cluster.local
2022-12-08T13:11:45.632184Z     debug   envoy init      added shared target SdsApi ROOTCA to init manager Cluster outbound|5678||test-app-8088.default.svc.cluster.local
2022-12-08T13:11:45.632557Z     debug   envoy config    Secret is updated.
2022-12-08T13:11:45.632901Z     debug   envoy config    Secret is updated.
2022-12-08T13:11:45.633403Z     debug   envoy upstream    upstream filter #0:
2022-12-08T13:11:45.633411Z     debug   envoy upstream      name: istio.metadata_exchange
2022-12-08T13:11:45.633436Z     debug   envoy config        upstream http filter #0
2022-12-08T13:11:45.633449Z     debug   envoy config          name: envoy.filters.http.upstream_codec
2022-12-08T13:11:45.633469Z     debug   envoy config        config: {"@type":"type.googleapis.com/envoy.extensions.filters.http.upstream_codec.v3.UpstreamCodec"}
2022-12-08T13:11:45.633518Z     debug   envoy config    Pausing discovery requests for type.googleapis.com/envoy.config.cluster.v3.Cluster (previous count 1)
2022-12-08T13:11:45.633524Z     debug   envoy upstream  add/update cluster outbound|5678||test-app-8088.default.svc.cluster.local starting warming
2022-12-08T13:11:45.633529Z     debug   envoy config    gRPC mux addWatch for type.googleapis.com/envoy.config.endpoint.v3.ClusterLoadAssignment
2022-12-08T13:11:45.633531Z     debug   envoy upstream  cds: add/update cluster 'outbound|5678||test-app-8088.default.svc.cluster.local'
2022-12-08T13:11:45.633548Z     debug   envoy upstream  cds: add/update cluster 'BlackHoleCluster' skipped
2022-12-08T13:11:45.633555Z     info    envoy upstream  cds: added/updated 1 cluster(s), skipped 2 unmodified cluster(s)
2022-12-08T13:11:45.633558Z     debug   envoy config    Decreasing pause count on discovery requests for type.googleapis.com/envoy.config.endpoint.v3.ClusterLoadAssignment (previous count 1)
2022-12-08T13:11:45.633562Z     debug   envoy config    Resuming discovery requests for type.googleapis.com/envoy.config.endpoint.v3.ClusterLoadAssignment
2022-12-08T13:11:45.633584Z     debug   envoy config    Decreasing pause count on discovery requests for type.googleapis.com/envoy.config.endpoint.v3.LbEndpoint (previous count 1)
2022-12-08T13:11:45.633588Z     debug   envoy config    Decreasing pause count on discovery requests for type.googleapis.com/envoy.extensions.transport_sockets.tls.v3.Secret (previous count 1)
2022-12-08T13:11:45.633596Z     debug   envoy config    gRPC config for type.googleapis.com/envoy.config.cluster.v3.Cluster accepted with 3 resources with version 2022-12-08T13:11:45Z/222
2022-12-08T13:11:45.633640Z     debug   envoy config    Decreasing pause count on discovery requests for type.googleapis.com/envoy.config.cluster.v3.Cluster (previous count 2)
2022-12-08T13:11:45.633753Z     debug   envoy config    Received gRPC message for type.googleapis.com/envoy.config.listener.v3.Listener at version 2022-12-08T13:11:45Z/222
2022-12-08T13:11:45.633759Z     debug   envoy config    Pausing discovery requests for type.googleapis.com/envoy.config.listener.v3.Listener (previous count 0)
2022-12-08T13:11:45.633817Z     debug   envoy config    Pausing discovery requests for type.googleapis.com/envoy.config.route.v3.RouteConfiguration (previous count 0)
2022-12-08T13:11:45.633821Z     debug   envoy config    Pausing discovery requests for type.googleapis.com/envoy.extensions.transport_sockets.tls.v3.Secret (previous count 0)
2022-12-08T13:11:45.633824Z     debug   envoy config    begin remove listener: name=33232bdf-9162-4fd6-ac89-b9f2931c8265
2022-12-08T13:11:45.633827Z     debug   envoy config    unknown/locked listener '33232bdf-9162-4fd6-ac89-b9f2931c8265'. no remove
2022-12-08T13:11:45.633828Z     debug   envoy config    begin remove listener: name=f35c22a5-22cc-4c1b-a08f-645abec8b7dc
2022-12-08T13:11:45.633830Z     debug   envoy config    unknown/locked listener 'f35c22a5-22cc-4c1b-a08f-645abec8b7dc'. no remove
2022-12-08T13:11:45.634173Z     debug   envoy config    begin add/update listener: name=0.0.0.0_80 hash=15208284309641815325
2022-12-08T13:11:45.634182Z     debug   envoy config    duplicate/locked listener '0.0.0.0_80'. no add/update
2022-12-08T13:11:45.634185Z     debug   envoy upstream  lds: add/update listener '0.0.0.0_80' skipped
2022-12-08T13:11:45.634192Z     debug   envoy config    Decreasing pause count on discovery requests for type.googleapis.com/envoy.config.route.v3.RouteConfiguration (previous count 1)
2022-12-08T13:11:45.634194Z     debug   envoy config    Decreasing pause count on discovery requests for type.googleapis.com/envoy.extensions.transport_sockets.tls.v3.Secret (previous count 1)
2022-12-08T13:11:45.634200Z     debug   envoy config    gRPC config for type.googleapis.com/envoy.config.listener.v3.Listener accepted with 1 resources with version 2022-12-08T13:11:45Z/222
2022-12-08T13:11:45.634225Z     debug   envoy config    Decreasing pause count on discovery requests for type.googleapis.com/envoy.config.listener.v3.Listener (previous count 1)
2022-12-08T13:11:45.634261Z     debug   envoy config    Resuming discovery requests for type.googleapis.com/envoy.config.listener.v3.Listener
2022-12-08T13:11:45.634288Z     debug   envoy config    Received gRPC message for type.googleapis.com/envoy.config.route.v3.RouteConfiguration at version 2022-12-08T13:11:45Z/222
2022-12-08T13:11:45.634293Z     debug   envoy config    Pausing discovery requests for type.googleapis.com/envoy.config.route.v3.RouteConfiguration (previous count 0)
2022-12-08T13:11:45.634602Z     debug   envoy rds       rds: loading new configuration: config_name=http.80 hash=15915126730005602314
2022-12-08T13:11:45.634720Z     debug   envoy config    gRPC config for type.googleapis.com/envoy.config.route.v3.RouteConfiguration accepted with 1 resources with version 2022-12-08T13:11:45Z/222
2022-12-08T13:11:45.634821Z     debug   envoy config    Decreasing pause count on discovery requests for type.googleapis.com/envoy.config.route.v3.RouteConfiguration (previous count 1)
2022-12-08T13:11:45.634827Z     debug   envoy config    Resuming discovery requests for type.googleapis.com/envoy.config.route.v3.RouteConfiguration
2022-12-08T13:11:45.635404Z     debug   envoy conn_handler      [C5332] new connection from 127.0.0.1:35172
2022-12-08T13:11:45.635449Z     debug   envoy http      [C5332] new stream
2022-12-08T13:11:45.635490Z     debug   envoy http      [C5332][S6084629102113665450] request headers complete (end_stream=true):
':authority', 'test-echo.com'
':path', '/test'
':method', 'GET'
'user-agent', 'curl/7.79.1'
'accept', '*/*'

2022-12-08T13:11:45.635499Z     debug   envoy http      [C5332][S6084629102113665450] request end stream
2022-12-08T13:11:45.635518Z     debug   envoy connection        [C5332] current connecting state: false
2022-12-08T13:11:45.635522Z     debug   envoy config    Received gRPC message for type.googleapis.com/envoy.config.endpoint.v3.ClusterLoadAssignment at version 2022-12-08T13:11:45Z/222
2022-12-08T13:11:45.635529Z     debug   envoy config    Pausing discovery requests for type.googleapis.com/envoy.config.endpoint.v3.ClusterLoadAssignment (previous count 0)
2022-12-08T13:11:45.635594Z     debug   envoy config    Pausing discovery requests for type.googleapis.com/envoy.config.endpoint.v3.LbEndpoint (previous count 0)
2022-12-08T13:11:45.635594Z     debug   envoy filter    cannot find cluster outbound|5678||test-app-8088.default.svc.cluster.local
2022-12-08T13:11:45.635633Z     debug   envoy router    [C5332][S6084629102113665450] unknown cluster 'outbound|5678||test-app-8088.default.svc.cluster.local'
2022-12-08T13:11:45.635640Z     debug   envoy http      [C5332][S6084629102113665450] Sending local reply with details cluster_not_found
2022-12-08T13:11:45.635643Z     debug   envoy upstream  transport socket match, socket tlsMode-istio selected for host with address 10.244.0.16:5678
2022-12-08T13:11:45.635654Z     debug   envoy upstream  EDS hosts or locality weights changed for cluster: outbound|5678||test-app-8088.default.svc.cluster.local current hosts 0 priority 0
2022-12-08T13:11:45.635669Z     debug   envoy http      [C5332][S6084629102113665450] encoding headers via codec (end_stream=true):
':status', '503'
'date', 'Thu, 08 Dec 2022 13:11:45 GMT'
'server', 'istio-envoy'

2022-12-08T13:11:45.635672Z     debug   envoy upstream  initializing Secondary cluster outbound|5678||test-app-8088.default.svc.cluster.local completed
2022-12-08T13:11:45.635676Z     debug   envoy init      init manager Cluster outbound|5678||test-app-8088.default.svc.cluster.local initializing
2022-12-08T13:11:45.635679Z     debug   envoy init      init manager Cluster outbound|5678||test-app-8088.default.svc.cluster.local initializing shared target SdsApi default
2022-12-08T13:11:45.635681Z     debug   envoy init      shared target SdsApi default initialized, notifying init manager Cluster outbound|5678||test-app-8088.default.svc.cluster.local
2022-12-08T13:11:45.635684Z     debug   envoy init      init manager Cluster outbound|5678||test-app-8088.default.svc.cluster.local initializing shared target SdsApi ROOTCA
2022-12-08T13:11:45.635686Z     debug   envoy init      shared target SdsApi ROOTCA initialized, notifying init manager Cluster outbound|5678||test-app-8088.default.svc.cluster.local
2022-12-08T13:11:45.635688Z     debug   envoy init      init manager Cluster outbound|5678||test-app-8088.default.svc.cluster.local initialized, notifying ClusterImplBase
2022-12-08T13:11:45.635691Z     debug   envoy upstream  warming cluster outbound|5678||test-app-8088.default.svc.cluster.local complete
2022-12-08T13:11:45.635699Z     debug   envoy config    Decreasing pause count on discovery requests for type.googleapis.com/envoy.config.cluster.v3.Cluster (previous count 1)
2022-12-08T13:11:45.635702Z     debug   envoy config    Resuming discovery requests for type.googleapis.com/envoy.config.cluster.v3.Cluster
2022-12-08T13:11:45.635734Z     debug   envoy upstream  adding TLS cluster outbound|5678||test-app-8088.default.svc.cluster.local
2022-12-08T13:11:45.635735Z     debug   envoy upstream  adding TLS cluster outbound|5678||test-app-8088.default.svc.cluster.local
2022-12-08T13:11:45.635746Z     debug   envoy upstream  adding TLS cluster outbound|5678||test-app-8088.default.svc.cluster.local
2022-12-08T13:11:45.635753Z     debug   envoy upstream  adding TLS cluster outbound|5678||test-app-8088.default.svc.cluster.local
2022-12-08T13:11:45.635760Z     debug   envoy upstream  adding TLS cluster outbound|5678||test-app-8088.default.svc.cluster.local
2022-12-08T13:11:45.635763Z     debug   envoy upstream  membership update for TLS cluster outbound|5678||test-app-8088.default.svc.cluster.local added 1 removed 0
2022-12-08T13:11:45.635765Z     debug   envoy upstream  membership update for TLS cluster outbound|5678||test-app-8088.default.svc.cluster.local added 1 removed 0
2022-12-08T13:11:45.635769Z     debug   envoy upstream  membership update for TLS cluster outbound|5678||test-app-8088.default.svc.cluster.local added 1 removed 0
2022-12-08T13:11:45.635772Z     debug   envoy upstream  adding TLS cluster outbound|5678||test-app-8088.default.svc.cluster.local
2022-12-08T13:11:45.635779Z     debug   envoy upstream  adding TLS cluster outbound|5678||test-app-8088.default.svc.cluster.local
2022-12-08T13:11:45.635780Z     debug   envoy config    Decreasing pause count on discovery requests for type.googleapis.com/envoy.config.endpoint.v3.LbEndpoint (previous count 1)
2022-12-08T13:11:45.635785Z     debug   envoy upstream  adding TLS cluster outbound|5678||test-app-8088.default.svc.cluster.local
2022-12-08T13:11:45.635788Z     debug   envoy config    gRPC config for type.googleapis.com/envoy.config.endpoint.v3.ClusterLoadAssignment accepted with 1 resources with version 2022-12-08T13:11:45Z/222
2022-12-08T13:11:45.635789Z     debug   envoy upstream  membership update for TLS cluster outbound|5678||test-app-8088.default.svc.cluster.local added 1 removed 0
2022-12-08T13:11:45.635790Z     debug   envoy upstream  membership update for TLS cluster outbound|5678||test-app-8088.default.svc.cluster.local added 1 removed 0
2022-12-08T13:11:45.635795Z     debug   envoy upstream  membership update for TLS cluster outbound|5678||test-app-8088.default.svc.cluster.local added 1 removed 0
2022-12-08T13:11:45.635801Z     debug   envoy upstream  adding TLS cluster outbound|5678||test-app-8088.default.svc.cluster.local
2022-12-08T13:11:45.635737Z     debug   envoy upstream  adding TLS cluster outbound|5678||test-app-8088.default.svc.cluster.local
2022-12-08T13:11:45.635811Z     debug   envoy config    Decreasing pause count on discovery requests for type.googleapis.com/envoy.config.endpoint.v3.ClusterLoadAssignment (previous count 1)
2022-12-08T13:11:45.635811Z     debug   envoy upstream  adding TLS cluster outbound|5678||test-app-8088.default.svc.cluster.local
2022-12-08T13:11:45.635815Z     debug   envoy config    Resuming discovery requests for type.googleapis.com/envoy.config.endpoint.v3.ClusterLoadAssignment
2022-12-08T13:11:45.635739Z     debug   envoy upstream  adding TLS cluster outbound|5678||test-app-8088.default.svc.cluster.local
2022-12-08T13:11:45.635765Z     debug   envoy upstream  membership update for TLS cluster outbound|5678||test-app-8088.default.svc.cluster.local added 1 removed 0
2022-12-08T13:11:45.635823Z     debug   envoy upstream  membership update for TLS cluster outbound|5678||test-app-8088.default.svc.cluster.local added 1 removed 0
2022-12-08T13:11:45.635829Z     debug   envoy upstream  membership update for TLS cluster outbound|5678||test-app-8088.default.svc.cluster.local added 1 removed 0
2022-12-08T13:11:45.635823Z     debug   envoy upstream  membership update for TLS cluster outbound|5678||test-app-8088.default.svc.cluster.local added 1 removed 0
2022-12-08T13:11:45.635774Z     debug   envoy upstream  membership update for TLS cluster outbound|5678||test-app-8088.default.svc.cluster.local added 1 removed 0
2022-12-08T13:11:45.635812Z     debug   envoy upstream  membership update for TLS cluster outbound|5678||test-app-8088.default.svc.cluster.local added 1 removed 0
2022-12-08T13:11:45.644074Z     debug   envoy connection        [C5216] remote close
2022-12-08T13:11:45.644103Z     debug   envoy connection        [C5216] closing socket: 0
2022-12-08T13:11:45.644176Z     debug   envoy conn_handler      [C5216] adding to cleanup list
2022-12-08T13:11:45.651814Z     debug   envoy connection        [C5217] remote close
2022-12-08T13:11:45.651824Z     debug   envoy connection        [C5217] closing socket: 0
2022-12-08T13:11:45.651876Z     debug   envoy conn_handler      [C5217] adding to cleanup list
2022-12-08T13:11:45.652424Z     debug   envoy upstream  adding TLS cluster outbound|5678||test-app-8088.default.svc.cluster.local
2022-12-08T13:11:45.652442Z     debug   envoy upstream  membership update for TLS cluster outbound|5678||test-app-8088.default.svc.cluster.local added 1 removed 0
2022-12-08T13:11:45.662496Z     debug   envoy connection        [C5218] remote close
2022-12-08T13:11:45.662510Z     debug   envoy connection        [C5218] closing socket: 0
2022-12-08T13:11:45.662548Z     debug   envoy conn_handler      [C5218] adding to cleanup list
2022-12-08T13:11:45.663066Z     debug   envoy conn_handler      [C5333] new connection from 127.0.0.1:35174
2022-12-08T13:11:45.663101Z     debug   envoy http      [C5333] new stream
2022-12-08T13:11:45.663128Z     debug   envoy http      [C5333][S8651892794354560641] request headers complete (end_stream=true):
':authority', 'test-echo.com'
':path', '/test'
':method', 'GET'
'user-agent', 'curl/7.79.1'
'accept', '*/*'
```

These logs show the following order of events:
1. Cluster test-app-8087 is serving requests...
2. Request HTTP/1.1 /test
3. Response 200 OK
4. CDS added test-app-8088
5. XDS client paused requesting Clusters, ClusterLoadAssignments, LbEndpoints and Secrets.
6. Cluster test-app-8088 started being warmed.
7. XDS client resumed requesting ClusterLoadAssignment.
8. LDS received new configuration.
9. RDS received new configuration.
10. New route was loaded!
11. Request HTTP/1.1 /test
12. Response 503, because cluster test-app-8088 is not yet warmed.
13. EDS receives ClusterLoadAssignments.
14. Cluster test-app-8088 is warmed.
15. Next requests succeed.

The order of messages above means that pausing CDS/EDS and LDS/RDS are performed independently, so
Istio should not send LDS and RDS until received ACK on ClusterLoadAssignment (EDS).

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
  until curl -s -f -o /dev/null -H "Host: test-echo.com" -H "warming: true" http://localhost:8080/
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
