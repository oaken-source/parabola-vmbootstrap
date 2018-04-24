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

check_exe() {
  local OPTIND o r=
  while getopts "r" o; do
    case "$o" in
      r) r=yes ;;
      *) die -e "$ERROR_INVOCATION" "Usage: ${FUNCNAME[0]} [-r] program ..." ;;
    esac
  done
  shift $((OPTIND-1))

  local v res=0
  for v in "$@"; do
    echo -n "checking for $v in \$PATH ... "

    local have_exe=yes
    type -p "$v" >/dev/null || have_exe=no
    echo $have_exe

    if [ "x$have_exe" != "xyes" ]; then
      [ "x$r" == "xyes" ] && die -e "$ERROR_MISSING" "missing $v in \$PATH"
      res="$ERROR_MISSING"
    fi
  done

  return "$res"
}

check_file() {
  local OPTIND o r=
  while getopts "r" o; do
    case "$o" in
      r) r=yes ;;
      *) die -e "$ERROR_INVOCATION" "Usage: ${FUNCNAME[0]} [-r] file ..." ;;
    esac
  done
  shift $((OPTIND-1))

  local v res=0
  for v in "$@"; do
    echo -n "checking for $v ... "

    local have_file=yes
    [ -f "$v" ] || have_file=no
    echo $have_file

    if [ "x$have_file" != "xyes" ]; then
      [ "x$r" == "xyes" ] && die -e "$ERROR_MISSING" "missing $v in filesystem"
      res="$ERROR_MISSING"
    fi
  done

  return "$res"
}

check_gpgkey() {
  local OPTIND o r=
  while getopts "r" o; do
    case "$o" in
      r) r=yes ;;
      *) die -e "$ERROR_INVOCATION" "Usage: ${FUNCNAME[0]} [-r] key" ;;
    esac
  done
  shift $((OPTIND-1))

  local v res=0
  for v in "$@"; do
    echo -n "checking for key $v ... "

    local have_key=yes
    sudo -u "$SUDO_USER" gpg --list-keys "$v" &>/dev/null || have_key=no
    echo $have_key

    if [ "x$have_key" != "xyes" ]; then
      [ "x$r" == "xyes" ] && die -e "$ERROR_MISSING" "missing $v in keyring"
      res="$ERROR_MISSING"
    fi
  done

  return "$res"
}
