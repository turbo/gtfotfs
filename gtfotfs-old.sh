#!/usr/bin/env bash

# Editors beware: 

declare -r CLEAR='\033[0m'
declare -r RED='\033[0;31m'
declare -r YELLOW='\033[0;33m'
declare -r GT_WORKSPACE="tmigrate"
declare -r GT_HISTORY="/tmp/$GT_WORKSPACE-history.xml"
declare -r GT_JQHISTORY="$GT_HISTORY.json"
declare -r GT_VERSION="v1.0.4"

declare -i GT_KEEPDIR=0

declare -A GT_OWNERMAP

declare GT_IGNOREFILE
declare GT_COLLECTION
declare GT_REPO     
declare GT_FIRSTCS="T"
declare GT_TARGETDIR 
declare GT_NAMEFILE
declare GT_GITREMOTE
declare GT_IGNOREFILE

function gtfotfs::check_dependencies() {
  for p in "${@}"; do
    hash "${p}" 2>&- || \
      gtfotfs::error "Required program \"${p}\" not installed or in search PATH."
  done
}

function gtfotfs::cstatus() {
  echo -e "${YELLOW}[${0} - $(date +%R)]${CLEAR} $1\n";
}

function gtfotfs::error() {
  if [ -n "$1" ]; then
    echo -e "${RED}ERROR: ${1}${CLEAR}\n";
  fi
  exit 1
}

function gtfotfs::usage() {
  cat <<EOF

TFVC to Git Migration Tool (${0}) ${GT_VERSION}
by turbo (minxomat@gmail.com | github.com/turbo)

Usage: ${0} <args>

Arguments:

  -c, --collection     Collection which contains target repo, e.g.:
                       https://tfs.example.com/tfs/ProjectCollection

  -s, --source         Source location within TFS, e.g.
                       $/contoso/sources/productive

  -h, --history        The numerical value of the change-set where
                       migration should begin. Prior history will be
                       dropped. E.g.: 1337. Default is first ever.

  -t, --target         Directory (will be created) where the new git
                       repository will live.

  -k, --keep           Do not delete and re-init target, instead over-
                       write prior contents. Default is false.

  -n, --names          JSON file which maps between old TFS account names
                       to proper git author strings. E.g.:
                       {
                         "CONTOSO\\\\j.doe": "John Doe <john.doe@contoso.com>",
                         ...
                       }

  -r, --remote         Path to new remote origin. Will be set up and pushed
                       to during the migration.

  -i, --ignore         Full path to a gitignore file, which will be applied during
                       the migration.

EOF
}

function gtfotfs::cleanup() {
  unset GIT_COMMITTER_DATE
  unset GIT_AUTHOR_DATE
  gtfotfs::cstatus "Done."
}

function gtfotfs::cd_error() {
  gtfotfs::error "FATAL: cd failed. Something's very wrong."
}

function gtfotfs::prepare_target_exisiting() {
  if [ ! -d "${GT_TARGETDIR}" ]; then 
    gtfotfs::error "Directory $GT_TARGETDIR does not exist."
  fi

  if [ ! -d "${GT_TARGETDIR}/.git" ]; then 
    gtfotfs::error "Directory $GT_TARGETDIR is not a git repository."
  fi

  if [ -n "${GT_GITREMOTE}" ]; then 
    gtfotfs::cstatus "Overwriting git remote origin."

    pushd "${GT_TARGETDIR}" || gtfotfs::cd_error
    
    git remote rm origin

    if ! git remote add origin "${GT_GITREMOTE}" ; then
      popd || gtfotfs::cd_error
      gtfotfs::error "Could not add origin ${GT_GITREMOTE}. Check git output."
    fi

    popd || gtfotfs::cd_error
  fi
}

function gtfotfs::prepare_target_new() {
  if [ -z "${GT_GITREMOTE}" ]; then 
    gtfotfs::error "Git remote (-r) is required for a new repository."
  fi

  gtfotfs::cstatus "Cleaning directory ${GT_TARGETDIR}"
  rm -rf "$GT_TARGETDIR"

  if ! mkdir -p "${GT_TARGETDIR}" ; then
    gtfotfs::error "Could not create directory ${GT_TARGETDIR}."
  fi

  pushd "${GT_TARGETDIR}" || gtfotfs::cd_error
  
  if ! git init ; then
    popd || gtfotfs::cd_error
    gtfotfs::error "Could not initialize git repository in ${GT_TARGETDIR}."
  fi

  gtfotfs::cstatus "Adding origin ${GT_GITREMOTE}."

  if ! git remote add origin "${GT_GITREMOTE}" ; then
    popd || gtfotfs::cd_error
    gtfotfs::error "Could not add origin ${GT_GITREMOTE}. Check git output."
  fi

  popd || gtfotfs::cd_error
}

