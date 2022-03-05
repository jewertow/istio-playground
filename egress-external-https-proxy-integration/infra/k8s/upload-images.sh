#!/bin/bash

# Important: this script must be executed from directory where Vagrantfile exists

FILTER=$1
if [ -z "$FILTER" ]
then
  echo "Missing filter argument. Run script as follows: './upload-images <filter>'"
  exit 1
fi

echo "Packaging filtered images to .tar files..."
docker images | grep "$FILTER" |\
  # concatenate REPOSITORY and TAG columns from 'docker images' output: "repository/image tag" -> "repository/image:tag"
  awk '{full_image_name = sprintf("%s:%s", $1, $2); print full_image_name}' |\
  # col 1: output from previous command as is
  # col 2: image name with tag, but without repository name (to avoid slash character in image file name)
  awk -F / '{print $0" "$2}' |\
  # col 1: add ".tar" extension to image name from 2nd input column
  # col 2: 1st column from input as is
  awk '{file_name = sprintf("%s.tar", $2); print file_name " " $1}' |\
  # save images to tar files by passing every output line to command 'docker save -o <file-name> <full-image-name>'
  xargs -l docker save -o

echo "Uploading images to vagrant machine..."
find . -name "*.tar" | xargs -I {} vagrant upload {} /home/vagrant/images/{} k8s

echo "Importing images from .tar files"
vagrant ssh k8s -c "find /home/vagrant/images -name '*.tar' | xargs -l sudo k0s ctr images import"
