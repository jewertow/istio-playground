#!/bin/bash
# This script requires to pass variable named PRIVATE_DNS_IP

sudo apt-get update -y
sudo apt-get install -y resolvconf

sudo bash -c "echo \"nameserver $PRIVATE_DNS_IP\" >> /etc/resolvconf/resolv.conf.d/head"
sudo systemctl restart resolvconf
