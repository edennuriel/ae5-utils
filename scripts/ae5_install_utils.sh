#!/usr/bin/env bash
echo ae5_install_utils
set -xue
shopt -s extglob
unset ME MYFILE MYDIR

MYDIR="$(cd "$(dirname ${BASH_SOURCE[0]})" >/dev/null 2>&1 && pwd)"
MYFILE=$(basename "${BASH_SOURCE[0]}")
ME=$MYDIR/$MYFILE
[[ -f ./require.sh ]] && source ./require.sh 
[[ $? -ne 0 ]] && echo could not source ./require.sh exiting && exit
# looking for any overrides (password for most part)
[[ -f ./env.sh  ]] && source ./env.sh
typeset -f bash_utils  || source ./bash_utils.sh 2>/dev/null
[[ $? -ne 0 ]] && echo "cannot source bash_utils exiting " && exit 1
# export AE5CLIENV="../conf/ae5cli_env.yml"
export REPO_PATH='/opt/anaconda/storage/object/anaconda-repository/'
export AEURL="https://$SHORTNAME.demo.anaconda.com/repository"
export UPDATE_TMPL="$FQDN.yaml"
export MYBIN=~/bin
export AE_CHART_PATH="/var/lib/gravity/site/packages/unpacked/gravitational.io/AnacondaEnterprise/${AEVER}/resources/helm-charts/Anaconda-Enterprise"
export TOKENFILE=~/.anaconda/anaconda-platform/tokens.json
CMD=${1:-""}

install_conda() { # install miniconda from bootstrap ae5 or from latest
  echo installing conda from bootstrap if found or miniconda if not
  local conda_installer=""
  install_utils
  if [[ ! $(command -v conda) ]];then
    [[ -f ~/anaconda-enterprise${AEVER}/installer/conda-bootstrap* ]] &&  conda_installer="~/anaconda-enterprise-${AEVER}/installer/conda-bootstrap*"
    if [[ -z $conda_installer ]]; then
       [[ -f ./Miniconda3-latest-Linux-x86_64.sh ]] || wget -q https://repo.anaconda.com/miniconda/Miniconda3-latest-Linux-x86_64.sh >> $ALLLOG 2>&1
       conda_installer=./Miniconda3-latest-Linux-x86_64.sh
    fi
    [[ -d ~/conda ]] && UPDATE=" -u "
    [[ -z $conda_installer ]] && echo cannot install conda && return 1
    bash $conda_installer $UPDATE -b -p ~/conda  >> $ALLLOG 2>&1
    ln ~/conda/bin/conda $MYBIN/conda 2>/dev/null
    export PATH="$MYBIN:$PATH"
    conda update conda -n base -y -q  >> $ALLLOG 2>&1
    conda init  >> $ALLLOG 2>&1
    source ~/.bashrc
  else 
   echo conda already avilable
  fi
}

create_ae5cli() { # ceate and activate ae5cli env with ae5 depgraph cas-mirror anaconda-enterprise-cli yq conda-depgraph
  [[ $(command -v conda) ]] || install_conda
  conda create -n ae5cli -q -y  >> $ALLLOG 2>&1
  conda install -n ae5cli -q -y  conda-depgraph anaconda-enterprise-cli cas-mirror ae5-tools accord yq git python-keycloak requests \
  -c ae5-admin \
  -c defaults \
  -c conda-forge \
  -c http://conda.anaconda.org/omegacen  >> $ALLLOG 2>&1
  # or conda env create -f $AE5CLIENV
}

install_utils() { # install admin utils
 # TODO: move to ansible/salt
 echo installing helm yq wget jq git bzip2 and bash-completion
 HELM=https://storage.googleapis.com/kubernetes-helm/helm-v2.8.1-linux-amd64.tar.gz
 YQ=https://github.com/mikefarah/yq/releases/download/2.4.0/yq_linux_amd64
 [[ -d $MYBIN ]] || mkdir $MYBIN
 for cmd in bzip2 git wget jq bash-completion
 do
   [[ $(command -v $cmd) ]] || sudo yum install $cmd -y -q
 done
 [[ $(command -v yq1) ]] || wget -q $YQ -O $MYBIN/yq1 && chmod +x $MYBIN/yq1
 if [[ ! $(command -v helm) ]]; then
    wget -q $HELM -O /tmp/helm.tar.gz  >> $ALLLOG 2>&1
    tar xvf /tmp/helm.tar.gz --strip-components 1 -C $MYBIN linux-amd64/helm  >> $ALLLOG 2>&1
  fi
}

configure_kubectl() { # Create kubectl config for the cluster
  # TODO: find the public IP and if not running on the master node configure local client (maybe with gravity)
  # configure kubectl
  MASTER_HOST=10.100.0.1
  CA_CERT=/var/lib/gravity/secrets/root.cert
  ADMIN_CERT=/var/lib/gravity/secrets/kubectl.cert
  ADMIN_KEY=/var/lib/gravity/secrets/kubectl.key

  kubectl config set-cluster default-cluster --server=https://${MASTER_HOST} --certificate-authority=${CA_CERT}
  kubectl config set-credentials default-admin --certificate-authority=${CA_CERT} --client-key=${ADMIN_KEY} --client-certificate=${ADMIN_CERT}
  kubectl config set-context default --cluster=default-cluster --user=default-admin
  kubectl config use-context default
}

configre_ae5_tools() {
  echo
}

configre_anaconda_cli() { # Configure anaconda-enterprise-cli to point to AE5
   echo configuering anaconda-enterprise-cli to point to current cluster
   anaconda-enterprise-cli config set sites.${SHORTNAME:-default}.url https://${FQDN}/repository/api
   anaconda-enterprise-cli config set default_site ${SHORTNAME:-default}
   anaconda-enterprise-cli config set ssl_verify false
}

configure_condarc() {
 echo
}

configre_ae5master_clients() { # Configure anaconda-enterprise-cli to point to AE5
   echo configuering condarc
}

create_ae5_condarc() { # Create a json config for conda to be included in the anaconda-platform-yaml pointing to cluster channels
  echo createing ~/.condarc pointing to the cluster
  CONDARC=${CONDARC:-${CUST}condarc/local.json}
  md $(dirname $CONDARC)
  # generated  at install time $(date +"created on %D at %T by ${REAL_USER:-eden}")
  cat << EOF > $CONDARC
{
 "conda": {
    "auto_update_conda": false,
    "show_channel_urls": true,
    "channel_alias": "${FQDN}/repository/conda",
    "ssl_verify": "/var/run/secrets/anaconda/ca-chain.pem",

    "channels": [ "defaults" ],
    "default_channels": [ "main","r" ]
  }
}
EOF
}

remove_conda() {  # remove anaconda from the host
  echo removing conda completely
  rm -rf ~/conda/
  rm ~/bin/conda
  rm -rf ~/.conda/
  [[ $(grep "conda initialize" ~/.bashrc 2>/dev/null) ]] && sed -i '/^# >>>/,/^# <<</d' ~/.bashrc
}

set +xue

