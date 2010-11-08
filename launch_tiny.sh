#!/usr/bin/env bash 

euca-add-keypair test > test.pem
# bundle up the UML image
euca-bundle-image -i ubuntu-lucid-uml.img
euca-upload-bundle -b uml-image-bucket -m /tmp/ubuntu-lucid-uml.img.manifest.xml
euca-register uml-image-bucket/ubuntu-lucid-uml.img.manifest.xml
# grab its AMI
AMI=`euca-describe-images | grep ubuntu-lucid-uml | cut -f2`
# run it, while feeding bogus kernel and ramdisk
euca-run-instances -k test -t m1.tiny --kernel aki-lucid --ramdisk ari-lucid ${AMI}