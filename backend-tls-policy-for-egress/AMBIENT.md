# BackendTLSPolicy for egress use-cases

## Environment Setup

1. Install Istio 1.28:

   ```shell
   curl -L https://istio.io/downloadIstio | ISTIO_VERSION=1.28.0 TARGET_ARCH=x86_64 sh -
   ```

1. Create a Kubernetes cluster with Kind:

   ```shell
   kind create cluster
   ```

1. Install Gateway API CRDs:

   ```shell
   kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.4.0/standard-install.yaml
   ```

1. Install Istio control plane:

   ```shell
   istioctl install -y \
      --set profile=ambient \
      --set meshConfig.accessLogFile=/dev/stdout
   ```

1. Deploy a client:

   ```shell
   kubectl label namespace default istio.io/dataplane-mode=ambient
   kubectl apply -f https://raw.githubusercontent.com/istio/istio/refs/heads/master/samples/curl/curl.yaml
   ```

1. Deploy a waypoint proxy that will act as an egress gateway:

   ```shell
   kubectl create namespace istio-egress
   istioctl waypoint apply --enroll-namespace --namespace istio-egress
   ```

1. Create a ServiceEntry:

   ```shell
   kubectl apply -f - <<EOF
   apiVersion: networking.istio.io/v1
   kind: ServiceEntry
   metadata:
     name: google
     namespace: istio-egress
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
   apiVersion: gateway.networking.k8s.io/v1
   kind: BackendTLSPolicy
   metadata:
     name: google-tls
     namespace: istio-egress
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
   kubectl exec deploy/curl -c curl -- curl -v -o /dev/null -D - http://www.google.com
   ```
