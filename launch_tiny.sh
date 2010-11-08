#!/usr/bin/env bash 

euca-add-keypair test > test.pem
euca-run-instances -k test -t m1.tiny ami-tiny
