#!/bin/bash
###############################################################################
#     parabola-vmbootstrap -- create and start parabola virtual machines      #
#                                                                             #
#     Copyright (C) 2017 - 2019  Andreas Grapentin                            #
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


readonly DEF_MIRROR="https://repo.parabola.nu/\$repo/os/\$arch"
readonly DEF_IMG_GB=64

Hooks=()
Mirror=$DEF_MIRROR
ImgSizeGb=$DEF_IMG_GB
Init=''


usage() {
  print "USAGE:"
  print "  pvmbootstrap [-h] [-H <hook>] [-M <mirror>] [-O] [-s <img_size>] <img> <arch>"
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
  echo  "  -M <mirror>     Specify a different mirror from which to fetch packages"
  echo  "                  (default: $DEF_MIRROR)"
  echo  "  -O              Bootstrap an openrc system instead of a systemd one"
  echo  "  -s <img_size>   Set the size (in GB) of the VM image (minimum: $MIN_GB, default: $DEF_IMG_GB)"
  echo
  echo  "Pre-defined hooks:"
  echo  "  ethernet-dhcp:  Configure and enable an ethernet device in the virtual"
  echo  "                  machine, using openresolv, dhcpcd, and systemd-networkd"
  echo
  echo  "This script is part of parabola-vmbootstrap. source code available at:"
  echo  " <https://git.parabola.nu/~oaken-source/parabola-vmbootstrap.git>"
}

pvm_native_arch() {
  local arch=$( [[ "$1" =~ arm.* ]] && echo 'armv7l' || echo "$1" )

  setarch "$arch" /bin/true 2>/dev/null || return "$EXIT_FAILURE"
}

