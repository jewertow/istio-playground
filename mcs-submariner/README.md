## Istio and Submariner

1. Deploy Istio in cluster 1:
```shell
kubectl config use-context cluster1
istioctl install -y -n istio-system -f cp-1.yaml
```

2. Deploy Istio in cluster 2:
```shell
kubectl config use-context cluster2
istioctl install -y -n istio-system -f cp-2.yaml
```

3. Deploy httbin in namespace foo in cluster 1:
```
kubectl config use-context cluster1
kubectl create namespace foo
kubectl label namespace foo istio-injection=enabled
kubectl apply -f https://raw.githubusercontent.com/istio/istio/release-1.17/samples/httpbin/httpbin.yaml -n foo
kubectl apply -f service-export.yaml
```

4. Check logs of istiod in cluster 2:
```
kubectl logs $(kubectl get pods -l app=istiod -n istio-system -o jsonpath={.items..metadata.name}) -n istio-system
```

There should be a warning like this:
```
warn	kube	failed processing add event for ServiceImport submariner-operator/httpbin-foo-cluster2 in cluster cluster2. No matching service found in cluster
```

Istio tries to find service httpbin-foo-cluster2 in namespace submariner-operator in the local cluster.


### Important to note

Creating namespace foo and service httpbin in the cluster2 does not solve the problem, because Istio tries to resolve httpbin-foo-cluster2.submariner-operator.

