#!/bin/bash
# set -xue
set -xu
shopt -s extglob

echo=""

CERTS_SH_DIR="$(cd "$(dirname ${BASH_SOURCE[0]})" >/dev/null 2>&1 && pwd)"
CERTS_SH_FILE=$(basename "${BASH_SOURCE[0]}")
CERTS_SH=$CERTS_SH_DIR/$CERTS_SH_FILE
[[ -f ${CERTS_SH_DIR}/require.sh ]] && source  ${CERTS_SH_DIR}/require.sh

RES=${RES:=""}             # this should be set by require
ROOTCA="${RES}rootca.crt"  # this file is required for proper creation of trust CA, if it is not available will be downloaded
FQDN=${FQDN:-""}           # this should be set by require

export CMD=${1:-source}
export CERTS_SRC=${2:-~/conf/certs}
export KIND=${3:-tf}
export COMMON_NAME="${4:-$FQDN}"


export BACKUP=${BACKUP:-./backup/} && mkdir -p $BACKUP 2>/dev/null
export CERTS=${CERTS:-./certs/} && mkdir -p $CERTS 2>/dev/null

SECRET=${CERTS}secret.yml       # Anaconda Enterprise
OPS_TLSKP=${CERTS}ops-tlskp.yml # Gravity OPS Center

get_backup_file_name() {
  source=${1}
  [[ $source ]] || return 1
  [[ -f $source ]] && source="$source-$(date '+%m%d%y')"
  [[ -f $source-$(date '+%m%d%y') ]] && source=$source-$(date '+%m%d%y_%H')
  [[ -f $source-$(date '+%m%d%y_%H') ]] && source=$source-$(date '+%m%d%y_%H%M')
  [[ -f $source-$(date '+%m%d%y_%H%M') ]] && source=$source-$(date '+%m%d%y_%H%M%S')
  [[ -f $source-$(date '+%m%d%y_%H%M%S') ]] && source=$source-$(date '+%m%d%y_%H%M%S_%s')
  echo $source
}

handle_args() {
  if [[ $CMD == "generate" || $CMD == "renew" ]]; then
     shift;
     [[ ! -d $CERTS_SRC ]] && echo " must be exported pointing to a fodler with certs or main.tf" && return 1
     if [[ $KIND == "tf" ]]; then
        [[ ! -f main.tf ]] &&  echo "ERROR: Can't find main.tf make sure you are in the terraform ssl folder" && return 1
        [[ ! $(command -v terraform) ]] &&  echo "ERROR: Can't find terraform binary which is needed for this " && return 1
        [[ -z AWS_SECRET_ACCESS_KEY ]] && echo "ERROR: Please make sure to set AWS_SECRET_ACCESS_KEY" && return 1
        [[ -z AWS_ACCESS_KEY_ID ]] && echo "ERROR: Please make sure to set AWS_ACCESS_KEY_ID" && return 1
     else echo "$KIND is not supported - Can use certbot or terraform source (folder/tf) only " && return 1
     fi
     [[ ! $(command -v base64) ]] && echo must have base64 for this to work && return 1
     export BASE64_ENC="base64 --wrap=0"
     [[ "$(uname)" == "Darwin" ]] && export BASE64_ENC="base64 -b 0"
  fi 
  return 0
}

truncate_file() { # remove any trailing spaces and special charcters
  file=${1}
  [[ -z $file ]] && echo truncate expect a file name as the positional argument 1 && return 1
  length=$(( $(wc -c < ${file}) - ${2:-1}))
  dd if=/dev/null of=${file} obs="$length" seek=1 >/dev/null 2>&1
}

check_cert_expiration() {
  echo checking if certs are already in current folder
  if [[ -f ${CERTS}fullchain.pem ]]; then
    local expire=$(days_to_expiration)
    echo certificate will expire in $expire days
    if [[ $expire -lt 7 ]]; then
      echo renewing certificate
    fi
  fi
}

get_certs_from_tf() { # get certs using teraform anaconda-etnerprise-ssl module
     terraform output certificate > ${CERTS}cert && truncate_file ${CERTS}cert
     terraform output intermediate > ${CERTS}inter && truncate_file ${CERTS}inter
     terraform output private_key > ${CERTS}privkey.pem && truncate_file ${CERTS}privkey.pem
     mv ${CERTS}cert ${CERTS}fullchain.pem
     cat ${CERTS}inter >> ${CERTS}fullchain.pem && rm ${CERTS}inter
     COMMON_NAME=$(terraform output certificate_domain)
}

get_certs_from_folder() { # assumes source has cert,pem, fulldhcain.pem and privkey.pem - copy to workdir
   CB=${1:-""} && [[ -z ${CERTS_SRC} ]] && echo must provide source directory with certs && return 1
   [[ -z $COMMON_NAME ]] && echo "Must ptovide a common name for the certs" && return 1
   cp ${CERTS_SRC}/cert.pem ${CERTS}fullchain.pem
   cat ${CERTS_SRC}/fullchain.pem >>  ${CERTS}fullchain.pem
   cp ${CERTS_SRC}/privkey.pem ${CERTS}privkey.pem
}

