## Steps to reproduce 400 DPE error in multi-tenant mesh

1. Install Service Mesh Operator.

2. Deploy multi-tenant control plane and include `client` namespace in the mesh:
```shell
oc new-project istio-system
oc apply -n istio-system -f - <<EOF
apiVersion: maistra.io/v2
kind: ServiceMeshControlPlane
metadata:
  name: basic
spec:
  addons:
    kiali:
      enabled: false
    prometheus:
      enabled: false
    grafana:
      enabled: false
  gateways:
    enabled: false
  general:
    logging:
      componentLevels:
        default: info
  proxy:
    accessLogging:
      file:
        name: /dev/stdout
  tracing:
    type: None
---
apiVersion: maistra.io/v1
kind: ServiceMeshMemberRoll
metadata:
  name: default
spec:
  members:
  - client
  - apm-server
EOF
```

3. Deploy fake Vault:
```shell
oc new-project vault-controller
oc apply -n vault-controller -f - <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: vault-config
data:
  nginx.conf: |-
    events {}
    http {
      log_format main '$remote_addr - $remote_user [$time_local]  $status "$request" $body_bytes_sent "$http_referer" "$http_user_agent" "$http_x_forwarded_for"';
      access_log /var/log/nginx/access.log main;
      error_log  /var/log/nginx/error.log;
      server {
        listen      443 ssl;
        server_name vault.vault-controller.svc.cluster.local;

        ssl_certificate         /etc/pki/tls/certs/vault.vault-controller.svc.cluster.local.crt;
        ssl_certificate_key     /etc/pki/tls/private/vault.vault-controller.svc.cluster.local.key;

        location / {
            default_type application/json;
            return 200 '{"message": "Hello, this is Vault!"}';
        }
      }
    }
  vault.vault-controller.svc.cluster.local.crt: |-
    -----BEGIN CERTIFICATE-----
    MIIDpzCCAo+gAwIBAgIUKV1NBADzr+byKrlmPy3Y1JtvI9QwDQYJKoZIhvcNAQEL
    BQAwNjE0MDIGA1UEAwwrY2EudmF1bHQudmF1bHQtY29udHJvbGxlci5zdmMuY2x1
    c3Rlci5sb2NhbDAeFw0yNDA4MDcwODI3NTFaFw0yNTA4MDcwODI3NTFaMDMxMTAv
    BgNVBAMMKHZhdWx0LnZhdWx0LWNvbnRyb2xsZXIuc3ZjLmNsdXN0ZXIubG9jYWww
    ggEiMA0GCSqGSIb3DQEBAQUAA4IBDwAwggEKAoIBAQCqPokO0apbaTG335REW9fS
    zkxSvT2sqpB4e1XQPCZKMmkYeb6DezeuE7UwBaD+eLacjFhytRxS8od/SUyL4a6d
    GRBqZub6eKM5cxt+JXYBF9t2M7/RDjJarki3IiryARouK8aj9fW9wka3uJSbSHJv
    UWQ2E00sF0vM+7a+R9U+zI9UKG8DDVt9QkMRjyc8ChMI1kg34b7LFk4qIzvMYOAh
    4D32k/HavS+p/oJSm7P/bc/7KwpuQ/qJA57XTkJ5H3ecSho1QHDfxk7WGbwqCMLF
    1EvyEqmOPP8HGc0SXioTcGc/IblwEobupvgUEECZBBohesNaHicxsrWoPWkZbNgb
    AgMBAAGjga8wgawwCQYDVR0TBAIwADALBgNVHQ8EBAMCBeAwHQYDVR0lBBYwFAYI
    KwYBBQUHAwIGCCsGAQUFBwMBMDMGA1UdEQQsMCqCKHZhdWx0LnZhdWx0LWNvbnRy
    b2xsZXIuc3ZjLmNsdXN0ZXIubG9jYWwwHQYDVR0OBBYEFDnsRqREmi1DPdGlaY0l
    zapvLZBEMB8GA1UdIwQYMBaAFCTaDxHPGdXqiTG3WVDNrxEQc2ZgMA0GCSqGSIb3
    DQEBCwUAA4IBAQCFmeKirr2Yv43pROkoNzKlLc1wTzi5uNP6QEJa9w12Or/7F1Sn
    4R1leEpRQK6m35serRImI9kiCeICIZxWT1LBm7Egk4EbZmlomCriFw7uo8qJzPbF
    skm0uIqdxmnSdlCeLepfg2/o6m9H4NfChUhZ/OPVyygLuTophdYx8w1zE4WVN4Pk
    Flnw1oQe5QCdk/mrKUg+WJKzoyJyUS8jxWxRUtzZkYmSNWD9E6bAMpod0YGuFPWR
    CURV16826DNPozk1PmtGkyDAMBSxosPDPFNSlWPbJTHxBqZadvDNO08m74OXCuMj
    8saxgqvaCrVD8CWvUSPlQU8SbavF+dM0RJYa
    -----END CERTIFICATE-----
  vault.vault-controller.svc.cluster.local.key: |-
    -----BEGIN PRIVATE KEY-----
    MIIEvQIBADANBgkqhkiG9w0BAQEFAASCBKcwggSjAgEAAoIBAQCqPokO0apbaTG3
    35REW9fSzkxSvT2sqpB4e1XQPCZKMmkYeb6DezeuE7UwBaD+eLacjFhytRxS8od/
    SUyL4a6dGRBqZub6eKM5cxt+JXYBF9t2M7/RDjJarki3IiryARouK8aj9fW9wka3
    uJSbSHJvUWQ2E00sF0vM+7a+R9U+zI9UKG8DDVt9QkMRjyc8ChMI1kg34b7LFk4q
    IzvMYOAh4D32k/HavS+p/oJSm7P/bc/7KwpuQ/qJA57XTkJ5H3ecSho1QHDfxk7W
    GbwqCMLF1EvyEqmOPP8HGc0SXioTcGc/IblwEobupvgUEECZBBohesNaHicxsrWo
    PWkZbNgbAgMBAAECggEASfcQgiU60CtUhBA58Tc7/iVOSLZaiN20Ffxz7JxtgFgF
    jDI8wRA0QUfjtSEE8PqOUFaziObCDxG7J+S3QqEDRdLhbHEX0mO+etPVcomhCtmM
    Kn9SS+hQnVBSXGqWYP10m/G+BHd01ISHSAQEYLDpsw6YLNxW75yRfNYx79ryvazZ
    eKiVYbVM1XPK8sqAZjsyaCMcj3lgrTh0tUWHad0WhCRQKLnclZ0Z1F4KFo3M8ERw
    iwne8QvuR8vQn+VSbks0FbbodMAv0/8abomj/GtZx8WAlcTQAGj2XGbvh/QtXthP
    fIwiB7IKVRPpijEDqg4DFUiiQ/c0NzHmL6vcJm66uQKBgQDhiTG1CaDOpIiSTEfc
    ajRUKZgVjKUvCSCp2cpPOGf2i6H4ysoMZ7Hq3AofuesUrkAYzGOYc71ePE8P+ozl
    cBQ8NUFhtF8hiH8UYnmr7Kf+JWl/68f62G0hyuQtdUYrBwNHy4gcKRl69jzH4zRs
    0DEycHF4v2tAvR4Eq1LM3gR+YwKBgQDBPWlwnsAAp68OJgLZFEopdIWVTm3u6mKz
    erSY6jnHHAqmtkmZWxhmfk5hDb4Lsj+/k2smcpA4AnC38/TkLynqDw3zq6qHNnQQ
    8JaD1Yo/+Zung9KKTexk5PNwLdk3CeTKyUyoIpvdnf3xN979JWaT9RlszMqbfIOh
    4fvqKpPw6QKBgBh7VgP62ZPU1GZdFWfdt3RzV2jvbXbfnMYTOBzFWLOwkJJ7INeb
    4fpGjGrJObVy/M40UZNY7PNvxH1Ni0HUmr22YjSC6diwAmtqDR8Wf13dHcifBYQ7
    Pg1vArnUgxtklXyToWC9LWDlnc9s4GH3b3+0KP0cej36yWlkV4aZiw9VAoGAaEgi
    6aLSDMhxINqEeO+JIhv+ptdfXipgv2i9ozProDbSzKrcxwSxA0awN5H5+EfmPRVq
    IqJ6j69JcwwVITsOjIA5UEFY0oUhV67uGxEW/XVPebQa34YzxzMC6Ivlh90v+ftu
    AeJDaPKFAzLahJQ1ai0/3kYaJJSqWKciknkNw1kCgYEA3eHW8f/MM7wqoCw72/SH
    7kmxN2BCpjTizl8fQHKDccWnp35iPeeMzpxw7a73sWJDi144Z6A2uR2N1cGNkhSI
    hIYf4yIu+mIyvano1PliLHlv46+WXrnQmmSwQ8NB9FoCA/lqKShDj78pUlrKhAVF
    8RuJME2dsqLgRT7hefWQyaw=
    -----END PRIVATE KEY-----
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: vault
spec:
  selector:
    matchLabels:
      app: vault
  template:
    metadata:
      labels:
        app: vault
    spec:
      containers:
      - name: vault
        image: nginx:1.27.0
        volumeMounts:
        - name: vault-config
          mountPath: /etc/nginx/nginx.conf
          subPath: nginx.conf
        - name: vault-config
          mountPath: /etc/pki/tls/certs/vault.vault-controller.svc.cluster.local.crt
          subPath: vault.vault-controller.svc.cluster.local.crt
        - name: vault-config
          mountPath: /etc/pki/tls/private/vault.vault-controller.svc.cluster.local.key
          subPath: vault.vault-controller.svc.cluster.local.key
        - name: var-volume
          mountPath: /var/log/nginx
          readOnly: false
        - name: var-volume
          mountPath: /var/cache/nginx
          readOnly: false
        - name: var-volume
          mountPath: /var/run
          readOnly: false
        - name: var-volume
          mountPath: /etc/nginx/conf.d/
          readOnly: false
      securityContext:
        sysctls:
        - name: net.ipv4.ip_unprivileged_port_start
          value: "0"
      volumes:
      - name: vault-config
        configMap:
          name: vault-config
      - name: var-volume
        emptyDir: {}
---
apiVersion: v1
kind: Service
metadata:
  name: vault
spec:
  selector:
    app: vault
  ports:
  - name: vault
    port: 8200
    protocol: TCP
    targetPort: 443
  type: ClusterIP
EOF
```

