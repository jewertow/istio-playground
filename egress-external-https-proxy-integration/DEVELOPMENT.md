### Testing local Istio

1. Build Istio:
```sh
# Execute from Istio directory
export TAG=<tag>
make gen
make build
make docker
```

2. Run VMs:
```sh
vagrant up
```

3. Overwrite kubeconfig file:
```sh
vagrant ssh k8s -c 'sudo cat /var/lib/k0s/pki/admin.conf' > ~/.kube/config-vagrant-k0s
export KUBECONFIG=~/.kube/config-vagrant-k0s
```

4. Upload images to k8s VM:
```sh
# filter images by registry localhost:5000
./infra/k8s/upload-images.sh localhost:5000
```

5. Install local version of Istio:
```sh
# Execute from $ISTIO_DIR/out/<arch>
./istioctl install -y \
    --set profile=demo \
    --set meshConfig.accessLogFile=/dev/stdout \
    --set meshConfig.outboundTrafficPolicy.mode=REGISTRY_ONLY \
    --set hub="localhost:5000" \
    --set tag="<tag>"
```
