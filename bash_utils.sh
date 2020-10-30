#/usr/bin/env bash
## Generic Bash Helpers ##
set -uxe

unset EXIT ME MYFILE MYDIR
[[ "$0" != "$BASH_SOURCE" ]] && EXIT=return || EXIT=exit
MYDIR="$(cd "$(dirname ${BASH_SOURCE[0]})" >/dev/null 2>&1 && pwd)"
MYFILE=$(basename "${BASH_SOURCE[0]}")
ME=$MYDIR/$MYFILE

SCR=${SCR:=~/scripts/}
LOGDIR=${LOGDIR:-~/logs}
LOG=${LOG:-${MYFILE%.*}}
LOG=${LOG:-stdout}
STDLOG=${STDLOG:-$LOGDIR/$LOG.log}
ERRLOG=${ERRLOG:-$LOGDIR/$LOG.err}

export BASE64_ENC="base64 --wrap=0"
[[ "$(uname)" == "Darwin" ]] && export BASE64_ENC="base64 -b 0"

run() {
  runs=$(grep -c "$*" $STATE)
  if [[ $runs -eq 0 ]]; then
    info "executing $1 for the first time"
    eval "$*" 2>>$ALLLOG
    if [[ $? -eq 0 ]]; then
      echo $(now) "$*" >> $STATE
      echo " success ($1)"
    else
      echo " failed!!!($1)"
    fi
  else
    echo "$*" already run $runs times
  fi
}

testing() {
  echo this is the outout of the function ... testing
  echo and these are the paramater passed $*
}

md() {
  [[ -z $1 ]] && return 1
  [[ -d $1 ]] && echo "$1" already exist && return 0
  mkdir -p $1
}

dedup() {
  new=""
  list=${1:-""}
  sep=${2:-" "}
  [[ -z $2 ]] && OIFS=$IFS && IFS=${sep}
  for i in $list
  do
    dup=0
    for n in $new
    do [[ $n == $i ]] && dup=1 ; done
    [[ $dup -eq 0 ]] && [[ -z $new  ]] && new="$i" || new="${new}${sep}$i"
  done
}

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

len() { # return the length of the input in lines
  [[ -z $1 ]] && return
  $(echo ${1} | wc -l)
}

init_log() {  # backup old log, and create new log file for the batch functions.
  md $LOGDIR
  [[ -f $STDLOG ]] && backup $STDLOG
  [[ -f $ERRLOG ]] && backup $ERRLOG
}

clean_logs() { # convinience function remove log files from /tmp/log
    rm -f $ERRLOG $STDLOG
}

view_log() { # tail log file
  tail -${1:-10}f $STDLOG
}

now() {  # no inputs return current date MMDDYYHHMMSSSS with "s" return DSHH:MMSSS else return date in given format

 [[ -z $1 ]] && echo $(date +'%m%d%y%H%M%S')
 [[ $1 == s ]] && echo $(date +'%d%H:%M%S')
}

yesno() { # prompt for yes or no
  while true
  do
    read -p "${1:-yes/no} " yn
    case ${yn,,} in
      yes|y ) echo yes; break;;
      no|n ) echo no ; break;;
    esac
  done
}

log() { # log to log file the message (1st positional) and the verosity 1-3 (2nd positional)
  msg=$1
  shift
  [[ $1 == 0 ]] && v=DEBUG
  [[ $1 == 1 ]] && v=INFO
  [[ $1 == 2 ]] && v=WARN
  echo $(now s): $v \{${FUNCNAME[1]}\} : \"$msg\" >> ${STDLOG}
}

info() { log "$1" 1 ;}
warn() { log "$1" 2 ;}
debug() { log "$1" 0 ;}

exit_gracefully() { # exit from a script with a message and rc=1 (1st positional) (assumes set -e)
 echo "${1:-Exiting....}"
 return 1
 # find an elegent way to exit when this is sourced...
}

backup() { # backup a file, if filename exist, rename it with current date time
  [[ -f $1 ]] || return 1
  target=$(get_backup_file_name "$1")
  log "Moving  $1 $target" 1
  mv "$1" "$target"
}

shiftx() {
    unset x f
    f=${1}
    [[ ! -f $1 ]] && echo missing file && return 1
    x=${2:-2}
    [[ $x -le 0 ]] && cat $f && return
    s=${3:-1}
    awk '{if (NR>'$s') printf "%-'$x's%s\n"," ",$0; if (NR<='$s') print $0}' $f
}

sedx() { # replace the value of export variable in a file, so for exampe sedx x=test myfile will change the value of x in myfile to test
    var=${1/=*}
    val=${1/*=}
    file=${2}
    debug "$var $val $file"
    if [[ $var ]] && [[ $val ]] && [[ $file ]]; then
        sed -i'.b' 's#\(export '${var}'=\).*$#\1'${val}'#' ${file}
    elif [[ $var ]] && [[ $val ]]; then
        # piped
        sed 's#\(export '${var}'=\).*$#\1'${val}'#'
    else
        echo "must provide var=val as input "
        return 1
    fi
}

in_path() {
   local IFS=:
   item=${1%/} && item=$(echo $item)
   for p in $PATH
   do
     p=$(echo ${p%/}) # remove trailing / and expand ~
     [[ $p == $item ]] && return ;
   done
   return 1
}

path_add() {
   [[ ! -d $1 && ! -f $1 ]] && echo "$1" is not a file or a directory && return 1
   if in_path "$1"; then echo "$1" already in path ; return ; fi
   if [[ ${2} == "-last" ]]; then
     PATH="$PATH:$1"
     echo "$1" added to the end of path
   else
     PATH="$1:$PATH"
     echo "$1" added to the beginig of path
   fi

}

bash_utils() {
  [[ $1 == -h ]] && echo print help
  [[ $1 == -e ]] && echo editing & sourcing
}

set +uxe
