#!/bin/bash

CERT_DIR=$1

if [ -z "${CERT_DIR}" ];
then
  echo "Missing argument with certificate directory. Run script as follows: './ssl-configmap.sh <certificate-directory>'"
  exit 1
fi

kubectl create configmap client-crt --from-file=client-crt.pem="${CERT_DIR}"/internal-client.corp.net.crt
kubectl create configmap client-key --from-file=client-key.pem="${CERT_DIR}"/internal-client.corp.net.key

kubectl create secret -n istio-system generic client-credential \
    --from-file=tls.key="${CERT_DIR}"/internal-client.corp.net.key \
    --from-file=tls.crt="${CERT_DIR}"/internal-client.corp.net.crt \
    --from-file=ca.crt="${CERT_DIR}"/ca.corp.net.crt
