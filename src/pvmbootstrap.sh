#!/bin/bash
###############################################################################
#     parabola-vmbootstrap -- create and start parabola virtual machines      #
#                                                                             #
#     Copyright (C) 2017 - 2019  Andreas Grapentin                            #
#     Copyright (C) 2019 - 2020  bill-auger                                   #
#                                                                             #
#     This program is free software: you can redistribute it and/or modify    #
#     it under the terms of the GNU General Public License as published by    #
#     the Free Software Foundation, either version 3 of the License, or       #
#     (at your option) any later version.                                     #
#                                                                             #
#     This program is distributed in the hope that it will be useful,         #
#     but WITHOUT ANY WARRANTY; without even the implied warranty of          #
#     MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the           #
#     GNU General Public License for more details.                            #
#                                                                             #
#     You should have received a copy of the GNU General Public License       #
#     along with this program.  If not, see <http://www.gnu.org/licenses/>.   #
###############################################################################


# defaults
readonly PKG_SET_MIN='minimal'
readonly PKG_SET_STD='standard'
readonly PKG_SET_DEV='devel'                            ; readonly DEF_PKG_SET=$PKG_SET_STD ;
readonly MIN_PKGS=('base'                             ) ; readonly ROOT_MB_MIN=800          ;
readonly STD_PKGS=('base' 'parabola-base'             ) ; readonly ROOT_MB_STD=1000         ;
readonly DEV_PKGS=('base' 'parabola-base' 'base-devel') ; readonly ROOT_MB_DEV=1250         ;
readonly DEF_PKGS=(${STD_PKGS[@]}                     ) ; readonly DEF_MIN_MB=$ROOT_MB_STD  ;
readonly DEF_KERNEL='linux-libre' # ASSERT: must be 'linux-libre', per 'parabola-base'
readonly DEF_MIRROR=https://repo.parabola.nu
readonly DEF_ROOT_MB=32000
readonly DEF_BOOT_MB=100
readonly DEF_SWAP_MB=0
readonly MANDATORY_PKGS_ALL=(                            )
readonly MANDATORY_PKGS_armv7h=(  haveged net-tools      )
readonly MANDATORY_PKGS_i686=(    haveged net-tools grub )
readonly MANDATORY_PKGS_ppc64le=( haveged net-tools      )
readonly MANDATORY_PKGS_riscv64=(                        )
readonly MANDATORY_PKGS_x86_64=(  haveged net-tools grub )

# misc
readonly GUEST_CACHED_PKGS=('ca-certificates-utils')
readonly PVM_HOOKS_SUCCESS_MSG="[hooks.sh] pre-init hooks successful"

# options
BasePkgSet=$DEF_PKG_SET
MinRootMb=$DEF_MIN_MB
Hooks=()
Kernels=()
Mirror=$DEF_MIRROR
IsNonsystemd=0
Pkgs=(${DEF_PKGS[@]})
OptPkgs=()
RootSizeMb=$DEF_ROOT_MB
BootSizeMb=$DEF_BOOT_MB
SwapSizeMb=$DEF_SWAP_MB
HasSwap=0


