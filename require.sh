#!/usr/bin/env bash
shopt -s extglob
export DEFAULT_USERNAME=admin
export DEFAULT_PASSWORD=admin123

# AE5
export AE5_USERNAME=${AE5_USERNAME:-$DEFAULT_USERNAME}  
export AE5_PASSWORD=${AE5_PASSWORD:-$DEFAULT_PASSWORD}    
# KeyCloak
export AE5_ADMIN_USERNAME=${AE5_ADMIN_USERNAME:-$DEFAULT_USERNAME} 
export AE5_ADMIN_PASSWORD=${AE5_ADMIN_PASSWORD:-$DEFAULT_PASSWORD} 
# OPS Center
export AE5_OPS_USERNAME=${AE5_OPS_USERNAME:-$DEFAULT_USERNAME} 
export AE5_OPS_PASSWORD=${AE5_OPS_PASSWORD:-$DEFAULT_PASSWORD}

export BASEDIR=${BASEDIR:-~}                  
export FQDN=${FQDN:-""}                      

unset ME MYFILE MYDIR
MYDIR="$(cd "$(dirname ${BASH_SOURCE[0]})" >/dev/null 2>&1 && pwd)"
MYFILE=$(basename "${BASH_SOURCE[0]}")
ME=$MYDIR/$MYFILE

set_ae5_env() {
  export FQDN="${FQDN:-ae541dev.demo.anaconda.com}"
  export SHORTNAME=${FQDN/.*}
  export DOMAIN=${FQDN/${SHORTNAME}/}
  export AEVER="${AEVER:-5.4.1-83.ge9f67fb31}"
}

## for existing installs
get_ae5_env() {
    [[ ! $(command -v kubectl) ]] && echo kubectl not found - if this is a new install you must set FQDN  && return 1
    export FQDN=$(kubectl get cm anaconda-enterprise-install -o jsonpath='{.data}' | awk -F : '/hostname/ {print $3}' | tr -d " ")
    export SHORTNAME=${FQDN/.*}
    export DOMAIN=${FQDN/${SHORTNAME}/}
    export AEVER="$(gravity status | awk '/version/ {print $4}')" 
    export AEIP="$(kubectl get nodes -o wide | awk '/master/ {print $6}')"
}

[[ -z $FQDN ]] && get_ae5_env || set_ae5_env
[[ $? -ne 0 ]] && echo failed to set the environment properly

export SCR=${BASEDIR}/scripts/
export CONF=${BASEDIR}/conf/
export BACKUP=${BASEDIR}/backups/
export MIRROR=${CONF}mirror/
export CUST=${CONF}customizations/
export CERTS=${CONF}certs/
export LOGDIR=${BASEDIR}/logs
export STDLOG=${LOGDIR}/installer.log
export ERRLOG=${LOGDIR}/installer.err
export ALLLOG=${LOGDIR}/out.log
export STATE=${LOGDIR}/state.log
export AE5_HOSTNAME=$FQDN

