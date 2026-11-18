#!/usr/bin/env bash
# Gentoo TUI installer — Debian Etch-inspired configuration frontend.
# This is a configuration wizard, not a complete disk partitioner/installer.
set -Eeuo pipefail
export LC_ALL=C

APP_NAME="Gentoo Setup"
TARGET="/mnt/gentoo"
GRUB_NAME="Gentoo Linux"
GRUB_LOGLEVEL="3"
GRUB_QUIET="yes"
GENTOO_MIRRORS="https://distfiles.gentoo.org"
SYNC_URI="https://github.com/gentoo/gentoo"
SYNC_TYPE="git"
MAKEOPTS="-j2"

need_root() {
    if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
        echo "Run this script as root: sudo $0" >&2
        exit 1
    fi
}

choose_tui() {
    if command -v whiptail >/dev/null 2>&1; then
        TUI=whiptail
    elif command -v dialog >/dev/null 2>&1; then
        TUI=dialog
    else
        echo "This installer needs whiptail or dialog."
        echo "Install one in the live environment, then run this script again."
        exit 1
    fi
}

msg() { "$TUI" --title "$APP_NAME" --msgbox "$1" 12 72; }
ask() {
    local prompt="$1" default="$2" result
    result=$("$TUI" --title "$APP_NAME" --inputbox "$prompt" 10 72 "$default" 3>&1 1>&2 2>&3) || return 1
    REPLY="$result"
}
menu() {
    "$TUI" --title "$APP_NAME" --menu "$1" 18 72 8 "${@:2}" 3>&1 1>&2 2>&3
}
yesno() { "$TUI" --title "$APP_NAME" --yesno "$1" 10 72; }

show_art() {
    clear
    cat <<'ART'
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
                                                          *=:...:*@
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
    echo
    echo "                 G E N T O O   L I N U X   S E T U P"
    echo "                       Debian Etch-style TUI"
    sleep 1
}

