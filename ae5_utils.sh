#!/usr/bin/env bash
unset ME MYFILE MYDIR
shopt -s extglob

MYDIR="$(cd "$(dirname ${BASH_SOURCE[0]})" >/dev/null 2>&1 && pwd)"
MYFILE=$(basename "${BASH_SOURCE[0]}")
ME=$MYDIR/$MYFILE
echo sourcing require.sh
[[ -f ./require.sh ]] && source ./require.sh
[[ $? -ne 0 ]] && echo could not source ./require.sh exiting && exit
echo "looking for overrides in env (password and such)"
[[ -f ./env.sh  ]] && source ./env.sh
echo sourcing bash_utils.sh 
typeset -f bash_utils  || source ./bash_utils.sh 2>/dev/null
[[ $? -ne 0 ]] && echo "cannot source bash_utils exiting " && exit 1

dependency_check() {
  for dep in helm jq gravity yq ae5 anaconda-enterprise-cli kubectl ; do
    [[ ! $(command -v $dep ) ]] && echo missing $dep && return 1
  done
}

ae5cli() {
  [[ $(conda info --env | grep ae5cli) ]] && conda activate ae5cli && return
  [[ $(command -v conda) ]] && install_conda && create_ae5cli
}

## Anaconda Enterprise CLI Helpers ##
add_channels() {
  channels=$*
  for channel in $channels
  do
    echo " - $AEURL/conda/$channel"
 done
 }

get_channels() { # get the list of channels user has access to
   echo $(anaconda-enterprise-cli channels list 2>/dev/null >&1| awk '! /==|Name/ {print $1}')
}


