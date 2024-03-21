# Analyzing performance of the control plane

## What does istiod do?

Istio's control plane - istiod - watches Kubernetes objects, like Services, Endpoints, Pods, ConfigMaps, etc.
When an object is updated, istiod receives an event from the Kubernetes api-server, updates Envoy configuration
and sends to relevant proxies.

The process of updating Envoy proxies is performed in the following order:
1. Event: an event from watched resources triggers istiod to update Envoy configuration.
2. Debounce: istiod delays adding the event to the push queue for a defined time to batch and merge subsequent events for that period. Debouncing can be tunned with `PILOT_DEBOUNCE_AFTER` (100ms by default).
3. Add to queue: when the delay period expires, istiod adds the events to the push queue.
4. Throttle: istiod throttles push requests from the queue and sends to connected proxies. Throttling prevents processing all events concurrently and CPU overloading. Throttling can be tunned with `PILOT_PUSH_THROTTLE`.
5. Send Envoy config to proxies: istiod generates Envoy configs, like clusters, listeners, etc., from push requests and sends to connected proxies.

## Factors affecting istiod performance

1. Number of changes in watched objects - more changes in watched objects require sending more updates to relevant proxies.
2. Allocated resources - if the amount of updates to perform by istiod exceeds its limits, the push requests must be queued and proxy configurations are longer out of date.
3. Number of proxies to update - more CPU, memory and network bandwith is required to update more proxies.
4. Envoy configuration size - same as above.

## Monitoring the control plane

### Latency

First you need to check how quickly proxies are updated. The key metrics:

1. `pilot_proxy_convergence_time` (distribution) - delay in seconds between config change and a proxy receiving all required configuration.

This metric is visualized in Grafana as "Proxy Push Time" in the dashboard "Istio Control Plane".

![Proxy Push Time](img/proxy-push-time.png)

2. `pilot_proxy_queue_time` (distribution) - time in seconds, a proxy is in the push queue before being dequeued.
3. `pilot_xds_push_time` (distribution) - total time in seconds Pilot takes to push lds, rds, cds and eds.

The first metrics is usually sufficient to understand what happens.

### Resource usage

Most of the work performed by istiod is CPU-intensive, so you usually need to look at:

1. `container_cpu_usage_seconds_total` - CPU usage reported by Kubernetes.
2. `process_cpu_seconds_total` - CPU usage reported by istiod.
This metric is visualized in Grafana as "CPU" in the dashboard "Istio Control Plane":
![CPU](img/istiod-cpu.png)

### Traffic

There are 2 factors affecting load on istiod: inbound requests and outbound push requests.
Inbound requests are new XDS connections from proxies and configuration updates made by users.
Outbound push requests are triggered by events from watched resources and configuration updates made by users.

Usually, the biggest impact on performance have events, so start from reviewing the following metrics:

1. `pilot_xds_pushes` (sum) - measures ops/s of all pushes made by istiod.

This metric is visualized in Grafana as "Pilot Pushes" in the dashboard "Istio Control Plane".

![Pilot Pushes](img/pilot-pushes.png)

2. `pilot_xds` (last value) - number of endpoints connected to this pilot using XDS.

#### TODO: Change screenshot

This metric is visualized in Grafana as "XDS Active Connections" in the dashboard "Istio Control Plane".

![XDS Active Connections](img/pilot-pushes.png)

There are also inbound-related metrics worth to check:

1. `pilot_inbound_updates` (sum) - total number of updates received by pilot.
2. `pilot_push_triggers` (sum) - total number of times a push was triggered, labeled by reason for the push.
3. `pilot_services` (last value) - total services known to pilot.