4. Deploy client app:
```shell
oc new-project client
oc apply -f https://raw.githubusercontent.com/maistra/istio/maistra-2.5/samples/sleep/sleep.yaml -n client
```
Once it's ready, you can send a test request to vault:
```shell
oc exec deploy/sleep -n client -- curl -vk https://vault.vault-controller.svc.cluster.local:8200
```
You should receive an output like this:
```
* IPv6: (none)
* IPv4: 10.217.4.81
*   Trying 10.217.4.81:8200...
* Connected to vault.vault-controller.svc.cluster.local (10.217.4.81) port 8200
* ALPN: curl offers h2,http/1.1
} [5 bytes data]
* TLSv1.3 (OUT), TLS handshake, Client hello (1):
} [512 bytes data]
* TLSv1.3 (IN), TLS handshake, Server hello (2):
{ [122 bytes data]
* TLSv1.3 (IN), TLS handshake, Encrypted Extensions (8):
{ [25 bytes data]
* TLSv1.3 (IN), TLS handshake, Certificate (11):
{ [952 bytes data]
* TLSv1.3 (IN), TLS handshake, CERT verify (15):
{ [264 bytes data]
* TLSv1.3 (IN), TLS handshake, Finished (20):
{ [52 bytes data]
* TLSv1.3 (OUT), TLS change cipher, Change cipher spec (1):
} [1 bytes data]
* TLSv1.3 (OUT), TLS handshake, Finished (20):
} [52 bytes data]
* SSL connection using TLSv1.3 / TLS_AES_256_GCM_SHA384 / x25519 / RSASSA-PSS
* ALPN: server accepted http/1.1
* Server certificate:
*  subject: CN=vault.vault-controller.svc.cluster.local
*  start date: Aug  7 08:27:51 2024 GMT
*  expire date: Aug  7 08:27:51 2025 GMT
*  issuer: CN=ca.vault.vault-controller.svc.cluster.local
*  SSL certificate verify result: unable to get local issuer certificate (20), continuing anyway.
*   Certificate level 0: Public key type RSA (2048/112 Bits/secBits), signed using sha256WithRSAEncryption
* using HTTP/1.x
} [5 bytes data]
> GET / HTTP/1.1
> Host: vault.vault-controller.svc.cluster.local:8200
> User-Agent: curl/8.9.1
> Accept: */*
> 
* Request completely sent off
{ [5 bytes data]
* TLSv1.3 (IN), TLS handshake, Newsession Ticket (4):
{ [297 bytes data]
* TLSv1.3 (IN), TLS handshake, Newsession Ticket (4):
{ [297 bytes data]
< HTTP/1.1 200 OK
< Server: nginx/1.27.0
< Date: Wed, 07 Aug 2024 09:35:00 GMT
< Content-Type: application/json
< Content-Length: 36
< Connection: keep-alive
< 
{ [36 bytes data]
100    36  100    36    0     0   2989      0 --:--:-- --:--:-- --:--:--  3272
* Connection #0 to host vault.vault-controller.svc.cluster.local left intact
{"message": "Hello, this is Vault!"}%
```
List listeners:
```shell
istioctl pc l deploy/sleep -n client
```
```
ADDRESSES    PORT  MATCH                                                                                         DESTINATION
0.0.0.0      80    ALL                                                                                           Route: 80
10.217.4.197 443   ALL                                                                                           Cluster: outbound|443||istiod-basic.istio-system.svc.cluster.local
0.0.0.0      8188  ALL                                                                                           Route: 8188
0.0.0.0      15001 ALL                                                                                           PassthroughCluster
0.0.0.0      15001 Addr: *:15001                                                                                 Non-HTTP/Non-TCP
0.0.0.0      15006 Addr: *:15006                                                                                 Non-HTTP/Non-TCP
0.0.0.0      15006 Trans: tls; App: istio-http/1.0,istio-http/1.1,istio-h2; Addr: 0.0.0.0/0                      InboundPassthroughClusterIpv4
0.0.0.0      15006 Trans: raw_buffer; App: http/1.1,h2c; Addr: 0.0.0.0/0                                         InboundPassthroughClusterIpv4
0.0.0.0      15006 Trans: tls; App: TCP TLS; Addr: 0.0.0.0/0                                                     InboundPassthroughClusterIpv4
0.0.0.0      15006 Trans: raw_buffer; Addr: 0.0.0.0/0                                                            InboundPassthroughClusterIpv4
0.0.0.0      15006 Trans: tls; Addr: 0.0.0.0/0                                                                   InboundPassthroughClusterIpv4
0.0.0.0      15006 Trans: tls; App: istio,istio-peer-exchange,istio-http/1.0,istio-http/1.1,istio-h2; Addr: *:80 Cluster: inbound|80||
0.0.0.0      15006 Trans: raw_buffer; Addr: *:80                                                                 Cluster: inbound|80||
0.0.0.0      15010 ALL                                                                                           Route: 15010
10.217.4.197 15012 ALL                                                                                           Cluster: outbound|15012||istiod-basic.istio-system.svc.cluster.local
0.0.0.0      15014 ALL                                                                                           Route: 15014
0.0.0.0      15021 ALL                                                                                           Inline Route: /healthz/ready*
0.0.0.0      15090 ALL                                                                                           Inline Route: /stats/prometheus*
```
List clusters:
```shell
istioctl pc c deploy/sleep -n client
```
```
SERVICE FQDN                                    PORT      SUBSET     DIRECTION     TYPE             DESTINATION RULE
                                                80        -          inbound       ORIGINAL_DST     
BlackHoleCluster                                -         -          -             STATIC           
InboundPassthroughClusterIpv4                   -         -          -             ORIGINAL_DST     
PassthroughCluster                              -         -          -             ORIGINAL_DST     
agent                                           -         -          -             STATIC           
istiod-basic.istio-system.svc.cluster.local     443       -          outbound      EDS              istiod-basic.istio-system
istiod-basic.istio-system.svc.cluster.local     8188      -          outbound      EDS              istiod-basic.istio-system
istiod-basic.istio-system.svc.cluster.local     15010     -          outbound      EDS              istiod-basic.istio-system
istiod-basic.istio-system.svc.cluster.local     15012     -          outbound      EDS              istiod-basic.istio-system
istiod-basic.istio-system.svc.cluster.local     15014     -          outbound      EDS              istiod-basic.istio-system
prometheus_stats                                -         -          -             STATIC           
sds-grpc                                        -         -          -             STATIC           
sleep.client.svc.cluster.local                  80        -          outbound      EDS              
xds-grpc                                        -         -          -             STATIC           
```