remove_tokens() { # remove tokens from conda and remove condarc
  log "removing tokens from $TOKENFILE and ~/.config/binstar" 1
  local t
  [[ -f $TOKENFILE ]] && rm -f $TOKENFILE
  rm -f ~/.config/binstar/*.token
}

env_lang_setup() { # Set env to UTF8 and english
  export PYTHONIOENCODING=UTF8
  export LC_ALL=en_CA.utf8
}

make_conda_public() { # remove tokens
  #sed -i 's#/t/[a-zA-Z0-9]*##g' ${1:-$condarc}
  remove_tokens
}


# demo helpers
# make this auto generated with make funcs..


repo_sources() { # show the different sources for packages in exising env
  conda list --explicit | awk -F/ '/https/ {print $3}' | sort
}

aec() { # alias for anaconda-enterprise-cli
  anaconda-enterprise-cli $*
}

ap() { # alias for anaconda-project
  anaconda-project $*
}

find_new_packages() { # find the packages that are needed (dependecies) for a set of new packages
  test_env=test1
  local
  npkg=${1:-tranquilizer}
  local repo=${2:-conda-forge}
  #dry='--dry-run'
  conda install $dry -n $test_env $npkg -c defaults -c https://conda.anaconda.org/$repo --show-channel-urls  2>/dev/null| awk "/$repo/ {print \$1}"
}

find_existing_packages() { # print package files that are available in local channels
  for i in $(find_new_packages); do aec packages list-files ${1:-conda-forge} $i 2>/dev/null| awk '/'$i'/ {print $2" "$1}' ;done
}

copy_to_channel() { # copy files to channel (upload)
  for i in $(npkgs ${1:-tranquilizer}); do aec packages list-files ${1:-conda-forge} $i 2>/dev/null| awk '/'$i'/ {print $2" "$1}' ;done | xargs -n2 -I% echo aec packages copyfile conda-forge % ${2:-developers}
}


mirror() {
  [[ -f $1 ]] && local yml=$1
  [[ ! -z $yml ]] && /home/centos/conda/envs/ae531/bin/cas-sync-api-v5 -f $yml -vc
}

get_path_to_env_pkgs() {
  cenvs=$(conda info | awk -F: '/directories/ {print $2}')
  ep=${cenvs}/${1:-build}/conda-meta
  find $ep -name "*.json" | xargs jq -r '.package_tarball_full_path'

}

replace_secrets() {
 if [[ x$1==x ]] || [[ x$2==x ]]; then
   echo "usage: replace secrets <secret name> <new secret resource file>"
 else
   kubectl get "$1" -o json > "$1.$(now).yml"
   [[ -f "$2" ]] && kubectl replace -f "$2"
 fi
}

replace_keycloak() {
	# delete old keycloak config and import new one
	kubectl delete secrets anaconda-enterprise-keycloak -n default
	kubectl create secret generic anaconda-enterprise-keycloak --from-file=/tmp/resources/keycloak.json -n default
}

replace_ae_certs() {
	# delete old cert and import new one
	kubectl delete secrets anaconda-enterprise-certs -n default --ignore-not-found=true

	# delete old ops cert and import new one
	# 'anaconda-enterprise-certs -n kube-system' only exists in 5.2.1+ installers
	kubectl delete secrets anaconda-enterprise-certs -n kube-system --ignore-not-found=true

	kubectl create -f /tmp/$FQDN/secret.yml
	kubectl create -f /tmp/$FQDN/ops_secret.yml
}

ae5_restart() {
	kubectl get po -n default | grep "ap-" | awk '{print $1}' | xargs kubectl delete po -n default
}

## cleanup
ae_cleanup() {
	kubectl delete svc -n kube-system anaconda-enterprise-ae-wagonwheel
	kubectl delete deployments -n kube-system anaconda-enterprise-ae-wagonwheel
	kubectl delete job -n default wait-for-wagonwheel
	kubectl delete job -n default generate-certs
	gravity site complete
}

ae_mirror() {
 echo "configuering cas-mirror"
 tar -C ~ -xvf /tmp/resources/mirror.tar.gz
}

aelogin() {
  user="${1:-enuriel}"
  pass="${2:-anaconda}"
  anaconda-enterprise-cli login --username=$user --password=$pass
}

create_ops_admin() {
  [[ -n $1 ]] && AE5_OPS_USERNAME="$1"
  [[ -n $2 ]] && AE5_OPS_PASSWORD="$2"

  sudo gravity enter -- --notty '/usr/bin/gravity' -- --insecure user create --type=admin --email="${AE5_OPS_USERNAME:-$DEFAULT_USERNAME}" --password="${AE5_OPS_PASSWORD:-$DEFAULT_PASSWORD}" --ops-url=https://gravity-site.kube-system.svc.cluster.local:3009
}
psql() {
  pcmd=$(kubectl get pods | awk '/postgres/ { print "kubectl exec -it "$1"  -- /usr/bin/psql -qt -U postgres "}')
  [[ ! -z $1 ]] && pcmd="$pcmd -d $1"
  [[ ! -z $2 ]] && pcmd="$pcmd -c \"$2\""
  eval "$pcmd"
}

############ LOCAL REPO UTILS ###############
export_channel(){
  channel=${1:-anaconda-enterprise}
  channels="select * from channels where name='"$channel"'"
  packages="select * from packages where channel_name='"$channel"'"
  package_files="select * from package_files where package_id in (select id from packages where channel_name='"$channel"')"
  mkdir $channel
  for i in channels packages package_files
  do
      #echo psql anaconda_repository '"'"COPY (${!i}) TO STDOUT;"'"' redirected_to  "$channel/$i.sql"
      psql anaconda_repository "COPY (${!i}) TO STDOUT;" > "$channel/$i.sql"
  done
  eval "$(copy_repo $channel)"
}


import_channel() {
  local exit_msg=""
  # cat test/packages.sql | psql anaconda_repository 'COPY packages FROM STDIN;'
  channel=${1}
  [[ -z $channel ]] && echo "No channel name provided" && return
  for i in channels packages package_files
  do
    [[ ! -f $channel/$i.sql ]] && echo "$exit_msg$channel/$i.sql is missing" && return
  done
  channel_exists=$(psql anaconda_repository "select name from channels where name='"$channel"';")
  [[ -n ${channel_exists//[[:space:]]} ]] && echo "channel $channel already exists!" && return
  [[ ! -f $channel/$channel.tar.gz ]] && echo "must have a tar file with packages and meta data $channels/$channel.tar.gz" && return
  for i in channels packages package_files
  do
    cat "$channel/$i.sql" | psql anaconda_repository "COPY $i FROM STDIN;"
  done
  tar xvf $channel/$channel.tar.gz -C $REPO_PATH
  [[ -n $exit_msg ]] && printf "$exit_msg"
 }

get_bucket_name() {
  channel=${1:-anaconda-enterprise}
  bucket_name="$(psql anaconda_repository "select bucket_name from channels where name ='"$channel"'")"
  echo "${bucket_name//[[:space:]]}"
}


copy_repo() {
   channel=${1:-anaconda-enterprise}
   bn="$(get_bucket_name $channel)"
   tar_file="${channel}.tar.gz"
   echo tar czvf "$channel/$tar_file" -C "$REPO_PATH$bn/.." ${bn##*/}
}


