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


# shellcheck source=/usr/lib/libretools/messages.sh
source "$(librelib messages)"


# defaults
readonly DEF_PKGS=('base' 'parabola-base' 'openssh')
readonly DEF_KERNEL='linux-libre' # ASSERT: must be 'linux-libre', per 'parabola-base'
readonly DEF_MIRROR=https://repo.parabola.nu
readonly DEF_IMG_GB=64
readonly MIN_GB=1
readonly DEF_BOOT_MB=100
readonly DEF_SWAP_MB=0

# misc
readonly THIS_DIR="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
readonly GUEST_CACHED_PKGS=('ca-certificates-utils')

# options
Hooks=()
Kernels=($DEF_KERNEL)
Mirror=$DEF_MIRROR
IsNonsystemd=0
Pkgs=()
ImgSizeGb=$DEF_IMG_GB
BootSizeMb=$DEF_BOOT_MB
SwapSizeMb=$DEF_SWAP_MB
HasSwap=0


usage() {
  print "USAGE:"
  print "  pvmbootstrap [-h] [-H <hook>   ] [-k <kernel>  ] [-M <mirror>   ]"
  print "               [-O] [-p <package>] [-s <img_size>] [-S <swap_size>]"
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
  echo  "  -h              Display this help and exit"
  echo  "  -H <hook>       Enable a hook to customize the created image. This can be"
  echo  "                  the path to a script, which will be executed once within"
  echo  "                  the running VM, or one of the pre-defined hooks described"
  echo  "                  below. This option can be specified multiple times."
  echo  "  -k <kernel>     Specify an additional kernel package (default: $DEF_KERNEL)."
  echo  "                  This option can be specified multiple times; but note that"
  echo  "                  '$DEF_KERNEL' will be installed, regardless of this option."
  echo  "  -M <mirror>     Specify a different mirror from which to fetch packages"
  echo  "                  (default: $DEF_MIRROR)"
  echo  "  -O              Bootstrap an openrc system instead of a systemd one"
  echo  "                  NOTE: This option is currently ignored; because"
  echo  "                        the 'preinit' hook is implemented as a systemd service."
  echo  "  -p <package>    Specify additional packages to be installed in the VM image."
  echo  "                  This option can be specified multiple times."
  echo  "  -s <img_size>   Set the size (in GB) of the VM image (minimum: $MIN_GB, default: $DEF_IMG_GB)"
  echo  "  -S <swap_size>  Set the size (in MB) of the swap partition (default: $DEF_SWAP_MB)"
  echo
  echo  "Pre-defined hooks:"
  echo  "  ethernet-dhcp:  Configure and enable an ethernet device in the virtual"
  echo  "                  machine, using openresolv, dhcpcd, and systemd-networkd"
  echo  "                  (systemd only)"
  echo
  echo  "This script is part of parabola-vmbootstrap. source code available at:"
  echo  "  <https://git.parabola.nu/parabola-vmbootstrap.git>"
}

pvm_native_arch() {
  local arch=$( [[ "$1" =~ arm.* ]] && echo 'armv7l' || echo "$1" )

  setarch "$arch" /bin/true 2>/dev/null || return "$EXIT_FAILURE"
}

