#!/usr/bin/env bash
# Gentoo Etch Installer — interactive AMD64 installer
# UEFI/BIOS, GPT, ext4/Btrfs/XFS, OpenRC/systemd Stage3, Portage, chroot setup.
# Disk partitioning is destructive and requires typing the selected device path.
set -Eeuo pipefail
export LC_ALL=C
APP='Gentoo Etch Installer'
VER='0.3'
TARGET=/mnt/gentoo
DISK=''
BOOT_MODE=''
ROOTFS=ext4
INIT=openrc
MIRROR=https://distfiles.gentoo.org
MAKEOPTS='-j2'
HOSTNAME=gentoo
GRUB_TITLE='Gentoo Linux'
LOGLEVEL=3
QUIET=yes
TIMEZONE=UTC
LOCALE=en_US.UTF-8
KEYMAP=us
ROOT_PASSWORD=''
NEW_USER=''
USER_PASSWORD=''
SWAP=yes
SWAP_SIZE=2G
STAGE3_FILE=''
STAGE3_URL=''
NETWORK=yes
SSH=no
INSTALL_KERNEL=yes
INSTALL_GRUB=yes
INSTALL_FIRMWARE=yes
TUI=''
MOUNTS=()

fail(){ echo "ERROR: $*" >&2; exit 1; }
have(){ command -v "$1" >/dev/null 2>&1; }
cleanup(){ local i; for ((i=${#MOUNTS[@]}-1;i>=0;i--)); do umount -R "${MOUNTS[i]}" 2>/dev/null || true; done; }
trap cleanup EXIT
need_root(){ [[ $EUID -eq 0 ]] || fail "Run as root: sudo $0"; }
init_tui(){ if have whiptail; then TUI=whiptail; elif have dialog; then TUI=dialog; else fail 'Install whiptail or dialog in the live environment.'; fi; }
msg(){ "$TUI" --title "$APP $VER" --msgbox "$1" 14 76; }
yesno(){ "$TUI" --title "$APP $VER" --yesno "$1" 12 76; }
menu(){ "$TUI" --title "$APP $VER" --menu "$1" 20 78 12 "${@:2}" 3>&1 1>&2 2>&3; }
ask(){ local v; v=$("$TUI" --title "$APP $VER" --inputbox "$1" 10 76 "${2:-}" 3>&1 1>&2 2>&3) || return 1; REPLY=$v; }
secret(){ local v; v=$("$TUI" --title "$APP $VER" --passwordbox "$1" 10 76 3>&1 1>&2 2>&3) || return 1; REPLY=$v; }
detect_boot(){ [[ -d /sys/firmware/efi ]] && BOOT_MODE=uefi || BOOT_MODE=bios; }

art(){ clear; cat <<'ART'
                                                              @
                                                             @*@
                                                             *-#
                                                            @=.+
                                                            #-.-#
                                                            +...+
                                                           @-...-%
                                                           *:...:*
                                                          @=.....-@
                                                          #:.....:*
                                                          +.......=@
                                                         @-.......=%
                                                          *=:...:@
                                                           @*:.:#
                                                             *:+
                                                             #-*
                                                             #-*
                                                             *-*
                                                             *:*
                                                             *:*
                                                             *:*
                                                             *:+
                                                             *.+
                                                             +.+
                                                             +.=@
                                                            @+.=@
                                                           @*-.-%
                                                          #+:...-%
                                                        @*-...-..-*@
                                                       *=:..-=-=-..=#@
                                                     *+:..:=-..:-=:.:+%
                                                     *..:==:.....:=-:.-#
                                                     +.:=:.........:=::*
                                                     +.--...........--:*
                                                     +.--...........--:*
                                                     +.--...........--:*
                                                     +.--...........--:*
                                                     +.--...........--:*
                                                     *.--...........--:*
                                                    *:.--...........--:*
                                                  @*:..:=-.........:=:.-%
                                                 #=...:..-=-.....:=-:.:.:*@
                                                *-...-+-..:-=:..-=:.:=+-..-*@
                                              @*:..-+# #*-..:=-=-.:-*@ #+-.:=#
                                      *+%    %=..:+#     #+-..-:.-*%     #+-.-*%    #**
                                     #:.-*@@#-.:=*@        *+:.-+#         #+-:=*@@%-.-*
                                    %-...:-=::-*@            *+*             #*-:-=-...-%
                                    +.......-*@                                #+.......+
                                   *:......:%                                   %-......:*
                                  %-.......-@                                   @=.......-#
                                 @=........-@                                   @-........=@
                                 *:........-@                                   %-.........+
                                #-....::--=+@                                   %+=--::....:*
                               @=--==++**#@@                                     @@#**++==---%
                               #**#@@                                                    @%**#
ART
 echo; echo '                 G E N T O O   L I N U X   S E T U P'; sleep 1; }

select_disk(){
 local -a opts=(); local dev size model type confirm
 while read -r dev size type; do [[ $type == disk ]] && opts+=("$dev" "$size"); done < <(lsblk -dpno NAME,SIZE,TYPE)
 ((${#opts[@]})) || { msg 'No disks detected.'; return 1; }
 DISK=$(menu 'Select the disk to erase completely:' "${opts[@]}") || return 1
 [[ -b $DISK ]] || { msg 'Not a block device.'; return 1; }
 if lsblk -nrpo MOUNTPOINT "$DISK" | grep -qE '^/'; then msg 'A partition on this disk is mounted. Unmount it first.'; return 1; fi
 ask "ALL DATA ON $DISK WILL BE ERASED. Type $DISK to confirm:" '' || return 1
 confirm=$REPLY; [[ $confirm == "$DISK" ]] || { msg 'Confirmation mismatch; disk unchanged.'; return 1; }
}
partition_disk(){
 have parted && have partprobe && have wipefs || fail 'Install parted, util-linux and e2fsprogs in the live environment.'
 have mkswap || fail 'Install util-linux (mkswap).'; have mkfs.fat || { [[ $(detect_boot; echo $BOOT_MODE) == bios ]] || fail 'Install dosfstools (mkfs.fat).'; }
 case ${ROOTFS:-ext4} in ext4) have mkfs.ext4 || fail 'Install e2fsprogs.';; btrfs) have mkfs.btrfs || fail 'Install btrfs-progs.';; xfs) have mkfs.xfs || fail 'Install xfsprogs.';; esac
 select_disk || return
 detect_boot
 local swapchoice fchoice p1 p2 p3 swappart='' rootpart bootpart=''
 swapchoice=$(menu 'Create swap partition?' yes Yes no No) || return; SWAP=$swapchoice
 if [[ $SWAP == yes ]]; then ask 'Swap size (e.g. 2G):' "$SWAP_SIZE" || return; SWAP_SIZE=$REPLY; [[ $SWAP_SIZE =~ ^[1-9][0-9]*[MG]$ ]] || { msg 'Invalid size. Use e.g. 2G.'; return; }; fi
 fchoice=$(menu 'Root filesystem:' ext4 ext4 btrfs Btrfs xfs XFS) || return; ROOTFS=$fchoice
 case $ROOTFS in ext4) have mkfs.ext4 || fail 'Install e2fsprogs.';; btrfs) have mkfs.btrfs || fail 'Install btrfs-progs.';; xfs) have mkfs.xfs || fail 'Install xfsprogs.';; esac
 if [[ $BOOT_MODE == uefi ]]; then have mkfs.fat || fail 'Install dosfstools.'; fi
 if [[ $SWAP == yes ]]; then have mkswap || fail 'Install util-linux.'; fi
 if ! yesno "FINAL WARNING: wipe and repartition $DISK?\nBoot mode: $BOOT_MODE\nFilesystem: $ROOTFS\nSwap: $SWAP"; then return; fi
 local base=${DISK##*/}; if [[ $base =~ [0-9]$ ]]; then p1="${DISK}p1"; p2="${DISK}p2"; p3="${DISK}p3"; else p1="${DISK}1"; p2="${DISK}2"; p3="${DISK}3"; fi
 local start_mib end_mib swap_mib
 if [[ $BOOT_MODE == uefi ]]; then start_mib=1025; else start_mib=3; fi
 if [[ $SWAP == yes ]]; then
   if [[ $SWAP_SIZE == *G ]]; then swap_mib=$(( ${SWAP_SIZE%G} * 1024 )); else swap_mib=${SWAP_SIZE%M}; fi
   end_mib=$((start_mib + swap_mib))
 fi
 wipefs -af "$DISK"; parted -s "$DISK" mklabel gpt
 if [[ $BOOT_MODE == uefi ]]; then
   parted -s "$DISK" mkpart ESP fat32 1MiB 1025MiB; parted -s "$DISK" set 1 esp on; bootpart=$p1
 else
   parted -s "$DISK" mkpart bios_grub 1MiB 3MiB; parted -s "$DISK" set 1 bios_grub on
 fi
 if [[ $SWAP == yes ]]; then
   parted -s "$DISK" mkpart primary linux-swap "${start_mib}MiB" "${end_mib}MiB"
   if [[ $BOOT_MODE == uefi ]]; then swappart=$p2; rootpart=$p3; else swappart=$p2; rootpart=$p3; fi
   parted -s "$DISK" mkpart primary "${end_mib}MiB" 100%
 else
   parted -s "$DISK" mkpart primary "${start_mib}MiB" 100%
   if [[ $BOOT_MODE == uefi ]]; then rootpart=$p2; else rootpart=$p2; fi
 fi
 partprobe "$DISK"; udevadm settle 2>/dev/null || true; sleep 2
 [[ -b $rootpart ]] || { msg "Could not detect root partition $rootpart. Disk layout not mounted."; return 1; }
 if [[ $BOOT_MODE == uefi ]]; then mkfs.fat -F32 "$bootpart"; fi
 if [[ $SWAP == yes ]]; then mkswap "$swappart"; swapon "$swappart" || true; fi
 case $ROOTFS in ext4) mkfs.ext4 -F "$rootpart";; btrfs) have mkfs.btrfs || fail 'Install btrfs-progs.'; mkfs.btrfs -f "$rootpart";; xfs) have mkfs.xfs || fail 'Install xfsprogs.'; mkfs.xfs -f "$rootpart";; esac
 mkdir -p "$TARGET"
 if [[ $ROOTFS == btrfs ]]; then
   mount "$rootpart" "$TARGET"; btrfs subvolume create "$TARGET/@"; btrfs subvolume create "$TARGET/@home"; umount "$TARGET"
   mount -o noatime,compress=zstd,subvol=@ "$rootpart" "$TARGET"; mkdir -p "$TARGET/boot" "$TARGET/home"
   mount -o noatime,compress=zstd,subvol=@home "$rootpart" "$TARGET/home"
 else mount "$rootpart" "$TARGET"; mkdir -p "$TARGET/boot"; fi
 MOUNTS+=("$TARGET")
 if [[ $BOOT_MODE == uefi ]]; then mount "$bootpart" "$TARGET/boot"; MOUNTS+=("$TARGET/boot"); fi
 mkdir -p "$TARGET/etc"
 local ru bu su; ru=$(blkid -s UUID -o value "$rootpart")
 if [[ $ROOTFS == btrfs ]]; then rootopts='defaults,noatime,compress=zstd,subvol=@'; else rootopts='defaults,noatime'; fi
 printf 'UUID=%s\t/\t%s\t%s\t0 1\n' "$ru" "$ROOTFS" "$rootopts" > "$TARGET/etc/fstab"
 if [[ $ROOTFS == btrfs ]]; then printf 'UUID=%s\t/home\tbtrfs\tdefaults,noatime,compress=zstd,subvol=@home\t0 2\n' "$ru" >> "$TARGET/etc/fstab"; fi
 if [[ $BOOT_MODE == uefi ]]; then bu=$(blkid -s UUID -o value "$bootpart"); printf 'UUID=%s\t/boot\tvfat\tumask=0077\t0 2\n' "$bu" >> "$TARGET/etc/fstab"; fi
 if [[ $SWAP == yes ]]; then su=$(blkid -s UUID -o value "$swappart"); printf 'UUID=%s\tnone\tswap\tsw\t0 0\n' "$su" >> "$TARGET/etc/fstab"; fi
 msg "Disk prepared. Root: $rootpart\nBoot mode: $BOOT_MODE\nFilesystem: $ROOTFS\nTarget: $TARGET\nReview $TARGET/etc/fstab."
}

