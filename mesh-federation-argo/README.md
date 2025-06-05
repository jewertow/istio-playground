## Mesh federation with ArgoCD

### Prerequisites

1. Install GitOps operator.
2. Install Service Mesh operator.

### Environment setup

1. Setup environment:

    ```shell
    export EAST_AUTH_PATH=
    export WEST_AUTH_PATH=
    ```
    ```shell
    alias keast="KUBECONFIG=$EAST_AUTH_PATH/kubeconfig kubectl"
    alias istioctl-east="istioctl --kubeconfig=$EAST_AUTH_PATH/kubeconfig"
    alias kwest="KUBECONFIG=$WEST_AUTH_PATH/kubeconfig kubectl"
    alias istioctl-west="istioctl --kubeconfig=$WEST_AUTH_PATH/kubeconfig"
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
    make -f common.mk clean
    ```

1. Deploy Istio:

    ```shell
    keast create namespace istio-cni
    keast apply -f istio-cni.yaml
    kwest create namespace istio-cni
    kwest apply -f istio-cni.yaml
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
    ```

1. Configure RBAC for GitOps operator:

    ```shell
    keast apply -f rbac.yaml
    kwest apply -f rbac.yaml
    ```

1. Deploy federation ingress gateway:

    ```shell
    keast apply -f east/federation-ingress-gateway.yaml
    kwest apply -f west/federation-ingress-gateway.yaml
    ```

1. Deploy applications:

    ```shell
    keast create namespace ns1
    keast label namespace ns1 istio-injection=enabled
    keast apply -f https://raw.githubusercontent.com/istio/istio/refs/heads/release-1.26/samples/sleep/sleep.yaml -n ns1
    ```
    ```shell
    kwest create namespace ns2
    kwest label namespace ns2 istio-injection=enabled
    kwest apply -f https://raw.githubusercontent.com/istio/istio/refs/heads/release-1.26/samples/httpbin/httpbin.yaml -n ns2
    ```

1. Export httpbin from the west cluster:

    ```shell
    kwest apply -f west/mesh-federation.yaml
    kwest apply -f west/ns2-federation.yaml
    ```

1. Import httpbin to the east cluster:

    ```shell
    keast apply -f east/mesh-federation.yaml
    keast apply -f east/ns2-federation.yaml
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

```yaml
  sources:
  - repoURL: https://github.com/openshift-service-mesh/istio
    path: manifests/charts/gateway
    targetRevision: release-1.24
    helm:
      valueFiles:
      - $values/west/federation-ingress-gateway-values.yaml
  - repoURL: https://github.com/jewertow/mesh-federation-argo-mesh-admin
    targetRevision: master
    ref: values
```