As you can see, there is no listener for port 8200 and no cluster for vault service.
This is expected, because `vault-controller` namespace is not included in the `ServiceMeshMemberRoll`.

The request was routed to `vault`, because outbound traffic policy is `ALLOW_ANY` by default,
and then services which do not match any listener are routed to the `PassthroughCluster` listener.
You can see in the logs of sleep application that the request was routed to that cluster:
```shell
oc logs --tail=3 deploy/sleep -n client -c istio-proxy
```
```
024-08-07T09:34:15.747065Z	info	Readiness succeeded in 1.475679178s
2024-08-07T09:34:15.747426Z	info	Envoy proxy is ready
[2024-08-07T09:34:27.773Z] "- - -" 0 - - - "-" 751 2364 6 - "-" "-" "-" "-" "10.217.4.81:8200" PassthroughCluster 10.217.0.112:38334 10.217.4.81:8200 10.217.0.112:38318 - -
```

5. Deploy a service exposed on the same port as vault and include it in the mesh:
```shell
oc new-project apm-server
oc apply -n apm-server -f - <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: apm-server-config
data:
  nginx.conf: |-
    events {}
    http {
      log_format main '$remote_addr - $remote_user [$time_local]  $status "$request" $body_bytes_sent "$http_referer" "$http_user_agent" "$http_x_forwarded_for"';
      access_log /var/log/nginx/access.log main;
      error_log  /var/log/nginx/error.log;
      server {
        listen      8200;
        server_name apm-server.apm-server.svc.cluster.local;

        location / {
            default_type application/json;
            return 200 '{"message": "Hello, this is APM Server!"}';
        }
      }
    }
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: apm-server
spec:
  selector:
    matchLabels:
      app: apm-server
  template:
    metadata:
      labels:
        app: apm-server
      annotations:
        sidecar.istio.io/inject: 'true'
    spec:
      containers:
      - name: apm-server
        image: nginx:1.27.0
        volumeMounts:
        - name: apm-server-config
          mountPath: /etc/nginx/nginx.conf
          subPath: nginx.conf
        - name: var-volume
          mountPath: /var/log/nginx
          readOnly: false
        - name: var-volume
          mountPath: /var/cache/nginx
          readOnly: false
        - name: var-volume
          mountPath: /var/run
          readOnly: false
        - name: var-volume
          mountPath: /etc/nginx/conf.d/
          readOnly: false
      volumes:
      - name: apm-server-config
        configMap:
          name: apm-server-config
      - name: var-volume
        emptyDir: {}
---
apiVersion: v1
kind: Service
metadata:
  name: apm-server
spec:
  selector:
    app: apm-server
  ports:
  - name: http
    port: 8200
    protocol: TCP
    targetPort: 8200
  type: ClusterIP
EOF
```

