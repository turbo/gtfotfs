#!/usr/bin/env bash

# TODO:
# Remove
# Rename functions and variables to be human readable


# Configurables
# Keep temporary directory
declare -i GT_KEEPDIR=0

# Directory and file names
# declare -r is a read-only variable
declare -r GT_HISTORY="/tmp/$GT_WORKSPACE-history.xml"
declare -r GT_JQHISTORY="$GT_HISTORY.json"
declare -r GT_VERSION="v1.0.4"
declare -r GT_WORKSPACE="tmigrate"

# Output colours
declare -r CLEAR='\033[0m'
declare -r RED='\033[0;31m'
declare -r YELLOW='\033[0;33m'

# Declare global variables
declare GT_COLLECTION
declare GT_FIRSTCS="T"
declare GT_GITREMOTE
declare GT_IGNOREFILE
declare GT_NAMEFILE
declare -A GT_OWNERMAP # declare -A is an array
declare GT_REPO
declare GT_TARGETDIR

# Environment variables used
# export GIT_AUTHOR_DATE="${GT_CURCSDATE}"
# export GIT_COMMITTER_DATE=$GIT_AUTHOR_DATE

# External binaries used

# Shell built-ins used
# hash
# popd


function print_usage_instructions() {

    cat <<EOF
    TFVC to Git Migration Tool (${0}) ${GT_VERSION}
    by turbo (minxomat@gmail.com | github.com/turbo)
    forked by Sourcegraph (github.com/sourcegraph/gtfotfs)

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


function check_dependencies() {

    # TODO: Refactor to test all dependencies, add the missing dependencies to an array, and if the array is not empty, then print the error including all missing dependencies, and exit
    # TODO: Print the $PATH env to help visually check that the right paths are in PATH, especially for tf

    # For each dependecy in the function args
    for dependency in "${@}"; do

        # Use the Bash built-in hash command to test if the dependency exists, and store its location in hash's storage
        # Close the stderr, to not get any error output from the hash command, only get an output if it exists
        # If no output (error), then print an error message that the required dependency is not installed or in $PATH
        # hash --help
        # hash: hash [-lr] [-p pathname] [-dt] [name ...]
        #     Remember or display program locations.
        #     Determine and remember the full pathname of each command NAME.  If
        #     no arguments are given, information about remembered commands is displayed.
        hash "${dependency}" 2>&- || print_error_and_exit "Required program \"${dependency}\" not installed or in PATH."

    done

}

function print_status_update() {

    # TODO: Add logging to a file
    
    # [/sourcegraph/gtfotfs-1.0.4/gtfotfs - 13:09] Adding origin localhost.
    echo -e "${YELLOW}[${0} - $(date +%R)]${CLEAR} $1\n"

}

function print_error_and_exit() {

    # TODO: Add logging to a file


    if [ -n "$1" ]; then
        echo -e "${RED}ERROR: ${1}${CLEAR}\n"
    fi
    exit 1
}



function cleanup() {
    unset GIT_COMMITTER_DATE
    unset GIT_AUTHOR_DATE
    print_status_update "Done."
}

function cd_error() {
    print_error_and_exit "FATAL: cd failed. Something's very wrong."
}

function prepare_target_exisiting() {
    if [ ! -d "${GT_TARGETDIR}" ]; then
        print_error_and_exit "Directory $GT_TARGETDIR does not exist."
    fi

    if [ ! -d "${GT_TARGETDIR}/.git" ]; then
        print_error_and_exit "Directory $GT_TARGETDIR is not a git repository."
    fi

    if [ -n "${GT_GITREMOTE}" ]; then
        print_status_update "Overwriting git remote origin."

        pushd "${GT_TARGETDIR}" || cd_error

        git remote rm origin

        if ! git remote add origin "${GT_GITREMOTE}"; then
            popd || cd_error
            print_error_and_exit "Could not add origin ${GT_GITREMOTE}. Check git output."
        fi

        popd || cd_error
    fi
}

function prepare_target_new() {
    if [ -z "${GT_GITREMOTE}" ]; then
        print_error_and_exit "Git remote (-r) is required for a new repository."
    fi

    print_status_update "Cleaning directory ${GT_TARGETDIR}"
    rm -rf "$GT_TARGETDIR"

    if ! mkdir -p "${GT_TARGETDIR}"; then
        print_error_and_exit "Could not create directory ${GT_TARGETDIR}."
    fi

    pushd "${GT_TARGETDIR}" || cd_error

    if ! git init; then
        popd || cd_error
        print_error_and_exit "Could not initialize git repository in ${GT_TARGETDIR}."
    fi

    print_status_update "Adding origin ${GT_GITREMOTE}."

    if ! git remote add origin "${GT_GITREMOTE}"; then
        popd || cd_error
        print_error_and_exit "Could not add origin ${GT_GITREMOTE}. Check git output."
    fi

    popd || cd_error
}

function stage_ignore_file() {
    print_status_update "Adding initial .gitignore file to exclude .tf directory."

    pushd "${GT_TARGETDIR}" || cd_error

    echo '.tf' >>".gitignore"

    if [ -n "${GT_IGNOREFILE}" ]; then
        cat "${GT_IGNOREFILE}" >>".gitignore"
    fi

    if ! git add .gitignore; then
        popd || cd_error
        print_error_and_exit "Could not stage .gitignore file. Check git output."
    fi

    popd || cd_error
}

function create_temp_workspace() {
    print_status_update "Deleting workspace (allowed to fail)."
    tf workspace -delete -noprompt "${GT_WORKSPACE}" -collection:"${GT_COLLECTION}" >/dev/null

    print_status_update "Creating workspace for collection ${GT_COLLECTION}."
    if ! tf workspace -new -noprompt "${GT_WORKSPACE}" -collection:"${GT_COLLECTION}"; then
        print_error_and_exit "Failed to create new workspace ${GT_COLLECTION}."
    fi

    print_status_update "Unmapping source (allowed to fail)"
    tf workfold -unmap -workspace:"${GT_WORKSPACE}" "${GT_REPO}"

    print_status_update "Mapping source ${GT_REPO} to ${GT_TARGETDIR}."
    if ! tf workfold -map "${GT_REPO}" -workspace:"${GT_WORKSPACE}" "${GT_TARGETDIR}"; then
        print_error_and_exit "Failed to map repo to workspace. Check tf output."
    fi
}

function get_tfs_history() {
    print_status_update "Getting history of ${GT_REPO} in range ${GT_FIRSTCS}. This will take *A WHILE*."

    rm -f "$GT_HISTORY"

    if ! tf history -workspace:"${GT_WORKSPACE}" "${GT_REPO}" -recursive -format:xml -version:"${GT_FIRSTCS}" -noprompt >"${GT_HISTORY}"; then
        print_error_and_exit "Unable to get TFVC history. See tf output."
    fi
}

function convert_history() {
    if ! xml2json -t xml2json -o "${GT_HISTORY}.json" "${GT_HISTORY}"; then
        print_error_and_exit "Unable to convert history to json. See file ${GT_HISTORY}."
    fi

    GT_NCS=$(jq '.history.changeset | length' "${GT_JQHISTORY}")
    print_status_update "$GT_NCS changesets in history."
}

function cs_sequence_old_to_new() {
    GT_CSSEQ=$(jq -r '[.history.changeset[]["@id"]] | reverse[]' "${GT_JQHISTORY}")
}

function lick_authors_into_shape() {
    GT_OAUTHORS=$(jq -r '[.history.changeset[]["@owner"]] | unique[]' "${GT_JQHISTORY}")

    if [ ! -f "$GT_NAMEFILE" ]; then
        print_error_and_exit "Owner mapping file ${GT_NAMEFILE} does not exist."
    fi

    while IFS="" read -r GT_OTOMAP; do
        GT_TMPMAP=$(jq -r '.["'"${GT_OTOMAP//\\/\\\\}"'"]' "$GT_NAMEFILE")

        if [ -z "${GT_TMPMAP}" ]; then
            print_error_and_exit "No mapping found for author ${GT_OTOMAP}."
        fi

        GT_OWNERMAP["${GT_OTOMAP}"]="${GT_TMPMAP}"
    done < <(tr ' ' '\n' <<<"${GT_OAUTHORS}")

    print_status_update "Owner mapping as configured by $GT_NAMEFILE:"

    for i in "${!GT_OWNERMAP[@]}"; do
        echo "$i -> ${GT_OWNERMAP[$i]}"
    done
    echo ""
}

function migrate() {
    GT_FIRSTCOMMIT=1

    while read -r GT_CURCSID; do
        GT_CURCSINFO=$(jq -c '.history.changeset[] | select (.["@id"] == "'"${GT_CURCSID}"'") | [.comment["#text"], .["@owner"], .["@date"]]' "${GT_JQHISTORY}")
        GT_CURCSDATE=$(echo "${GT_CURCSINFO}" | jq -r '.[2]')
        GT_CURCSAUTHOR=$(echo "${GT_CURCSINFO}" | jq -r '.[1]')
        GT_CURCSMESSAGE=$(echo "${GT_CURCSINFO}" | jq -r '.[0]')

        if [ -z "${GT_OWNERMAP["${GT_CURCSAUTHOR}"]}" ]; then
            print_error_and_exit "Source author ${GT_CURCSAUTHOR} is not mapped."
        fi

        print_status_update "Getting changeset C${GT_CURCSID} (${GT_NCS} left):"
        echo "Author:  ${GT_CURCSAUTHOR} -> ${GT_OWNERMAP["${GT_CURCSAUTHOR}"]}"
        echo "Date:    ${GT_CURCSDATE}"
        echo "Message: ${GT_CURCSMESSAGE}"
        echo ""

        pushd "${GT_TARGETDIR}" || cd_error

        if ((GT_FIRSTCOMMIT > 0)); then
            if ! tf get "${GT_TARGETDIR}" -force -recursive -noprompt -version:"C${GT_CURCSID}"; then
                popd || cd_error
                print_error_and_exit "Error while getting first commit. See tf output."
            fi
            GT_FIRSTCOMMIT=0
        else
            if ! tf get "${GT_TARGETDIR}" -recursive -noprompt -version:"C${GT_CURCSID}"; then
                popd || cd_error
                print_error_and_exit "Error while getting current commit. See tf output."
            fi
        fi

        export GIT_AUTHOR_DATE="${GT_CURCSDATE}"
        export GIT_COMMITTER_DATE=$GIT_AUTHOR_DATE

        if ! git add .; then
            popd || cd_error
            print_error_and_exit "Error while staging files. See git output."
        fi

        if ! git commit --allow-empty -am "[TFS-${GT_CURCSID}] ${GT_CURCSMESSAGE}" --author="${GT_OWNERMAP["${GT_CURCSAUTHOR}"]}"; then
            popd || cd_error
            print_error_and_exit "Error while committing changes. See git output."
        fi

        ((GT_NCS--))
        popd || cd_error
        echo ""
    done <<<"${GT_CSSEQ}"
}

function push_to_origin() {
    pushd "${GT_TARGETDIR}" || cd_error

    print_status_update "Optimizing repository size."

    git reflog expire --all --expire=now
    git gc --prune=now --aggressive

    print_status_update "Pushing to origin now."
    if ! git push -u origin --all --force; then
        popd || cd_error
        print_error_and_exit "Error while pushing to origin. See git output."
    fi

    popd || cd_error
}

function main() {
    # No args == help
    if [[ $# -eq 0 ]]; then
        print_usage_instructions
        exit 0
    fi

    check_dependencies tf jq xml2json git java

    # Parse arguments
    while [[ "$#" -gt 0 ]]; do case $1 in
        -c | --collection)
            GT_COLLECTION="$2"
            shift
            shift
            ;;
        -s | --source)
            GT_REPO="$2"
            shift
            shift
            ;;
        -h | --history)
            GT_FIRSTCS="C$2~T"
            shift
            shift
            ;;
        -t | --target)
            GT_TARGETDIR="$2"
            shift
            shift
            ;;
        -k | --keep)
            GT_KEEPDIR=1
            shift
            shift
            ;;
        -n | --names)
            GT_NAMEFILE="$2"
            shift
            shift
            ;;
        -r | --remote)
            GT_GITREMOTE="$2"
            shift
            shift
            ;;
        -i | --ignore)
            GT_IGNOREFILE="$2"
            shift
            shift
            ;;
        *)
            print_error_and_exit "Unknown parameter: $1"
            shift
            shift
            ;;
        esac done

    # Validate arguments
    if [ -z "$GT_COLLECTION" ]; then print_error_and_exit "Collection (-c) is required."; fi
    if [ -z "$GT_REPO" ]; then print_error_and_exit "Repository path (-s) is required."; fi
    if [ -z "$GT_TARGETDIR" ]; then print_error_and_exit "Target directory (-t) is required."; fi
    if [ -z "$GT_NAMEFILE" ]; then print_error_and_exit "Owner map (-n) is required."; fi

    if ((GT_KEEPDIR > 0)); then
        prepare_target_exisiting
    else
        prepare_target_new
        stage_ignore_file
    fi

    create_temp_workspace
    get_tfs_history
    convert_history
    cs_sequence_old_to_new
    lick_authors_into_shape
    migrate
    push_to_origin

    cleanup
    exit 0
}

trap "cleanup; exit 1" SIGHUP SIGINT SIGQUIT SIGPIPE SIGTERM

main "$@"