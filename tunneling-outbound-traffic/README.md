## Tunneling outbound traffic with Istio

![tunneling-traffic](docs/solution.jpg)

### Prerequisites

#### 1. Istio
Download and build Istio from my fork.
```sh
git clone https://github.com/jewertow/upstream-istio
cd istio
export ISTIO_SRC=$(pwd)
export TAG=tunnel-api
make gen
make build
make docker
```

#### 2. Envoy
Envoy is used as the forward proxy. The script below pulls container with Envoy and extracts binary to host.
```sh
(cd infra/forward-proxy; ./get-envoy.sh)
```

#### 3. Kubernetes
```sh
(cd infra/k8s;
wget -O k0s "https://github.com/k0sproject/k0s/releases/download/v1.23.1+k0s.1/k0s-v1.23.1+k0s.1-amd64" ;
chmod u+x k0s)
```

### Setup environment
1. Generate nginx configurations
```sh
(cd infra/external-app; ansible-playbook generate-nginx-configs.yaml)
```

2. Run VMs
```sh
vagrant up
```

3. Configure kube config file
```sh
vagrant ssh k8s -c 'sudo cat /var/lib/k0s/pki/admin.conf' > ~/.kube/config-vagrant-k0s
export KUBECONFIG=~/.kube/config-vagrant-k0s
```

4. Upload container images from host to k8s VM:
```sh
./infra/k8s/upload-images.sh tunneling
```

6. Install Istio
```sh
$ISTIO_SRC/out/linux_amd64/istioctl install -y \
    --set profile=demo \
    --set meshConfig.accessLogFile=/dev/stdout \
    --set meshConfig.outboundTrafficPolicy.mode=REGISTRY_ONLY \
    --set hub="localhost:5000" \
    --set tag="tunnel-api"
```
