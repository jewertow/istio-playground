## OSSM 3 - locality failover in multi-primary deployment

### Prerequisites

1. Create 2 OpenShift clusters.
2. Install OpenShift Service Mesh Operator v3.0.0-tp.2.
3. Make sure that you have installed `kubectl`, `istioctl` and `openssl`.

### Deploy control planes

1. Setup environment variables:
```shell
export CTX_CLUSTER1=<cluster1-ctx>
export CTX_CLUSTER2=<cluster2-ctx>
export ISTIO_VERSION=1.23.0
```

2. Create istio-system namespace in each cluster:
```shell
kubectl get ns istio-system --context "${CTX_CLUSTER1}" || kubectl create namespace istio-system --context "${CTX_CLUSTER1}"
kubectl get ns istio-system --context "${CTX_CLUSTER2}" || kubectl create namespace istio-system --context "${CTX_CLUSTER2}"
```

3. Create shared root certificate:
```shell
openssl genrsa -out root-key.pem 4096
cat <<EOF > root-ca.conf
[ req ]
encrypt_key = no
prompt = no
utf8 = yes
default_md = sha256
default_bits = 4096
req_extensions = req_ext
x509_extensions = req_ext
distinguished_name = req_dn
[ req_ext ]
subjectKeyIdentifier = hash
basicConstraints = critical, CA:true
keyUsage = critical, digitalSignature, nonRepudiation, keyEncipherment, keyCertSign
[ req_dn ]
O = Istio
CN = Root CA
EOF

openssl req -sha256 -new -key root-key.pem \
  -config root-ca.conf \
  -out root-cert.csr

openssl x509 -req -sha256 -days 3650 \
  -signkey root-key.pem \
  -extensions req_ext -extfile root-ca.conf \
  -in root-cert.csr \
  -out root-cert.pem
```

4. Create intermediate certificates:
```shell
for cluster in west east; do
  mkdir $cluster

  openssl genrsa -out ${cluster}/ca-key.pem 4096
  cat <<EOF > ${cluster}/intermediate.conf
[ req ]
encrypt_key = no
prompt = no
utf8 = yes
default_md = sha256
default_bits = 4096
req_extensions = req_ext
x509_extensions = req_ext
distinguished_name = req_dn
[ req_ext ]
subjectKeyIdentifier = hash
basicConstraints = critical, CA:true, pathlen:0
keyUsage = critical, digitalSignature, nonRepudiation, keyEncipherment, keyCertSign
subjectAltName=@san
[ san ]
DNS.1 = istiod.istio-system.svc
[ req_dn ]
O = Istio
CN = Intermediate CA
L = $cluster
EOF

  openssl req -new -config ${cluster}/intermediate.conf \
    -key ${cluster}/ca-key.pem \
    -out ${cluster}/cluster-ca.csr

  openssl x509 -req -sha256 -days 3650 \
    -CA root-cert.pem \
    -CAkey root-key.pem -CAcreateserial \
    -extensions req_ext -extfile ${cluster}/intermediate.conf \
    -in ${cluster}/cluster-ca.csr \
    -out ${cluster}/ca-cert.pem

  cat ${cluster}/ca-cert.pem root-cert.pem \
    > ${cluster}/cert-chain.pem
  cp root-cert.pem ${cluster}
done
```

5. Push the intermediate CAs to each cluster:
```shell
kubectl --context "${CTX_CLUSTER1}" label namespace istio-system topology.istio.io/network=network1
kubectl get secret -n istio-system --context "${CTX_CLUSTER1}" cacerts || kubectl create secret generic cacerts -n istio-system --context "${CTX_CLUSTER1}" \
  --from-file=east/ca-cert.pem \
  --from-file=east/ca-key.pem \
  --from-file=east/root-cert.pem \
  --from-file=east/cert-chain.pem
kubectl --context "${CTX_CLUSTER2}" label namespace istio-system topology.istio.io/network=network2
kubectl get secret -n istio-system --context "${CTX_CLUSTER2}" cacerts || kubectl create secret generic cacerts -n istio-system --context "${CTX_CLUSTER2}" \
  --from-file=west/ca-cert.pem \
  --from-file=west/ca-key.pem \
  --from-file=west/root-cert.pem \
  --from-file=west/cert-chain.pem
```

