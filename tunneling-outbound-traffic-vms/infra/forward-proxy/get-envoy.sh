#!/bin/bash

container_id=$(docker create envoyproxy/envoy:v1.21.0)
docker cp $container_id:/usr/local/bin/envoy ./envoy
docker rm $container_id