prepare_content() { #
  if [[ ! -f $ROOTCA ]]; then 
    echo AE5 needs a ca bundle to place in all containers, because the file is not found, trying to get it from anaconda.
    wget -q https://curl.haxx.se/ca/cacert.pem -O $ROOTCA
    if [[ $? -ne 0 ]]; then echo failed to get rootca exiting && return 1 ; fi
  fi
  CONTENTS=${CERTS}contents.yml

  # Delete existing keystore, discard error from non-existent keystore
  keytool -noprompt -delete -alias auth -keystore ${CERTS}keystore.jks -storepass anaconda 2&> /dev/null

  # Generate the PKCS12 certs
  openssl pkcs12 -passout pass:anaconda -export -in ${CERTS}fullchain.pem -inkey \
  ${CERTS}privkey.pem -out ${CERTS}${COMMON_NAME}.p12 -name auth

  # Generate the keystore
  keytool -noprompt -importkeystore -deststorepass anaconda -destkeypass anaconda -destkeystore \
  ${CERTS}keystore.jks -srckeystore ${CERTS}${COMMON_NAME}.p12 -srcstoretype PKCS12 -srcstorepass anaconda -alias auth

  # Generate the contents for both the AE secret and Ops Center secret
  printf "  tls.crt: " > $CONTENTS
  $BASE64_ENC ${CERTS}fullchain.pem >> $CONTENTS
  printf '\n' >> $CONTENTS
  printf "  tls.key: " >> $CONTENTS
  $BASE64_ENC ${CERTS}privkey.pem >> $CONTENTS
  printf '\n' >> $CONTENTS
  printf "  wildcard.crt: " >> $CONTENTS
  $BASE64_ENC ${CERTS}fullchain.pem >> $CONTENTS
  printf '\n' >> $CONTENTS
  printf "  wildcard.key: " >> $CONTENTS
  $BASE64_ENC ${CERTS}privkey.pem >> $CONTENTS
  printf '\n' >> $CONTENTS
  printf "  keystore.jks: " >> $CONTENTS
  $BASE64_ENC ${CERTS}keystore.jks >> $CONTENTS
  printf '\n' >> $CONTENTS
  printf "  rootca.crt: " >> $CONTENTS
  $BASE64_ENC $ROOTCA >> $CONTENTS
  printf '\n' >> $CONTENTS
}

generate_ymls_for_resources() {
# Generate secret.yml
cat > $SECRET <<EOL
apiVersion: v1
kind: Secret
type: Opaque
metadata:
  name: anaconda-enterprise-certs
  namespace: default
data:
EOL
cat $CONTENTS >> $SECRET


crt=$(cat ${CERTS}fullchain.pem)

cat > $OPS_TLSKP <<EOL
kind: tlskeypair
version: v2
metadata:
  name: keypair
spec:
  private_key: |
  `awk '{if (NR <= 1 ) { print "  "$0} else {print "    "$0}}' ${CERTS}privkey.pem`
  cert: |
  `awk '{if (NR <= 1) { print "  "$0} else {print "    "$0}}' ${CERTS}fullchain.pem`
EOL

}

cleanup() {
  pushd $CERTS
  for f in fullchain.pem privkey.pem *.p12 keystore.jks contents.yml
  do
    [[ -f $f ]] && rm $f
  done
  popd
}


days_to_expiration() {
  expires="$( openssl x509 -dates -noout < fullchain.pem | awk -F= '/notAfter/ {$1="";print}' | awk '{$NF="";print}')"
  expires_epoc=$(date -j -f "%b   %d %H:%M:%S %Y" "$expires" +%s 2>/dev/null)
  now=$(date +%s)
  days_to_expiration=$(( ($expires_epoc - $now) / (60*60*24) ))
  echo $days_to_expiration
}

update_cluster() { # if running on the AE5 server can do the update in place otherwise need ansible to do that.
  [[ ! -f $SECRET ]] && echo SECRET must be a path to a secret resource file && return 1
  $echo kubectl replace -f $SECRET
  sed -i s/default/kube-system/ $SECRET 
  $echo kubectl replace -f $SECRET
  $echo sudo gravity resource create $OPS_TLSKP
  $echo sudo gravity site complete
}

backup_certs(){
  BDIR=${BACKUP}certs-`date +%m%d%Y` && mkdir -p $BDIR > /dev/null
  [[ ! $(command -v kubectl) ]] && echo "can not find kubectl" && return 1
  [[ ! "$(kubectl get secrets  anaconda-enterprise-certs )" ]] && echo "can not find screts" && return 1
  pushd $BDIR
  kubectl get secrets anaconda-enterprise-certs -o json > $(get_backup_file_name anaconda-enterprise-certs.json)
  kubectl get secrets anaconda-enterprise-certs -o json -n kube-system > $(get_backup_file_name ops-anaconda-enterprise-certs.json)
  gravity resource get tlskeypair --format json > $(get_backup_file_name ops-tlskeypair.json)
  popd
}

replace_certs() {
  backup_certs \
  && update_cluster \
  && cleanup \
  && echo for new certs to take effect execture kubectl delete pods --all
}

generate_certs() {
  handle_args $@ \
  && get_certs_from_$KIND \
  && prepare_content \
  && generate_ymls_for_resources # && cleanup
}

renew_certs() {
  # call terraform apply &&
  generate_certs $@ &&
  replace_certs 
}
  
usage() {
  echo "$1"
  echo "$CERTS_SH_FILE generate path [ tf | folder ] [ FQDN ] # generate secret using tf/folder (lets encrypt)"
  echo "$CERTS_SH_FILE renew path [ tf | folder ]             # same as above but also replace the certs - must be on AE5 master"
  echo "$CERTS_SH_FILE replace [ path ]                       # backup certs and replace - must be on AE5 master"
}   

[[ $CMD == replace ]] && replace_certs
[[ $CMD == generate  ]] && generate_certs $@
[[ $CMD == renew ]] && renew_certs $@
[[ $CMD == source ]] && [[ $0 =~ bash ]] && echo sourced $CERTS_SH 
[[ $CMD == source ]] && [[ ! $0 =~ bash ]] && usage "please source $CERTS_SH or "

# set +xue

# TODO: Add provision for the actual ACME flow
# setup terraform / certbot 
# handle aws login for terraform / certbot for the route-53 plugin

