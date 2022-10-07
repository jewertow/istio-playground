## Tunneling outbound traffic with Istio on Kubernetes or OpenShift

#### 1. Setup Kubernetes or OpenShift cluster
KinD:
```shell
kind create cluster --name istio-tunneling-demo
```
OpenShift:
```shell
crc start
oc login -u kubeadmin https://api.crc.testing:6443
```

#### 2. Install Istio 1.15
First download Istio:
```shell
curl -L https://istio.io/downloadIstio | ISTIO_VERSION=1.15.0 TARGET_ARCH=x86_64 sh -
export PATH=$PWD/istio-1.15.0/bin:$PATH
```
Install on Kubernetes:
```shell
istioctl install -y \
    --set profile=demo \
    --set meshConfig.accessLogFile=/dev/stdout \
    --set meshConfig.outboundTrafficPolicy.mode=REGISTRY_ONLY
```
Install on OpenShift:
```shell
oc adm policy add-scc-to-group anyuid system:serviceaccounts:istio-operator
istioctl operator init
oc adm policy add-scc-to-group anyuid system:serviceaccounts:istio-system
oc apply -f - <<EOF
apiVersion: install.istio.io/v1alpha1
kind: IstioOperator
metadata:
  namespace: istio-system
  name: istio-tunneling-outbound-traffic
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
```shell
kubectl label namespace default istio-injection=enabled
```
On OpenShift additionally set proper security context and network attachment
```shell
oc adm policy add-scc-to-group anyuid system:serviceaccounts:default
cat <<EOF | oc -n default create -f -
apiVersion: "k8s.cni.cncf.io/v1"
kind: NetworkAttachmentDefinition
metadata:
  name: istio-cni
EOF
```

#### 4. Deploy sleep app
```shell
kubectl apply -f https://raw.githubusercontent.com/istio/istio/release-1.15/samples/sleep/sleep.yaml
```
Optionally install Kiali, Prometheus and Grafana:
```shell
kubectl apply -f https://raw.githubusercontent.com/istio/istio/release-1.15/samples/addons/prometheus.yaml
kubectl apply -f https://raw.githubusercontent.com/istio/istio/release-1.15/samples/addons/grafana.yaml
kubectl apply -f https://raw.githubusercontent.com/istio/istio/release-1.15/samples/addons/kiali.yaml
```

#### 5. Create namespace for "external" workloads:
On Kubernetes:
```shell
kubectl create namespace external
```
On OpenShift:
```shell
oc new-project external
oc project default
```
It is important to **NOT** enabling sidecar injection in this namespace.

#### 6. Deploy a forward proxy:
```shell
kubectl apply -f external-forward-proxy/ssl-certificate.yaml -n external
kubectl apply -f external-forward-proxy/ssl-private-key.yaml -n external
kubectl apply -f external-forward-proxy/envoy-config.yaml -n external
kubectl apply -f external-forward-proxy/deployment.yaml -n external
kubectl apply -f external-forward-proxy/service.yaml -n external
```

#### 7. Deploy an external app:
**TODO**: set proper permissions in external-app deployment and remove the security context below
```shell
oc adm policy add-scc-to-group anyuid system:serviceaccounts:external
kubectl apply -f external-app/ssl-certificate.yaml -n external
kubectl apply -f external-app/ssl-private-key.yaml -n external
kubectl apply -f external-app/nginx-config.yaml -n external
kubectl apply -f external-app/deployment.yaml -n external
kubectl apply -f external-app/service.yaml -n external
```

#### 6. Enable tunneling and originating TLS during connection to external-forward-proxy
**TODO**: explain why destination rules must be applied to the "external" namespace
```shell
kubectl apply -f samples/destination-rules.yaml -n external
```

7. Test connection:
```shell
kubectl exec $(kubectl get pods -l app=sleep -n default -o jsonpath='{.items[].metadata.name}') -n default -c sleep -- \
    curl -v http://external-app.external.svc.cluster.local:8080/test/1
kubectl exec $(kubectl get pods -l app=sleep -n default -o jsonpath='{.items[].metadata.name}') -n default -c sleep -- \
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

TODO: add timestamp to external-forward-proxy-logs