usage()
{
  print "USAGE:"
  print "  pvmbootstrap [-b <base-set>] [-h] [-H <hook>] [-k <kernel>] [-M <mirror>]"
  print "               [-O] [-p <package>] [-s <root_size>] [-S <swap_size>]"
  print "               <img> <arch>"
  echo
  prose "Produce preconfigured parabola GNU/Linux-libre virtual machine instances."
  echo
  prose "The produced image file is written to <img>, and is configured and
         bootstrapped for the achitecture specified in <arch>. <arch> can be any
         one of the supported architectures: 'x86_64', 'i686' or 'armv7h',
         or one of the experimental arches: 'ppc64le' or 'riscv64'."
  echo
  echo  "Supported options:"
  echo  "  -b <base-set>   Select one of the pre-defined package-sets described below"
  echo  "                  (default: 'standard')"
  echo  "  -h              Display this help and exit"
  echo  "  -H <hook>       Enable a hook to customize the created image. This can be"
  echo  "                  the path to a script, which will be executed once within"
  echo  "                  the running VM, or one of the pre-defined hooks described"
  echo  "                  below. This option can be specified multiple times."
  echo  "  -k <kernel>     Specify an additional kernel package (default: $DEF_KERNEL)."
  echo  "                  This option can be specified multiple times; but note that"
  echo  "                  '$DEF_KERNEL' will be installed as part of the '$PKG_SET_STD' and"
  echo  "                  '$PKG_SET_DEV' package sets, regardless of this option."
  echo  "  -M <mirror>     Specify a different mirror from which to fetch packages"
  echo  "                  (default: $DEF_MIRROR)"
  echo  "  -O              Bootstrap an openrc system instead of a systemd one"
  echo  "                  NOTE: This option is currently ignored; because"
  echo  "                        the 'preinit' hook is implemented as a systemd service."
  echo  "  -p <package>    Specify additional packages to be installed in the VM image."
  echo  "                  This option can be specified multiple times."
  echo  "                  Note that these will be ignored if -s <root_size> is 0."
  echo  "  -s <root_size>  Set the size (in MB) of the root partition (default: $DEF_ROOT_MB)."
  echo  "                  If this is 0 (or less than the <base-set> requires),"
  echo  "                  the VM image will be the smallest size possible,"
  echo  "                  fit to the <base-set>; and any -p <package> will be ignored."
  echo  "  -S <swap_size>  Set the size (in MB) of the swap partition (default: $DEF_SWAP_MB)"
  echo
  echo  "Pre-defined package-sets:"
  print "  $PKG_SET_MIN:%$((15 - ${#PKG_SET_MIN}))s${MIN_PKGS[*]}" ""
  print "  $PKG_SET_STD:%$((15 - ${#PKG_SET_STD}))s${STD_PKGS[*]}" ""
  print "  $PKG_SET_DEV:%$((15 - ${#PKG_SET_DEV}))s${DEV_PKGS[*]}" ""
  echo
  echo  "Pre-defined hooks:"
  echo  "  ethernet-dhcp:  Configure and enable an ethernet device in the virtual"
  echo  "                  machine, using openresolv, dhcpcd, and systemd-networkd"
  echo  "                  (systemd only)"
  echo
  echo  "This script is part of parabola-vmbootstrap. source code available at:"
  echo  "  <https://git.parabola.nu/parabola-vmbootstrap.git>"
}