function gtfotfs::stage_ignore_file() {
  gtfotfs::cstatus "Adding initial .gitignore file to exclude .tf directory."
  
  pushd "${GT_TARGETDIR}" || gtfotfs::cd_error

  echo '.tf' >> ".gitignore"

  if [ -n "${GT_IGNOREFILE}" ]; then 
    cat "${GT_IGNOREFILE}" >> ".gitignore"
  fi

  if ! git add .gitignore ; then
    popd || gtfotfs::cd_error
    gtfotfs::error "Could not stage .gitignore file. Check git output."
  fi

  popd || gtfotfs::cd_error
}

function gtfotfs::create_temp_workspace() {
  gtfotfs::cstatus "Deleting workspace (allowed to fail)."
  tf workspace -delete -noprompt "${GT_WORKSPACE}" -collection:"${GT_COLLECTION}" > /dev/null

  gtfotfs::cstatus "Creating workspace for collection ${GT_COLLECTION}."
  if ! tf workspace -new -noprompt "${GT_WORKSPACE}" -collection:"${GT_COLLECTION}" ; then
    gtfotfs::error "Failed to create new workspace ${GT_COLLECTION}."
  fi

  gtfotfs::cstatus "Unmapping source (allowed to fail)"
  tf workfold -unmap -workspace:"${GT_WORKSPACE}" "${GT_REPO}"

  gtfotfs::cstatus "Mapping source ${GT_REPO} to ${GT_TARGETDIR}."
  if ! tf workfold -map "${GT_REPO}" -workspace:"${GT_WORKSPACE}" "${GT_TARGETDIR}" ; then
    gtfotfs::error "Failed to map repo to workspace. Check tf output."
  fi
}

function gtfotfs::get_tfs_history() {
  gtfotfs::cstatus "Getting history of ${GT_REPO} in range ${GT_FIRSTCS}. This will take *A WHILE*."
  
  rm -f "$GT_HISTORY"
  
  if ! tf history -workspace:"${GT_WORKSPACE}" "${GT_REPO}" -recursive -format:xml -version:"${GT_FIRSTCS}" -noprompt > "${GT_HISTORY}" ; then
    gtfotfs::error "Unable to get TFVC history. See tf output."
  fi
}

function gtfotfs::convert_history() {
  if ! xml2json -t xml2json -o "${GT_HISTORY}.json" "${GT_HISTORY}" ; then
    gtfotfs::error "Unable to convert history to json. See file ${GT_HISTORY}."
  fi

  GT_NCS=$(jq '.history.changeset | length' "${GT_JQHISTORY}")
  gtfotfs::cstatus "$GT_NCS changesets in history."
}

function gtfotfs::cs_sequence_old_to_new() {
  GT_CSSEQ=$(jq -r '[.history.changeset[]["@id"]] | reverse[]' "${GT_JQHISTORY}")
}

function gtfotfs::lick_authors_into_shape() {
  GT_OAUTHORS=$(jq -r '[.history.changeset[]["@owner"]] | unique[]' "${GT_JQHISTORY}")

  if [ ! -f "$GT_NAMEFILE" ]; then 
    gtfotfs::error "Owner mapping file ${GT_NAMEFILE} does not exist."
  fi

  while IFS="" read -r GT_OTOMAP; do
    GT_TMPMAP=$(jq -r '.["'"${GT_OTOMAP//\\/\\\\}"'"]' "$GT_NAMEFILE")

    if [ -z "${GT_TMPMAP}" ]; then 
      gtfotfs::error "No mapping found for author ${GT_OTOMAP}."
    fi

    GT_OWNERMAP["${GT_OTOMAP}"]="${GT_TMPMAP}"
  done < <(tr ' ' '\n' <<< "${GT_OAUTHORS}")

  gtfotfs::cstatus "Owner mapping as configured by $GT_NAMEFILE:"
  
  for i in "${!GT_OWNERMAP[@]}"; do
    echo "$i -> ${GT_OWNERMAP[$i]}"
  done
  echo ""
}