stage3(){
 local variant channel manifest rel
 variant=$(menu 'Choose official AMD64 Stage3:' openrc 'OpenRC (standard)' systemd 'systemd (standard)') || return; INIT=$variant
 channel="current-stage3-amd64-$variant"; manifest="/tmp/latest-stage3-$variant.txt"
 curl -fL --retry 3 "https://distfiles.gentoo.org/releases/amd64/autobuilds/$channel/latest-stage3-amd64-$variant.txt" -o "$manifest" || { msg 'Cannot fetch Stage3 manifest. Check network.'; return 1; }
 rel=$(awk '!/^#/ && /stage3-amd64-.*\.tar\.(xz|zst)$/ {print $1; exit}' "$manifest")
 [[ -n $rel ]] || { msg 'No Stage3 archive found in manifest.'; return 1; }
 STAGE3_URL="https://distfiles.gentoo.org/releases/amd64/autobuilds/$rel"; STAGE3_FILE="/tmp/${rel##*/}"
 msg "Selected archive:\n$rel\n\nDownloading official Gentoo Stage3."
 wget -c "$STAGE3_URL" -O "$STAGE3_FILE" || { msg 'Stage3 download failed.'; return 1; }
 [[ -d $TARGET ]] || mkdir -p "$TARGET"
 if mountpoint -q "$TARGET"; then :; elif [[ -n $(ls -A "$TARGET") ]]; then msg 'Target is not mounted and is not empty. Refusing to extract.'; return 1; fi
 tar xpf "$STAGE3_FILE" --xattrs-include='*.*' --numeric-owner -C "$TARGET" || { msg 'Stage3 extraction failed.'; return 1; }
 msg "Stage3 extracted to $TARGET\nInit: $INIT"
}