6. Install Istio in each clusters:
```shell
kubectl --context "${CTX_CLUSTER1}" create namespace istio-cni
kubectl apply --context "${CTX_CLUSTER1}" -f - <<EOF
apiVersion: sailoperator.io/v1alpha1
kind: IstioCNI
metadata:
  name: default
spec:
  version: v${ISTIO_VERSION}
  namespace: istio-cni
---
apiVersion: sailoperator.io/v1alpha1
kind: Istio
metadata:
  name: default
spec:
  version: v${ISTIO_VERSION}
  namespace: istio-system
  values:
    meshConfig:
      accessLogFile: /dev/stdout
    global:
      meshID: mesh1
      multiCluster:
        clusterName: cluster1
      network: network1
    pilot:
      env:
        ROOT_CA_DIR: /etc/cacerts
EOF
```
```shell
kubectl --context "${CTX_CLUSTER2}" create namespace istio-cni
kubectl apply --context "${CTX_CLUSTER2}" -f - <<EOF
apiVersion: sailoperator.io/v1alpha1
kind: IstioCNI
metadata:
  name: default
spec:
  version: v${ISTIO_VERSION}
  namespace: istio-cni
---
apiVersion: sailoperator.io/v1alpha1
kind: Istio
metadata:
  name: default
spec:
  version: v${ISTIO_VERSION}
  namespace: istio-system
  values:
    meshConfig:
      accessLogFile: /dev/stdout
    global:
      meshID: mesh1
      multiCluster:
        clusterName: cluster2
      network: network2
    pilot:
      env:
        ROOT_CA_DIR: /etc/cacerts
EOF
```

8. Wait for control planes to be ready:
```shell
kubectl wait --context "${CTX_CLUSTER1}" --for=condition=Ready istios/default --timeout=3m
kubectl wait --context "${CTX_CLUSTER2}" --for=condition=Ready istios/default --timeout=3m
```

9. Create east-west gateway in each cluster:
```shell
kubectl apply --context "${CTX_CLUSTER1}" -f https://raw.githubusercontent.com/istio-ecosystem/sail-operator/main/docs/multicluster/east-west-gateway-net1.yaml
kubectl apply --context "${CTX_CLUSTER2}" -f https://raw.githubusercontent.com/istio-ecosystem/sail-operator/main/docs/multicluster/east-west-gateway-net2.yaml
```

10. Install a remote secret in cluster2 that provides access to the cluster1 API server:
```shell
istioctl create-remote-secret \
  --context="${CTX_CLUSTER1}" \
  --name=cluster1 | \
  kubectl apply -f - --context="${CTX_CLUSTER2}"
```

11. Install a remote secret in cluster1 that provides access to the cluster2 API server:
```shell
istioctl create-remote-secret \
  --context="${CTX_CLUSTER2}" \
  --name=cluster2 | \
  kubectl apply -f - --context="${CTX_CLUSTER1}"
```

### Deploy applications

1. Deploy sample application in cluster1:
```shell
kubectl --context="${CTX_CLUSTER1}" create namespace sample
kubectl --context="${CTX_CLUSTER1}" label namespace sample istio-injection=enabled
kubectl apply --context="${CTX_CLUSTER1}" \
  -f "https://raw.githubusercontent.com/istio/istio/${ISTIO_VERSION}/samples/helloworld/helloworld.yaml" \
  -l service=helloworld -n sample
kubectl apply --context="${CTX_CLUSTER1}" \
  -f "https://raw.githubusercontent.com/istio/istio/${ISTIO_VERSION}/samples/helloworld/helloworld.yaml" \
  -l version=v1 -n sample
kubectl apply --context="${CTX_CLUSTER1}" \
  -f "https://raw.githubusercontent.com/istio/istio/${ISTIO_VERSION}/samples/sleep/sleep.yaml" -n sample
```

2. Deploy sample application in cluster2:
```shell
kubectl --context="${CTX_CLUSTER2}" create namespace sample
kubectl --context="${CTX_CLUSTER2}" label namespace sample istio-injection=enabled
kubectl apply --context="${CTX_CLUSTER2}" \
  -f "https://raw.githubusercontent.com/istio/istio/${ISTIO_VERSION}/samples/helloworld/helloworld.yaml" \
  -l service=helloworld -n sample
kubectl apply --context="${CTX_CLUSTER2}" \
  -f "https://raw.githubusercontent.com/istio/istio/${ISTIO_VERSION}/samples/helloworld/helloworld.yaml" \
  -l version=v2 -n sample
kubectl apply --context="${CTX_CLUSTER2}" \
  -f "https://raw.githubusercontent.com/istio/istio/${ISTIO_VERSION}/samples/sleep/sleep.yaml" -n sample
```

