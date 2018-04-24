#!/bin/bash
 ##############################################################################
 #                         parabola-imagebuilder                              #
 #                                                                            #
 #    Copyright (C) 2018  Andreas Grapentin                                   #
 #                                                                            #
 #    This program is free software: you can redistribute it and/or modify    #
 #    it under the terms of the GNU General Public License as published by    #
 #    the Free Software Foundation, either version 3 of the License, or       #
 #    (at your option) any later version.                                     #
 #                                                                            #
 #    This program is distributed in the hope that it will be useful,         #
 #    but WITHOUT ANY WARRANTY; without even the implied warranty of          #
 #    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the           #
 #    GNU General Public License for more details.                            #
 #                                                                            #
 #    You should have received a copy of the GNU General Public License       #
 #    along with this program.  If not, see <http://www.gnu.org/licenses/>.   #
 ##############################################################################

# shellcheck source=src/shared/feedback.sh
. "$TOPSRCDIR"/shared/feedback.sh
# shellcheck source=src/shared/checks.sh
. "$TOPSRCDIR"/shared/checks.sh

retry() {
  local OPTIND o n=5 s=60
  while getopts "n:s:" o; do
    case "$o" in
      n) n="$OPTARG" ;;
      s) s="$OPTARG" ;;
      *) die -e $ERROR_INVOCATION "Usage: ${FUNCNAME[0]} [-n tries] [-s delay] cmd ..." ;;
    esac
  done
  shift $((OPTIND-1))

  for _ in $(seq "$((n - 1))"); do
    "$@" && return 0
    sleep "$s"
  done
  "$@" || return
}

# appends a command to a trap
# source: https://stackoverflow.com/questions/3338030/multiple-bash-traps-for-the-same-signal
#
# - 1st arg:  code to add
# - remaining args:  names of traps to modify
#
trap_add() {
    trap_add_cmd=$1; shift || fatal "${FUNCNAME[0]} usage error"
    for trap_add_name in "$@"; do
        trap -- "$(
            # helper fn to get existing trap command from output
            # of trap -p
            extract_trap_cmd() { printf '%s\n' "$3"; }
            # print the new trap command
            printf '%s\n' "${trap_add_cmd}"
            # print existing trap command with newline
            eval "extract_trap_cmd $(trap -p "${trap_add_name}")"
        )" "${trap_add_name}" \
            || fatal "unable to add to trap ${trap_add_name}"
    done
}
# set the trace attribute for the above function.  this is
# required to modify DEBUG or RETURN traps because functions don't
# inherit them unless the trace attribute is set
declare -f -t trap_add