Once it's ready, you can send a request to `vault` once again:
```shell
oc exec deploy/sleep -n client -- curl -vk https://vault.vault-controller.svc.cluster.local:8200
```
This time it should fail with the following error:
```
* IPv6: (none)
* IPv4: 10.217.4.81
*   Trying 10.217.4.81:8200...
* Connected to vault.vault-controller.svc.cluster.local (10.217.4.81) port 8200
* ALPN: curl offers h2,http/1.1
} [5 bytes data]
* TLSv1.3 (OUT), TLS handshake, Client hello (1):
} [512 bytes data]
* TLSv1.3 (OUT), TLS alert, record overflow (534):
} [2 bytes data]
* OpenSSL/3.3.1: error:0A0000C6:SSL routines::packet length too long
  0     0    0     0    0     0      0      0 --:--:-- --:--:-- --:--:--     0
* closing connection #0
curl: (35) OpenSSL/3.3.1: error:0A0000C6:SSL routines::packet length too long
command terminated with exit code 35
```
Look at the logs again:
```shell
oc logs --tail=3 deploy/sleep -n client -c istio-proxy
```
```
2024-08-07T09:34:15.747426Z	info	Envoy proxy is ready
[2024-08-07T09:34:27.773Z] "- - -" 0 - - - "-" 751 2364 6 - "-" "-" "-" "-" "10.217.4.81:8200" PassthroughCluster 10.217.0.112:38334 10.217.4.81:8200 10.217.0.112:38318 - -
[2024-08-07T09:46:58.337Z] "- - HTTP/1.1" 400 DPE http1.codec_error - "-" 0 11 0 - "-" "-" "-" "-" "-" - - 10.217.4.81:8200 10.217.0.112:59228 - -
```
List listeners, routes and clusters:
```shell
istioctl pc l deploy/sleep -n client                       
ADDRESSES    PORT  MATCH                                                                                         DESTINATION
0.0.0.0      80    ALL                                                                                           Route: 80
10.217.4.197 443   ALL                                                                                           Cluster: outbound|443||istiod-basic.istio-system.svc.cluster.local
0.0.0.0      8188  ALL                                                                                           Route: 8188
0.0.0.0      8200  ALL                                                                                           Route: 8200
0.0.0.0      15001 ALL                                                                                           PassthroughCluster
0.0.0.0      15001 Addr: *:15001                                                                                 Non-HTTP/Non-TCP
0.0.0.0      15006 Addr: *:15006                                                                                 Non-HTTP/Non-TCP
0.0.0.0      15006 Trans: tls; App: istio-http/1.0,istio-http/1.1,istio-h2; Addr: 0.0.0.0/0                      InboundPassthroughClusterIpv4
0.0.0.0      15006 Trans: raw_buffer; App: http/1.1,h2c; Addr: 0.0.0.0/0                                         InboundPassthroughClusterIpv4
0.0.0.0      15006 Trans: tls; App: TCP TLS; Addr: 0.0.0.0/0                                                     InboundPassthroughClusterIpv4
0.0.0.0      15006 Trans: raw_buffer; Addr: 0.0.0.0/0                                                            InboundPassthroughClusterIpv4
0.0.0.0      15006 Trans: tls; Addr: 0.0.0.0/0                                                                   InboundPassthroughClusterIpv4
0.0.0.0      15006 Trans: tls; App: istio,istio-peer-exchange,istio-http/1.0,istio-http/1.1,istio-h2; Addr: *:80 Cluster: inbound|80||
0.0.0.0      15006 Trans: raw_buffer; Addr: *:80                                                                 Cluster: inbound|80||
0.0.0.0      15010 ALL                                                                                           Route: 15010
10.217.4.197 15012 ALL                                                                                           Cluster: outbound|15012||istiod-basic.istio-system.svc.cluster.local
0.0.0.0      15014 ALL                                                                                           Route: 15014
0.0.0.0      15021 ALL                                                                                           Inline Route: /healthz/ready*
0.0.0.0      15090 ALL                                                                                           Inline Route: /stats/prometheus*
```
```shell
istioctl pc r deploy/sleep -n client
```
```
NAME                              VHOST NAME                                            DOMAINS                                     MATCH                  VIRTUAL SERVICE
80                                sleep.client.svc.cluster.local:80                     sleep, sleep.client + 1 more...             /*                     
8188                              istiod-basic.istio-system.svc.cluster.local:8188      istiod-basic.istio-system, 10.217.4.197     /*                     
8200                              apm-server.apm-server.svc.cluster.local:8200          apm-server.apm-server, 10.217.5.175         /*                     
15010                             istiod-basic.istio-system.svc.cluster.local:15010     istiod-basic.istio-system, 10.217.4.197     /*                     
15014                             istiod-basic.istio-system.svc.cluster.local:15014     istiod-basic.istio-system, 10.217.4.197     /*                     
                                  backend                                               *                                           /healthz/ready*        
InboundPassthroughClusterIpv4     inbound|http|0                                        *                                           /*                     
InboundPassthroughClusterIpv4     inbound|http|0                                        *                                           /*                     
                                  backend                                               *                                           /stats/prometheus*     
inbound|80||                      inbound|http|80                                       *                                           /*                     
inbound|80||                      inbound|http|80                                       *                                           /*
```
```shell
istioctl pc c deploy/sleep -n client
```
```
SERVICE FQDN                                    PORT      SUBSET     DIRECTION     TYPE             DESTINATION RULE
                                                80        -          inbound       ORIGINAL_DST     
BlackHoleCluster                                -         -          -             STATIC           
InboundPassthroughClusterIpv4                   -         -          -             ORIGINAL_DST     
PassthroughCluster                              -         -          -             ORIGINAL_DST     
agent                                           -         -          -             STATIC           
apm-server.apm-server.svc.cluster.local         8200      -          outbound      EDS              
istiod-basic.istio-system.svc.cluster.local     443       -          outbound      EDS              istiod-basic.istio-system
istiod-basic.istio-system.svc.cluster.local     8188      -          outbound      EDS              istiod-basic.istio-system
istiod-basic.istio-system.svc.cluster.local     15010     -          outbound      EDS              istiod-basic.istio-system
istiod-basic.istio-system.svc.cluster.local     15012     -          outbound      EDS              istiod-basic.istio-system
istiod-basic.istio-system.svc.cluster.local     15014     -          outbound      EDS              istiod-basic.istio-system
prometheus_stats                                -         -          -             STATIC           
sds-grpc                                        -         -          -             STATIC           
sleep.client.svc.cluster.local                  80        -          outbound      EDS              
xds-grpc                                        -         -          -             STATIC
```

