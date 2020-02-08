# readonly DATA_IMG=./pvmdata.img # optional large qemu disk
readonly THIS_DIR="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
readonly UNPRIVILEGED_ERR_MSG="This program must be run as a regular user"
readonly MOUNTS_ERR_MSG="some PVM mountpoints are mounted - possibly orphans from a previous run - unmount them first"
readonly MOUNTVARS_ERR_MSG="FIXME: pvm_setup_loopdev() was called in an improper state - one of [ \$bootdir , \$workdir , \$loopdev ] is already set"


# shellcheck source=/usr/lib/libretools/messages.sh
source "$(librelib messages)"


pvm_get_pvmboot_cmd()
{
  local intree_cmd=$THIS_DIR/pvmboot.sh
  local installed_cmd='pvmboot'

  [[ -f "$intree_cmd" ]]             && echo "$intree_cmd"           && return "$EXIT_SUCCESS"
  type -p $installed_cmd &>/dev/null && echo "$installed_cmd"        && return "$EXIT_SUCCESS"
                                        error "can not find pvmboot" && return "$EXIT_FAILURE"
}

pvm_get_hook() # ( hook_name )
{
  local hook_name=$1
  local intree_dir=$THIS_DIR/hooks
  local installed_dir=/usr/lib/parabola-vmbootstrap
  local hook_filename=hook-$hook_name.sh
  local locations=( "$intree_dir/$hook_filename" "$installed_dir/$hook_filename" "$hook_name" '' )
  local location

  for location in "${locations[@]}" ; do [[ -f "$location" ]] && break ; done ;
  [[ "$location" ]] && echo "$location"       || warning "no such hook: '%s'" "$hook_name"
  [[ "$location" ]] && return "$EXIT_SUCCESS" || return "$EXIT_FAILURE"
}

pvm_find_part_n() # ( imagefile fs_types ) , sets: $part_n
{
  local imagefile="$1" ; shift ;
  local fs_types="$@"

  # try locating the partition by filesystem type
  for fs_type in $fs_types
  do  local part_data=$(parted "$imagefile" print 2> /dev/null | grep $fs_type | head -n 1)
      part_n=$(         echo $part_data | cut -d ' ' -f 1                                 )

      ! [[ "$part_n" =~ ^[0-9]+$ ]] && part_n='' || break
  done

  [[ "$part_n" =~ ^[0-9]+$ ]] && return "$EXIT_SUCCESS" || return "$EXIT_FAILURE"
}

pvm_find_boot_part_n() # ( imagefile ) , sets: boot_part_n
{
  local imagefile="$1"
  local part_n

  pvm_find_part_n "$imagefile" fat32 ext2 || return "$EXIT_FAILURE"

  boot_part_n=$part_n

  return "$EXIT_SUCCESS"
}

pvm_find_root_part_n() # ( imagefile ) , sets: root_part_n
{
  local imagefile="$1"
  local part_n

  pvm_find_part_n "$imagefile" ext4 || return "$EXIT_FAILURE"

  root_part_n=$part_n

  return "$EXIT_SUCCESS"
}

pvm_check_unprivileged() # exits on failure
{
  [[ "$(id -u)" -eq 0 ]] && error "$UNPRIVILEGED_ERR_MSG" && exit "$EXIT_NOPERMISSION"
}

pvm_native_arch() # ( arch )
{
  local arch=$1
  local native_arch=$( [[ "$arch" =~ arm.* ]] && echo 'armv7l' || echo "$arch" )

  setarch "$native_arch" /bin/true 2>/dev/null && return "$EXIT_SUCCESS" || \
                                                  return "$EXIT_FAILURE"
}

pvm_check_file_exists_writable() # (file_path [ is_error_if_not_exists ])
{
  local file_path="$1"
  local is_error_if_not_exists=$( [[ "$2" == 'true' ]] && echo 1 || echo 0 )

  if   [[ -e "$file_path" ]]
  then if   [[ -w "$file_path" ]]
       then return "$EXIT_SUCCESS"
       else error "file exists but is not writable: '%s'" "$file_path"
            return "$EXIT_FAILURE"
       fi
  elif (( ! $is_error_if_not_exists ))
  then return "$EXIT_SUCCESS"
  else error "no such file: %s" "$file_path"
       return "$EXIT_FAILURE"
  fi
}

pvm_check_file_exists_and_writable() # (file_path)
{
  local file_path="$1"

  pvm_check_file_exists_writable $file_path true && return "$EXIT_SUCCESS" || \
                                                    return "$EXIT_FAILURE"
}

pvm_check_file_not_exists_or_writable() # (file_path)
{
  local file_path="$1"

  pvm_check_file_exists_writable $file_path && return "$EXIT_SUCCESS" || \
                                               return "$EXIT_FAILURE"
}

pvm_prompt_clobber_file() # (file_path)
{
  local file_path="$1"

  if   pvm_check_file_not_exists_or_writable "$file_path"
  then if   [[ -e "$file_path" ]]
       then warning "file exists: '%s'\nContinue? [y/N]" "$file_path"
            read -p " " -n 1 -r ; echo ;

            [[ $REPLY =~ ^[Yy]$ ]] || return "$EXIT_FAILURE"
            rm -f "$file_path"     || return "$EXIT_FAILURE"
        fi
       return "$EXIT_SUCCESS"
  else return "$EXIT_FAILURE"
  fi
}

