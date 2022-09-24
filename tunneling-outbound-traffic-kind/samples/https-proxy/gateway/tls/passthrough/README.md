TODO: describe this case

kubectl apply -f gateway.yaml
kubectl apply -f virtual-service.yaml
kubectl apply -f originate-tls.yaml

kubectl delete -f gateway.yaml
kubectl delete -f virtual-service.yaml
kubectl delete -f originate-tls.yaml