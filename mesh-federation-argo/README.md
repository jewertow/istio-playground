## Mesh federation with ArgoCD

### Prerequisites

1. Install GitOps operator.
2. Install Service Mesh operator.

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
    ```shell
    wget https://raw.githubusercontent.com/istio/istio/release-1.24/tools/certs/common.mk -O common.mk
    wget https://raw.githubusercontent.com/istio/istio/release-1.24/tools/certs/Makefile.selfsigned.mk -O Makefile.selfsigned.mk
    ```

### Demo

1. Generate certificates for Istio CA with common root:

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

1. Deploy Istio:

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

1. Configure RBAC for GitOps operator:

    ```shell
    keast apply -f rbac.yaml
    kwest apply -f rbac.yaml
    kcent apply -f rbac.yaml
    ```

1. Deploy federation ingress gateway in the clusters, which export services:

    ```shell
    keast apply -f east/federation-ingress-gateway.yaml
    kwest apply -f west/federation-ingress-gateway.yaml
    ```

1. Deploy egress gateway in the cluster, which imports services:

   ```shell
   kcent apply -f central/istio-egressgateway.yaml
   kcent apply -f central/istio-ingressgateway.yaml
   ```

1. Deploy applications in the central cluster:

    ```shell
    kcent create namespace ns1
    kcent label namespace ns1 istio-injection=enabled
    kcent apply -f https://raw.githubusercontent.com/istio/istio/refs/heads/release-1.26/samples/bookinfo/networking/bookinfo-gateway.yaml -n ns1
    kcent apply -f https://raw.githubusercontent.com/istio/istio/refs/heads/release-1.26/samples/bookinfo/platform/kube/bookinfo.yaml -n ns1
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

    Send a test request to make sure that everything is installed correctly:
    ```shell
    HOST=$(kcent get routes istio-ingressgateway -n istio-system -o jsonpath='{.spec.host}')
    curl -v http://$HOST/productpage > /dev/null
    ```
   
1. Deploy ratings app in the east cluster:

    ```shell
    keast create namespace ns2
    keast label namespace ns2 istio-injection=enabled
    keast apply -n ns2 -l app=ratings -f https://raw.githubusercontent.com/istio/istio/refs/heads/release-1.26/samples/bookinfo/platform/kube/bookinfo.yaml
    ```

1. Export httpbin from the west cluster:

    ```shell
    kwest apply -f west/mesh-federation.yaml
    kwest apply -f west/ns2-federation.yaml
    ```

1. Import httpbin to the east cluster:

    ```shell
    keast apply -f east/mesh-federation.yaml
    keast apply -f east/ns1-federation.yaml
    ```

1. Send a test request to the imported service:

    ```shell
    keast exec deploy/sleep -n ns1 -c sleep -- curl -v httpbin-service.mesh.global:8000/headers
    ```

#### Enable egress gateway:

1. Deploy egress gateway:

    ```shell
    keast apply -f egress-gateway.yaml
    kwest apply -f egress-gateway.yaml
    ```
