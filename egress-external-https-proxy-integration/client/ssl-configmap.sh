#!/bin/bash

CERT_DIR=$1

kubectl create configmap client-crt --from-file=client-crt.pem=${CERT_DIR}/internal-client.corp.net.crt
kubectl create configmap client-key --from-file=client-key.pem=${CERT_DIR}/internal-client.corp.net.key
