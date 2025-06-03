1. Install control plane:

    ```shell
    helm template -s templates/ambient/istio.yaml . \
      --set localCluster=east \
      --set remoteCluster=west \
      --set debug=false \
      | istioctl --kubeconfig=east.kubeconfig install -y -f -
    ```
    ```shell
    helm template -s templates/ambient/istio.yaml . \
      --set localCluster=west \
      --set remoteCluster=east \
      --set debug=false \
      | istioctl --kubeconfig=west.kubeconfig install -y -f -
    ```

1. Install Gateway API CRDs:

   ```shell
   keast apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.3.0/standard-install.yaml
   kwest apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.3.0/standard-install.yaml
   ```

1. Deploy east-west gateways:

   ```shell
   helm template -s templates/ambient/east-west-gw.yaml . --set localCluster=east | keast apply -f - 
   helm template -s templates/ambient/east-west-gw.yaml . --set localCluster=east | kwest apply -f - 
   ```

1. Deploy apps:

   ```shell
   keast label namespace default istio.io/dataplane-mode=ambient
   keast apply -f https://raw.githubusercontent.com/istio/istio/refs/heads/release-1.26/samples/sleep/sleep.yaml
   ```
   ```shell
   kwest label namespace default istio.io/dataplane-mode=ambient
   kwest apply -f https://raw.githubusercontent.com/istio/istio/refs/heads/release-1.26/samples/sleep/sleep.yaml
   kwest apply -f https://raw.githubusercontent.com/istio/istio/refs/heads/release-1.26/samples/httpbin/httpbin.yaml
   ```

1. Send a test request in west cluster:

   ```shell
   kwest exec deploy/sleep -c sleep -- curl -v httpbin:8000/headers
   ```