pvm_bootstrap() # assumes: $arch $imagefile $loopdev $workdir , traps: INT TERM RETURN
{
  # prompt to clobber if the target output file already exists
  pvm_check_no_mounts                  || return "$EXIT_FAILURE"
  mkdir -p "$(dirname "$imagefile")"   || return "$EXIT_FAILURE"
  pvm_prompt_clobber_file "$imagefile" || return "$EXIT_FAILURE"

  msg "starting build for %s image: %s" "$arch" "$imagefile"

  # create the raw image file
  local img_mb=$(( $BootSizeMb + $SwapSizeMb + $RootSizeMb ))
  qemu-img create -f raw "$imagefile" "${img_mb}M" || return "$EXIT_FAILURE"

  # prepare for cleanup
  trap 'pvm_bootstrap_cleanup' INT TERM RETURN

  # mount the virtual disk
  local bootdir workdir loopdev
  pvm_setup_loopdev                                || return "$EXIT_FAILURE" # sets: $bootdir $workdir $loopdev
  sudo dd if=/dev/zero of="$loopdev" bs=1M count=8 || return "$EXIT_FAILURE"

  # partition
  local bios_grub_begin="1MiB"
  local bios_grub_end="2MiB"
  local boot_begin=${bios_grub_end}
  local boot_end="$(( ${boot_begin/MiB} + $BootSizeMb ))MiB"
  local swap_begin=${boot_end}
  local swap_end="$(( ${swap_begin/MiB} + $SwapSizeMb ))MiB"
  local root_begin=${swap_end}
  local boot_label boot_fs_type
  case "$arch" in
    armv7h) boot_label='ESP'     ; boot_fs_type='fat32' ;;
    *     ) boot_label='primary' ; boot_fs_type='ext2'  ;;
  esac
  local swap_label='primary'
  local root_label='primary'
  local swap_part="mkpart $swap_label linux-swap $swap_begin $swap_end"
  msg "partitioning blank image"
  sudo parted -s "$loopdev"                                \
    mklabel gpt                                            \
    mkpart primary $bios_grub_begin $bios_grub_end         \
    set 1 bios_grub on                                     \
    mkpart $boot_label $boot_fs_type $boot_begin $boot_end \
    set 2 boot on                                          \
    $( (( $HasSwap )) && echo $swap_part )                 \
    mkpart $root_label ext4 $root_begin 100%               || return "$EXIT_FAILURE"

  # refresh partition data
  sudo partprobe "$loopdev"

  # make file systems
  local boot_mkfs_cmd
  local boot_loopdev="$loopdev"p2
  local swap_loopdev="$loopdev"p3
  local root_loopdev="$loopdev"p$( (( $HasSwap )) && echo 4 || echo 3 )
  case "$arch" in
    armv7h         ) boot_mkfs_cmd='mkfs.vfat -F 32' ;;
    i686|x86_64    ) boot_mkfs_cmd='mkfs.ext2'       ;;
    ppc64le|riscv64) boot_mkfs_cmd='mkfs.ext2'       ;;
  esac
  msg "creating target filesystems"
  sudo $boot_mkfs_cmd "$boot_loopdev" || return "$EXIT_FAILURE"
  ! (( $HasSwap ))                    || \
  sudo mkswap         "$swap_loopdev" || return "$EXIT_FAILURE"
  sudo mkfs.ext4      "$root_loopdev" || return "$EXIT_FAILURE"

  # mount partitions
  msg "mounting target partitions"
  sudo mount "$root_loopdev" "$workdir"      || return "$EXIT_FAILURE"
  sudo mkdir -p              "$workdir"/boot || return "$EXIT_FAILURE"
  sudo mount "$boot_loopdev" "$workdir"/boot || return "$EXIT_FAILURE"

  # setup qemu-user-static, if necessary
  if ! pvm_native_arch "$arch"; then
    local qemu_arch
    case "$arch" in
      armv7h) qemu_arch=arm     ;;
      *     ) qemu_arch="$arch" ;;
    esac

    local qemu_static=$(sudo grep -l -F -e "interpreter /usr/bin/qemu-$qemu_arch-"   \
                                  -r -- /proc/sys/fs/binfmt_misc 2>/dev/null       | \
                        xargs -r sudo grep -xF 'enabled'                             )
    if [[ -n "$qemu_static" ]]; then
      msg "found qemu-user-static for arch: '%s'" "$qemu_arch"
    else
      error "missing qemu-user-static for arch: '%s'" "$qemu_arch"
      return "$EXIT_FAILURE"
    fi

    sudo mkdir -p "$workdir"/usr/bin
    sudo cp -v "/usr/bin/qemu-$qemu_arch-"* "$workdir"/usr/bin || return "$EXIT_FAILURE"
  fi

  # prepare pacstrap config
  local pacconf="$(mktemp -t pvm-pacconf-XXXXXXXXXX)" || return "$EXIT_FAILURE"
  local repos=(libre core extra community pcr)
  (( $IsNonsystemd )) && repos=('nonsystemd' ${repos[@]})
  echo -e "[options]\nArchitecture = $arch" > "$pacconf"
  for repo in ${repos[@]};    do echo "[$repo]"                           >> "$pacconf";
      for mirror_n in {1..5}; do echo "Server = $Mirror/\$repo/os/\$arch" >> "$pacconf"; done;
  done

  # prepare package lists
  local kernels=(     ${Kernels[@]}                                                   )
  local pkgs=(        ${Pkgs[@]} ${Kernels[@]} ${OptPkgs[@]} ${MANDATORY_PKGS_ALL[@]} )
  local pkgs_cached=( ${GUEST_CACHED_PKGS[@]}                                         )
  case "$arch" in
    armv7h ) pkgs+=( ${MANDATORY_PKGS_armv7h[@]}  ) ;;
    i686   ) pkgs+=( ${MANDATORY_PKGS_i686[@]}    ) ;;
    ppc64le) pkgs+=( ${MANDATORY_PKGS_ppc64le[@]} ) ;;
    riscv64) pkgs+=( ${MANDATORY_PKGS_riscv64[@]} ) ;;
    x86_64 ) pkgs+=( ${MANDATORY_PKGS_x86_64[@]}  ) ;;
  esac
  ((   $IsNonsystemd )) && [[ "$BasePkgSet" == "$PKG_SET_MIN"        ]] && pkgs+=(libelogind)
  (( ! $IsNonsystemd )) && [[ "${Hooks[@]}" =~ hook-ethernet-dhcp.sh ]] && pkgs+=(dhcpcd)

  # minimize package lists
  Kernels=() ; Pkgs=() ;
  for kernel in $(printf "%s\n" "${kernels[@]}" | sort -u) ; do Kernels+=($kernel) ; done ;
  for pkg    in $(printf "%s\n" "${pkgs[@]}"    | sort -u) ; do Pkgs+=($pkg)       ; done ;

  # pacstrap! :)
  msg "installing packages into the work chroot"
  sudo pacstrap -GMc -C "$pacconf" "$workdir" "${pkgs[@]}"        || return "$EXIT_FAILURE"
  sudo pacstrap -GM  -C "$pacconf" "$workdir" "${pkgs_cached[@]}" || return "$EXIT_FAILURE"

  # generate list of installed packages
  msg2 "generating a list of installed packages"
  local pkglist_awk_prog='/\[installed\]$/ {print $1 "/" $2 "-" $3}'
  local pkglist_file=$(dirname $imagefile)/pkglist.txt
  pacman -Sl -r "$workdir/" --config "$pacconf" | awk "$pkglist_awk_prog" > $pkglist_file

  # generate an fstab
  msg "generating /etc/fstab"
  case "$arch" in
    riscv64)                                                        ;;
    *      ) sudo swapoff --all
             (( $HasSwap )) && sudo swapon "$swap_loopdev"
             genfstab -U "$workdir" | sudo tee "$workdir"/etc/fstab
             (( $HasSwap )) && sudo swapoff "$swap_loopdev"
             sudo swapon --all                                      ;;
  esac

  # configure the system envoronment
  local hostname='parabola'
  local lang='en_US.UTF-8'
  msg "configuring system envoronment"
  echo -n "/etc/hostname: "    ; echo $hostname    | sudo tee "$workdir"/etc/hostname    ;
  echo -n "/etc/locale.conf: " ; echo "LANG=$lang" | sudo tee "$workdir"/etc/locale.conf ;
  sudo sed -i "s/#${lang}/${lang}/" "$workdir"/etc/locale.gen

  # install a boot loader
  msg "installing boot loader"
  case "$arch" in
    armv7h)
      msg2 "(armv7h has no boot loader)"
      ;;
    i686|x86_64)
      local grub_def_file="$workdir"/etc/default/grub
      local grub_cfg_file=/boot/grub/grub.cfg
      # enable serial console
      local field=GRUB_CMDLINE_LINUX_DEFAULT
      local value="console=tty0 console=ttyS0"
      sudo sed -i "s/.*$field=.*/$field=\"$value\"/" "$grub_def_file" || return "$EXIT_FAILURE"
      # disable boot menu timeout
      local field=GRUB_TIMEOUT
      local value=0
      sudo sed -i "s/.*$field=.*/$field=$value/" "$grub_def_file"     || return "$EXIT_FAILURE"
      # install grub to the VM
      sudo arch-chroot "$workdir" grub-install "$loopdev"             || return "$EXIT_FAILURE"
      sudo arch-chroot "$workdir" grub-mkconfig -o $grub_cfg_file     || return "$EXIT_FAILURE"
      ;;
    ppc64le)
      msg2 "(ppc64le has no boot loader)"
      ;;
    riscv64)
      # FIXME: for the time being, use berkeley bootloader to boot
      if [[ -f /usr/lib/parabola-vmbootstrap/bbl ]]; then
        cp /usr/lib/parabola-vmbootstrap/bbl "$workdir"/boot/
      else
        error "riscv64 requires the berkeley bootloader from the 'parabola-vmbootstrap' package"
        return "$EXIT_FAILURE"
      fi
      ;;
  esac

  # regenerate the initcpio(s), to skip the 'autodetect' hook
  for kernel in ${Kernels[@]}
  do
    local preset_file="$workdir"/etc/mkinitcpio.d/${kernel}.preset
    local default_options="default_options=\"-S autodetect\""

    msg "regenerating initcpio for kernel: '${kernel}'"
    sudo cp "$preset_file"{,.backup}                                 || return "$EXIT_FAILURE"
    echo "$default_options" | sudo tee -a "$preset_file" > /dev/null || return "$EXIT_FAILURE"
    sudo arch-chroot "$workdir" mkinitcpio -p ${kernel}              || return "$EXIT_FAILURE"
    sudo mv "$preset_file"{.backup,}                                 || return "$EXIT_FAILURE"
  done

  # initialize the pacman keyring
  msg "initializing the pacman keyring"
  sudo arch-chroot "$workdir" pacman-key --init
  sudo arch-chroot "$workdir" pacman-key --populate archlinux archlinux32 archlinuxarm parabola

  # push hooks into the image
  msg "preparing hooks"
  sudo mkdir -p "$workdir"/root/hooks
  [ "${#Hooks[@]}" -eq 0 ] || sudo cp -v "${Hooks[@]}" "$workdir"/root/hooks/
  (( $IsNonsystemd )) && sudo rm "$workdir"/root/hooks/hook-ethernet-dhcp.sh # systemd-only hook

  # create a master hook script
  msg2 "hooks.sh:"
  sudo tee "$workdir"/root/hooks.sh << EOF
