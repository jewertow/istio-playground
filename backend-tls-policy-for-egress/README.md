# BackendTLSPolicy for egress use-cases

## Environment Setup

1. Create a Kubernetes cluster with Kind:

   ```shell
   kind create cluster
   ```

1. Install Gateway API CRDs:

   ```shell
   kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.3.0/experimental-install.yaml
   ```

1. Install Istio control plane:

   ```shell
   istioctl install -y \
      --set profile=minimal \
      --set meshConfig.accessLogFile=/dev/stdout \
      --set values.pilot.env.PILOT_ENABLE_ALPHA_GATEWAY_API=true \
      --set values.pilot.image=quay.io/jewertow/pilot:backend-tls-policy-service-entry
   ```

1. Deploy a client:
   ```shell
   kubectl label namespace default istio-injection=enabled
   kubectl apply -f https://raw.githubusercontent.com/istio/istio/refs/heads/master/samples/curl/curl.yaml
   ```

## Simple TLS origination by sidecar proxy

> [!IMPORTANT]
> `BackendTLSPolicy` cannot reference `ServiceEntry` resources in `targetRefs`, so we create a headless service to represent the external service within the cluster.
> `ExternalName` services are also unsuitable, as Istio does not support applying `UpstreamTlsContext` to that service type.

1. Create a ServiceEntry:

   ```shell
   kubectl apply -f - <<EOF
   apiVersion: networking.istio.io/v1
   kind: ServiceEntry
   metadata:
     name: google
   spec:
     hosts:
     - www.google.com
     ports:
     - number: 80
       name: http
       protocol: HTTP
       targetPort: 443
     resolution: DNS
   EOF
   ```

1. Enable TLS origination:

   ```shell
   kubectl apply -f - <<EOF
   apiVersion: gateway.networking.k8s.io/v1alpha3
   kind: BackendTLSPolicy
   metadata:
     name: google-tls
   spec:
     targetRefs:
     - group: networking.istio.io
       kind: ServiceEntry
       name: google
       sectionName: http
     validation:
       hostname: www.google.com
       wellKnownCACertificates: System
   EOF
   ```

1. Verify that policy was applied as expected:

   ```shell
   kubectl exec deploy/curl -c curl -- curl -v -o /dev/null -D - http://www.google.com:443
   ```

## Simple TLS orgination by the egress gateway

1. Update the ServiceEntry and BackendTLSPolicy:

   ```shell
   kubectl apply -f - <<EOF
   apiVersion: networking.istio.io/v1
   kind: ServiceEntry
   metadata:
     name: google
   spec:
     hosts:
     - www.google.com
     ports:
     - number: 80
       name: http
       protocol: HTTP
     - number: 443
       name: https
       protocol: HTTPS
     resolution: DNS
   ---
   apiVersion: gateway.networking.k8s.io/v1alpha3
   kind: BackendTLSPolicy
   metadata:
     name: google-tls
   spec:
     targetRefs:
     - group: networking.istio.io
       kind: ServiceEntry
       name: google
       sectionName: https
     validation:
       hostname: www.google.com
       wellKnownCACertificates: System
   EOF
   ```

1. Deploy an egress gateway:

   ```shell
   kubectl apply -f - <<EOF
   apiVersion: gateway.networking.k8s.io/v1
   kind: Gateway
   metadata:
     name: egress-gateway
     namespace: istio-system
     annotations:
       networking.istio.io/service-type: ClusterIP
   spec:
     gatewayClassName: istio
     listeners:
     - name: http
       hostname: www.google.com
       port: 80
       protocol: HTTP
       allowedRoutes:
         namespaces:
           from: All
   ---
   apiVersion: gateway.networking.k8s.io/v1
   kind: HTTPRoute
   metadata:
     name: forward-from-egress-gateway-to-google
   spec:
     parentRefs:
     - name: egress-gateway
       namespace: istio-system
     hostnames:
     - www.google.com
     rules:
     - backendRefs:
       - kind: Hostname
         group: networking.istio.io
         name: www.google.com
         port: 443
   EOF
   ```

1. Configure routing from sidecar to egress:

   ```shell
   kubectl apply -f - <<EOF
   apiVersion: gateway.networking.k8s.io/v1
   kind: HTTPRoute
   metadata:
     name: route-requests-to-google-via-egress-gateway
   spec:
     parentRefs:
     - kind: ServiceEntry
       group: networking.istio.io
       name: google
     rules:
     - backendRefs:
       - name: egress-gateway-istio
         namespace: istio-system
         port: 80
   EOF
   ```

1. Send a HTTP request:

   ```shell
   kubectl exec deploy/curl -c curl -- curl -v -o /dev/null -D - http://www.google.com
   ```