portage_config(){
 local m; m=$(menu 'Distfiles mirror:' official 'Official Gentoo' germany 'FAU Germany' custom 'Custom URL') || return
 case $m in official) MIRROR=https://distfiles.gentoo.org;; germany) MIRROR=https://ftp.fau.de/gentoo;; custom) ask 'Mirror URL:' "$MIRROR" || return; MIRROR=$REPLY;; esac
 ask 'MAKEOPTS (e.g. -j4):' "$MAKEOPTS" || return; MAKEOPTS=$REPLY
 mkdir -p "$TARGET/etc/portage/repos.conf"
 cat > "$TARGET/etc/portage/make.conf" <<EOF2
# Generated by $APP $VER
COMMON_FLAGS="-O2 -pipe"
CFLAGS="\${COMMON_FLAGS}"
CXXFLAGS="\${COMMON_FLAGS}"
MAKEOPTS="$MAKEOPTS"
GENTOO_MIRRORS="$MIRROR"
EOF2
 cat > "$TARGET/etc/portage/repos.conf/gentoo.conf" <<'EOF2'
[DEFAULT]
main-repo = gentoo
[gentoo]
location = /var/db/repos/gentoo
sync-type = git
sync-uri = https://github.com/gentoo/gentoo
auto-sync = yes
EOF2
 msg 'Portage configuration written.'
}