# generate for all users...
eden() { anaconda-enterprise-cli login --username eden --password ${pass} ; }
admin() { anaconda-enterprise-cli login --username admin --password ${pass} ; }

grv() {
  sudo gravity exec /usr/bin/gravity --insecure $*
}

docker() {
  sudo gravity exec -t /usr/bin/docker $*
}
export -f docker

echo "use docker for docker in gravity, and grv for running gravity command in gravity conrtainer"

# kubectl get pods | awk '/-session=/'
# kubectl get pods | awk '/postgres/ { print "kubectl exec -it "$1"  -- /usr/bin/pg_dumpall -U postgres  "}'


search_deployments(){
  for dep in $(kubectl get deploy | c1 | egrep -v 'NAME|sess')
  do
    echo searching $dep ;
    kubectl get deploy $dep -o yaml | grep ${1:-ae-ed}
  done
}


## AE5 CLI Helpers ##
ae5_ls_projects () {
   [[ $1 == "-a" ]] && ae5 project list --format json 2>$ERRLOG| jq -r '.[]|"\"\(.id):\(.owner)\/\(.name)\""'
   [[ $1 == "-i" ]] && ae5 project list --format json 2>$ERRLOG| jq -r '.[]|"\(.id)"'
   [[ -z $1 ]] && ae5 project list --format json 2>$ERRLOG | jq '.[].name'
}
export -f ae5_ls_projects

ae5_get_project_id() {
  ae5_ls_projects -a | grep "$1" | awk '{print $1}'
}

ae5_ls_revisions() {
  log "Filtering projects on \"${1:-:}\"" 0
  ae5_ls_projects -a | grep ${1:-:} | while read prj
  do
    id=$(echo $prj | sed -e 's#:.*##' -e 's#"##g')
    pname=$(echo $prj | sed -e 's#.*/##' -e 's#"##g')
    user=$(echo $prj | sed -e 's#/.*$##' -e 's#^.*:##')
    log "getting revisions for $pname with id $id" 0
    ae5 project revision list "$id" --no-header --columns "name" 2>>$ERRLOG | xargs -I% -n1 echo $pname:$user:$id:%
  done
}
export -f ae5_ls_revisions

ae5_backup_revisions() {
  local user pname id ver rev
  ae5_ls_revisions ${1} | while read rev
  do
    IFS=':' ; read -ra REC <<< "$rev" ; IFS=' '
    user="${REC[1]}" ; id="${REC[2]}" ; pname="${REC[0]}" ; ver="${REC[3]}" ; pname_=$(echo $pname|sed 's# #_#g')
    printf "$rev\nuser=$user\nver=$ver\nname=$pname\nid=$id\n\n"
    [[ -d users/$user ]] || mkdir -p users/$user
    pushd users/$user
    ae5 project download ${id}:${ver}
    [[ ! -f "$pname.json" ]] && ae5 project info $id --format json > ${pname_}.json
    [[ ! -f "$pname-$ver.json" ]] && ae5 project revision info $id:$ver --format json > ${pname_}-${ver}.json
    popd
  done
}

ae5_ls() {
  ae5 ${1:-project} list --columns ${2:-name} --no-header
}

ae5_ls_sessions() {
  ae5_ls session $1
}

ae5_ls_deployments() {
 ae5_ls deployment $1
}


ae5_upload_prjects() {
  ae5_ls_projects > projects_list.txt
  ls *.tar.*[gz,bz2]| xargs -I% echo ae5 project upload \"%\" > upload
  cat  projects_list.txt | xargs -n 1 -I% sed -i "/%/d" upload
}

