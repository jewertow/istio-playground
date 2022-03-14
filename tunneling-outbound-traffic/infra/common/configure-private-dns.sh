#!/bin/bash

if [ -z "${PRIVATE_DNS_IP}" ];
then
  echo "Script requires an input variable named PRIVATE_DNS_IP."
  exit 1
fi

sudo apt-get update -y
sudo apt-get install -y resolvconf

sudo bash -c "echo \"nameserver $PRIVATE_DNS_IP\" >> /etc/resolvconf/resolv.conf.d/head"
sudo systemctl restart resolvconf
