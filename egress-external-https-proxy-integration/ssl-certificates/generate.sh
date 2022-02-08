#!/bin/bash

# create a root certificate and private key to sign the certificate
openssl req -x509 -sha256 -nodes \
    -days 365 \
    -newkey rsa:2048 \
    -subj '/CN=external-app.corp.net' \
    -keyout ca.corp.net.key \
    -out ca.corp.net.crt

# create a certificate and a private key for external-app.corp.net
openssl req -newkey rsa:2048 -nodes \
    -subj "/CN=external-app.corp.net" \
    -keyout external-app.corp.net.key \
    -out external-app.corp.net.csr
openssl x509 -req \
    -days 365 \
    -CA ca.corp.net.crt \
    -CAkey ca.corp.net.key \
    -set_serial 0 \
    -in external-app.corp.net.csr \
    -out external-app.corp.net.crt

# generate client certificate and private key
openssl req -newkey rsa:2048 -nodes \
    -out internal-client.corp.net.csr \
    -keyout internal-client.corp.net.key \
    -subj "/CN=internal-client.corp.net"
openssl x509 -req \
    -days 365 \
    -CA ca.corp.net.crt \
    -CAkey ca.corp.net.key \
    -set_serial 1 \
    -in internal-client.corp.net.csr \
    -out internal-client.corp.net.crt