pvm_bootstrap() {
  msg "starting creation of %s image: %s" "$arch" "$imagefile"

  # create the raw image file
  qemu-img create -f raw "$imagefile" "${ImgSizeGb}G" || return "$EXIT_FAILURE"

  # prepare for cleanup
  trap 'pvm_cleanup' INT TERM RETURN

  # mount the virtual disk
  local workdir loopdev
  workdir="$(mktemp -d -t pvm-rootfs-XXXXXXXXXX)"    || return "$EXIT_FAILURE"
  loopdev="$(sudo losetup -fLP --show "$imagefile")" || return "$EXIT_FAILURE"
  sudo dd if=/dev/zero of="$loopdev" bs=1M count=8   || return "$EXIT_FAILURE"

  # partition
  local boot_begin="$( [[ "$arch" =~ i686|x86_64 ]] && echo 2 || echo 1 )MiB"
  local boot_end="$(( ${boot_begin/MiB} + $BootSizeMb ))MiB"
  local swap_begin=${boot_end}
  local swap_end="$(( ${swap_begin/MiB} + $SwapSizeMb ))MiB"
  local root_begin=${swap_end}
  local legacy_part boot_label boot_fs_type boot_flag
  case "$arch" in
    i686|x86_64)
        legacy_part='mkpart primary 1MiB 2Mib'
        boot_label='primary'
        boot_fs_type='ext2'
        boot_flag='bios_grub'                   ;; # legacy_part
    armv7h)
        boot_label='ESP'
        boot_fs_type='fat32'
        boot_flag='boot'                        ;;
    ppc64le|riscv64)
        boot_label='primary'
        boot_fs_type='ext2'
        boot_flag='boot'                        ;;
  esac
  local swap_label='primary'
  local root_label='primary'
  local swap_part=$( (( $HasSwap )) && echo "mkpart $swap_label linux-swap $swap_begin $swap_end")
  msg "partitioning blank image"
  sudo parted -s "$loopdev"                                \
    mklabel gpt                                            \
    $legacy_part                                           \
    mkpart $boot_label $boot_fs_type $boot_begin $boot_end \
    set 1 $boot_flag on                                    \
    $swap_part                                             \
    mkpart $root_label ext4 $root_begin 100%               || return "$EXIT_FAILURE"

  # refresh partition data
  sudo partprobe "$loopdev"

  # make file systems
  local boot_mkfs_cmd boot_loopdev swap_loopdev root_loopdev
  case "$arch" in
    i686|x86_64)
      boot_mkfs_cmd='mkfs.ext2'
      boot_loopdev="$loopdev"p2
      swap_loopdev="$loopdev"p3
      root_loopdev="$loopdev"p$( (( $HasSwap )) && echo 4 || echo 3 ) ;;
    armv7h)
      boot_mkfs_cmd='mkfs.vfat -F 32'
      boot_loopdev="$loopdev"p1
      swap_loopdev="$loopdev"p2
      root_loopdev="$loopdev"p$( (( $HasSwap )) && echo 3 || echo 2 ) ;;
    ppc64le|riscv64)
      boot_mkfs_cmd='mkfs.ext2'
      boot_loopdev="$loopdev"p1
      swap_loopdev="$loopdev"p2
      root_loopdev="$loopdev"p$( (( $HasSwap )) && echo 3 || echo 2 ) ;;
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
    # target arch can't execute natively, pacstrap is going to need help by qemu
    local qemu_arch
    case "$arch" in
      armv7h) qemu_arch=arm     ;;
      *     ) qemu_arch="$arch" ;;
    esac

    local qemu_user_static=$(sudo grep -l -F -e "interpreter /usr/bin/qemu-$qemu_arch-"   \
                                             -r -- /proc/sys/fs/binfmt_misc 2>/dev/null | \
                                  xargs -r sudo grep -xF 'enabled'                        )
    if [[ -n "$qemu_user_static" ]]; then
      msg "found qemu-user-static for %s" "$arch"
    else
      error "missing qemu-user-static for %s" "$arch"
      return "$EXIT_FAILURE"
    fi

    sudo mkdir -p "$workdir"/usr/bin
    sudo cp -v "/usr/bin/qemu-$qemu_arch-"* "$workdir"/usr/bin || return "$EXIT_FAILURE"
  fi

  # prepare pacstrap config
  local pacconf repos
  pacconf="$(mktemp -t pvm-pacconf-XXXXXXXXXX)" || return "$EXIT_FAILURE"
  repos=(libre core extra community pcr)
  (( $IsNonsystemd )) && repos=('nonsystemd' ${repos[@]})
  echo -e "[options]\nArchitecture = $arch" > "$pacconf"
  for repo in ${repos[@]};    do echo "[$repo]"                           >> "$pacconf";
      for mirror_n in {1..5}; do echo "Server = $Mirror/\$repo/os/\$arch" >> "$pacconf"; done;
  done

  # prepare package lists
  local kernels=(     ${Kernels[@]}                           )
  local pkgs=(        ${DEF_PKGS[@]} ${Kernels[@]} ${Pkgs[@]} )
  local pkgs_cached=( ${GUEST_CACHED_PKGS[@]}                 )
  case "$arch" in
    i686|x86_64) pkgs+=(grub)              ;;
    riscv64    )                           ;;
    *          ) pkgs+=(haveged net-tools) ;;
  esac
  ((   $IsNonsystemd )) &&                                              && pkgs+=(libelogind)
  (( ! $IsNonsystemd )) && [[ "${Hooks[@]}" =~ hook-ethernet-dhcp.sh ]] && pkgs+=(dhcpcd)

  # minimize package lists
  Kernels=() ; Pkgs=() ;
  for kernel in $(printf "%s\n" "${kernels[@]}" | sort -u) ; do Kernels+=($kernel) ; done ;
  for pkg    in $(printf "%s\n" "${pkgs[@]}"    | sort -u) ; do Pkgs+=($pkg)       ; done ;

  # pacstrap! :)
  msg "installing packages into the work chroot"
  sudo pacstrap -GMc -C "$pacconf" "$workdir" "${pkgs[@]}"        || return "$EXIT_FAILURE"
  sudo pacstrap -GM  -C "$pacconf" "$workdir" "${pkgs_cached[@]}" || return "$EXIT_FAILURE"

  # create an fstab
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
  echo "/etc/hostname: "    ; echo $hostname    | sudo tee "$workdir"/etc/hostname    ;
  echo "/etc/locale.conf: " ; echo "LANG=$lang" | sudo tee "$workdir"/etc/locale.conf ;
  sudo sed -i "s/#${lang}/${lang}/" "$workdir"/etc/locale.gen

  # install a boot loader
  msg "installing boot loader"
  case "$arch" in
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
    armv7h)
      echo "(armv7h has no boot loader)"
      ;;
    riscv64)
      # FIXME: for the time being, use fedora bbl to boot
      warning "(riscv64 requires a blob - downloading it now)"
      local bbl_url=https://fedorapeople.org/groups/risc-v/disk-images/bbl
      sudo wget $bbl_url -O "$workdir"/boot/bbl || return "$EXIT_FAILURE"
      ;;
    ppc64le)
      # FIXME: what about ppc64le?
      echo "(ppc64le has no boot loader)"
      ;;
  esac

  # regenerate the initcpio(s), skipping the autodetect hook
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
  sudo mkdir -p "$workdir/root/hooks"
  [ "${#Hooks[@]}" -eq 0 ] || sudo cp -v "${Hooks[@]}" "$workdir"/root/hooks/
  (( $IsNonsystemd )) && sudo rm "$workdir"/root/hooks/hook-ethernet-dhcp.sh # systemd-only hook

  # create a master hook script
  local hooks_success_msg="[hooks.sh] pre-init hooks successful"
  echo "hooks.sh:"
  sudo tee "$workdir"/root/hooks.sh << EOF
