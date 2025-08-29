# BackendTLSPolicy for egress use-cases

## Setup environment

```shell
kind create cluster
```

```shell
kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.3.0/experimental-install.yaml
istioctl install -y \
    --set profile=minimal \
    --set meshConfig.accessLogFile=/dev/stdout \
    --set values.pilot.env.PILOT_ENABLE_ALPHA_GATEWAY_API=true
```

```shell
kubectl label ns default istio-injection=enabled
kubectl apply -f https://raw.githubusercontent.com/istio/istio/refs/heads/master/samples/curl/curl.yaml
```

## Simple TLS origination from sidecar

1. Create a ServiceEntry:

```shell
kubectl apply -f - <<EOF
apiVersion: networking.istio.io/v1
kind: ServiceEntry
metadata:
  name: google
spec:
  hosts:
  - www.google.com
  ports:
  - number: 443
    name: https
    protocol: HTTPS
  resolution: DNS
EOF
```

2. Create a headless Service for google:

```shell
kubectl apply -f - <<EOF
apiVersion: v1
kind: Service
metadata:
  name: google-headless
spec:
  type: ClusterIP
  clusterIP: None
  ports:
  - name: https
    port: 443
    protocol: TCP
EOF
```

3. Generate an EndpointSlice for the google-headless Service:

```shell
IPS=$(dig +short A www.google.com | sort -u)

{
cat <<EOF
apiVersion: discovery.k8s.io/v1
kind: EndpointSlice
metadata:
  name: google-headless
  labels:
    kubernetes.io/service-name: google-headless
addressType: IPv4
endpoints:
- addresses:
EOF

for ip in $IPS; do
  echo "  - \"$ip\""
done

cat <<EOF
ports:
- name: https
  port: 443
  protocol: TCP
EOF
} > endpoint-slice.yaml
kubectl apply -f endpoint-slice.yaml
```

4. Configure routing to HTTPS port for HTTP requests:

```shell
kubectl apply -f - <<EOF
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: google-route-http-to-https
spec:
  parentRefs:
  - kind: ServiceEntry
    group: networking.istio.io
    name: google
  rules:
  - backendRefs:
    - name: google-headless
      port: 443
EOF
```

5. Enable TLS origination:

```shell
kubectl apply -f - <<EOF
apiVersion: gateway.networking.k8s.io/v1alpha3
kind: BackendTLSPolicy
metadata:
  name: google-tls
spec:
  targetRefs:
  - group: ""
    kind: Service
    name: google-headless
  validation:
    hostname: www.google.com
    wellKnownCACertificates: System
EOF
```

6. Send a HTTP request to port 443:

```shell
kubectl exec deploy/curl -c curl -- curl -v -o /dev/null -D - http://www.google.com:443
```

> [!NOTE]
> Look that the HTTP request is being sent to the port 443. This is because the `HTTPRoute` routes requests to the headless service, which is translated into an ORIGINAL_DST cluster, and it does not have associated endpoints, so the port cannot be changed.
