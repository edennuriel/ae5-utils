#/usr/bin/env bash
## Conda Client Helpers ##

get_token() { # try to obtain the persistent token stored by anaconda enterprise client
  log "looking in $TOKENFILE for tokens" 1
  if [[ -f ~/.anaconda/anaconda-platform/tokens.json ]]; then
    TOKEN=$( jq -r --arg AEURL "$AEURL/api" '.|to_entries[]|select(.key|tostring|.==$AEURL)|.value.bearer_token' $TOKENFILE)
  log "found token in $TOKENFILE" 1
  echo $TOKEN
 else
  log "Must login to get a token" 2
  echo token-not-set
 fi
}

get_condarc() { # return the full path to hte configuration files used by conda
   condarc=$(conda info --json | jq -r '.rc_path')
   [[ -z ${condarc} ]] && condarc="~/.condarc"
   echo $condarc
}

condarc_configured() {  # create a condarc with all channels the user has access to
  condarc=$(get_condarc)

  # if configured for the same user (can only work when using explixit tokens)
  #if [[ -f $condarc ]] && [[ $(grep ${TOKEN:-token-not-set} $condarc) ]]; then echo yes

  if [[ -f $condarc ]]; then echo yes
  else echo no
  fi
}


configure_condarc() { # create a condarc with all channels the user has access to
   condarc=$(get_condarc)
   log "configuering condarc" 1
   log "checking access to all channels \"$channels\"" 1
   channels=$(get_channels)

   if [[ ! -f $condarc ]]; then log "Creating a new condarc in $condarc" 1
   else backup $condarc
   fi

   cat > "${condarc}" << EOF
# add_anaconda_token: False
allow_other_channels: False #locks down channels for aliases only...
auto_update_conda: False
show_channel_urls: True
ssl_verify: False
channel_alias: $AEURL/conda

channels:
 - defaults

default_channels:
EOF
  log "checking access to channels " 1
  add_channels $channels >> "${condarc}"
}

aelogin() {  # login to anaconda enterprise, this will also configure condarc
   user=${1:+"--username=$1"}
   shift
   pass=${1:+"--password=$2"}
   shift

   #$(process_args)
   export TOKEN=$(get_token)
   log "Checking if token exists" 1
   [[ $TOKEN != 'token-not-set' ]] &&  [[ $(yesno "Token exists, do you want to login as a different user?") == yes ]] && export TOKEN='token-not-set'
   log "Logging in" 1
   [[ $TOKEN == 'token-not-set' ]] && anaconda-enterprise-cli login $user $pass
   [[ $(condarc_configured) == "yes" ]] && [[ $(yesno "Do you want to reconfigure .condarc?") == "yes" ]] && backup $condarc
   [[ $(condarc_configured) == "no" ]] && configure_condarc
}

remove_conda() {
  rm -rf $MYBIN/conda ~/conda ~/.condarc ~/.conda ~/.anaconda ~/.binstar 2>/dev/null
  sed -i.rmconda '/# >>> conda/,/#<<< conda/d' ~/.bashrc
}