system_config(){
 ask 'Hostname:' "$HOSTNAME" || return; HOSTNAME=$REPLY
 ask 'Timezone (e.g. Europe/Berlin):' "$TIMEZONE" || return; TIMEZONE=$REPLY
 ask 'Locale (e.g. en_US.UTF-8):' "$LOCALE" || return; LOCALE=$REPLY
 ask 'Console keymap:' "$KEYMAP" || return; KEYMAP=$REPLY
 secret 'Set root password:' || return; ROOT_PASSWORD=$REPLY; [[ -n $ROOT_PASSWORD ]] || { msg 'Root password cannot be empty.'; return; }
 ask 'Create regular user (blank to skip):' "$NEW_USER" || return; NEW_USER=$REPLY
 if [[ -n $NEW_USER ]]; then [[ $NEW_USER =~ ^[a-z_][a-z0-9_-]*$ ]] || { msg 'Invalid username.'; return; }; secret "Password for $NEW_USER:" || return; USER_PASSWORD=$REPLY; [[ -n $USER_PASSWORD ]] || { msg 'User password cannot be empty.'; return; }; fi
 mkdir -p "$TARGET/etc"; printf '%s\n' "$HOSTNAME" > "$TARGET/etc/hostname"
 cat > "$TARGET/etc/hosts" <<EOF2
127.0.0.1 localhost
::1 localhost
127.0.1.1 $HOSTNAME.localdomain $HOSTNAME
EOF2
 mkdir -p "$TARGET/etc/portage"; printf '%s UTF-8\n' "$LOCALE" > "$TARGET/etc/locale.gen"; printf 'KEYMAP=%s\n' "$KEYMAP" > "$TARGET/etc/vconsole.conf"
 msg 'System settings saved. Passwords are applied during chroot setup.'
}