function gtfotfs::migrate() {
  GT_FIRSTCOMMIT=1

  while read -r GT_CURCSID; do
    GT_CURCSINFO=$(jq -c '.history.changeset[] | select (.["@id"] == "'"${GT_CURCSID}"'") | [.comment["#text"], .["@owner"], .["@date"]]' "${GT_JQHISTORY}")
    GT_CURCSDATE=$(echo "${GT_CURCSINFO}" | jq -r '.[2]')
    GT_CURCSAUTHOR=$(echo "${GT_CURCSINFO}" | jq -r '.[1]')
    GT_CURCSMESSAGE=$(echo "${GT_CURCSINFO}" | jq -r '.[0]')

    if [ -z "${GT_OWNERMAP["${GT_CURCSAUTHOR}"]}" ]; then
      gtfotfs::error "Source author ${GT_CURCSAUTHOR} is not mapped."
    fi

    gtfotfs::cstatus "Getting changeset C${GT_CURCSID} (${GT_NCS} left):"
    echo "Author:  ${GT_CURCSAUTHOR} -> ${GT_OWNERMAP["${GT_CURCSAUTHOR}"]}"
    echo "Date:    ${GT_CURCSDATE}"
    echo "Message: ${GT_CURCSMESSAGE}"
    echo ""

    pushd "${GT_TARGETDIR}" || gtfotfs::cd_error

    if ((GT_FIRSTCOMMIT > 0)); then 
      if ! tf get "${GT_TARGETDIR}" -force -recursive -noprompt -version:"C${GT_CURCSID}" ; then
        popd || gtfotfs::cd_error
        gtfotfs::error "Error while getting first commit. See tf output."
      fi
      GT_FIRSTCOMMIT=0
    else
      if ! tf get "${GT_TARGETDIR}" -recursive -noprompt -version:"C${GT_CURCSID}" ; then
        popd || gtfotfs::cd_error
        gtfotfs::error "Error while getting current commit. See tf output."
      fi
    fi

    export GIT_AUTHOR_DATE="${GT_CURCSDATE}"
    export GIT_COMMITTER_DATE=$GIT_AUTHOR_DATE

    if ! git add . ; then
      popd || gtfotfs::cd_error
      gtfotfs::error "Error while staging files. See git output."
    fi
    
    if ! git commit --allow-empty -am "[TFS-${GT_CURCSID}] ${GT_CURCSMESSAGE}" --author="${GT_OWNERMAP["${GT_CURCSAUTHOR}"]}" ; then
      popd || gtfotfs::cd_error
      gtfotfs::error "Error while committing changes. See git output."
    fi

    (( GT_NCS-- ))
    popd || gtfotfs::cd_error
    echo ""
  done <<< "${GT_CSSEQ}"
}

function gtfotfs::push_to_origin() {
  pushd "${GT_TARGETDIR}" || gtfotfs::cd_error

  gtfotfs::cstatus "Optimizing repository size."
  
  git reflog expire --all --expire=now
  git gc --prune=now --aggressive

  gtfotfs::cstatus "Pushing to origin now."
  if ! git push -u origin --all --force ; then
    popd || gtfotfs::cd_error
    gtfotfs::error "Error while pushing to origin. See git output."
  fi

  popd || gtfotfs::cd_error
}

function main() {
  # No args == help
  if [[ $# -eq 0 ]] ; then
    gtfotfs::usage
    exit 0
  fi

  gtfotfs::check_dependencies tf jq xml2json git java

  # Parse arguments
  while [[ "$#" -gt 0 ]]; do case $1 in
    -c|--collection)  GT_COLLECTION="$2"      ;shift;shift;;
    -s|--source)      GT_REPO="$2"            ;shift;shift;;
    -h|--history)     GT_FIRSTCS="C$2~T"      ;shift;shift;;
    -t|--target)      GT_TARGETDIR="$2"       ;shift;shift;;
    -k|--keep)        GT_KEEPDIR=1            ;shift;shift;;
    -n|--names)       GT_NAMEFILE="$2"        ;shift;shift;;
    -r|--remote)      GT_GITREMOTE="$2"       ;shift;shift;;
    -i|--ignore)      GT_IGNOREFILE="$2"      ;shift;shift;;
    *) gtfotfs::error "Unknown parameter: $1" ;shift;shift;;
  esac; done

  # Validate arguments
  if [ -z "$GT_COLLECTION"  ]; then gtfotfs::error "Collection (-c) is required."; fi;
  if [ -z "$GT_REPO"        ]; then gtfotfs::error "Repository path (-s) is required."; fi;
  if [ -z "$GT_TARGETDIR"   ]; then gtfotfs::error "Target directory (-t) is required."; fi;
  if [ -z "$GT_NAMEFILE"    ]; then gtfotfs::error "Owner map (-n) is required."; fi;

  if ((GT_KEEPDIR > 0)); then 
    gtfotfs::prepare_target_exisiting
  else
    gtfotfs::prepare_target_new
    gtfotfs::stage_ignore_file
  fi

  gtfotfs::create_temp_workspace
  gtfotfs::get_tfs_history
  gtfotfs::convert_history
  gtfotfs::cs_sequence_old_to_new
  gtfotfs::lick_authors_into_shape
  gtfotfs::migrate
  gtfotfs::push_to_origin

  gtfotfs::cleanup
  exit 0
}

trap "gtfotfs::cleanup; exit 1" SIGHUP SIGINT SIGQUIT SIGPIPE SIGTERM

main "$@"
