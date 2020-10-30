#!/bin/bash
set -xue

echo=""
[[ -f ~/scripts/require.sh ]] && source  ~/scripts/require.sh

export BASE64_ENC="base64 --wrap=0"
[[ "$(uname)" == "Darwin" ]] && export BASE64_ENC="base64 -b 0"

RES=${RES:=""}
ROOTCA="${RES}rootca.crt"  # this file is required for proper creation of trust CA
FQDN=${FQDN:-""}

export BACKUP=${BACKUP:-./backup} && md $BACKUP
export CERTS=${CERTS:-./certs} && md $BACKUP

SECRET=${CERTS}/secret.yml
OPS_SECRET=${CERTS}/ops-secret.yml
OPS_TLSKP=${CERTS}/ops-tlskp.yml

CMD=${1:-source}
KIND=${2:-tf}
COMMON_NAME="${3:-$FQDN}"

if [[ $CMD == "gen" ]]; then
   [[ $KIND != "cb" && $KIND != "tf" && -n $KIND  ]] && echo "can use certbot or terraform source (cb/tf) only " && return 1
fi

truncate_file() {
  file=${1}
  [[ -z $file ]] && echo truncate expect a file name as the positional argument 1 && return 1
  length=$(( $(wc -c < ${file}) - ${2:-1}))
  dd if=/dev/null of=${file} obs="$length" seek=1 >/dev/null 2>&1
}

renew_certs() {
  echo checking if certs are already in current folder
  if [[ -f fullchain.pem ]]; then
    local expire=$(days_to_expiration)
    echo certificate will expire in $expire days
    if [[ $expire -lt 7 ]]; then
      echo renewing certificate
    fi
  fi
}

# Grab certificates and private key from Terraform state file, generate full chain
# needs to run in terraform folder (tfstate and conf)
get_certs_from_tf() {
   terraform output certificate > ${CERTS}/cert && truncate_file ${CERTS}/cert
   terraform output intermediate > ${CERTS}/inter && truncate_file ${CERTS}/inter
   terraform output private_key > ${CERTS}/privkey.pem && truncate_file ${CERTS}/privkey.pem
   mv ${CERTS}/cert ${CERTS}/fullchain.pem
   cat ${CERTS}/inter >> ${CERTS}/fullchain.pem && rm ${CERTS}/inter
   COMMON_NAME=$(terraform output certificate_domain)
}

get_certs_from_cb() { # assumes source has cert,pem, fulldhcain.pem and privkey.pem - copy to workdir
   CB=${1:-""} && [[ -z $CB ]] && echo must provide source directory with certs && return 1
   [[ -z $COMMON_NAME ]] && echo "Must ptovide a common name for the certs" && return 1
   cp $CB/cert.pem ${CERTS}/fullchain.pem
   cat $CB/fullchain.pem >>  ${CERTS}/fullchain.pem
   cp $CB/privkey.pem ${CERTS}/privkey.pem
}

prepare_content() { #
  [[ ! -f $ROOTCA ]] && echo please update the file to point to the rootca.crt this is needed for creating the trust store for the pods... && exit 1
  # Configure certs/secrets files, grab Mozilla CA bundle
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
touch $SECRET
cat > $SECRET <<EOL
apiVersion: v1
kind: Secret
metadata:
  name: anaconda-enterprise-certs
  namespace: default
type: Opaque
data:
EOL
cat $CONTENTS >> $SECRET

sed s/default/kube-system/ $SECRET > $OPS_SECRET

crt=$(cat ${CERTS}/fullchain.pem)

touch $OPS_TLSKP
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
  $echo kubectl replace -f $OPS_SECRET
  $echo kubectl replace -f $SECRET
  $echo sudo gravity resource create $OPS_TLSKP
  $echo sudo gravity site complete
}

backup_certs(){
  BDIR=${BACKUP}certs-`date +%m%d%Y` && md $BDIR
  [[ ! $(command -v kubectl) ]] && echo "can not find kubectl" && return 1
  [[ ! "$(kubectl get secrets  anaconda-enterprise-certs )" ]] && echo "can not find screts" && return 1
  pushd $BDIR
  kubectl get secrets anaconda-enterprise-certs -o json > $(get_backup_file_name anaconda-enterprise-certs.json)
  kubectl get secrets anaconda-enterprise-certs -o json -n kube-system > $(get_backup_file_name ops-anaconda-enterprise-certs.json)
  gravity resource get tlskeypair --format json > $(get_backup_file_name ops-tlskeypair.json)
  popd
}

if [[ $CMD == gen  ]]; then
  [[ $KIND == "cb" ]] && get_certs_from_cb
  [[ $KIND == "tf" || -z $KIND ]] && get_certs_from_tf
  prepare_content && generate_ymls_for_resources # && cleanup
elif [[ $CMD == replace ]]; then
    echo backing up certs in $BDIR
    backup_certs
    echo updating cluster certs
    update_cluster
    echo cleaning up
    cleanup
    echo restarting all pods
    kubectl delete pods --all
fi

set +xue