pvm_bootstrap() {
  msg "starting creation of %s image: %s" "$arch" "$file"

  # create the raw image file
  qemu-img create -f raw "$file" "${ImgSizeGb}G" || return "$EXIT_FAILURE"

  # prepare for cleanup
  trap 'pvm_cleanup' INT TERM RETURN

  # mount the virtual disk
  local workdir loopdev
  workdir="$(mktemp -d -t pvm-rootfs-XXXXXXXXXX)"  || return "$EXIT_FAILURE"
  loopdev="$(sudo losetup -fLP --show "$file")"    || return "$EXIT_FAILURE"
  sudo dd if=/dev/zero of="$loopdev" bs=1M count=8 || return "$EXIT_FAILURE"

  # partition
  msg "partitioning blank image"
  case "$arch" in
    i686|x86_64)
      sudo parted -s "$loopdev" \
        mklabel gpt \
        mkpart primary 1MiB 2Mib \
        set 1 bios_grub on \
        mkpart primary ext2 2MiB 514MiB \
        mkpart primary linux-swap 514MiB 4610MiB \
        mkpart primary ext4 4610MiB 100% || return "$EXIT_FAILURE" ;;
    armv7h)
      sudo parted -s "$loopdev" \
        mklabel gpt \
        mkpart ESP fat32 1MiB 513MiB \
        set 1 boot on \
        mkpart primary linux-swap 513MiB 4609MiB \
        mkpart primary ext4 4609MiB 100% || return "$EXIT_FAILURE" ;;
    ppc64le|riscv64)
      sudo parted -s "$loopdev" \
        mklabel gpt \
        mkpart primary ext2 1MiB 513MiB \
        set 1 boot on \
        mkpart primary linux-swap 513MiB 4609MiB \
        mkpart primary ext4 4609MiB 100% || return "$EXIT_FAILURE" ;;
  esac

  # refresh partition data
  sudo partprobe "$loopdev"

  # make file systems
  local swapdev
  msg "creating target filesystems"
  case "$arch" in
    i686|x86_64)
      sudo mkfs.ext2 "$loopdev"p2 || return "$EXIT_FAILURE"
      sudo mkswap "$loopdev"p3    || return "$EXIT_FAILURE"
      sudo mkfs.ext4 "$loopdev"p4 || return "$EXIT_FAILURE"
      swapdev="$loopdev"p3 ;;
    armv7h)
      sudo mkfs.vfat -F 32 "$loopdev"p1 || return "$EXIT_FAILURE"
      sudo mkswap "$loopdev"p2          || return "$EXIT_FAILURE"
      sudo mkfs.ext4 "$loopdev"p3       || return "$EXIT_FAILURE"
      swapdev="$loopdev"p2 ;;
    ppc64le|riscv64)
      sudo mkfs.ext2 "$loopdev"p1 || return "$EXIT_FAILURE"
      sudo mkswap "$loopdev"p2    || return "$EXIT_FAILURE"
      sudo mkfs.ext4 "$loopdev"p3 || return "$EXIT_FAILURE"
      swapdev="$loopdev"p2 ;;
  esac

  # mount partitions
  msg "mounting target partitions"
  case "$arch" in
    i686|x86_64)
      sudo mount "$loopdev"p4 "$workdir"      || return "$EXIT_FAILURE"
      sudo mkdir -p "$workdir"/boot           || return "$EXIT_FAILURE"
      sudo mount "$loopdev"p2 "$workdir"/boot || return "$EXIT_FAILURE"
      ;;
    armv7h|ppc64le|riscv64)
      sudo mount "$loopdev"p3 "$workdir"      || return "$EXIT_FAILURE"
      sudo mkdir -p "$workdir"/boot           || return "$EXIT_FAILURE"
      sudo mount "$loopdev"p1 "$workdir"/boot || return "$EXIT_FAILURE"
      ;;
  esac

  # setup qemu-user-static, if necessary
  if ! pvm_native_arch "$arch"; then
    # target arch can't execute natively, pacstrap is going to need help by qemu
    local qemu_arch
    case "$arch" in
      armv7h) qemu_arch=arm ;;
      *) qemu_arch="$arch" ;;
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
  repos=('libre' 'core' 'extra' 'community' 'pcr')
  echo -e "[options]\nArchitecture = $arch\n\n" > "$pacconf"
  for repo in ${repos[@]}; do echo -e "[$repo]\nServer = $Mirror\n" >> "$pacconf"; done;

  # prepare lists of packages
  # FIXME: [nonsystemd] is in a transitional phase
  #        package name suffices such as '-opernrc' will be removed soon
  #        ideally, the install process will be identical for either systemd or openrc
  #          depending only on which repos are enabled
  local pkgs=("base$Init" "openssh$Init" openresolv ldns)
  case "$arch" in
    i686|x86_64) pkgs+=(grub) ;;
  esac
  case "$arch" in
    riscv64) ;;
    *) pkgs+=("haveged$Init" net-tools) ;;
  esac
  if [[ ! $Init ]]; then
    # FIXME: Add back in base packages that the switch from base group
    #          to base PKG yanked and be specific on OpenRC to avoid conflicts
    #        ideally, we will assign these to a new 'base-extras' group
    pkgs+=(cryptsetup device-mapper dhcpcd e2fsprogs inetutils           \
           jfsutils linux-libre logrotate lvm2 man-db mdadm nano         \
           netctl pacman-mirrorlist perl reiserfsprogs s-nail sysfsutils \
           texinfo usbutils vi xfsprogs your-freedom systemd-udev        \
           systemd-libudev                                               )
  else
    pkgs+=(systemd-libs-dummy)
  fi

  local pkg_guest_cache=(ca-certificates-utils)

  # pacstrap! :)
  msg "installing packages into the work chroot"
  sudo pacstrap -GMc -C "$pacconf" "$workdir" "${pkgs[@]}"            || return "$EXIT_FAILURE"
  sudo pacstrap -GM  -C "$pacconf" "$workdir" "${pkg_guest_cache[@]}" || return "$EXIT_FAILURE"

  # create an fstab
  msg "generating /etc/fstab"
  case "$arch" in
    riscv64) ;;
    *)
      sudo swapoff --all
      sudo swapon "$swapdev"
      genfstab -U "$workdir" | sudo tee "$workdir"/etc/fstab
      sudo swapoff "$swapdev"
      sudo swapon --all ;;
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

  # regenerate the initcpio, skipping the autodetect hook
  local kernel='linux-libre'
  local preset_file="$workdir"/etc/mkinitcpio.d/${kernel}.preset
  local default_options="default_options=\"-S autodetect\""
  msg "regenerating initcpio for kernel: '${kernel}'"
  sudo cp "$preset_file"{,.backup}                                 || return "$EXIT_FAILURE"
  echo "$default_options" | sudo tee -a "$preset_file" > /dev/null || return "$EXIT_FAILURE"
  sudo arch-chroot "$workdir" mkinitcpio -p ${kernel}              || return "$EXIT_FAILURE"
  sudo mv "$preset_file"{.backup,}                                 || return "$EXIT_FAILURE"

  # initialize the pacman keyring
  msg "initializing the pacman keyring"
  sudo arch-chroot "$workdir" pacman-key --init
  sudo arch-chroot "$workdir" pacman-key --populate archlinux archlinux32 archlinuxarm parabola

  # push hooks into the image
  msg "preparing hooks"
  sudo mkdir -p "$workdir/root/hooks"
  [ "${#Hooks[@]}" -eq 0 ] || sudo cp -v "${Hooks[@]}" "$workdir"/root/hooks/

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
mkinitcpio -p linux-libre

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
  if [ -f "./src/pvmboot.sh" ]; then
    pvmboot_cmd=(bash ./src/pvmboot.sh)
  elif type -p pvmboot &>/dev/null; then
    pvmboot_cmd=('pvmboot')
  else
    error "pvmboot not available -- unable to run hooks"
    return "$EXIT_FAILURE"
  fi
  pvmboot_cmd+=("$file" "${qemu_flags[@]}")
  exec 3>&1
  msg "booting the machine to run the pre-init hooks"
  DISPLAY='' "${pvmboot_cmd[@]}" | tee /dev/fd/3 | grep -q -F "$hooks_success_msg"
  local res=$?
  exec 3>&-
  ! (( $res )) || error "%s: failed to complete preinit hooks" "$file"

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
  while getopts 'hOs:M:H:' arg; do
    case "$arg" in
      h) usage; return "$EXIT_SUCCESS";;
      H) if [ -e "/usr/lib/libretools/pvmbootstrap/hook-$OPTARG.sh" ]; then
           hooks+=("/usr/lib/libretools/pvmbootstrap/hook-$OPTARG.sh")
         elif [ -e "./src/hooks/hook-$OPTARG.sh" ]; then
           hooks+=("./src/hooks/hook-$OPTARG.sh")
         elif [ -e "$OPTARG" ]; then
           Hooks+=("$OPTARG")
         else
           warning "%s: hook does not exist" "$OPTARG"
         fi ;;
      M) Mirror="$OPTARG";;
      O) Init="-openrc";;
      s) ImgSizeGb="$(sed 's|[^0-9]||g' <<<$OPTARG)";;
      *) error "invalid argument: %s\n" "$arg"; usage >&2; exit "$EXIT_INVALIDARGUMENT";;
    esac
  done

  local shiftlen=$(( OPTIND - 1 ))
  shift $shiftlen
  local file="$1"
  local arch="$2"
  local has_params=$( [ "$#" -eq 2               ] && echo 1 || echo 0 )
  local has_space=$(  [ "$ImgSizeGb" -ge $MIN_GB ] && echo 1 || echo 0 )
  (( ! $has_params )) && error "insufficient arguments" && usage >&2 && exit "$EXIT_INVALIDARGUMENT"
  (( ! $has_space  )) && error "image size too small"   && usage >&2 && exit "$EXIT_INVALIDARGUMENT"

  # determine if the target arch is supported
  case "$arch" in
    i686|x86_64|armv7h) ;;
    ppc64le|riscv64)
      warning "arch %s is experimental" "$arch";;
    *)
      error "arch %s is unsupported" "$arch"
      exit "$EXIT_INVALIDARGUMENT";;
  esac

  # determine whether the target output file already exists
  if [ -e "$file" ]; then
    warning "%s: file exists. Continue? [y/N]" "$file"
    read -p " " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
      exit "$EXIT_FAILURE"
    fi
    rm -f "$file" || exit
  fi

  # create the virtual machine
  if ! pvm_bootstrap; then
    error "bootstrap failed for image: %s" "$file"
    exit "$EXIT_FAILURE"
  fi

  msg "bootstrap complete for image: %s" "$file"
}

main "$@"
