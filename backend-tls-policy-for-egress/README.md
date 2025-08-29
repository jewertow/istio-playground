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
   ```
   istioctl install -y \
      --set profile=minimal \
      --set meshConfig.accessLogFile=/dev/stdout \
      --set values.pilot.env.PILOT_ENABLE_ALPHA_GATEWAY_API=true
   ```

1. Deploy a client:
   ```shell
   kubectl label namespace default istio-injection=enabled
   kubectl apply -f https://raw.githubusercontent.com/istio/istio/refs/heads/master/samples/curl/curl.yaml
   ```

## Simple TLS origination from sidecar

> [!IMPORTANT]
> `BackendTLSPolicy` cannot reference `ServiceEntry` resources in `targetRefs`, so we create a headless service to represent the external service within the cluster.
> `ExternalName` services are also unsuitable, as Istio does not support applying `UpstreamTlsContext` to that service type.

1. Create a headless Service:


   ```shell
   kubectl apply -f - <<EOF
   apiVersion: v1
   kind: Service
   metadata:
     name: google-headless
   spec:
     type: ClusterIP
     clusterIP: None
     ports:
     - name: https
       port: 443
       protocol: TCP
   EOF
   ```

1. Generate an EndpointSlice for the google-headless Service:

   ```shell
   IPS=$(dig +short A www.google.com | sort -u)

   {
   cat <<EOF
   apiVersion: discovery.k8s.io/v1
   kind: EndpointSlice
   metadata:
     name: google-headless
     labels:
       kubernetes.io/service-name: google-headless
   addressType: IPv4
   endpoints:
   - addresses:
   EOF

   for ip in $IPS; do
     echo "  - \"$ip\""
   done

   cat <<EOF
   ports:
   - name: https
     port: 443
     protocol: TCP
   EOF
   } > endpoint-slice.yaml
   kubectl apply -f endpoint-slice.yaml
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
     - group: ""
       kind: Service
       name: google-headless
     validation:
       hostname: www.google.com
       wellKnownCACertificates: System
   EOF
   ```

1. Send a HTTP request to port 443:

   ```shell
   kubectl exec deploy/curl -c curl -- curl -v -o /dev/null -D - http://www.google.com:443
   ```

> [!NOTE]
> Notice that the HTTP request is sent to port 443. This is necessary because the `HTTPRoute` directs traffic to the headless service, which is implemented as an ORIGINAL_DST cluster. Since this cluster does not have associated endpoints, the port cannot be changed and must match the target service's port.
