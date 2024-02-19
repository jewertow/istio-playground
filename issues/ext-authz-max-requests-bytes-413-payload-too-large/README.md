#### Steps to reproduce

1. Create KinD cluster:
```shell
kind create cluster --name test
```

2. Install Istio with external authorization settings:
```shell
istioctl install -y -f - <<EOF
apiVersion: install.istio.io/v1alpha1
kind: IstioOperator
metadata:
  name: test
spec:
  profile: default
  meshConfig:
    accessLogFile: /dev/stdout
    extensionProviders:
    - name: "sample-ext-authz-http"
      envoyExtAuthzHttp:
        service: "ext-authz.default.svc.cluster.local"
        port: 8000
        includeRequestHeadersInCheck: ["x-ext-authz"]
        includeRequestBodyInCheck:
          allowPartialMessage: true
          maxRequestBytes: 5000000
          packAsBytes: true
    - name: "sample-ext-authz-grpc"
      envoyExtAuthzGrpc:
        service: "ext-authz.default.svc.cluster.local"
        port: 9000
        includeRequestBodyInCheck:
          allowPartialMessage: true
          maxRequestBytes: 5000000
          packAsBytes: true
EOF
```

3. Enable injection:
```shell
kubectl label namespace default istio-injection=enabled
```

4. Deploy authorization server:
```shell
kubectl apply -f - <<EOF
apiVersion: v1
kind: Service
metadata:
  name: ext-authz
spec:
  ports:
  - name: http
    port: 8000
    targetPort: 8000
  - name: grpc
    port: 9000
    targetPort: 9000
  selector:
    app: ext-authz
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ext-authz
spec:
  selector:
    matchLabels:
      app: ext-authz
  template:
    metadata:
      annotations:
        sidecar.istio.io/inject: "false"
      labels:
        app: ext-authz
    spec:
      containers:
      - image: quay.io/jewertow/ext-authz:ext-auth-fix-2
        imagePullPolicy: IfNotPresent
        name: ext-authz
        ports:
        - containerPort: 8000
        - containerPort: 9000
EOF
```

5. Deploy uploader app:
```shell
kubectl apply -f - <<EOF
apiVersion: v1
kind: Service
metadata:
  name: file-uploader
spec:
  selector:
    app: file-uploader
  ports:
    - name: http
      protocol: TCP
      port: 3000
      targetPort: 3000
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: file-uploader
spec:
  selector:
    matchLabels:
      app: file-uploader
  template:
    metadata:
      labels:
        app: file-uploader
    spec:
      volumes:
        - name: uploads
          emptyDir: {}
      containers:
        - image: twostoryrobot/simple-file-upload
          name: file-uploader
          ports:
          - containerPort: 3000
          env:
          - name: KEY_TESTUSER
            value: /uploads/testuser-file.txt
          volumeMounts:
          - name: uploads
            mountPath: /uploads
EOF
```

5. Expose file uploader through a Gateway:
```shell
kubectl apply -f - <<EOF
apiVersion: networking.istio.io/v1alpha3
kind: Gateway
metadata:
  name: file-uploader
spec:
  selector:
    istio: ingressgateway
  servers:
  - hosts:
    - "*"
    port:
      number: 80
      name: http
      protocol: HTTP
---
apiVersion: networking.istio.io/v1beta1
kind: VirtualService
metadata:
  name: file-uploader
spec:
  hosts:
  - '*'
  gateways:
  - file-uploader
  http:
  - match:
    - uri:
        prefix: /file-upload/
    route:
    - destination:
        host: file-uploader
        port:
          number: 3000
    rewrite:
      uri: /
EOF
```

6. Configure custom authorization:
```shell
kubectl apply -f - <<EOF
apiVersion: security.istio.io/v1beta1
kind: AuthorizationPolicy
metadata:
  name: ext-authz
spec:
  selector:
    matchLabels:
      app: file-uploader
  action: CUSTOM
  provider:
    name: sample-ext-authz-grpc
  rules:
  - {}
EOF
```

8. Generate test files:
```shell
# 500KB
fallocate -l 1000000 test-1
# 1MiB + 1B
fallocate -l 1048577 test-2
```

9. Expose ingress gateway in another terminal:
```shell
kubectl port-forward service/istio-ingressgateway -n istio-system 8080:80
```

