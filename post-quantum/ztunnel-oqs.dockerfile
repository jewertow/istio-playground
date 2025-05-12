FROM fedora:41

RUN dnf -y update && dnf -y install openssl oqsprovider iptables

COPY ztunnel /usr/local/bin/ztunnel

WORKDIR /

ENTRYPOINT ["/usr/local/bin/ztunnel"]
