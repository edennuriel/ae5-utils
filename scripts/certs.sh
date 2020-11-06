#!/bin/bash
set -xue

echo=""
[[ -f ~/scripts/require.sh ]] && source  ~/scripts/require.sh

RES=${RES:=""}
ROOTCA="${RES}rootca.crt"  # this file is required for proper creation of trust CA
FQDN=${FQDN:-""}

export BACKUP=${BACKUP:-./backup} && mkdir -p $BACKUP 2>/dev/null
export CERTS=${CERTS:-./certs} && mkdir -p $CERTS 2>/dev/null

SECRET=${CERTS}/secret.yml       # Anaconda Enterprise
OPS_TLSKP=${CERTS}/ops-tlskp.yml # Gravity OPS Center

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
  export CMD=${1:-source}
  export KIND=${2:-tf}
  export COMMON_NAME="${3:-$FQDN}"

  if [[ $CMD == "generate" || $CMD == "renew" ]]; then
     if [[ $KIND == "tf" ]]; then
        if [[ ! -f main.tf ]] || [[ ! $(command -v terraform) ]]; then echo "This needs to be run from tf folder" && return 1; fi
     elif [[ $KIND == "folder" ]]; then [[ ! -d $CB ]] && echo "CB must be exported with the folder where certs and keys are" && return 1; fi
     else echo "$KIND is not supported - Can use certbot or terraform source (folder/tf) only " && return 1
     fi
     [[ ! $(command -v base64) ]] && echo must have base64 for this to work && return 1
     export BASE64_ENC="base64 --wrap=0"
     [[ "$(uname)" == "Darwin" ]] && export BASE64_ENC="base64 -b 0"
  fi 
}

truncate_file() { # remove any trailing spaces and special charcters
  file=${1}
  [[ -z $file ]] && echo truncate expect a file name as the positional argument 1 && return 1
  length=$(( $(wc -c < ${file}) - ${2:-1}))
  dd if=/dev/null of=${file} obs="$length" seek=1 >/dev/null 2>&1
}

check_cert_expiration() {
  echo checking if certs are already in current folder
  if [[ -f ${CERTS}/fullchain.pem ]]; then
    local expire=$(days_to_expiration)
    echo certificate will expire in $expire days
    if [[ $expire -lt 7 ]]; then
      echo renewing certificate
    fi
  fi
}

get_certs_from_tf() { # get certs using teraform anaconda-etnerprise-ssl module
     terraform output certificate > ${CERTS}/cert && truncate_file ${CERTS}/cert
     terraform output intermediate > ${CERTS}/inter && truncate_file ${CERTS}/inter
     terraform output private_key > ${CERTS}/privkey.pem && truncate_file ${CERTS}/privkey.pem
     mv ${CERTS}/cert ${CERTS}/fullchain.pem
     cat ${CERTS}/inter >> ${CERTS}/fullchain.pem && rm ${CERTS}/inter
     COMMON_NAME=$(terraform output certificate_domain)
   else
     echo to get cerificates via teraform you must have terraform installed and run this from the ssl teraform folder
     return 1
   fi
}

get_certs_from_folder() { # assumes source has cert,pem, fulldhcain.pem and privkey.pem - copy to workdir
   CB=${1:-""} && [[ -z $CB ]] && echo must provide source directory with certs && return 1
   [[ -z $COMMON_NAME ]] && echo "Must ptovide a common name for the certs" && return 1
   cp $CB/cert.pem ${CERTS}/fullchain.pem
   cat $CB/fullchain.pem >>  ${CERTS}/fullchain.pem
   cp $CB/privkey.pem ${CERTS}/privkey.pem
}

prepare_content() { #
  if [[ ! -f $ROOTCA ]]; then 
    echo AE5 needs a ca bundle to place in all containers, because the file is not found, trying to get it from anaconda.
    wget -q https://curl.haxx.se/ca/cacert.pem -O $ROOTCA
    if [[ $? -ne 0 ]]; then echo failed to get rootca exiting && return 1 ; fi
  fi
  CONTENTS=${CERTS}/contents.yml

  # Delete existing keystore, discard error from non-existent keystore
  keytool -noprompt -delete -alias auth -keystore ${CERTS}/keystore.jks -storepass anaconda 2&> /dev/null

  # Generate the PKCS12 certs
  openssl pkcs12 -passout pass:anaconda -export -in ${CERTS}/fullchain.pem -inkey \
  ${CERTS}/privkey.pem -out ${CERTS}/${COMMON_NAME}.p12 -name auth

  # Generate the keystore
  keytool -noprompt -importkeystore -deststorepass anaconda -destkeypass anaconda -destkeystore \
  ${CERTS}/keystore.jks -srckeystore ${CERTS}/${COMMON_NAME}.p12 -srcstoretype PKCS12 -srcstorepass anaconda -alias auth

  # Generate the contents for both the AE secret and Ops Center secret
  printf "  tls.crt: " > $CONTENTS
  $BASE64_ENC ${CERTS}/fullchain.pem >> $CONTENTS
  printf '\n' >> $CONTENTS
  printf "  tls.key: " >> $CONTENTS
  $BASE64_ENC ${CERTS}/privkey.pem >> $CONTENTS
  printf '\n' >> $CONTENTS
  printf "  wildcard.crt: " >> $CONTENTS
  $BASE64_ENC ${CERTS}/fullchain.pem >> $CONTENTS
  printf '\n' >> $CONTENTS
  printf "  wildcard.key: " >> $CONTENTS
  $BASE64_ENC ${CERTS}/privkey.pem >> $CONTENTS
  printf '\n' >> $CONTENTS
  printf "  keystore.jks: " >> $CONTENTS
  $BASE64_ENC ${CERTS}/keystore.jks >> $CONTENTS
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


crt=$(cat ${CERTS}/fullchain.pem)

cat > $OPS_TLSKP <<EOL
kind: tlskeypair
version: v2
metadata:
  name: keypair
spec:
  private_key: |
  `awk '{if (NR>1) print "    "$0; if (NR<=1) print $0}' ${CERTS}/privkey.pem`
  cert: |
  `awk '{if (NR>1) print "    "$0; if (NR<=1) print $0}' ${CERTS}/fullchain.pem`
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
  generate_certs $@ &&
  replace_certs 
}
  
[[ $CMD == replace ]] && replace_certs
[[ $CMD == generate  ]] && generate_certs $@
[[ $CMD == renew ]] && renew_certs $@

set +xue
