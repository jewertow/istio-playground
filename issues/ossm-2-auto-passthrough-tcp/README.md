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
    kubectl apply -f kind/istio.yaml
    ```
    
    ```shell
    # OCP
    kubectl create namespace istio-system
    kubectl create secret generic cacerts -n istio-system \
        --from-file=root-cert.pem=ocp/root-cert.pem \
        --from-file=ca-cert.pem=ocp/ca-cert.pem \
        --from-file=ca-key.pem=ocp/ca-key.pem \
        --from-file=cert-chain.pem=ocp/cert-chain.pem
    kubectl apply -f ocp/istio.yaml
    ```

1. Install Service Mesh in OCP:

   ```shell
   kubectl create namespace server
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
       egress:
         enabled: false
     general:
       logging:
         componentLevels:
           default: info
     proxy:
       accessLogging:
         file:
           name: /dev/stdout
     tracing:
       type: None
     version: v2.5
   ---
   apiVersion: maistra.io/v1
   kind: ServiceMeshMemberRoll
   metadata:
     name: default
   spec:
     members:
     - server
   EOF
   ```

1. Install Istio in KIND:

   ```shell
   istioctl install -y -f - <<EOF
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
   ```
