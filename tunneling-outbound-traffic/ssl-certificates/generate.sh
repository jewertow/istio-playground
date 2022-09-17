#!/bin/sh

if [ -z "$HOST" ]
then
  echo "Environment variable HOST must be exported or passed to the script."
  exit 1
fi

if [ -z "$DOMAIN" ]
then
  echo "Environment variable DOMAIN must be exported or passed to the script."
  exit 1
fi

# create a root certificate and private key to sign the certificate
openssl req -x509 -sha256 -nodes \
    -days 365 \
    -newkey rsa:2048 \
    -subj "/CN=ca.${DOMAIN}" \
    -keyout ca."${DOMAIN}".key \
    -out ca."${DOMAIN}".crt

# create a certificate and a private key for external-app.corp.net
openssl req -newkey rsa:2048 -nodes \
    -subj "/CN=${HOST}.${DOMAIN}" \
    -keyout "${HOST}"."${DOMAIN}".key \
    -out "${HOST}"."${DOMAIN}".csr
openssl x509 -req \
    -days 365 \
    -CA ca."${DOMAIN}".crt \
    -CAkey ca."${DOMAIN}".key \
    -set_serial 0 \
    -in "${HOST}"."${DOMAIN}".csr \
    -out "${HOST}"."${DOMAIN}".crt

# generate client certificate and private key
openssl req -newkey rsa:2048 -nodes \
    -out client."${DOMAIN}".csr \
    -keyout client."${DOMAIN}".key \
    -subj "/CN=client.${DOMAIN}"
openssl x509 -req \
    -days 365 \
    -CA ca."${DOMAIN}".crt \
    -CAkey ca."${DOMAIN}".key \
    -set_serial 1 \
    -in client."${DOMAIN}".csr \
    -out client."${DOMAIN}".crt
