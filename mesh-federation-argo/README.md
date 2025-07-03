## Mesh federation with ArgoCD

### Prerequisites

1. Create 3 OCP clusters (east, west, central).
1. Install Service Mesh operator in all clusters.
1. Install GitOps operator in all clusters.
1. Install Kiali and User Workload Monitoring in the central cluster.

### Environment setup

1. Setup environment:

    ```shell
    export EAST_AUTH_PATH=
    export WEST_AUTH_PATH=
    export CENTRAL_AUTH_PATH=
    ```
    ```shell
    alias keast="KUBECONFIG=$EAST_AUTH_PATH/kubeconfig kubectl"
    alias istioctl-east="istioctl --kubeconfig=$EAST_AUTH_PATH/kubeconfig"
    alias kwest="KUBECONFIG=$WEST_AUTH_PATH/kubeconfig kubectl"
    alias istioctl-west="istioctl --kubeconfig=$WEST_AUTH_PATH/kubeconfig"
    alias kcent="KUBECONFIG=$CENTRAL_AUTH_PATH/kubeconfig kubectl"
    alias istioctl-cent="istioctl --kubeconfig=$CENTRAL_AUTH_PATH/kubeconfig"
    ```

   Generate certificates for Istio CA with common root:

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
     INTERMEDIATE_CN="East Intermediate CA" \
     INTERMEDIATE_ORG=my-company.org \
     east-cacerts
   make -f Makefile.selfsigned.mk \
     INTERMEDIATE_CN="West Intermediate CA" \
     INTERMEDIATE_ORG=my-company.org \
     west-cacerts
   make -f Makefile.selfsigned.mk \
     INTERMEDIATE_CN="Central Intermediate CA" \
     INTERMEDIATE_ORG=my-company.org \
     central-cacerts
   make -f common.mk clean
   ```

### GitOps

   Apply permissive RBAC for GitOps operator (only for demo purposes):

   ```shell
   keast apply -f rbac.yaml
   kwest apply -f rbac.yaml
   kcent apply -f rbac.yaml
   ```

### Service Mesh

   ```shell
   keast create namespace istio-cni
   keast apply -f istio-cni.yaml

   kwest create namespace istio-cni
   kwest apply -f istio-cni.yaml

   kcent create namespace istio-cni
   kcent apply -f istio-cni.yaml
   ```
   ```shell
   keast create namespace istio-system
   keast create secret generic cacerts -n istio-system \
     --from-file=root-cert.pem=east/root-cert.pem \
     --from-file=ca-cert.pem=east/ca-cert.pem \
     --from-file=ca-key.pem=east/ca-key.pem \
     --from-file=cert-chain.pem=east/cert-chain.pem
   keast apply -f east/istio.yaml

   kwest create namespace istio-system
   kwest create secret generic cacerts -n istio-system \
     --from-file=root-cert.pem=west/root-cert.pem \
     --from-file=ca-cert.pem=west/ca-cert.pem \
     --from-file=ca-key.pem=west/ca-key.pem \
     --from-file=cert-chain.pem=west/cert-chain.pem
   kwest apply -f west/istio.yaml

   kcent create namespace istio-system
   kcent create secret generic cacerts -n istio-system \
     --from-file=root-cert.pem=central/root-cert.pem \
     --from-file=ca-cert.pem=central/ca-cert.pem \
     --from-file=ca-key.pem=central/ca-key.pem \
     --from-file=cert-chain.pem=central/cert-chain.pem
   kcent apply -f central/istio.yaml
   ```

### OpenShift Monitoring

   ```shell
   kcent apply -f central/user-workload-monitoring.yaml
   ```

### Kiali

   ```shell
   kcent apply -f central/service-monitor.yaml -n istio-system
   kcent apply -f central/pod-monitor.yaml -n istio-system
   kcent apply -f central/kiali.yaml
   ```

## Demo

### East cluster

1. Deploy and export `ratings` service:

   ```shell
   keast create namespace ns2
   keast label namespace ns2 istio-injection=enabled
   keast apply -n ns2 -l account=ratings -f https://raw.githubusercontent.com/istio/istio/refs/heads/release-1.26/samples/bookinfo/platform/kube/bookinfo.yaml
   keast apply -n ns2 -l app=ratings -f https://raw.githubusercontent.com/istio/istio/refs/heads/release-1.26/samples/bookinfo/platform/kube/bookinfo.yaml

   keast apply -f east/federation-ingress-gateway.yaml
   keast apply -f east/mesh-federation.yaml
   keast apply -f east/namespace-federation.yaml
   ```

### West cluster

1. Deploy and export `details` and `ratings` services:

   ```shell
   kwest create namespace ns3
   kwest label namespace ns3 istio-injection=enabled
   kwest apply -n ns3 -l account=details -f https://raw.githubusercontent.com/istio/istio/refs/heads/release-1.26/samples/bookinfo/platform/kube/bookinfo.yaml
   kwest apply -n ns3 -l app=details -f https://raw.githubusercontent.com/istio/istio/refs/heads/release-1.26/samples/bookinfo/platform/kube/bookinfo.yaml
   kwest apply -n ns3 -l account=ratings -f https://raw.githubusercontent.com/istio/istio/refs/heads/release-1.26/samples/bookinfo/platform/kube/bookinfo.yaml
   kwest apply -n ns3 -l app=ratings -f https://raw.githubusercontent.com/istio/istio/refs/heads/release-1.26/samples/bookinfo/platform/kube/bookinfo.yaml
   
   kwest apply -f west/federation-ingress-gateway.yaml
   kwest apply -f west/mesh-federation.yaml
   kwest apply -f west/bookinfo-federation.yaml
   ```

### Central cluster

This cluster will import services from east and west clusters.

1. Deploy ingress and egress gateways:

   ```shell
   kcent apply -f central/istio-egressgateway.yaml
   kcent apply -f central/istio-ingressgateway.yaml
   ```

1. Deploy productpage and reviews:

   ```shell
   kcent create namespace ns1
   kcent label namespace ns1 istio-injection=enabled
   kcent apply -f https://raw.githubusercontent.com/istio/istio/refs/heads/release-1.26/samples/bookinfo/networking/bookinfo-gateway.yaml -n ns1
   kcent apply -l app=productpage -f https://raw.githubusercontent.com/istio/istio/refs/heads/release-1.26/samples/bookinfo/platform/kube/bookinfo.yaml -n ns1
   kcent apply -l account=productpage -f https://raw.githubusercontent.com/istio/istio/refs/heads/release-1.26/samples/bookinfo/platform/kube/bookinfo.yaml -n ns1
   kcent apply -l app=reviews -f https://raw.githubusercontent.com/istio/istio/refs/heads/release-1.26/samples/bookinfo/platform/kube/bookinfo.yaml -n ns1
   kcent apply -l account=reviews -f https://raw.githubusercontent.com/istio/istio/refs/heads/release-1.26/samples/bookinfo/platform/kube/bookinfo.yaml -n ns1
   kcent apply -f central/pod-monitor.yaml -n ns1
   ```
   ```shell
   kcent patch gateway bookinfo-gateway -n ns1 --type='json' \
     -p='[
       {
         "op": "replace",
         "path": "/spec/servers/0/port/number",
         "value": 80
       }
     ]'
   ```

1. Enable mesh federation and import remote services:

   ```shell
   kcent apply -f central/mesh-federation.yaml
   kcent apply -f central/bookinfo-federation.yaml
   ```

1. Update productpage to consume imported ratings:

   ```shell
   kcent patch deployment productpage-v1 -n ns1 \
     --type='strategic' \
     -p='{
       "spec": {
         "template": {
           "spec": {
             "containers": [
               {
                 "name": "productpage",
                 "env": [
                   {
                     "name": "DETAILS_HOSTNAME",
                     "value": "details.mesh.global"
                   }
                 ]
               }
             ]
           }
         }
       }
     }'
   ```
   ```shell
   kcent patch deployment reviews-v2 -n ns1 \
     --type='strategic' \
     -p='{
       "spec": {
         "template": {
           "spec": {
             "containers": [
               {
                 "name": "reviews",
                 "env": [
                   {
                     "name": "RATINGS_HOSTNAME",
                     "value": "ratings.mesh.global"
                   }
                 ]
               }
             ]
           }
         }
       }
     }'
   ```
   ```shell
   kcent patch deployment reviews-v3 -n ns1 \
     --type='strategic' \
     -p='{
       "spec": {
         "template": {
           "spec": {
             "containers": [
               {
                 "name": "reviews",
                 "env": [
                   {
                     "name": "RATINGS_HOSTNAME",
                     "value": "ratings.mesh.global"
                   }
                 ]
               }
             ]
           }
         }
       }
     }'
   ```

1. Send requests in a loop:

   ```shell
   HOST=$(kcent get routes istio-ingressgateway -n istio-system -o jsonpath='{.spec.host}')
   while true; do curl -v http://$HOST/productpage > /dev/null; sleep 2; done
   ```
