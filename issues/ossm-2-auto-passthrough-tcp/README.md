## Mesh federation with ArgoCD

### Prerequisites

1. Create an OCP cluster for servers.
1. Create a KIND cluster for clients.
1. Install Service Mesh operator in the OCP cluster.

### Environment setup

1. Generate certificates for multi-cluster traffic:

   ```shell
   wget https://raw.githubusercontent.com/istio/istio/release-1.24/tools/certs/common.mk -O common.mk
   wget https://raw.githubusercontent.com/istio/istio/release-1.24/tools/certs/Makefile.selfsigned.mk -O Makefile.selfsigned.mk
   ```
   ```shell
   make -f Makefile.selfsigned.mk \
     ROOTCA_CN="Root CA" \
     ROOTCA_ORG=my-company.org \
     root-ca
   make -f Makefile.selfsigned.mk \
     INTERMEDIATE_CN="KIND Intermediate CA" \
     INTERMEDIATE_ORG=my-company.org \
     kind-cacerts
   make -f Makefile.selfsigned.mk \
     INTERMEDIATE_CN="OCP Intermediate CA" \
     INTERMEDIATE_ORG=my-company.org \
     ocp-cacerts
   make -f common.mk clean
   ```

1. Create config maps with certificates:

    ```shell
    # KIND
    kubectl create namespace istio-system
    kubectl create secret generic cacerts -n istio-system \
        --from-file=root-cert.pem=kind/root-cert.pem \
        --from-file=ca-cert.pem=kind/ca-cert.pem \
        --from-file=ca-key.pem=kind/ca-key.pem \
        --from-file=cert-chain.pem=kind/cert-chain.pem
    ```
    
    ```shell
    # OCP
    kubectl create namespace istio-system
    kubectl create secret generic cacerts -n istio-system \
        --from-file=root-cert.pem=ocp/root-cert.pem \
        --from-file=ca-cert.pem=ocp/ca-cert.pem \
        --from-file=ca-key.pem=ocp/ca-key.pem \
        --from-file=cert-chain.pem=ocp/cert-chain.pem
    ```

### Test Service Mesh 2.5 (Istio 1.18)

1. Install Service Mesh in OCP:

   ```shell
   kubectl apply -n istio-system -f - <<EOF
   apiVersion: maistra.io/v2
   kind: ServiceMeshControlPlane
   metadata:
     name: basic
   spec:
     mode: ClusterWide
     addons:
       kiali:
         enabled: false
       prometheus:
         enabled: false
       grafana:
         enabled: false
     gateways:
       ingress:
         service:
           type: LoadBalancer
           metadata:
             annotations:
               service.beta.kubernetes.io/aws-load-balancer-type: nlb
       egress:
         enabled: false
       openshiftRoute:
         enabled: false
     general:
       logging:
         componentLevels:
           default: info
     proxy:
       accessLogging:
         file:
           name: /dev/stdout
     security:
       manageNetworkPolicy: false
     tracing:
       type: None
     version: v2.5
   EOF
   ```
   ```shell
   kubectl create namespace server
   kubectl label ns server istio-injection=enabled
   kubectl apply -n server -f https://raw.githubusercontent.com/istio/istio/master/samples/httpbin/httpbin.yaml
   kubectl patch deploy httpbin -n server -p '{"spec":{"template":{"metadata":{"labels":{"sidecar.istio.io/inject":"true"}}}}}'
   kubectl apply -n server -f https://raw.githubusercontent.com/maistra/istio/maistra-2.5/samples/tcp-echo/tcp-echo.yaml
   kubectl patch deploy tcp-echo -n server -p '{"spec":{"template":{"metadata":{"labels":{"sidecar.istio.io/inject":"true"}}}}}'
   ```

1. Install Istio in KIND:

   ```shell
   curl -L https://istio.io/downloadIstio | ISTIO_VERSION=1.18.7 TARGET_ARCH=x86_64 sh -
   ```
   ```shell
   ./istio-1.18.7/bin/istioctl install -y -f - <<EOF
   apiVersion: install.istio.io/v1alpha1
   kind: IstioOperator
   spec:
     profile: minimal
     meshConfig:
       accessLogFile: /dev/stdout
       defaultConfig:
         proxyMetadata:  
           ISTIO_META_DNS_CAPTURE: "true"
           ISTIO_META_DNS_AUTO_ALLOCATE: "true"
   EOF
   ```
   ```shell
   kubectl create namespace client
   kubectl label ns client istio-injection=enabled
   kubectl apply -n client -f https://raw.githubusercontent.com/istio/istio/master/samples/curl/curl.yaml
   ```

1. Expose httpbin from OCP cluster:

   ```shell
   kubectl apply -f - <<EOF
   apiVersion: networking.istio.io/v1beta1
   kind: Gateway
   metadata:
     name: auto-passthrough
     namespace: istio-system
   spec:
     selector:
       app: istio-ingressgateway
     servers:
     - port:
         number: 443
         name: tls
         protocol: TLS
       hosts:
       - "httpbin.server.svc.cluster.local"
       - "tcp-echo.server.svc.cluster.local"
       tls:
         mode: AUTO_PASSTHROUGH
   EOF
   ```

1. Create ServiceEntry in KIND:

   ```shell
   # OCP
   OCP_INGRESS_ADDR=$(kubectl get svc istio-ingressgateway -n istio-system -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
   ```
   ```shell
   # KIND
   OCP_INGRESS_ADDR=
   kubectl apply -n istio-system -f - <<EOF
   apiVersion: networking.istio.io/v1beta1
   kind: ServiceEntry
   metadata:
     name: httpbin
   spec:
     hosts:
     - httpbin.server.svc.cluster.local
     location: MESH_INTERNAL
     ports:
     - number: 8000
       name: http
       protocol: HTTP
     endpoints:
     - address: "$OCP_INGRESS_ADDR"
       ports:
         http: 443
       labels:
         security.istio.io/tlsMode: istio
     resolution: DNS
   ---
   apiVersion: networking.istio.io/v1beta1
   kind: ServiceEntry
   metadata:
     name: tcp-echo
   spec:
     hosts:
     - tcp-echo.server.svc.cluster.local
     location: MESH_INTERNAL
     ports:
     - number: 9000
       name: tcp
       protocol: TCP
     endpoints:
     - address: "$OCP_INGRESS_ADDR"
       ports:
         tcp: 443
       labels:
         security.istio.io/tlsMode: istio
     resolution: DNS
   EOF
   ```

> [!NOTE]
> Since ISTIO_META_DNS_AUTO_ALLOCATE is enabled we can ignore the warning:
> Warning: addresses are required for ports serving TCP (or unset) protocol

1. Send a test request from KIND to httpbin in OCP:

   ```shell
   kubectl exec deploy/curl -n client -c curl -- curl -v http://httpbin.server.svc.cluster.local:8000/headers
   ```

1. Send a test request from KIND to tcp-echo in OCP:

   ```shell
   kubectl exec deploy/curl -n client -c curl -- nc tcp-echo.server.svc.cluster.local 9000
   ```