ae5_download_projects() {
  ae5 project list --no-header --columns name | xargs -I% echo ae5 project download \"%\"
}

ae5_get_project_acls() {
  psql anaconda_storage 'select p.name,a.name from projects p join project_acls a on p.id=a.project_id;'
}

ae5_rm_project_acls() { # remove acls for a given project, if -a remove all project acls (truncate)
  prj=${*:-blabla}
  if [[ "$1"=="-a" ]]; then
     psql anaconda_storage 'truncate project_acls;'
  else
     psql anaconda_storage 'delete from project_acls where project_id=(select id from projects where name='"'${prj}'"');'
  fi
}

ae5_stop_all_deployments(){
  [[ -n "$(ae5 deployment list --columns id --no-header)" ]] && \
  ae5 deployment list --columns id --no-header 2>/dev/null | xargs -n1 ae5 deployment stop --yes
}

ae5_stop_all_sessions(){
  [[ -n "$(ae5 session list --columns id --no-header)" ]] && \
        ae5 session list --no-header --columns id | xargs -n1 ae5 session stop --yes
}

## Easy Condfig For Environments ##

ae() {
   local login=""
   [[ -z $1 ]] && login=login
   ae5 $login --hostname ${FQDN} --username ${AE_USER_NAME} --password ${AE_USER_PASS} --admin-username ${AE_ADMIN_USER_NAME} --admin-password ${AE_ADMIN_PASS} $*
}

init_log
parse_parm() {
 for i in $@
 do
   echo $i
 done
}
eaeutils() {
  vi $ME
  source $ME
}

aeutils() {
 egrep '^\w+\(\)\s+{' $ME | sed 's/[\(\)\{]//g' | awk -F# '{printf "%-25s : %s\n",$1,$2}'
}

alias f="declare -f"
alias fn="declare -F"
# download all projects
# ae5_ls_projects -a |xargs -n 1 | sed 's/"//g' | cut -d: -f1 | xargs -I% -n1 bash -c 'echo aepyviz project download  %'
# extract
# ls | xargs -n1 tar xvf
# rename
#  for i in $(find . -name anaconda-project.yml); do name="$(yq '.name' $i | sed 's/ /_/g')"; fldr=$(echo $i | awk -F/ '{print $2}');echo mv $fldr $name ; done
get_k8s_token() {
  APISERVER=$(kubectl config view --minify | grep server | cut -f 2- -d ":" | tr -d " ")
  SECRET_NAME=$(kubectl get secrets | grep ^default | cut -f1 -d ' ')
  K8S_TOKEN=$(kubectl describe secret $SECRET_NAME | grep -E '^token' | cut -f2 -d':' | tr -d " ")
  echo $K8S_TOKEN
  if [[ "$1"=='t' ]]; then
    echo testing connection with token
    curl $APISERVER/api --header "Authorization: Bearer $K8S_TOKEN" --insecure
  fi
}


#oppenssl check connection to self
# echo "Q" | openssl s_client -connect se.demo.anaconda.com:443 -CAfile /etc/pki/tls/certs/ca-bundle.crt 2>/dev/null | grep "Verify"

# copy all packages from specific channel that are are sources elsewhere to AE5 channel
# conda list -n temp | awk '/pyviz/ {print $1"-"$2"-"$3".tar.bz2"}' | xargs -n1 -I% anaconda-enterprise-cli  upload /home/centos/miniconda3/pkgs/% --channel pyviz

ae5_hard_clean() { # clean deployment and session from db
  psql anaconda_workspace "truncate table sessions cascade;"
  psql anaconda_deploy 'truncate table deployments cascade;'
  # add removal of projects
  # add removal of project on pending state...
  [[ -n $(k8s_sessions_and_deployments) ]] && k8s_sessions_and_deployments | xargs -n1 kubectl delete
}

search_sessions() { # seaech input string in all session deployments
    for dep in $(kubectl get deploy | c1 | grep 'session');
    do
        echo searching $dep;
        kubectl get deploy $dep -o yaml | grep --color=auto ${1:-ae-ed};
    done
}

