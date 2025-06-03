## Mesh federation with ArgoCD

### Prerequisites

1. GitOps operator.
2. Service Mesh operator.

### Demo

1. Deploy Istio:

    ```shell
    kubectl create namespace istio-cni
    kubectl create namespace istio-system
    kubectl apply -f east-mesh.yaml
    ```

1. Deploy federation ingress gateway:

   ```shell
   kubectl apply -f federation-ingress-gateway.yaml
   ```