10. Upload file `test-1`:
```shell
curl -v POST -H "x-ext-authz: allow" -F 'data=@test-1' \
  "http://localhost:8080/file-upload/upload?key=TESTUSER"
```
The request should succeed and return an output like this:
```
> POST /file-upload/upload?key=TESTUSER HTTP/1.1
> Host: localhost:8080
> User-Agent: curl/7.79.1
> Accept: */*
> x-ext-authz: allow
> Content-Length: 1000198
> Content-Type: multipart/form-data; boundary=------------------------c9bc73108cd2aef4
> 
* We are completely uploaded and fine
* Mark bundle as not supporting multiuse
< HTTP/1.1 201 Created
< x-powered-by: Express
< content-type: text/html; charset=utf-8
< content-length: 17
< etag: W/"11-2tVWPieapG5csoqNQnGkrNqjBFo"
< date: Mon, 19 Feb 2024 19:05:07 GMT
< x-envoy-upstream-service-time: 70
< server: istio-envoy
< 
* Connection #1 to host localhost left intact
Upload successful
```

11. Try to upload file `test-2`, which is too big and the request should fail:
```shell
curl -v POST -H "x-ext-authz: allow" -F 'data=@test-2' \
  "http://localhost:8080/file-upload/upload?key=TESTUSER"
```
The request should fail and return and output like this:
```
> POST /file-upload/upload?key=TESTUSER HTTP/1.1
> Host: localhost:8080
> User-Agent: curl/7.79.1
> Accept: */*
> x-ext-authz: allow
> Content-Length: 1048775
> Content-Type: multipart/form-data; boundary=------------------------2250fd4b2ba26870
> Expect: 100-continue
> 
* Mark bundle as not supporting multiuse
< HTTP/1.1 100 Continue
* We are completely uploaded and fine
* Mark bundle as not supporting multiuse
< HTTP/1.1 413 Payload Too Large
< content-length: 17
< content-type: text/plain
< date: Mon, 19 Feb 2024 19:07:54 GMT
< server: istio-envoy
< x-envoy-upstream-service-time: 2
< 
* Connection #1 to host localhost left intact
Payload Too Large
```

#### Workarounds

1. HTTP buffer:
```shell
kubectl apply -f - <<EOF
apiVersion: networking.istio.io/v1alpha3
kind: EnvoyFilter
metadata:
  name: size-limit
spec:
  workloadSelector:
    labels:
      app: file-uploader
  configPatches:
  - applyTo: HTTP_FILTER
    match:
      context: SIDECAR_INBOUND
      listener:
        filterChain:
          filter:
            name: envoy.filters.network.http_connection_manager
            subFilter:
              name: envoy.filters.http.ext_authz
    patch:
      operation: INSERT_BEFORE
      value:
        name: envoy.filters.http.buffer
        typed_config:
          "@type": type.googleapis.com/envoy.extensions.filters.http.buffer.v3.Buffer
          maxRequestBytes: 2000000 # 2MB
EOF
```

2. Listener per connection buffer limit:
```shell
kubectl apply -f - <<EOF
apiVersion: networking.istio.io/v1alpha3
kind: EnvoyFilter
metadata:
  name: listener-per-connection-buffer-limit
spec:
  workloadSelector:
    labels:
      app: file-uploader
  configPatches:
  - applyTo: LISTENER
    match:
      listener:
        name: virtualInbound
    patch:
      operation: MERGE
      value:
        per_connection_buffer_limit_bytes: 2000000 # 2MB
EOF
```

#### Solution

```shell
istioctl install -y -f - <<EOF
apiVersion: install.istio.io/v1alpha1
kind: IstioOperator
metadata:
  name: test
spec:
  hub: quay.io/jewertow
  tag: extauthz
  profile: default
  meshConfig:
    accessLogFile: /dev/stdout
    extensionProviders:
    - name: "sample-ext-authz-http"
      envoyExtAuthzHttp:
        service: "ext-authz.default.svc.cluster.local"
        port: 8000
        includeRequestHeadersInCheck: ["x-ext-authz"]
        includeRequestBodyInCheck:
          allowPartialMessage: true
          maxRequestBytes: 5000000
          packAsBytes: true
    - name: "sample-ext-authz-grpc"
      envoyExtAuthzGrpc:
        service: "ext-authz.default.svc.cluster.local"
        port: 9000
        includeRequestBodyInCheck:
          allowPartialMessage: true
          maxRequestBytes: 5000000
          packAsBytes: true
EOF
```
