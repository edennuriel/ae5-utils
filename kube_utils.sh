kcomp() { #activate complitions for kubectl
 source <(kubectl completion bash)
 # [[ -n $KUBECONFIG ]] && return
 # [[ ! -f ~/.kube/config ]] && cp $KUBECONFIG ~/.kube/config
 # unset KUBECONFIG
}

kubectl() {
 unset MYKAS
 if [[ -n $KAS ]]; then
   MYKAS="--as $KAS"
   echo "running as $KAS"
 fi
 sudo gravity exec -ti kubectl $MYKAS "$@"
}

kns() { #change neame space for active context
  ns=${1:-default}
  kubectl config set-context --current --namespace=$ns
}


kas() { #set user/service account for current context
  if [[ -n $1 ]]; then
    export KAS=system:serviceaccount:$1
 else
    unset KAS
 fi
}
  