As you can see, istio-proxy has listener on port 8200 that routes traffic to `apm-server.apm-server.svc.cluster.local:8200`,
so the error "400 DPE" (DownstreamProtocolError - The downstream request had an HTTP protocol error.) is expected,
because `sleep` sent HTTPS request to HTTP connection manager that can't handle TLS handshake.

## Possible solutions

### Prefer port 80 for HTTP services

Istio always creates a listener on port 80 with HTTP connection manager that handles requests to HTTP services
and routes requests to proper clusters based on the "Host" header. It's worth to note that clients cannot connect
to non-HTTP services on port 80, because that listener always exists.

```shell
oc apply -n apm-server -f - <<EOF
apiVersion: v1
kind: Service
metadata:
  name: apm-server
spec:
  selector:
    app: apm-server
  ports:
  - name: http
    port: 80
    protocol: TCP
    targetPort: 8200
  type: ClusterIP
EOF
```

Send a request to vault once again - now it should arrive successfully.

### Include vault service in the mesh

Restore port 8200 in apm-server and add `vault-controller` to the SMMR:
```shell
oc apply -f - <<EOF
apiVersion: v1
kind: Service
metadata:
  name: apm-server
  namespace: apm-server
spec:
  selector:
    app: apm-server
  ports:
  - name: http
    port: 8200
    protocol: TCP
    targetPort: 8200
  type: ClusterIP
---
apiVersion: maistra.io/v1
kind: ServiceMeshMemberRoll
metadata:
  name: default
  namespace: istio-system
spec:
  members:
  - client
  - apm-server
  - vault-controller
EOF
```