k8s_sessions_and_deployments() {
  kubectl get deploy -o name | egrep -- '-session-|-app-'
}
### reset secript... ###
reset_demo() {
  ae5_stop_all_sessions
  ae5_stop_all_deployments
  ae5_restart

}

reset_demo_hard() {
  if [[ $(ae5 account list --no-header --columns hostname | head -1) == $FQDN ]] ; then
    # delete all projects (based on user logged in)
    ae5_hard_clean
    ae5_rm_project_acls -a
    ae5_ls_projects -i | xargs -n1 ae5 project delete --yes
    # ae5_upload_projects ...
    echo ae5_upload_projects
    echo source ./upload
    ae5_restart
 fi
}

extract_certs_from_secrets() { # extract certs from running secrets into files
  kubectl get secrets anaconda-enterprise-certs -o jsonpath="{.data['rootca\.crt']}" | base64 -d > rootca.crt
  kubectl get secrets anaconda-enterprise-certs -o jsonpath="{.data['tls\.crt']}" | base64 -d > tls.crt
  kubectl get secrets anaconda-enterprise-certs -o jsonpath="{.data['tls\.key']}" | base64 -d > tls.key
  kubectl get secrets anaconda-enterprise-certs -o jsonpath="{.data['tls\.crt']}" | base64 -d > tls.crt
  kubectl get secrets anaconda-enterprise-certs -o jsonpath="{.data['wildcard\.crt']}" | base64 -d > wildcard.crt
  kubectl get secrets anaconda-enterprise-certs -o jsonpath="{.data['wildcard\.key']}" | base64 -d > wildcard.key
  kubectl get secrets anaconda-enterprise-certs -o jsonpath="{.data['keystore\.jks']}" | base64 -d > keystore.jks
}

update_ops_tlskp() { # uses key and cert files to update ops center certificates 1-key 2-cert defaults wildcard.key wildcard.crt
local keyfile=${1:-./wildcard.key}
local certfile=${2:-./wildcard.crt}
[[ ! (-f $keyfile && -f $certfile) ]] && echo cannot access key and cert files - $keyfile $certile
  OPS_TLSKP=tlskp.yaml
  touch $OPS_TLSKP
  cat > $OPS_TLSKP <<EOL
kind: tlskeypair
version: v2
metadata:
  name: keypair
spec:
  private_key: |
    `awk '{if (NR>1) print "    "$0; if (NR<=1) print $0}'  $keyfile`
  cert: |
    `awk '{if (NR>1) print "    "$0; if (NR<=1) print $0}'  $certfile`
EOL
  echo run '"sudo gravity create $OPS_TLSKP"' to update ops center certs
}

pods() {
  kubectl get pods
}

pgbackup() {
 kubectl get pods | awk '/postgres/ { print "kubectl exec -it "$1"  -- /usr/bin/pg_dumpall -U postgres  "}'
}

ktop() {
 watch -n 10 kubectl top ${1:-nodes} --heapster-namespace monitoring
}

c1() { # shortcut for cut column 1...
  cut -f${1:-1} -d${2:-" "} | grep -v NAME
}

klog() {
  local log=${1:-workspace}
  kubectl log $(pods | c1 | grep $log | head -1) -f --all-containers
}

# accessing docker registery
create_dreg_on_planet() {
  cat > /var/lib/gravity/planet/share/dreg << EOT
#!/usr/bin/env bash
  dreg() {
    local rest=\${1:-_catalog}
    curl -k -s --cert /var/state/kubelet.cert \
            --key /var/state/kubelet.key \
            https://localhost:5000/v2/\$rest | jq '.'
  }

dreg
EOT
  sudo gravity exec chmod +x /ext/share/dreg

}

dreg() {
  $echo sudo gravity exec /ext/share/dreg $*
  sudo gravity exec /ext/share/dreg $*
}

dreg_name_tag_filter() { # easy pipe target to join dreg repo/tags/list output
   jq '.name as $name|[$name, .tags[]]|join("/")';
}