#!/bin/bash
echo "[hooks.sh] boot successful - configuring ...."

# generate the locale
locale-gen

# fix the mkinitcpio
for kernel in ${Kernels[@]} ; do mkinitcpio -p \$kernel ; done ;

# fix ca-certificates
pacman -U --noconfirm /var/cache/pacman/pkg/ca-certificates-utils-*.pkg.tar.xz

# run the hooks
for hook in /root/hooks/*; do
  echo "[hooks.sh] running hook: '\$(basename \$hook)'"
  source "\$hook" || return
done

# clean up after yourself
systemctl disable preinit.service
rm -f  /root/.bash_history
rm -rf /root/hooks
rm -f  /root/hooks.sh
rm -f  /usr/lib/systemd/system/preinit.service
rm -f  /var/cache/pacman/pkg/*

# report success :)
echo "$PVM_HOOKS_SUCCESS_MSG - powering off"
[[ -e "/usr/lib/libretools/common.sh" ]] && rm -f /usr/lib/libretools/common.sh
EOF

  # create a pre-init service to run the hooks
  msg2 "preinit.service:"
  sudo tee "$workdir"/usr/lib/systemd/system/preinit.service << 'EOF'
[Unit]
Description=Oneshot VM Preinit
After=multi-user.target

[Service]
StandardOutput=journal+console
StandardError=journal+console
ExecStart=/usr/bin/bash /root/hooks.sh
Type=oneshot
ExecStopPost=shutdown -r now

[Install]
WantedBy=multi-user.target
EOF

  # configure services
  msg "configuring services"
  # disable audit
  sudo arch-chroot "$workdir" systemctl mask systemd-journald-audit.socket
  # enable the entropy daemon, to avoid stalling https
  sudo arch-chroot "$workdir" systemctl enable haveged.service
  # enable the pre-init service
  sudo arch-chroot "$workdir" systemctl enable preinit.service || return "$EXIT_FAILURE"

  # unmount everything
  pvm_bootstrap_cleanup
}

pvm_bootstrap_preinit() # assumes: $imagefile
{
  pvm_check_no_mounts || return "$EXIT_FAILURE"

  # boot the machine to run the pre-init hooks
  [[ "$(pvm_get_pvmboot_cmd)" ]] && msg "booting the VM to run the pre-init hooks" || \
                                    warning "unable to run pre-init hooks"
  exec 3>&1
  pvm_boot "$imagefile" | tee /dev/fd/3 | grep -q -F "$PVM_HOOKS_SUCCESS_MSG"
  local res=$?
  exec 3>&-
  ! (( $res )) || error "%s: failed to complete preinit hooks" "$imagefile"

  return $res
}

pvm_bootstrap_cleanup() # unsets: $pacconf , untraps: INT TERM RETURN
{
  trap - INT TERM RETURN

  [[ "${workdir}${pacconf}" ]] && msg "cleaning up"

  [[ -n "$workdir" ]] && sudo rm -f "$workdir"/usr/bin/qemu-*C
  [[ -n "$pacconf" ]] && rm -f "$pacconf"
  pvm_cleanup || return "$EXIT_FAILURE"

  unset pacconf
}

main() # ( [cli_options] imagefile arch )
{
  pvm_check_unprivileged # exits on failure

  # parse options
  while getopts 'b:hH:k:M:Op:s:S:' arg; do
    case "$arg" in
      b) case $OPTARG in $PKG_SET_MIN) BasePkgSet=$OPTARG                             ;
                                       Pkgs=(${MIN_PKGS[@]}) ; MinRootMb=$ROOT_MB_MIN ;;
                         $PKG_SET_STD) BasePkgSet=$OPTARG    ; Kernels+=($DEF_KERNEL) ;
                                       Pkgs=(${STD_PKGS[@]}) ; MinRootMb=$ROOT_MB_STD ;;
                         $PKG_SET_DEV) BasePkgSet=$OPTARG    ; Kernels+=($DEF_KERNEL) ;
                                       Pkgs=(${DEV_PKGS[@]}) ; MinRootMb=$ROOT_MB_DEV ;;
                         *           ) warning "invalid base set: %s" "$OPTARG"       ;;
         esac                                                                           ;;
      h) usage; return "$EXIT_SUCCESS"                                                  ;;
      H) Hooks+=( "$(pvm_get_hook $OPTARG)" )                                           ;;
      k) Kernels+=($OPTARG)                                                             ;;
      M) Mirror="$OPTARG"                                                               ;;
      O) IsNonsystemd=0                                                                 ;; # TODO:
      p) OptPkgs+=($OPTARG)                                                             ;;
      s) RootSizeMb="$(sed 's|[^0-9]||g' <<<$OPTARG)"                                   ;;
      S) SwapSizeMb="$(sed 's|[^0-9]||g' <<<$OPTARG)"                                   ;;
      *) error "invalid option: '%s'" "$arg" ; usage >&2 ; exit "$EXIT_INVALIDARGUMENT" ;;
    esac
  done
  local shiftlen=$(( OPTIND - 1 ))
  shift $shiftlen
  local imagefile="$1"
  local arch="$2"
  (( $# != 2 )) && error "insufficient arguments" && usage >&2 && exit "$EXIT_INVALIDARGUMENT"

  (( $RootSizeMb > 0          )) && \
  (( $RootSizeMb < $MinRootMb )) && warning "specified root FS size too small - ignoring OptPkgs"
  (( $RootSizeMb < $MinRootMb )) && RootSizeMb=$MinRootMb && OptPkgs=()
  RootSizeMb=$(( $RootSizeMb + (${#Kernels[@]} * 75) ))
  HasSwap=$( (( $SwapSizeMb > 0 )) && echo 1 || echo 0 )

  msg "making $arch image: $imagefile"

  # determine if the target arch is supported
  case "$arch" in
    i686|x86_64|armv7h)                                            ;;
    ppc64le|riscv64   ) warning "arch is experimental: %s" "$arch" ;;
    *                 ) error   "arch is unsupported: %s"  "$arch"
                        exit "$EXIT_INVALIDARGUMENT"               ;;
  esac

  # create the virtual machine
  if pvm_bootstrap; then
    if pvm_bootstrap_preinit; then
      msg "bootstrap complete for image: %s" "$imagefile"
      exit "$EXIT_SUCCESS"
    else
      error "bootstrap complete, but preinit failed for image: %s" "$imagefile"
      exit "$EXIT_FAILURE"
    fi
  else
    error "bootstrap failed for image: %s" "$imagefile"
    exit "$EXIT_FAILURE"
  fi
}


if   source /usr/lib/parabola-vmbootstrap/pvm-common.sh.inc                     2> /dev/null || \
     source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"/pvm-common.sh.inc 2> /dev/null
then main "$@"
else echo "can not find pvm-common.sh.inc" && exit 1
fi
