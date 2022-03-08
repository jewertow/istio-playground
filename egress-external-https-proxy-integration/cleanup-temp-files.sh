#!/bin/bash

for file_ext in "tar" "log" "pcap"
do
  find . -name "*.$file_ext" -type f | xargs rm -f
done
