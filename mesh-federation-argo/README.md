## Mesh federation with ArgoCD

### Prerequisites

1. Install GitOps operator.
2. Install Service Mesh operator.

### Demo

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

1. Deploy Istio:

    ```shell
    keast create namespace istio-cni
    keast apply -f istio-cni.yaml
    kwest create namespace istio-cni
    kwest apply -f istio-cni.yaml
    ```
    ```shell
    keast create namespace istio-system
    keast apply -f east/istio.yaml
    kwest create namespace istio-system
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
    kwest apply -f west/ns1-federation.yaml
    ```

1. Import httpbin to the east cluster:

    ```shell
    keast apply -f east/mesh-federation.yaml
    keast apply -f east/ns2-federation.yaml
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