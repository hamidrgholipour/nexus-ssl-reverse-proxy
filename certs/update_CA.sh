#! /bin/bash
cp ./rootCA.crt /usr/local/share/ca-certificates/
update-ca-certificates
