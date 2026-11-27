#!/usr/bin/env bash
# Checks that every stage of every Dockerfile named on the command line runs as a non-root
# user (spec 10.9): each stage must set a non-root USER before its first RUN, and no stage
# may ever switch to root. Hadolint's DL3002 only looks at the last USER of the whole file;
# this looks at every stage, in order.
#
#   bash infra/images/check-dockerfile-users.sh apps/web/Dockerfile apps/cms/Dockerfile
#
# Exit 0: every stage is fine. Exit 1: a stage breaks a rule (each is printed). Exit 2: usage.
#
# Rules, per stage ("FROM ... AS name" starts one):
#   - a RUN must come after a USER that names someone other than root (uid 0 or "root");
#   - USER root, USER 0 and USER with a variable (cannot be read here) are not allowed;
#   - the stage must set a non-root USER at all (a stage built FROM an earlier stage starts
#     with that stage's user).
# COPY and ADD run as root whatever the USER is, so they are not limited; their ownership is
# set with --chown. There is no root setup step in these Dockerfiles, so none is allowed:
# if one is ever needed, change this script on purpose, in the same commit.
set -euo pipefail

[[ $# -ge 1 ]] || {
  printf 'usage: bash infra/images/check-dockerfile-users.sh <Dockerfile>...\n' >&2
  exit 2
}

errors=0
problem() {
  printf 'FAIL %s: %s\n' "$1" "$2"
  errors=$((errors + 1))
}

check_file() {
  local file=$1 line instr='' buf='' lineno=0 start=0
  local stage=0 stage_name='' stage_nonroot=0 in_stage=0
  local -A ended=() # stage name (lower case) -> 1 when the stage ended non-root

  [[ -f $file ]] || {
    problem "$file" 'no such file'
    return
  }

  end_stage() {
    if ((in_stage)) && ((!stage_nonroot)); then
      problem "$file" "stage $stage ($stage_name) never sets a non-root USER"
    fi
    if ((in_stage)) && [[ -n $stage_name ]]; then
      ended["${stage_name,,}"]=$stage_nonroot
    fi
  }

  handle() { # handle LINE-NUMBER INSTRUCTION-TEXT
    local n=$1 text=$2 kw args parent as_name
    kw=${text%%[[:space:]]*}
    kw=${kw^^}
    args=${text#"${text%%[[:space:]]*}"}
    args=${args#"${args%%[![:space:]]*}"}
    case $kw in
      FROM)
        end_stage
        stage=$((stage + 1))
        in_stage=1
        stage_nonroot=0
        # FROM [--platform=...] image [AS name]
        local -a words
        read -ra words <<<"$args"
        local -a plain=()
        local w
        for w in "${words[@]}"; do [[ $w == --* ]] || plain+=("$w"); done
        parent=${plain[0]:-}
        as_name=''
        if ((${#plain[@]} >= 3)) && [[ ${plain[1]^^} == AS ]]; then as_name=${plain[2]}; fi
        stage_name=${as_name:-"#$stage"}
        if [[ -n $parent && -n ${ended["${parent,,}"]:-} ]]; then
          stage_nonroot=${ended["${parent,,}"]}
        fi
        ;;
      USER)
        local user=${args%%[[:space:]]*}
        local uid=${user%%:*}
        if [[ $user == *'$'* ]]; then
          problem "$file" "line $n: USER $user uses a variable, which this check cannot read"
        elif [[ -z $uid || ${uid,,} == root || $uid =~ ^0+$ ]]; then
          problem "$file" "line $n: USER $user is root (stage $stage, $stage_name)"
        else
          stage_nonroot=1
        fi
        ;;
      RUN)
        if ((!stage_nonroot)); then
          problem "$file" "line $n: RUN before a non-root USER (stage $stage, $stage_name)"
        fi
        ;;
    esac
  }

  # Read instructions: skip comments and blank lines, join lines that end in a backslash.
  while IFS= read -r line || [[ -n $line ]]; do
    lineno=$((lineno + 1))
    line=${line%$'\r'}
    line=${line#"${line%%[![:space:]]*}"}
    [[ -z $line || $line == '#'* ]] && continue
    if [[ -z $buf ]]; then start=$lineno; fi
    if [[ $line == *\\ ]]; then
      buf+="${line%\\} "
      continue
    fi
    buf+=$line
    instr=$buf
    buf=''
    handle "$start" "$instr"
  done <"$file"
  if [[ -n $buf ]]; then handle "$start" "$buf"; fi
  end_stage

  if ((stage == 0)); then problem "$file" 'no FROM instruction'; fi
}

for f in "$@"; do check_file "$f"; done

if ((errors)); then
  printf '%s problem(s)\n' "$errors"
  exit 1
fi
printf 'ok: every stage of %s runs as a non-root user before its first RUN\n' "$*"