#!/bin/bash
echo "[hooks.sh] boot successful - configuring ...."

systemctl disable preinit.service

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
rm -rf /root/hooks
rm -f /root/hooks.sh
rm -f /usr/lib/systemd/system/preinit.service
rm -f /var/cache/pacman/pkg/*
rm -f /root/.bash_history

# report success :)
echo "$hooks_success_msg"
EOF

  # create a pre-init service to run the hooks
  echo "preinit.service:"
  sudo tee "$workdir"/usr/lib/systemd/system/preinit.service << 'EOF'
[Unit]
Description=Oneshot VM Preinit
After=multi-user.target

[Service]
StandardOutput=journal+console
StandardError=journal+console
ExecStart=/usr/bin/bash /root/hooks.sh
Type=oneshot
ExecStopPost=echo "powering off"
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
  pvm_cleanup

  # boot the machine to run the pre-init hooks
  local pvmboot_cmd
  local qemu_flags=(-no-reboot)
  if [ -f "$THIS_DIR/pvmboot.sh" ]; then # in-tree
    pvmboot_cmd=("$THIS_DIR/pvmboot.sh")
  elif type -p pvmboot &>/dev/null; then # installed
    pvmboot_cmd=('pvmboot')
  else
    error "pvmboot not available -- unable to run hooks"
    return "$EXIT_FAILURE"
  fi
  pvmboot_cmd+=("$imagefile" "${qemu_flags[@]}")
  exec 3>&1
  msg "booting the machine to run the pre-init hooks"
  DISPLAY='' "${pvmboot_cmd[@]}" | tee /dev/fd/3 | grep -q -F "$hooks_success_msg"
  local res=$?
  exec 3>&-
  ! (( $res )) || error "%s: failed to complete preinit hooks" "$imagefile"

  return $res
}

pvm_cleanup() {
  trap - INT TERM RETURN

  msg "cleaning up"
  [ -n "$pacconf" ] && rm -f "$pacconf"
  unset pacconf
  if [ -n "$workdir" ]; then
    sudo rm -f "$workdir"/usr/bin/qemu-*
    sudo umount -R "$workdir" 2> /dev/null
    rmdir "$workdir"
  fi
  unset workdir
  [ -n "$loopdev" ] && sudo losetup -d "$loopdev"
  unset loopdev
}

main() {
  if [ "$(id -u)" -eq 0 ]; then
    error "This program must be run as a regular user"
    exit "$EXIT_NOPERMISSION"
  fi

  # parse options
  while getopts 'hH:k:M:Op:s:S:' arg; do
    case "$arg" in
      h) usage; return "$EXIT_SUCCESS";;
      H) if [ -e   "$THIS_DIR/hooks/hook-$OPTARG.sh" ]; then                  # in-tree
           Hooks+=("$THIS_DIR/hooks/hook-$OPTARG.sh")
         elif [ -e "/usr/lib/libretools/pvmbootstrap/hook-$OPTARG.sh" ]; then # installed
           Hooks+=("/usr/lib/libretools/pvmbootstrap/hook-$OPTARG.sh")
         elif [ -e "$OPTARG" ]; then
           Hooks+=("$OPTARG")
         else
           warning "%s: hook does not exist" "$OPTARG"
         fi ;;
      k) Kernels+=($OPTARG);;
      M) Mirror="$OPTARG";;
      O) IsNonsystemd=0;; # TODO:
      p) Pkgs+=($OPTARG);;
      s) ImgSizeGb="$( sed 's|[^0-9]||g' <<<$OPTARG)";;
      S) SwapSizeMb="$(sed 's|[^0-9]||g' <<<$OPTARG)";;
      *) error "invalid argument: %s\n" "$arg"; usage >&2; exit "$EXIT_INVALIDARGUMENT";;
    esac
  done

  local shiftlen=$(( OPTIND - 1 ))
  shift $shiftlen
  local imagefile="$1"
  local arch="$2"
  local has_params=$( (( $# == 2                                           )) && echo 1 || echo 0 )
  local has_space=$(  (( ($ImgSizeGb*1000) >= ($MIN_GB*1000) + $SwapSizeMb )) && echo 1 || echo 0 )
  HasSwap=$(          (( $SwapSizeMb > 0                                   )) && echo 1 || echo 0 )
  (( ! $has_params )) && error "insufficient arguments" && usage >&2 && exit "$EXIT_INVALIDARGUMENT"
  (( ! $has_space  )) && error "image size too small"   && usage >&2 && exit "$EXIT_INVALIDARGUMENT"

  # determine if the target arch is supported
  case "$arch" in
    i686|x86_64|armv7h)                                           ;;
    ppc64le|riscv64   ) warning "arch %s is experimental" "$arch" ;;
    *                 ) error "arch %s is unsupported" "$arch"
                        exit "$EXIT_INVALIDARGUMENT"              ;;
  esac

  # determine whether the target output file already exists
  if [ -e "$imagefile" ]; then
    warning "%s: file exists. Continue? [y/N]" "$imagefile"
    read -p " " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
      exit "$EXIT_FAILURE"
    fi
    rm -f "$imagefile" || exit
  fi

  # create the virtual machine
  if ! pvm_bootstrap; then
    error "bootstrap failed for image: %s" "$imagefile"
    exit "$EXIT_FAILURE"
  fi

  msg "bootstrap complete for image: %s" "$imagefile"
}

main "$@"