freg_all_tags() {
   local target="${1:-/tmp/dreg_catalog}"
   echo > $target
   dreg _catalog | jq -r '.repositories[]' | xargs -I% echo "dreg %/tags/list | dreg_name_tag_filter >> $target" > ${target}.sh
   source $target.sh
   cat $target
}

remove_images_for_tags() {
 tag=${1}
 [[ -z $1 ]] && echo must provide a tag && return 1
 docker image ls | awk '{ if ($2=='$tag') {print "docker rmi "$3}}'
}

create_dreg_on_planet
ae_update() {
         local conf=${1:-${FQDN}.yaml}
        [[ $conf =~ \.json ]] && yq '.' $conf > ${conf//.json}.yaml && conf=${conf//.json}.yaml
        $echo helm upgrade -f $conf anaconda-enterprise $AE_CHART_PATH
}

replace_new_lines() {
  awk '{printf "%s\\n", $0}' "$1"
}

export_filter(){
    for flt in $* .metadata.managedFields .metadata.creationTimestamp .metadata.resourceVersion .metadata.selfLink .metadata.uid
    do
      filter="del($flt)|$filter"
    done
    yq -r -y "$filter."
}


minio_utils() {
  export minio_ep=$(kubectl get ep | awk '/ect-sto/ { print "https://"$2}')
  # mc config host add $SHORTNAME $minio_ep s3-access-key s3-secret-key --insecure
  alias mc='mc --insecure'
  alias mcls='mc ls'
  alias mccp='mc cp'
  alias mccat='mc cat'
  alias mcmkdir='mc mb'
  alias mcpipe='mc pipe'
  alias mcfind='mc find'
}

# set local env to reflect cluster
set_conda_env_to_yaml_conf() { # replace local condarc with the one set in AE5 yaml
  kubectl get cm anaconda-enterprise-anaconda-platform.yml  -o jsonpath={.data} | yq -y '.conda' >> $( conda info | grep " active env location" | awk '{print $5}')/.condarc
}

get_ae_cm_api() {
  local l="$(kubectl get cm anaconda-enterprise-anaconda-platform.yml  -o yaml | export_filter)"
  echo "$l"
}

get_ae_cm() { # extract the yaml from the config map, inputs "keys" - list all root keys, "git" - show git section, any other key wil present the key only. A second input can be provided with a filename to be used  instead of getting the cm.
  [[ -f $2 ]] && conf="$(echo "$(cat $2)"  | yq -r '.data[]')"
  [[ -z $2 ]] && conf="$(echo "$(get_ae_cm_api)"  | yq -r '.data[]')"
  [[ -z $1 ]] && echo "$conf" && return
  [[ $1 =~ "-" || $1 =~ "."  ]] && jq_path=".[\"$1\"]" || jq_path=".$1"
  [[ $1 == "keys" ]] && jq_path=".|keys"
  [[ $1 == "git" ]] && jq_path=".storage.git"
  echo "$(echo "$conf" | yq -r -y "$jq_path")"
}

gen_ae_cm() { # replace the data in ae cm with the input file - input is yml/json file, same as you would see in the ops center UI
  pushd $WRKDIR
  local new_ae_yaml="$1"
  dst=${2:-new_aecm.yaml}
  [[ -z $new_ae_yaml ]] && echo missing conf && return
  [[ ! -f $new_ae_yaml ]] && echo cannot access "$new_ae_yaml" && return
  aecmapi_backup=$(get_backup_file_name aecmapi.bck)
  get_ae_cm_api | export_filter > $aecmapi_backup
  cat $aecmapi_backup | yq -r -y --arg a "$(cat $new_ae_yaml)" '.data["anaconda-platform.yml"]=$a' > ${dst}
  popd
}


customize_ae_cm() { # modify anaconda-enterprise-yaml, merge a provided json dictionary (single key) with existing yaml
  pushd $WRKDIR
  local f=""
  local subkey=""
  org=aecm_org.json
  new=${2:-aecm_new.json}
  [[ $new =~ \.yaml$ || $new =~ \.yml$ ]] && f=' -y '
  dlt=${1:-${FQDN}}
  [[ ! -f $dlt ]] && echo "Missing delta yaml file $dlt" && return
  get_ae_cm | yq -S '.' > $org
  local key="$(jq -r '.|keys[0]' $dlt)"
  echo $key
  if [[ $key == "storage" ]]; then
    jq  --slurpfile dlt $dlt '.storage.git=($dlt[]|.storage|.git)' $org  | yq -S $f '.' > $new
  else
    jq  --slurpfile dlt $dlt --arg key $key '.[$key]=($dlt[][$key])' $org | yq -S $f '.' > $new
  fi
  popd
}

switch_git_internal() { # change the configuraiton to internal git...
  customize_ae_cm ~/wrk/customization/git/internal.json aecm-git-internal.yml
  gen_ae_cm aecm-git-internal.yml aecm.yml
  kubectl replace -f aecm.yml
  rm  aecm.yml  aecm-git-internal.yml
}

# TODO: Customize is generic for most keys in the configMap... excption is git.
# track all changes using the file name (date, type of customization, etc.. and log)

customize_resource_profiles() {
  rpsrc=${1:-~/conf/customizations/resource_profiles/7rp.json}
  [[ -f $rpsrc ]] || (echo "must provide resource profile json" && return 1)
  pushd ${WRKDIR}
  #backup aecm with audit.p..
  customize_ae_cm $rpsrc rp_ae_cm.json
  gen_ae_cm rp_ae_cm.json rp_ae_cmapi.yml
  kubectl replace -f rp_ae_cmapi.yml
  restart_ws
  popd
}

customize_ae5_condarc() {
  pushd ${WRKDIR}
  condarc=${1:-~/conf/customizations/condarc/local.json}
  [[ -f $condarc ]] || (echo "must provide condarc json file" && return 1)
  #backup aecm with audit.p..
  customize_ae_cm $condarc condarc_ae_cm.json
  gen_ae_cm condarc_ae_cm.json condarc_ae_cmapi.yml
  diff to test...
  kubectl replace -f condarc_ae_cmapi.yml
  popd
}


add_missing_packages() { # the idea is to upload all missing packages with dependencies from a specific channel (like pyviz, conda-forge etc..)
  # parse inputs
  # dst channel
  # source channel
  # conda args...
  cenv=temp
  dst=pyviz
  export pkgs_location="$(conda info --json | jq -r '.pkgs_dirs[0]')"

  conda create -n $cenv --yes
  conda install -n $cenv $* --yes

  anaconda-enterprise-cli channels create $dst
  conda list -n $cenv | awk -v l=$pkgs_location/ -v c=$dst '/pyviz/ {print l$1"-"$2"-"$3".tar.bz2 --channel "c}' | xargs -n3 anaconda-enterprise-cli upload
}

# miniconda oneliner
# curl -sLo miniconda.sh  https://repo.anaconda.com/miniconda/Miniconda3-latest-Linux-x86_64.sh  && bash ./miniconda.sh -b -p ~/conda
e_log() {
  local log="${1:-workspace}"
  id="$(ae5 deployment list --columns endpoint,id | grep eden | cut -f2 -d-)"
  [[ $id ]] || id="$(ae5 session list --columns endpoint,id | grep eden | cut -f2 -d-)"
  [[ $id ]] || id=$log
  kubectl log $(pods | c1 | grep "$id" | head -1) -f --all-containers
}

get_user_secrets() {
  user=${1:-eden}
  get secrets -l=anaconda-owner=user-creds-$user -o json | jq '.items[].data|map_values(@base64d)'
}

rootfs() {
  export rootfs=$(sudo find /var/lib/gravity/local/packages/unpacked/gravitational.io/planet-dbtools/ -type d -name "rootfs")
  echo $rootfs
}

add_shared_secret() { # add key value pair to the shared screts in anaconda enterprise
  [[ $1 == "-h" ]] && echo Usage: add_shared_secret path file_with_content && return
  key=${1:-/etc/krb5.conf}
  val=${2:-~/conf/customizations/shared_secrets/krb/krb5.conf}
  file=${3}

  # create the content and manifest for the key/value pair
  anaconda-enterprise-cli spark-config --config $key $val
  [[ ! -f $file ]] && kubectl get secret anaconda-config-files -o yaml |export_filter  > anaconda-config-files.org \
     && file=anaconda-config-files.org

  yq -y 'del(.data.anaconda_manifest)' anaconda-config-files.org > current_content.yaml
  yq -y 'del(.data.anaconda_manifest)|.data' anaconda-config-files-secret.yaml > added_content.yaml

  # merge manifests
  manifest="$(yq  -r  '.data|.anaconda_manifest|@base64d' anaconda-config-files.org)"
  manifest="$manifest $(yq  -r  '.data|.anaconda_manifest|@base64d'  anaconda-config-files-secret.yaml)"
  # merge manifests
  export manifest="$(echo $manifest | jq -s '.[0] * .[1]')"

  # merge content and add manifest key
  yq --argjson mnf "$manifest" -s '.[0].data += .[1] | .[0].data += {anaconda_manifest:($mnf|@base64)} | .[0]' \
       current_content.yaml added_content.yaml \
       | export_filter > anaconda-config-files.new
  echo to view generate config - get_shared_secrets anaconda-config-files.new
  echo to replace config - kubectl replace -f anaconda-config-files.new
}

get_shared_secrets() {
  [[ $1 == "-h" ]] && echo "Usage: get_shared_secrets [optional file] - saved output of kubectl get secrete anaconda-config-files -o yaml" && return
  [[ -f $1 ]] && export items="$(yq -y '.data' $1)"
  [[ -z $1 ]] && export items="$(kubectl get secret anaconda-config-files -o yaml | yq -y '.data')"
  [[ -z $items ]] && echo no items && return 1
  echo ---- Manifest ----
  echo "$items" | yq -r -y '.anaconda_manifest|@base64d'
  echo ---- Content ----
  echo "$items" | yq -r 'del(.anaconda_manifest)|to_entries[]|.value=(.value|@base64d)|.'
 }

del_shared_secret() {
  [[ $1 == "-h" ]] && echo "Usage: del_shared_secrets key [optional file] - saved output of kubectl get secrete anaconda-config-files -o yaml" && return
  [[ -z $1 ]] && please provide a key to remove && return
  export key=$1
  if [[ -z $2 ]]; then
     kubectl get secret anaconda-config-files -o yaml | export_filter > anaconda-enterprise-sercret.org
    file=anaconda-enterprise-sercret.org
  else
    file=$2
  fi

  # update manifest - filter the item that mactches the key to delete (dictionary)
  export items="$(yq -y '.data' $file)"
  manifest="$(yq -r '.data.anaconda_manifest|@base64d' $file | jq --arg rmkey $rmkey '.|with_entries(select(.value != $rmkey))')"
  # remove content
  hash_key="$(echo "$items" | yq -r -y '.anaconda_manifest|@base64d' | xargs -n2 -l bash -c '[[ "$1" == "$rmkey" ]] && echo $0 | cut -d":" -f1')"
  yq -r -y --argjson manifest "$manifest"  --arg hash_key $hash_key '.data["anaconda_manifest"]=($manifest|@base64)|.data=(.data|with_entries(select (.key != $hash_key)))' $file > ${file}.new
  echo kubectl replace -f ${file}.new
}

ae5_delete_projects() {
  # ae5_stop_all_deploymentdds
  # ae5_stop_all_sessions
  ae5_hard_clean
  remove_collaborators
  ae5_ls_projects | xargs -n1 -i% ae5 project delete % --yes
}

ae5_reset_projects() {
  ae5_download_projects
 }


KTOKEN=$(kubectl get secrets -o jsonpath="{.items[?(@.metadata.annotations['kubernetes\.io/service-account\.name']=='default')].data.token}"|base64 --decode)

kget() {
  curl -X GET $APISERVER/api/v1/$1 --header "Authorization: Bearer $KTOKEN" --insecure
}

id2name() {
  id=$(kubectl get pods "$1" -o json | jq '.spec.containers[]|select(.name|test ("sync"))|.env[]|select(.name=="TOOL_PROJECT_URL")|.value' | awk -F/ '{print $NF}' | sed s/\"//)
  psql anaconda_storage "select name from projects where id='$id';"
}

[[ $SHELL =~ bash ]] && source <(kubectl completion bash)