For other metrics look at this [table](https://istio.io/latest/docs/reference/commands/pilot-discovery/#metrics).

### Metrics correlation

When analyzing performance problems, pay attention to the correlation of metrics - for example,
if you see CPU spikes, pay attention to the pilot pushes - the spikes should overlap.
If not, look at latency-related metrics. Before looking for problems with the platform,
make sure that the control plane metrics don't show any anomalies.

## Tunning performance

### Scaling istiod horizontally and/or vertically

#### TODO: Fix X and Y

By default, istiod deployed with `ServiceMeshControlPlane` has on X CPU and Y memory.
These values are not universal and should be adjust to the mesh size, rate of changes, traffic, etc.

```yaml
apiVersion: maistra.io/v2
kind: ServiceMeshControlPlane
metadata:
  name: basic
spec:
  runtime:
    components:
      pilot:
        container:
          resources:
            requests:
              cpu: 250m
              memory: 1024Mi
        deployment:
          replicas: 2
```

Scale istiod horizontally to reduce load on a single instance and split work across more instances.
Scale istiod vertically when you observe slow processing updates and CPU spikes.

### Filter out irrelevant updates

In most cases, applications communicate only with some of other applications, not all of them.
Then, you can limit the amount of updates being sent from the control plane to proxies. To be precise,
you can limit the number of clusters (CDS) and endpoints (EDS) being sent to proxies.

To do that, you just need to apply the `Sidecar` object with proper `spec.egress` setting:
```yaml
apiVersion: networking.istio.io/v1alpha3
kind: Sidecar
metadata:
  name: ratings
  namespace: bookinfo
spec:
  workloadSelector:
    labels:
      app: ratings
  egress:
  - hosts:
    - "istio-system/*"
    - "./reviews.bookinfo.svc.cluster.local"
```

In this case, the app `ratings` will receive clusters and endpoints only for `reviews.bookinfo.svc.cluster.local`
and services from the control plane namespace.

You can also define default mesh-wide `Sidecar` and additionally customize particular workloads.
For example, if your applications usually communicate with apps only from the same namespace, and only some
communication with apps from other namespaces, you can apply the following configuration:
```yaml
apiVersion: networking.istio.io/v1alpha3
kind: Sidecar
metadata:
  name: default
  namespace: istio-system
spec:
  egress:
  - hosts:
    - "./*"
    - "istio-system/*"
---
apiVersion: networking.istio.io/v1alpha3
kind: Sidecar
metadata:
  name: ratings
  namespace: bookinfo
spec:
  workloadSelector:
    labels:
      app: ratings
  egress:
  - hosts:
    - "istio-system/*"
    - "httpbin/*
```

Even though gateways are istio-proxies, the `Sidecar` resource is not applicable to gateways.
However, you can enable `PILOT_FILTER_GATEWAY_CLUSTER_CONFIG: true` to send only these clusters and endpoints,
which are used in a `VirtualService` configured for a particular gateway.

```yaml
apiVersion: maistra.io/v2
kind: ServiceMeshControlPlane
metadata:
  name: basic
spec:
  runtime:
    components:
      pilot:
        container:
          env:
            PILOT_FILTER_GATEWAY_CLUSTER_CONFIG: "true"
```

### Ignoring irrelvant events (only in cluster-wide mode)

If you have cluster-wide `ServiceMeshControlPlane`, you can define discovery selectors to specify from which namespaces
events should not be ignored by istiod.

```yaml
apiVersion: maistra.io/v2
kind: ServiceMeshControlPlane
metadata:
  name: basic
spec:
meshConfig:
  discoverySelectors:
  - matchLabels:
      env: prod
      region: us-east1
  - matchExpressions:
    - key: app
      operator: In
      values:
        - cassandra
        - spark
```

This is very usuful to avoid receiving events from openshift-* namespaces.

### Tweak batching events and throttling pushes

This is fairly advanced technique, which require very good understand what istiod does and what's the bottleneck.

Key environment variables:
1. `PILOT_DEBOUNCE_AFTER` (100ms by default) - The delay added to config/registry events for debouncing. This will delay the push by at least this interval. If no change is detected within this period, the push will happen, otherwise we'll keep delaying until things settle, up to a max of `PILOT_DEBOUNCE_MAX`.
2. `PILOT_DEBOUNCE_MAX` (10s by default) - The maximum amount of time to wait for events while debouncing. If events keep showing up with no breaks for this time, we'll trigger a push.
3. `PILOT_PUSH_THROTTLE` (0 by default) - Limits the number of concurrent pushes allowed. On larger machines this can be increased for faster pushes. If set to 0 or unset, the max will be automatically determined based on the machine size.