pvm_setup_loopdev() # assumes: $imagefile , sets: $bootdir $workdir $loopdev , traps: INT TERM EXIT
{
  if file "$imagefile" | grep -Eq ': (data|DOS/MBR )'; then
    if [[ -z "${bootdir}${workdir}${loopdev}" ]]; then
      pvm_check_no_mounts && msg "creating loopback devices" || return "$EXIT_FAILURE"
    else
      error "$MOUNTVARS_ERR_MSG"
      return "$EXIT_FAILURE"
    fi
  else
    error "not a raw qemu image: '%s'" "$imagefile"
    return "$EXIT_FAILURE"
  fi

  trap 'pvm_cleanup' INT TERM EXIT

  # setup the loopback device
  bootdir="$(mktemp -d -t pvm-bootfs-XXXXXXXXXX)"    || return "$EXIT_FAILURE"
  workdir="$(mktemp -d -t pvm-rootfs-XXXXXXXXXX)"    || return "$EXIT_FAILURE"
  loopdev="$(sudo losetup -fLP --show "$imagefile")" || return "$EXIT_FAILURE"

  return "$EXIT_SUCCESS"
}

pvm_mount() # assumes: $imagefile $loopdev $bootdir $workdir
{
  pvm_setup_loopdev || return "$EXIT_FAILURE" # sets: $bootdir $workdir $loopdev

  # find boot and root filesystem partitions
  local boot_part_n root_part_n
  pvm_find_boot_part_n "$imagefile" || return "$EXIT_FAILURE" # sets: $boot_part_n
  pvm_find_root_part_n "$imagefile" || return "$EXIT_FAILURE" # sets: $root_part_n

  # mount boot and root filesystems
  msg "mounting image filesystems"
  sudo mount "$loopdev"p$boot_part_n "$bootdir" || return "$EXIT_FAILURE"
  sudo mount "$loopdev"p$root_part_n "$workdir" || return "$EXIT_FAILURE"

  return "$EXIT_SUCCESS"
}

pvm_umount() # unsets: $bootdir $workdir
{
  [[ "${bootdir}${workdir}${loopdev}" ]] && msg "un-mounting image filesystems"

  (sudo umount "$workdir"/boot && rmdir "$workdir") 2> /dev/null
  (sudo umount "$bootdir"      && rmdir "$bootdir") 2> /dev/null
  (sudo umount "$workdir"      && rmdir "$workdir") 2> /dev/null

  unset bootdir
  unset workdir
}

pvm_cleanup() # unsets: $loopdev , untraps: INT TERM EXIT
{
  trap - INT TERM EXIT

  pvm_umount
  sudo losetup -d "$loopdev"
  pvm_check_no_mounts || return "$EXIT_FAILURE"

  unset loopdev

  return "$EXIT_SUCCESS"
}

pvm_check_no_mounts() # assumes: $imagefile
{
  local n_pvm_mounts=$(   mount | grep /tmp/pvm                | wc --lines      )
  local n_loop_devs=$(    sudo losetup --associated $imagefile | wc --lines      )
  local are_any_mounts=$( (( $n_pvm_mounts + $n_loop_devs )) && echo 1 || echo 0 )

  (( $are_any_mounts )) && error "$MOUNTS_ERR_MSG" && return "$EXIT_FAILURE" || \
                                                      return "$EXIT_SUCCESS"
}

pvm_probe_arch() # assumes: $bootdir $workdir $imagefile , sets: $arch
{
  msg "detecting CPU architecture for image"

  local kernel=$(find "$bootdir" -maxdepth 1 -type f -iname '*vmlinu*' | head -n1)
  local guest_arch

  if [ -n "$kernel" ]; then
    msg2 "found kernel binary: %s" "$kernel"
  else
    warning "%s: unable to find kernel binary" "$imagefile"
    return "$EXIT_FAILURE"
  fi

  guest_arch="$(readelf -h "$workdir"/bin/true 2>/dev/null      | \
                grep Machine | sed 's|[^:]*:\s*\([^:,]*\).*|\1|')"

  case "$guest_arch" in
    ARM                 ) arch=armv7h  ;;
    i386|i386:*|*\ 80386) arch=i686    ;;
    PowerPC64           ) arch=ppc64le ;;
    RISC-V              ) arch=riscv64 ;;
    x86_64|*\ X86-64    ) arch=x86_64  ;;
    *                   ) arch=''      ;;
  esac

  if [[ "$arch" ]]; then
    msg2 "detected guest \`/bin/true\` arch: '%s'=>'%s'" "$guest_arch" "$arch"
    return "$EXIT_SUCCESS"
  else
    error "image arch is unknown: '%s'" "$guest_arch"
    return "$EXIT_FAILURE"
  fi
}

pvm_boot() # ( imagefile qemu_args )
{
  local imagefile="$1" ; shift ;
  local qemu_args=(-no-reboot $@)
  local pvmboot_cmd=$(pvm_get_pvmboot_cmd)
  local was_error=$?

  [[ "$pvmboot_cmd" ]] || return $EXIT_FAILURE

  DISPLAY='' "$pvmboot_cmd" "$imagefile" "${qemu_args[@]}" ; was_error=$? ;

  (( ! $was_error )) && return $EXIT_SUCCESS || return $EXIT_FAILURE
}