Send a request to vault - it should arrive successfully again.

List listeners:
```shell
istioctl pc l deploy/sleep -n client
```
```
ADDRESSES    PORT  MATCH                                                                                         DESTINATION
0.0.0.0      80    ALL                                                                                           Route: 80
10.217.4.197 443   ALL                                                                                           Cluster: outbound|443||istiod-basic.istio-system.svc.cluster.local
0.0.0.0      8188  ALL                                                                                           Route: 8188
0.0.0.0      8200  ALL                                                                                           Route: 8200
10.217.4.81  8200  ALL                                                                                           Cluster: outbound|8200||vault.vault-controller.svc.cluster.local
0.0.0.0      15001 ALL                                                                                           PassthroughCluster
0.0.0.0      15001 Addr: *:15001                                                                                 Non-HTTP/Non-TCP
0.0.0.0      15006 Addr: *:15006                                                                                 Non-HTTP/Non-TCP
0.0.0.0      15006 Trans: tls; App: istio-http/1.0,istio-http/1.1,istio-h2; Addr: 0.0.0.0/0                      InboundPassthroughClusterIpv4
0.0.0.0      15006 Trans: raw_buffer; App: http/1.1,h2c; Addr: 0.0.0.0/0                                         InboundPassthroughClusterIpv4
0.0.0.0      15006 Trans: tls; App: TCP TLS; Addr: 0.0.0.0/0                                                     InboundPassthroughClusterIpv4
0.0.0.0      15006 Trans: raw_buffer; Addr: 0.0.0.0/0                                                            InboundPassthroughClusterIpv4
0.0.0.0      15006 Trans: tls; Addr: 0.0.0.0/0                                                                   InboundPassthroughClusterIpv4
0.0.0.0      15006 Trans: tls; App: istio,istio-peer-exchange,istio-http/1.0,istio-http/1.1,istio-h2; Addr: *:80 Cluster: inbound|80||
0.0.0.0      15006 Trans: raw_buffer; Addr: *:80                                                                 Cluster: inbound|80||
0.0.0.0      15010 ALL                                                                                           Route: 15010
10.217.4.197 15012 ALL                                                                                           Cluster: outbound|15012||istiod-basic.istio-system.svc.cluster.local
0.0.0.0      15014 ALL                                                                                           Route: 15014
0.0.0.0      15021 ALL                                                                                           Inline Route: /healthz/ready*
0.0.0.0      15090 ALL                                                                                           Inline Route: /stats/prometheus*
```
As you can see, there are 2 listeners for port 8200. Why?