grub_config(){
 ask 'GRUB menu title / distributor name:' "$GRUB_TITLE" || return; GRUB_TITLE=$REPLY
 ask 'Kernel loglevel (0-7):' "$LOGLEVEL" || return; LOGLEVEL=$REPLY
 [[ $LOGLEVEL =~ ^[0-7]$ ]] || { msg 'Loglevel must be 0 through 7.'; return; }
 local q; q=$(menu 'Boot messages:' quiet 'Quiet boot' verbose 'Verbose boot') || return
 [[ $q == quiet ]] && QUIET=yes || QUIET=no
 mkdir -p "$TARGET/etc/default"
 if [[ $QUIET == yes ]]; then
   printf 'GRUB_DISTRIBUTOR="%s"\nGRUB_CMDLINE_LINUX_DEFAULT="quiet loglevel=%s"\nGRUB_CMDLINE_LINUX=""\n' "${GRUB_TITLE//\"/}" "$LOGLEVEL" > "$TARGET/etc/default/grub"
 else
   printf 'GRUB_DISTRIBUTOR="%s"\nGRUB_CMDLINE_LINUX_DEFAULT="loglevel=%s"\nGRUB_CMDLINE_LINUX=""\n' "${GRUB_TITLE//\"/}" "$LOGLEVEL" > "$TARGET/etc/default/grub"
 fi
 msg 'GRUB settings saved to /etc/default/grub.'
}

install_chroot(){
 [[ -f $TARGET/etc/gentoo-release && -f $TARGET/etc/portage/make.conf ]] || { msg 'Extract Stage3 and configure Portage first.'; return 1; }
 [[ -n $ROOT_PASSWORD ]] || { msg 'Configure system settings and root password first.'; return 1; }
 if [[ ! -f $TARGET/etc/default/grub ]]; then mkdir -p $TARGET/etc/default; printf 'GRUB_DISTRIBUTOR=\"%s\"\nGRUB_CMDLINE_LINUX_DEFAULT=\"quiet loglevel=%s\"\nGRUB_CMDLINE_LINUX=\"\"\n' "$GRUB_TITLE" "$LOGLEVEL" > $TARGET/etc/default/grub; fi
 detect_boot
 mkdir -p "$TARGET"/{dev,proc,sys,run}
 mount --rbind /dev "$TARGET/dev"; mount --make-rslave "$TARGET/dev"; MOUNTS+=("$TARGET/dev")
 mount -t proc /proc "$TARGET/proc"; MOUNTS+=("$TARGET/proc")
 mount --rbind /sys "$TARGET/sys"; mount --make-rslave "$TARGET/sys"; MOUNTS+=("$TARGET/sys")
 mount --rbind /run "$TARGET/run"; mount --make-rslave "$TARGET/run"; MOUNTS+=("$TARGET/run")
 cp -L /etc/resolv.conf "$TARGET/etc/resolv.conf"
 local inside="$TARGET/root/etch-install-inside.sh"; mkdir -p "$TARGET/root"
 cat > "$inside" <<'CHROOT'
#!/usr/bin/env bash
set -Eeuo pipefail
source /etc/profile
emerge --sync
# Enable the selected locale.
locale-gen
eselect locale set "$LOCALE" 2>/dev/null || true
env-update; source /etc/profile
ln -snf "/usr/share/zoneinfo/$TIMEZONE" /etc/localtime
printf 'root:%s\n' "$ROOT_PASSWORD" | chpasswd
if [[ -n "$NEW_USER" ]]; then
 useradd -m -G wheel,audio,video,users -s /bin/bash "$NEW_USER" || true
 printf '%s:%s\n' "$NEW_USER" "$USER_PASSWORD" | chpasswd
fi
emerge --noreplace app-admin/sudo app-editors/nano sys-process/htop
if [[ "$INSTALL_FIRMWARE" == yes ]]; then emerge --noreplace sys-kernel/linux-firmware || true; fi
if [[ "$INSTALL_KERNEL" == yes ]]; then emerge --noreplace sys-kernel/gentoo-kernel-bin; fi
if [[ "$NETWORK" == yes ]]; then emerge --noreplace net-misc/networkmanager; fi
if [[ "$SSH" == yes ]]; then emerge --noreplace net-misc/openssh; fi
if [[ "$INIT" == openrc ]]; then
 [[ "$NETWORK" == yes ]] && rc-update add NetworkManager default || true
 [[ "$SSH" == yes ]] && rc-update add sshd default || true
else
 [[ "$NETWORK" == yes ]] && systemctl enable NetworkManager
 [[ "$SSH" == yes ]] && systemctl enable sshd
fi
if [[ "$NEW_USER" != '' ]]; then sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers; fi
if [[ "$INSTALL_GRUB" == yes ]]; then
 emerge --noreplace sys-boot/grub
 if [[ "$BOOT_MODE" == uefi ]]; then grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=Gentoo
 else grub-install "$DISK"; fi
 grub-mkconfig -o /boot/grub/grub.cfg
fi
echo 'Gentoo installation commands completed.'
CHROOT
 chmod 700 "$inside"
 if ! yesno 'Run Portage sync and package installation inside chroot now? This may take a long time and requires internet.'; then return; fi
 chroot "$TARGET" /usr/bin/env ROOT_PASSWORD="$ROOT_PASSWORD" NEW_USER="$NEW_USER" USER_PASSWORD="$USER_PASSWORD" INIT="$INIT" TIMEZONE="$TIMEZONE" LOCALE="$LOCALE" BOOT_MODE="$BOOT_MODE" DISK="$DISK" INSTALL_KERNEL="$INSTALL_KERNEL" INSTALL_GRUB="$INSTALL_GRUB" INSTALL_FIRMWARE="$INSTALL_FIRMWARE" NETWORK="$NETWORK" SSH="$SSH" /bin/bash /root/etch-install-inside.sh
 msg 'Chroot installation finished. Review errors and verify GRUB before rebooting.'
}

