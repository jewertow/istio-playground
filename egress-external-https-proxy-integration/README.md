## Proof of concept of tunneling outgoing traffic by Istio egress gateway via external HTTPS proxy

![tunneling-traffic](docs/solution.jpg)

### Requirements

#### Envoy
```sh
./envoy/get-envoy.sh
```

#### Istio
Follow the instructions from the official documentation: https://istio.io/latest/docs/setup/getting-started/#download.

#### Kubernetes
```sh
wget -O k0s https://github.com/k0sproject/k0s/releases/download/v1.23.1+k0s.1/k0s-v1.23.1+k0s.1-amd64
chmod u+x k0s
```

### Setup environment
1. Run VMs
```sh
vagrant up
```

2. Configure kube config file
```sh
vagrant ssh k8s -c 'sudo cat /var/lib/k0s/pki/admin.conf' > ~/.kube/config-vagrant-k0s
export KUBECONFIG=~/.kube/config-vagrant-k0s
```

3. Install Istio
```sh
istioctl install -y \
    --set profile=demo \
    --set meshConfig.accessLogFile=/dev/stdout \
    --set meshConfig.outboundTrafficPolicy.mode=REGISTRY_ONLY
```

4. Display proxy access log
```sh
vagrant ssh external-proxy -c 'tail -f /var/log/envoy/access.log'
```

#### Test TLS passthrough
```sh
kubectl label namespace default istio-injection=enabled
# samples from https://github.com/istio/istio/tree/master/samples
kubectl apply -f samples/sleep/sleep.yaml
kubectl apply -f istio/external-services.yaml
kubectl exec $(kubectl get pods -l app=sleep -o jsonpath='{.items[].metadata.name}') -c sleep -- curl -v -sSL -o /dev/null -D - https://www.google.com
kubectl exec $(kubectl get pods -l app=sleep -o jsonpath='{.items[].metadata.name}') -c sleep -- curl -v -sSL -o /dev/null -D - https://www.wikipedia.org
# check external proxy access log - it should be empty
kubectl apply -f istio/external-outbound-traffic-through-egress-gateway.yaml
kubectl apply -f istio/create-custom-listener/tcp-tunnel-filter.yaml
# now traffic should be routed via external proxy
kubectl exec $(kubectl get pods -l app=sleep -o jsonpath='{.items[].metadata.name}') -c sleep -- curl -v -sSL -o /dev/null -D - https://www.google.com
kubectl exec $(kubectl get pods -l app=sleep -o jsonpath='{.items[].metadata.name}') -c sleep -- curl -v -sSL -o /dev/null -D - https://www.wikipedia.org
# check external proxy access log once again - there should be similar logs
[2022-01-28T13:23:03.527Z] 192.168.56.20:47191 "CONNECT 216.58.209.4:443 - HTTP/1.1" - 200 - DC
[2022-01-28T13:23:30.407Z] 192.168.56.20:59205 "CONNECT 91.198.174.192:443 - HTTP/1.1" - 200 - DC
```

#### Test mTLS
1. Print nginx (mTLS server) logs:
```sh
vagrant ssh external-app -c 'sudo tail -f /var/log/nginx/access.log'
```

2. Deploy client and test connection:
```sh
kubectl label namespace default istio-injection=enabled
./client/ssl-configmap.sh "$(pwd)/ssl-certificates"
kubectl apply -f client/sleep.yaml
kubectl apply -f external-app/service-entry.yaml
kubectl exec $(kubectl get pods -l app=sleep -o jsonpath='{.items[].metadata.name}') -c sleep -- \
    curl -v --insecure \
    --cert /etc/pki/tls/certs/client-crt.pem \
    --key /etc/pki/tls/private/client-key.pem \
    https://external-app.default.svc.cluster.local

# check external proxy access log - it should be empty
# kubectl apply -f istio/external-outbound-traffic-through-egress-gateway.yaml
# kubectl apply -f istio/create-custom-listener/tcp-tunnel-filter.yaml
# now traffic should be routed via external proxy
# kubectl exec $(kubectl get pods -l app=sleep -o jsonpath='{.items[].metadata.name}') -c sleep -- curl -v -sSL -o /dev/null -D - https://www.google.com
# kubectl exec $(kubectl get pods -l app=sleep -o jsonpath='{.items[].metadata.name}') -c sleep -- curl -v -sSL -o /dev/null -D - https://www.wikipedia.org
# check external proxy access log once again - there should be similar logs
# [2022-01-28T13:23:03.527Z] 192.168.56.20:47191 "CONNECT 216.58.209.4:443 - HTTP/1.1" - 200 - DC
# [2022-01-28T13:23:30.407Z] 192.168.56.20:59205 "CONNECT 91.198.174.192:443 - HTTP/1.1" - 200 - DC
```

#### TODO
1. Investigate why istiod logs conflict after applying of VirtualService
```
2022-01-28T13:27:02.527694Z	info	ads	Push Status: {
    "pilot_conflict_outbound_listener_tcp_over_current_tcp": {
        "0.0.0.0:443": {
            "proxy": "sleep-698cfc4445-5f4w2.default",
            "message": "Listener=0.0.0.0:443 AcceptedTCP=www.google.com RejectedTCP=www.wikipedia.org TCPServices=1"
        }
    }
}
```