configure_target() {
    ask "Target root directory (must already be mounted):" "$TARGET" || return
    TARGET="$REPLY"
    [[ -n "$TARGET" && "$TARGET" == /* ]] || { msg "Target must be an absolute path."; return; }
    if [[ ! -d "$TARGET" ]]; then
        msg "Directory does not exist. Create/mount the target filesystem first."
        return
    fi
    if ! yesno "Use target directory:\n$TARGET\n\nThis wizard will write configuration files there. It will NOT format or partition disks."; then
        return
    fi
    mkdir -p "$TARGET/etc/portage"
    msg "Target set to:\n$TARGET"
}

grub_config() {
    ask "GRUB menu title / distribution name:" "$GRUB_NAME" || return
    GRUB_NAME="$REPLY"
    ask "Kernel loglevel (0-7; 3 is a quiet default):" "$GRUB_LOGLEVEL" || return
    [[ "$REPLY" =~ ^[0-7]$ ]] || { msg "Loglevel must be a number from 0 to 7."; return; }
    GRUB_LOGLEVEL="$REPLY"

    local q
    q=$(menu "Choose GRUB boot-message mode:" \
        quiet "Quiet boot (quiet)" \
        verbose "Verbose boot (show kernel messages)") || return
    [[ "$q" == quiet ]] && GRUB_QUIET=yes || GRUB_QUIET=no

    mkdir -p "$TARGET/etc/default"
    {
        printf '# Generated by %s\n' "$APP_NAME"
        printf 'GRUB_DISTRIBUTOR="%s"\n' "${GRUB_NAME//\"/}"
        if [[ "$GRUB_QUIET" == yes ]]; then
            printf 'GRUB_CMDLINE_LINUX_DEFAULT="quiet loglevel=%s"\n' "$GRUB_LOGLEVEL"
        else
            printf 'GRUB_CMDLINE_LINUX_DEFAULT="loglevel=%s"\n' "$GRUB_LOGLEVEL"
        fi
        printf 'GRUB_CMDLINE_LINUX=""\n'
    } > "$TARGET/etc/default/grub"

    msg "GRUB configuration written to:\n$TARGET/etc/default/grub\n\nAfter installing Gentoo, review it and run grub-mkconfig from the installed system."
}

portage_config() {
    local mirror sync_type
    mirror=$(menu "Select a distfiles mirror:" \
        official "https://distfiles.gentoo.org" \
        germany "https://ftp.fau.de/gentoo" \
        netherlands "https://mirror.leaseweb.com/gentoo" \
        japan "https://ftp.jaist.ac.jp/pub/Linux/Gentoo" \
        custom "Enter a custom mirror") || return

    case "$mirror" in
        official) GENTOO_MIRRORS="https://distfiles.gentoo.org" ;;
        germany) GENTOO_MIRRORS="https://ftp.fau.de/gentoo" ;;
        netherlands) GENTOO_MIRRORS="https://mirror.leaseweb.com/gentoo" ;;
        japan) GENTOO_MIRRORS="https://ftp.jaist.ac.jp/pub/Linux/Gentoo" ;;
        custom)
            ask "Custom distfiles mirror URL:" "$GENTOO_MIRRORS" || return
            GENTOO_MIRRORS="$REPLY"
            ;;
    esac

    sync_type=$(menu "Choose Portage repository sync method:" \
        git "Git (recommended)" \
        webrsync "webrsync (snapshot)") || return
    if [[ "$sync_type" == git ]]; then
        SYNC_TYPE=git
        SYNC_URI="https://github.com/gentoo/gentoo"
    else
        SYNC_TYPE=webrsync
        SYNC_URI=""
    fi

    ask "MAKEOPTS (parallel build jobs; e.g. -j2):" "$MAKEOPTS" || return
    MAKEOPTS="$REPLY"

    mkdir -p "$TARGET/etc/portage/repos.conf"
    cat > "$TARGET/etc/portage/make.conf" <<EOF
# Generated by $APP_NAME
COMMON_FLAGS="-O2 -pipe"
CFLAGS="\${COMMON_FLAGS}"
CXXFLAGS="\${COMMON_FLAGS}"
MAKEOPTS="$MAKEOPTS"
GENTOO_MIRRORS="$GENTOO_MIRRORS"
EOF

    if [[ "$SYNC_TYPE" == git ]]; then
        cat > "$TARGET/etc/portage/repos.conf/gentoo.conf" <<EOF
[DEFAULT]
main-repo = gentoo

[gentoo]
location = /var/db/repos/gentoo
sync-type = git
sync-uri = $SYNC_URI
auto-sync = yes
EOF
    else
        cat > "$TARGET/etc/portage/repos.conf/gentoo.conf" <<'EOF'
[DEFAULT]
main-repo = gentoo

[gentoo]
location = /var/db/repos/gentoo
sync-type = webrsync
auto-sync = yes
EOF
    fi

    msg "Portage configuration written:\n- $TARGET/etc/portage/make.conf\n- $TARGET/etc/portage/repos.conf/gentoo.conf\n\nReview MAKEOPTS and mirror reachability before syncing."
}

summary() {
    local text
    text="Target:       $TARGET\nGRUB title:   $GRUB_NAME\nGRUB loglevel:$GRUB_LOGLEVEL\nBoot mode:    $GRUB_QUIET\nMirror:       $GENTOO_MIRRORS\nSync:         $SYNC_TYPE\nMAKEOPTS:     $MAKEOPTS\n\nThis frontend currently configures GRUB and Portage only."
    msg "$text"
}

main_menu() {
    while true; do
        local choice
        choice=$(menu "Select an installation stage:" \
            target "1. Target directory" \
            grub "2. GRUB Config" \
            portage "3. Portage Config" \
            summary "4. Review configuration" \
            quit "Exit") || break
        case "$choice" in
            target) configure_target ;;
            grub) grub_config ;;
            portage) portage_config ;;
            summary) summary ;;
            quit) break ;;
        esac
    done
}

need_root
choose_tui
show_art
msg "Welcome to Gentoo Setup!\n\nA classic text-mode configuration frontend inspired by the Debian Etch installer.\n\nThis version does not partition, format, or install the operating system. Mount your target root filesystem first."
main_menu
clear
echo "$APP_NAME closed."