When we added `vault-controller` namespace to the SMMR, Istio was configured to watch that namespace
and it discovered the `vault` Service, so it configured a listener for the virtual IP 10.217.4.81 (ClusuterIP) and port 8200.
That listener routes traffic to the cluster `outbound|8200||vault.vault-controller.svc.cluster.local`.
There is no route, like in the previous listener, because the port 8200 is named `vault`, so Istio can't conclude its protocol
and configures `TcpProxy` by default.

The previous listener matches any other traffic to port 8200, and since `apm-server` Service has port named `http`,
Istio concluded that it's HTTP service and configured `HTTPConnectionManager`, therefore the listener routes to the `Route: 8200`,
not `Cluster: outbound|8200||apm-server.apm-server.svc.cluster.local`.

### Create a ServiceEntry for vault

1. Restore SMMR without `vault-controller` namespace:
```shell
oc apply -n istio-system -f - <<EOF
apiVersion: maistra.io/v1
kind: ServiceMeshMemberRoll
metadata:
  name: default
spec:
  members:
  - client
  - apm-server
EOF
```

2. Send a request to vault - it should fail again.
```shell
oc exec deploy/sleep -n client -- curl -vk https://vault.vault-controller.svc.cluster.local:8200
```

3. Create a ServiceEntry for `vault` as it is treated as an external service when it is not included in SMMR:
```shell
oc apply -n istio-system -f - <<EOF
apiVersion: networking.istio.io/v1beta1
kind: ServiceEntry
metadata:
  name: vault
spec:
  hosts:
  - vault.vault-controller.svc.cluster.local
  location: MESH_EXTERNAL
  ports:
  - number: 8200
    name: https
    protocol: TLS
  resolution: DNS
EOF
```

4. Send a request to vault - it should succeed.
```shell
oc exec deploy/sleep -n client -- curl -vk https://vault.vault-controller.svc.cluster.local:8200
```

