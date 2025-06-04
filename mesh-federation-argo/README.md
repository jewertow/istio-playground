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

1. Deploy gateways:

    ```shell
    keast apply -f egress-gateway.yaml
    kwest apply -f egress-gateway.yaml
    ```
    ```shell
    keast apply -f east/federation-ingress-gateway.yaml
    kwest apply -f west/federation-ingress-gateway.yaml
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