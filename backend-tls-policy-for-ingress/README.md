# BackendTLSPolicy for egress use-cases

### Environment setup

1. Create a KIND cluster:

   ```shell
   curl -sL https://raw.githubusercontent.com/istio/istio/master/samples/kind-lb/setupkind.sh | sh
   ```

1. Install Gateway API CRDs:

   ```shell
   kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.3.0/experimental-install.yaml
   ```

1. Install Istio control plane:

   ```shell
   istioctl install -y \
      --set profile=minimal \
      --set meshConfig.accessLogFile=/dev/stdout \
      --set values.pilot.env.PILOT_ENABLE_ALPHA_GATEWAY_API=true \
      --set values.pilot.image=quay.io/jewertow/pilot:master
   ```

### Deploy a TLS server

1. Generate a self-signed certificate for the server:

   ```shell
   # Generate a self-signed root CA certificate
   openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
     -keyout root-ca.key -out root-ca.crt \
     -subj "/CN=example.com Root CA/O=example.com"

   # Generate a server private key and CSR with SAN
   openssl req -new -nodes -newkey rsa:2048 \
     -keyout server.key -out server.csr \
     -subj "/CN=test.example.com/O=example.com" \
     -reqexts SAN -config <(cat /etc/ssl/openssl.cnf <(printf "\n[SAN]\nsubjectAltName=DNS:test.example.com"))

   # Sign the server certificate with the root CA, including SAN
   openssl x509 -req -in server.csr -CA root-ca.crt -CAkey root-ca.key -CAcreateserial \
     -out server.crt -days 365 -extensions SAN \
     -extfile <(cat /etc/ssl/openssl.cnf <(printf "\n[SAN]\nsubjectAltName=DNS:test.example.com"))
   ```

1. Create secrets for the server and the gateway:

   ```shell
   # Create the Kubernetes TLS secret for the server
   kubectl create secret tls server-tls \
      --key=server.key \
      --cert=server.crt
   # Create a ConfigMap with the root CA certificate
   kubectl create configmap server-ca-cert --from-file=ca.crt=root-ca.crt
   ```

1. Create a ConfigMap for nginx TLS configuration:

   ```shell
   kubectl create configmap nginx-conf --from-literal=default.conf="
   server {
     listen 80;
     server_name _;
     location / {
       return 200 'Hello from nginx HTTP!';
     }
   }
   server {
     listen 443 ssl;
     server_name _;
     ssl_certificate /etc/nginx/tls/tls.crt;
     ssl_certificate_key /etc/nginx/tls/tls.key;
     location / {
       return 200 'Hello from nginx HTTPS!';
     }
   }
   "
   ```

1. Deploy nginx service and deployment exposing ports 80 and 443:

   ```shell
   kubectl apply -f - <<EOF
   apiVersion: apps/v1
   kind: Deployment
   metadata:
     name: server
   spec:
     selector:
       matchLabels:
         app: server
     template:
       metadata:
         labels:
           app: server
       spec:
         containers:
         - name: nginx
           image: nginx:1.25
           ports:
           - containerPort: 80
           - containerPort: 443
           volumeMounts:
           - name: tls
             mountPath: /etc/nginx/tls
             readOnly: true
           - name: nginx-conf
             mountPath: /etc/nginx/conf.d/default.conf
             subPath: default.conf
         volumes:
         - name: tls
           secret:
             secretName: server-tls
         - name: nginx-conf
           configMap:
             name: nginx-conf
   ---
   apiVersion: v1
   kind: Service
   metadata:
     name: server
   spec:
     selector:
       app: server
     ports:
     - name: http
       port: 80
     - name: https
       port: 443
   EOF
   ```

## Expose the server

1. Deploy the gateway:

   ```shell
   kubectl create namespace istio-ingress
   kubectl apply -f - <<EOF
   apiVersion: gateway.networking.k8s.io/v1
   kind: Gateway
   metadata:
     name: gateway
     namespace: istio-ingress
   spec:
     gatewayClassName: istio
     listeners:
     - name: default
       hostname: "*.example.com"
       port: 80
       protocol: HTTP
       allowedRoutes:
         namespaces:
           from: All
   ---
   apiVersion: gateway.networking.k8s.io/v1
   kind: HTTPRoute
   metadata:
     name: http
     namespace: default
   spec:
     parentRefs:
     - name: gateway
       namespace: istio-ingress
     hostnames: ["test.example.com"]
     rules:
     - matches:
       - path:
           type: PathPrefix
           value: /
       backendRefs:
       - name: server
         port: 80
   EOF
   ```

1. Verify connectivity:

   ```shell
   IP=$(kubectl get service gateway-istio -n istio-ingress -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
   curl -v -H "Host: test.example.com" "http://$IP:80/"
   ```

1. Enable simple TLS origination:

   ```shell
   kubectl apply -f - <<EOF
   apiVersion: gateway.networking.k8s.io/v1alpha3
   kind: BackendTLSPolicy
   metadata:
     name: server-tls
   spec:
     targetRefs:
     - group: ""
       kind: Service
       name: server
       sectionName: https
     validation:
       caCertificateRefs:
       - group: ""
         kind: ConfigMap
         name: server-ca-cert
       hostname: test.example.com
   EOF
   ```

1. Update the HTTP route:

   ```shell
   kubectl apply -f - <<EOF
   apiVersion: gateway.networking.k8s.io/v1
   kind: HTTPRoute
   metadata:
     name: http
   spec:
     parentRefs:
     - name: gateway
       namespace: istio-ingress
     hostnames: ["test.example.com"]
     rules:
     - matches:
       - path:
           type: PathPrefix
           value: /
       backendRefs:
       - name: server
         port: 443
   EOF
   ```