5. List listeners and clusters:
```shell
istioctl pc l deploy/sleep -n client
```
```
ADDRESSES      PORT  MATCH                                                                                         DESTINATION
0.0.0.0        80    ALL                                                                                           Route: 80
10.217.4.197   443   ALL                                                                                           Cluster: outbound|443||istiod-basic.istio-system.svc.cluster.local
0.0.0.0        8188  ALL                                                                                           Route: 8188
0.0.0.0        8200  ALL                                                                                           Route: 8200
240.240.180.80 8200  ALL                                                                                           Cluster: outbound|8200||vault.vault-controller.svc.cluster.local
0.0.0.0        15001 ALL                                                                                           PassthroughCluster
0.0.0.0        15001 Addr: *:15001                                                                                 Non-HTTP/Non-TCP
0.0.0.0        15006 Addr: *:15006                                                                                 Non-HTTP/Non-TCP
0.0.0.0        15006 Trans: tls; App: istio-http/1.0,istio-http/1.1,istio-h2; Addr: 0.0.0.0/0                      InboundPassthroughClusterIpv4
0.0.0.0        15006 Trans: raw_buffer; App: http/1.1,h2c; Addr: 0.0.0.0/0                                         InboundPassthroughClusterIpv4
0.0.0.0        15006 Trans: tls; App: TCP TLS; Addr: 0.0.0.0/0                                                     InboundPassthroughClusterIpv4
0.0.0.0        15006 Trans: raw_buffer; Addr: 0.0.0.0/0                                                            InboundPassthroughClusterIpv4
0.0.0.0        15006 Trans: tls; Addr: 0.0.0.0/0                                                                   InboundPassthroughClusterIpv4
0.0.0.0        15006 Trans: tls; App: istio,istio-peer-exchange,istio-http/1.0,istio-http/1.1,istio-h2; Addr: *:80 Cluster: inbound|80||
0.0.0.0        15006 Trans: raw_buffer; Addr: *:80                                                                 Cluster: inbound|80||
0.0.0.0        15010 ALL                                                                                           Route: 15010
10.217.4.197   15012 ALL                                                                                           Cluster: outbound|15012||istiod-basic.istio-system.svc.cluster.local
0.0.0.0        15014 ALL                                                                                           Route: 15014
0.0.0.0        15021 ALL                                                                                           Inline Route: /healthz/ready*
0.0.0.0        15090 ALL                                                                                           Inline Route: /stats/prometheus*
```
```shell
istioctl pc c deploy/sleep -n client
```
```
SERVICE FQDN                                    PORT      SUBSET     DIRECTION     TYPE             DESTINATION RULE
                                                80        -          inbound       ORIGINAL_DST     
BlackHoleCluster                                -         -          -             STATIC           
InboundPassthroughClusterIpv4                   -         -          -             ORIGINAL_DST     
PassthroughCluster                              -         -          -             ORIGINAL_DST     
agent                                           -         -          -             STATIC           
apm-server.apm-server.svc.cluster.local         8200      -          outbound      EDS              
istiod-basic.istio-system.svc.cluster.local     443       -          outbound      EDS              istiod-basic.istio-system
istiod-basic.istio-system.svc.cluster.local     8188      -          outbound      EDS              istiod-basic.istio-system
istiod-basic.istio-system.svc.cluster.local     15010     -          outbound      EDS              istiod-basic.istio-system
istiod-basic.istio-system.svc.cluster.local     15012     -          outbound      EDS              istiod-basic.istio-system
istiod-basic.istio-system.svc.cluster.local     15014     -          outbound      EDS              istiod-basic.istio-system
prometheus_stats                                -         -          -             STATIC           
sds-grpc                                        -         -          -             STATIC           
sleep.client.svc.cluster.local                  80        -          outbound      EDS              
vault.vault-controller.svc.cluster.local        8200      -          outbound      STRICT_DNS       
xds-grpc                                        -         -          -             STATIC
```

As you can see, there is a listener matching IP 240.240.180.80 and port 8200 that routes traffic
to the cluster `outbound|8200||vault.vault-controller.svc.cluster.local`. Istio allocated a virtual IP that is resolved
by the DNS proxy, because `vault` is an external service, so Istio does not know its real IP.

It's also worth to mentation about cluster type of `vault.vault-controller.svc.cluster.local` - this is `STRICT_DNS`,
because Istio does not watch that namespace, so it can't discover its enpoints and configure `EDS` type. In such a case,
istio-proxy will resolve `vault.vault-controller.svc.cluster.local` when a request is routed to this cluster and will route
traffic to the resolved address.
