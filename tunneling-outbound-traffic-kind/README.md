## Tunneling outbound traffic with Istio inside k8s

#### 1. Setup KinD or OpenShift cluster
```shell
kind create cluster --name istio-tunneling-demo
# in case of testing on OpenShift
crc start
oc login -u kubeadmin https://api.crc.testing:6443
```

#### 2. Install Istio 1.15
```shell
curl -L https://istio.io/downloadIstio | ISTIO_VERSION=1.15.0 TARGET_ARCH=x86_64 sh -
export PATH=$PWD/istio-1.15.0/bin:$PATH
# on k8s
istioctl install -y \
    --set profile=demo \
    --set meshConfig.accessLogFile=/dev/stdout \
    --set meshConfig.outboundTrafficPolicy.mode=REGISTRY_ONLY
# on openshift
oc adm policy add-scc-to-group anyuid system:serviceaccounts:istio-operator
istioctl operator init
oc adm policy add-scc-to-group anyuid system:serviceaccounts:istio-system
oc apply -f - <<EOF
apiVersion: install.istio.io/v1alpha1
kind: IstioOperator
metadata:
  namespace: istio-system
  name: example-istiocontrolplane
spec:
  profile: openshift
  components:
    egressGateways:
    - name: istio-egressgateway
      enabled: true
  meshConfig:
    accessLogFile: "/dev/stdout"
    outboundTrafficPolicy:
      mode: REGISTRY_ONLY
EOF
```

#### 3. Enable sidecar injection:
```sh
kubectl label namespace default istio-injection=enabled
# on openshift additionally set proper security context and network attachment
oc adm policy add-scc-to-group anyuid system:serviceaccounts:default
cat <<EOF | oc -n default create -f -
apiVersion: "k8s.cni.cncf.io/v1"
kind: NetworkAttachmentDefinition
metadata:
  name: istio-cni
EOF
```

#### 4. Deploy sleep app:
```sh
kubectl apply -f https://raw.githubusercontent.com/istio/istio/release-1.15/samples/sleep/sleep.yaml
```

#### 5. Create namespace for "external" workloads:
```shell
kubectl create namespace external
# in case of testing on OpenShift
oc new-project external
```

#### 6. Deploy Envoy acting as a forward proxy:
```shell
kubectl apply -f external-forward-proxy/ssl-certificate.yaml -n external
kubectl apply -f external-forward-proxy/ssl-private-key.yaml -n external
kubectl apply -f external-forward-proxy/envoy-config.yaml -n external
kubectl apply -f external-forward-proxy/deployment.yaml -n external
kubectl apply -f external-forward-proxy/service.yaml -n external
```

#### 7. Deploy target server:
```shell
# TODO: set proper permissions in external-app deployment and remove the security context below
oc adm policy add-scc-to-group anyuid system:serviceaccounts:external
kubectl apply -f external-app/ssl-certificate.yaml -n external
kubectl apply -f external-app/ssl-private-key.yaml -n external
kubectl apply -f external-app/nginx-config.yaml -n external
kubectl apply -f external-app/deployment.yaml -n external
kubectl apply -f external-app/service.yaml -n external
```

#### 6. Enable tunneling and originating TLS during connection to external-forward-proxy
```shell
kubectl apply -f samples/https-proxy/destination-rules.yaml -n external
```

7. Test connection:
```shell
kubectl exec $(kubectl get pods -l app=sleep -o jsonpath='{.items[].metadata.name}') -c sleep -- \
    curl -v http://external-app.external.svc.cluster.local:8080/test/1
kubectl exec $(kubectl get pods -l app=sleep -o jsonpath='{.items[].metadata.name}') -c sleep -- \
    curl -v --insecure https://external-app.external.svc.cluster.local/test/2
```

Cleanup:
```shell
kubectl delete -f external-forward-proxy/service.yaml -n external
kubectl delete -f external-forward-proxy/deployment.yaml -n external
kubectl delete -f external-forward-proxy/ssl-certificate.yaml -n external
kubectl delete -f external-forward-proxy/ssl-private-key.yaml -n external
kubectl delete -f external-forward-proxy/envoy-config.yaml -n external

kubectl delete -f external-app/service.yaml -n external
kubectl delete -f external-app/deployment.yaml -n external
kubectl delete -f external-app/nginx-config.yaml -n external
kubectl delete -f external-app/ssl-certificate.yaml -n external
kubectl delete -f external-app/ssl-private-key.yaml -n external

kubectl delete -f https://raw.githubusercontent.com/istio/istio/release-1.13/samples/sleep/sleep.yaml

kind delete cluster --name istio-tunneling-demo
```