options(){ local x; x=$(menu 'Toggle optional installation components:' network "NetworkManager: $NETWORK" ssh "OpenSSH: $SSH" kernel "Kernel binary: $INSTALL_KERNEL" grub "GRUB: $INSTALL_GRUB" firmware "linux-firmware: $INSTALL_FIRMWARE" done 'Return') || return
 case $x in network) [[ $NETWORK == yes ]] && NETWORK=no || NETWORK=yes;; ssh) [[ $SSH == yes ]] && SSH=no || SSH=yes;; kernel) [[ $INSTALL_KERNEL == yes ]] && INSTALL_KERNEL=no || INSTALL_KERNEL=yes;; grub) [[ $INSTALL_GRUB == yes ]] && INSTALL_GRUB=no || INSTALL_GRUB=yes;; firmware) [[ $INSTALL_FIRMWARE == yes ]] && INSTALL_FIRMWARE=no || INSTALL_FIRMWARE=yes;; esac
}
summary(){ msg "Target: $TARGET\nDisk: ${DISK:-not selected}\nBoot: ${BOOT_MODE:-not detected}\nFilesystem: $ROOTFS\nStage3: ${STAGE3_FILE:-not downloaded}\nInit: $INIT\nMirror: $MIRROR\nHostname: $HOSTNAME\nTimezone: $TIMEZONE\nLocale: $LOCALE\nGRUB title: $GRUB_TITLE\nLoglevel: $LOGLEVEL\nQuiet: $QUIET\nUser: ${NEW_USER:-none}\nNetworkManager: $NETWORK\nSSH: $SSH\nKernel: $INSTALL_KERNEL\nGRUB: $INSTALL_GRUB"; }
main(){
 need_root; init_tui
 for x in lsblk blkid mount umount tar curl wget awk grep sed; do have "$x" || fail "Missing command: $x"; done
 detect_boot; art
 msg "Welcome to $APP $VER.\n\nAMD64 Gentoo installer with disk partitioning, Stage3 download, Portage setup and chroot package installation.\n\nWARNING: partitioning erases the selected disk. Use a live environment and back up important data. This installer cannot guarantee hardware-specific kernel support."
 while true; do
  local c; c=$(menu 'Installation stages:' disk '1. Disk partitioning (ERASES DISK)' stage3 '2. Stage3 selection / download' portage '3. Portage Config' system '4. Hostname / locale / users' grub '5. GRUB Config' options '6. Optional components' install '7. Install system in chroot' summary '8. Review settings' exit 'Exit') || break
  case $c in disk) partition_disk;; stage3) stage3;; portage) portage_config;; system) system_config;; grub) grub_config;; options) options;; install) install_chroot;; summary) summary;; exit) break;; esac
 done
 clear; echo "$APP closed. Do not reboot unless installation completed and boot setup was verified."
}
main "$@"