3. Wait for apps to be ready:
```shell
kubectl --context="${CTX_CLUSTER1}" wait --for condition=available -n sample deployment/helloworld-v1
kubectl --context="${CTX_CLUSTER2}" wait --for condition=available -n sample deployment/helloworld-v2
kubectl --context="${CTX_CLUSTER1}" wait --for condition=available -n sample deployment/sleep
kubectl --context="${CTX_CLUSTER2}" wait --for condition=available -n sample deployment/sleep
```

### Demo

1. Send 10 requests to helloworld server:
```shell
for i in {0..9}; do
  kubectl exec --context="${CTX_CLUSTER1}" -n sample -c sleep \
    "$(kubectl get pod --context="${CTX_CLUSTER1}" -n sample -l \
    app=sleep -o jsonpath='{.items[0].metadata.name}')" \
    -- curl -sS helloworld.sample:5000/hello;
done
```

You should see responses only from helloworld-v1 deployed in cluster-1:
```
Hello version: v1, instance: helloworld-v1-69ff8fc747-vlzg9
...
```

2. Expose helloworld-v2 from cluster-2 to cluster-1:
```shell
kubectl apply -n istio-system --context "${CTX_CLUSTER2}" -f - <<EOF
apiVersion: networking.istio.io/v1alpha3
kind: Gateway
metadata:
  name: cross-network-gateway
spec:
  selector:
    istio: eastwestgateway
  servers:
    - port:
        number: 15443
        name: tls
        protocol: TLS
      tls:
        mode: AUTO_PASSTHROUGH
      hosts:
        - "helloworld.sample.svc.cluster.local"
EOF
```

3. Send 10 requests again:
```shell
for i in {0..9}; do
  kubectl exec --context="${CTX_CLUSTER1}" -n sample -c sleep \
    "$(kubectl get pod --context="${CTX_CLUSTER1}" -n sample -l \
    app=sleep -o jsonpath='{.items[0].metadata.name}')" \
    -- curl -sS helloworld.sample:5000/hello;
done
```

And now you should see response from both clusters.
```
Hello version: v2, instance: helloworld-v2-779454bb5f-4z665
Hello version: v1, instance: helloworld-v1-69ff8fc747-vlzg9
...
```

### Locality failover

1. Get regions of your nodes, and make sure that nodes within a cluster belong to the same region:
```shell
kubectl --context "${CTX_CLUSTER1}" get nodes -o yaml | grep "topology.kubernetes.io/region"
```
```shell
kubectl --context "${CTX_CLUSTER2}" get nodes -o yaml | grep "topology.kubernetes.io/region"
```

2. Export region variables:
```shell
export REGION1=<region-of-nodes-from-cluster-1>
export REGION2=<region-of-nodes-from-cluster-2>
```

3. Create `DestinationRule` for locality failover:
```shell
kubectl --context="${CTX_CLUSTER1}" apply -n sample -f - <<EOF
apiVersion: networking.istio.io/v1
kind: DestinationRule
metadata:
  name: helloworld
spec:
  host: helloworld.sample.svc.cluster.local
  trafficPolicy:
    loadBalancer:
      localityLbSetting:
        enabled: true
        failover:
        - from: ${REGION1}
          to: ${REGION2}
    outlierDetection:
      consecutive5xxErrors: 1
      interval: 1s
      baseEjectionTime: 1m
EOF
```

4. Send requests in a loop to helloworld again:
```shell
for i in {0..999}; do                                                                        
  kubectl exec --context="${CTX_CLUSTER1}" -n sample -c sleep \
    "$(kubectl get pod --context="${CTX_CLUSTER1}" -n sample -l \
    app=sleep -o jsonpath='{.items[0].metadata.name}')" \
    -- curl -sS helloworld.sample:5000/hello;
done
```

You should see that traffic is being sent to helloworld-v1:
```
Hello version: v1, instance: helloworld-v1-69ff8fc747-vlzg9
Hello version: v1, instance: helloworld-v1-69ff8fc747-vlzg9
Hello version: v1, instance: helloworld-v1-69ff8fc747-vlzg9
...
```

Trigger failover in cluster-1:
```shell
kubectl --context="${CTX_CLUSTER1}" scale deployment helloworld-v1 --replicas=0 -n sample
```

Now you should see responses from cluster-2:
```
Hello version: v2, instance: helloworld-v2-779454bb5f-4z665
Hello version: v2, instance: helloworld-v2-779454bb5f-4z665
Hello version: v2, instance: helloworld-v2-779454bb5f-4z665
...
```

Scale helloworld-v1 up and you should see response from cluster-1 again:
```shell
kubectl --context="${CTX_CLUSTER1}" scale deployment helloworld-v1 --replicas=1 -n sample
```
