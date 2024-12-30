#!/bin/bash

#>>>>>>>>>>>>>>>>>>>>>>>>> Start Create Certificates Functions <<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<

function Create_Certificates {
## 1) Create self_signed certificates with root CA

echo "# New Key for root.crt"
mkdir -p ${PWD}/certs
openssl ecparam -out ${PWD}/certs/root.key -name prime256v1 -genkey

echo "# Create CSR for root CA"
openssl req -new -sha256 -key ${PWD}/certs/root.key  -out ${PWD}/certs/root.csr -subj "/C=IR/ST=Tehran/L=Tehran/O=ISC/OU=OPR/CN=root-$HOSTNAME"

echo "# create root cert"
openssl x509 -req -sha256 -days 3650 -in ${PWD}/certs/root.csr -signkey  ${PWD}/certs/root.key -out ${PWD}/certs/root.crt

## for upload secure charts to nexus by curl command
#New_CA_Cert=$(openssl x509 -in ${PWD}/certs/root.crt -text -noout | grep "Serial Number" -A1 | tail -n1)
#if [ ! $(openssl crl2pkcs7 -nocrl -certfile /etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem | openssl pkcs7 -print_certs -noout -text  | grep $New_CA_Cert) ] ;then 
#	sed -i '/Nexus begin/,/Nexus end/{/Nexus begin/!{/Nexus end/!d}}' /etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem  
#	sed -i '/Nexus begin/d' /etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem 
#	sed -i '/Nexus end/d' /etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem
#	echo -e "\n# Nexus begin repository ca trust" >> /etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem
#	cat ${PWD}/certs/root.crt >> /etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem
#	echo -e "\n# Nexus end repository ca trust" >> /etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem
#else
#	echo "cert already addes in /etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem"
#fi
############OR#######################
cp ${PWD}/certs/root.crt /etc/pki/ca-trust/source/anchors/
mkdir -p mkdir -p /etc/docker/cert.d/nexus-repo.$HOSTNAME:8443/
cp ${PWD}/certs/root.crt /etc/docker/cert.d/nexus-repo.$HOSTNAME:8443/

update-ca-trust enable
update-ca-trust
update-ca-trust extract
systemctl daemon-reload
systemctl restart docker


#####################################
echo "# create new Key for server cert"
openssl ecparam -out ${PWD}/certs/server.key -name prime256v1 -genkey

echo "#create csr config file for server cert"

######################################## Create CSR Conf file  ##########################################
cat <<EOF | tee ${PWD}/certs/cert.conf
[ req ]
req_extensions = v3_req
distinguished_name = req_distinguished_name
prompt = no

[req_distinguished_name]
C  = IR
ST = TEH
L  = Tehran
O  = ISC
OU = OPR
commonName=nexus-repo.$HOSTNAME

[v3_req]
subjectAltName = @alt_names
keyUsage = keyEncipherment, dataEncipherment, nonRepudiation, digitalSignature
extendedKeyUsage = serverAuth

[alt_names]
DNS.1 = nexus-repo.$HOSTNAME
EOF

count=1

for ip in $(ip -4 address show | grep ens | grep -oP '(?<=inet\s)\d+(\.\d+){3}')
do

echo "IP.$count = $ip" >> ${PWD}/certs/cert.conf
count=$((count+1))

done
########################################################################################################

echo "# create CSR for Server cert"
openssl req -new -sha256 -key ${PWD}/certs/server.key -out ${PWD}/certs/server.csr -config ${PWD}/certs/cert.conf

echo "# create server.crt"
openssl x509 -req -in ${PWD}/certs/server.csr -CA  ${PWD}/certs/root.crt -CAkey ${PWD}/certs/root.key -CAcreateserial -out ${PWD}/certs/server.crt -days 3650 -sha256 -extfile ${PWD}/certs/cert.conf -extensions v3_req

echo "# verify Certificate of server"
openssl x509 -in ${PWD}/certs/server.crt -text -noout
openssl verify -CAfile /etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem  ${PWD}/certs/server.crt

##2) create JKS file from the certificates made by step 1

echo "# Pack all the certificates and server private key into a pkcs12 file."

openssl pkcs12 -export -inkey ${PWD}/certs/server.key -in ${PWD}/certs/server.crt -CAfile ${PWD}/certs/root.crt -out ${PWD}/certs/cert-chain.pkcs12

if [ ! -f ${PWD}/jdk*/jre/bin/keytool ] ; then
	echo "#extract JDK"
	if [ -f ${PWD}/jdk*.tar.gz ] ; then
		tar -zxf ${PWD}/jdk*.tar.gz
	else
		echo "JDK tar file not found"
		exit 1
	fi
fi

echo "# Pack that file into a java keystore by using the below keytool command."

${PWD}/jdk*/jre/bin/keytool -importkeystore -srckeystore ${PWD}/certs/cert-chain.pkcs12  -destkeystore ${PWD}/certs/keystore.jks -deststoretype pkcs12
}

#>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>> End Of Function <<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<




function Config_Nexus_Docker {

##3) configure nexus dashboard ports

mkdir -p /nexus-data/etc/ssl
cp ${PWD}/certs/keystore.jks /nexus-data/etc/ssl/

read -p "Enter keystpre.jks password: " jkspass
#sed -e "s/password/${jkspass}/g" ${PWD}/jetty-https.xml > /nexus-data/etc/jetty-https.xml
cat ${PWD}/jetty-https.xml | sed -e  "s/password/${jkspass}/g"  > /nexus-data/etc/jetty-https.xml

chown -R 200:200 /nexus-data

cat << EOF | tee /nexus-data/etc/nexus.properties
application-port-ssl=8443
nexus-args=\${jetty.etc}/jetty.xml,\${jetty.etc}/jetty-http.xml,\${jetty.etc}/jetty-requestlog.xml,\${jetty.etc}/jetty-https.xml
ssl.etc=\${karaf.data}/etc/ssl
EOF


#####For 4 core CPU and specific port:

#####docker run --name nexus -h nexus_docker -e INSTALL4J_ADD_VM_PARAMS="-XX:ActiveProcessorCount=4 -Xms256m -Xmx512m -XX:MaxDirectMemorySize=1024m" -d -p 8443-8444:8443-8444/tcp  -v /nexus-data/:/nexus-data -v /nexus-data/etc/jetty-https.xml:/opt/sonatype/nexus/etc/jetty/jetty-https.xml:ro   sonatype/nexus3:3.63.0

#####For Full cpu and network host port
docker run --name nexus -e INSTALL4J_ADD_VM_PARAMS="-Xms2703m -Xmx2703m -XX:MaxDirectMemorySize=2703m -Djava.util.prefs.userRoot=/nexus-data/javaprefs" -h nexus_docker -d --network=host --restart=unless-stopped  -v /nexus-data/:/nexus-data -v /nexus-data/etc/jetty-https.xml:/opt/sonatype/nexus/etc/jetty/jetty-https.xml:ro   sonatype/nexus3:3.63.0
}

docker load -i ${PWD}/nexus.tgz

Create_Certificates

Config_Nexus_Docker
