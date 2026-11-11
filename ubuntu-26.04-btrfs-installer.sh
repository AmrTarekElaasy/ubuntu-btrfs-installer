#!/usr/bin/env bash
# ============================================================
# Ubuntu Btrfs Installer  (offline: copies the live system from /rofs)
#
#  - Layout : @ (root) + @home (user data) on Btrfs, separate ext4 /boot, EFI
#  - SAFETY : nothing is erased by accident.
#       * Mode 2 (free space)  : creates new partitions only, erases NOTHING.
#       * Mode 1 (reinstall)   : deletes only the subvolume @ (stubborn or not).
#                                @home is kept unless you type DELETE-HOME.
#                                EFI and /boot: default answer is FORMAT (you can say no).
#       * Mode 3 (manual)      : formats the partitions you name, and you
#                                must type each erased partition name to confirm.
#       * Mode 4 (wipe disk)   : ERASES THE WHOLE DISK, makes a new GPT and installs
#                                with the free-space method (new EFI + boot + root).
#                                You must type the disk name twice (when choosing the
#                                mode and again on the final install screen).
#  - CHECK FIRST: before anything is touched, the whole plan is validated
#    (tools, live image, space, partitions, internet if needed).
#  - TUI (whiptail): an archinstall-style main menu. Every item shows its
#    current value; arrows + Enter open it, Back/Esc returns. Nothing is
#    touched until you choose INSTALL, review the summary and confirm.
#  - PARTITIONS (modes 1 and 3): three INDEPENDENT pages - Root (Btrfs),
#    Boot, EFI. Fixing one page never redoes the others.
#  - MAIN MENU shows a short plan: which partitions, their size, and what
#    will be FORMATTED and what is kept.
#  - UI CUSTOMIZATION (yes/no page, default YES): dock at the bottom + auto-hide,
#    wallpapers, blue accent. Written as system-wide dconf defaults, so it works
#    from the installer (no user session needed) and needs no internet.
#  - DOCK: when the extras installed Discover, it replaces Ubuntu Software in the dock.
#  - NEVER LOSE PROGRESS: every execution step that fails stops IN PLACE.
#    You fix the problem (even from a shell opened by the installer) and
#    choose "retry"; finished work is not redone and your answers are kept.
# ============================================================
# This installer needs bash (arrays, [[ ]], process substitution). If it was started with
# another shell (sh / dash / "sudo dash script.sh"), restart it with bash right away.
# This check uses only syntax that every shell understands, so it must stay at the top.
if [ -z "${BASH_VERSION:-}" ]; then
    if command -v bash >/dev/null 2>&1; then exec bash "$0" "$@"; fi
    echo "This installer needs bash. Run it like this:  sudo bash $0" >&2
    exit 1
fi
set -Eeuo pipefail

SCRIPT_PATH=$(readlink -f "$0")
MP=/mnt/target
TOP=/mnt/btrfs-top
CHK=/mnt/inst-check
MAPPER=cryptroot
ROFS=${ROFS:-/rofs}
LOG_FILE=${LOG_FILE:-/var/log/ubuntu-btrfs-installer.log}
BTRFS_OPTS="noatime,compress=zstd:1"
ENV_FILE=/tmp/installer.env
STATE_FILE=/run/ubuntu-btrfs-installer.state
EFI_PARTTYPE="c12a7328-f81f-11d2-ba4b-00a0c93ec93b"
MIN_ROOT_BYTES=$((12 * 1024 * 1024 * 1024))
# Sizes (MiB) used when EFI / boot must be created automatically in free space.
MIN_EFI_MIB=300;  GOOD_EFI_MIB=512
MIN_BOOT_MIB=1024; GOOD_BOOT_MIB=2048
ALIGN_SLACK_MIB=4
# Sanity ceilings for EXISTING partitions chosen as EFI or /boot.
MAX_EFI_MIB=2048     # 2 GiB
MAX_BOOT_MIB=5120    # 5 GiB
# Minimums for EXISTING partitions chosen as EFI or /boot.
MIN_EXIST_BOOT_MIB=400
TTY_DEV=${TTY_DEV:-/dev/tty}      # where the TUI is drawn (the log never sees it)
WT_TITLE="Ubuntu Btrfs Installer"
NL=$'\n'

C_RST=$'\033[0m'; C_RED=$'\033[1;31m'; C_GRN=$'\033[1;32m'
C_YEL=$'\033[1;33m'; C_BLU=$'\033[1;34m'; C_CYN=$'\033[1;36m'; C_BLD=$'\033[1m'

msg()  { echo -e "${C_CYN}==>${C_RST} $*"; }
ok()   { echo -e "${C_GRN}[OK]${C_RST} $*"; }
warn() { echo -e "${C_YEL}[WARN]${C_RST} $*" >&2; }
die()  { echo -e "${C_RED}[FATAL]${C_RST} $*" >&2; exit 1; }

# ============================================================
# INNER MODE: runs inside the chroot of the new system
# ============================================================
inner_main() {
    trap 'echo "[inner ERROR] line $LINENO: $BASH_COMMAND" >&2' ERR
    # shellcheck disable=SC1090
    . "$ENV_FILE"
    rm -f "$ENV_FILE"
    export DEBIAN_FRONTEND=noninteractive

    local HAVE_NET=false
    if timeout 6 getent hosts archive.ubuntu.com >/dev/null 2>&1; then HAVE_NET=true; fi
    echo "==> [chroot] network available: $HAVE_NET"

    # --- hostname / hosts / timezone ---
    echo "$NEW_HOST" > /etc/hostname
    cat > /etc/hosts <<EOF
127.0.0.1   localhost
127.0.1.1   $NEW_HOST
::1         localhost ip6-localhost ip6-loopback
EOF
    ln -sf "/usr/share/zoneinfo/$NEW_TZ" /etc/localtime
    echo "$NEW_TZ" > /etc/timezone

    # --- fstab / crypttab (by filesystem UUID; fsck pass 0 for btrfs) ---
    cat > /etc/fstab <<EOF
# <file system>   <mount>     <type>  <options>                          <dump> <pass>
UUID=$FS_UUID     /           btrfs   $BTRFS_OPTS,subvol=@                0      0
UUID=$FS_UUID     /home       btrfs   $BTRFS_OPTS,subvol=@home            0      0
UUID=$BOOT_UUID   /boot       ext4    defaults                           0      2
UUID=$EFI_UUID    /boot/efi   vfat    umask=0077                         0      2
EOF
    if [ "$USE_LUKS" = "true" ]; then
        echo "$MAPPER UUID=$LUKS_UUID none luks,discard" > /etc/crypttab
    else
        : > /etc/crypttab
    fi

    # --- user (password read from a file-safe env, root account locked) ---
    H="/home/$NEW_USER"; H_UID=""; H_GID=""
    if [ -d "$H" ]; then
        H_UID=$(stat -c %u "$H"); H_GID=$(stat -c %g "$H")
        # root/system-owned folders are not a real user's home: ignore those ids
        if [ "$H_UID" -lt 1000 ] || [ "$H_GID" -lt 1000 ]; then H_UID=""; H_GID=""; fi
    fi
    if ! id -u "$NEW_USER" >/dev/null 2>&1; then
        UA=(-s /bin/bash -G sudo,adm,cdrom,dip,plugdev)
        if [ -d "$H" ]; then UA+=(-M -d "$H"); else UA+=(-m); fi
        # give the user the SAME uid/gid that owns the kept home, when they are free
        if [ -n "$H_GID" ] && ! getent group "$H_GID" >/dev/null && ! getent group "$NEW_USER" >/dev/null; then
            groupadd -g "$H_GID" "$NEW_USER"
        fi
        if getent group "$NEW_USER" >/dev/null; then UA+=(-g "$NEW_USER"); fi
        if [ -n "$H_UID" ] && ! getent passwd "$H_UID" >/dev/null; then UA+=(-u "$H_UID"); fi
        useradd "${UA[@]}" "$NEW_USER"
    else
        usermod -aG sudo,adm,cdrom,dip,plugdev "$NEW_USER"
    fi
    printf '%s:%s\n' "$NEW_USER" "$NEW_PASS" | chpasswd
    # if the kept home still belongs to different ids (they were taken), fix ownership
    if [ -d "$H" ]; then
        N_UID=$(id -u "$NEW_USER"); N_GID=$(id -g "$NEW_USER")
        if [ "$(stat -c %u "$H")" != "$N_UID" ] || [ "$(stat -c %g "$H")" != "$N_GID" ]; then
            echo "==> [chroot] fixing ownership of the kept home $H"
            chown -R --no-dereference "$N_UID:$N_GID" "$H"
        fi
    fi
    passwd -l root >/dev/null 2>&1 || true

    # --- remove live-session leftovers ---
    rm -f /etc/casper.conf /etc/sudoers.d/casper* 2>/dev/null || true
    dpkg -s casper >/dev/null 2>&1 && dpkg --purge --force-depends casper 2>/dev/null || true
    for f in /etc/gdm3/custom.conf /etc/gdm3/daemon.conf; do
        [ -f "$f" ] && sed -i -E '/^\s*(AutomaticLogin|TimedLogin)(Enable)?\s*=/d' "$f" || true
    done
    rm -f /etc/sddm.conf.d/*autologin* /etc/lightdm/lightdm.conf.d/*autologin* 2>/dev/null || true

    # --- apt: drop cdrom sources ---
    [ -f /etc/apt/sources.list ] && sed -i '/cdrom:/d' /etc/apt/sources.list || true
    rm -f /etc/apt/sources.list.d/*cdrom* 2>/dev/null || true
    if grep -lq 'cdrom:' /etc/apt/sources.list.d/* 2>/dev/null; then
        warn "A file in /etc/apt/sources.list.d still mentions cdrom: - check it after boot."
    fi

    # --- make sure a kernel exists in /boot ---
    if ! ls /boot/vmlinuz-* >/dev/null 2>&1; then
        warn "No kernel found in /boot after copy."
        if [ "$HAVE_NET" = true ]; then
            apt-get update -y && apt-get install -y linux-image-generic linux-headers-generic
        fi
        ls /boot/vmlinuz-* >/dev/null 2>&1 || { echo "FATAL: no kernel in /boot and no network to install one." >&2; exit 1; }
    fi

    # --- LUKS needs the initramfs hook ---
    if [ "$USE_LUKS" = "true" ] && ! dpkg -s cryptsetup-initramfs >/dev/null 2>&1; then
        if [ "$HAVE_NET" = true ]; then
            apt-get update -y && apt-get install -y cryptsetup-initramfs
        else
            echo "FATAL: cryptsetup-initramfs missing and no network; the system would not unlock at boot." >&2
            exit 1
        fi
    fi

    # --- GRUB EFI modules (and signed boot chain for Secure Boot) ---
    if [ ! -d /usr/lib/grub/x86_64-efi ]; then
        if [ "$HAVE_NET" = true ]; then
            apt-get update -y || true
            apt-get install -y grub-efi-amd64-bin
        fi
        [ -d /usr/lib/grub/x86_64-efi ] || { echo "FATAL: GRUB EFI modules missing and could not be installed." >&2; exit 1; }
    fi
    if [ "$HAVE_NET" = true ]; then
        for p in grub-efi-amd64-signed shim-signed; do
            dpkg -s "$p" >/dev/null 2>&1 || apt-get install -y "$p" || echo "[WARN] could not install $p (Secure Boot may not work)"
        done
    fi

    # dracut (Ubuntu 26.04) needs the btrfs tools to put Btrfs support into the initramfs.
    # The live image does not ship them, so install them first (otherwise the log shows
    # "btrfs: command not found" and the initramfs is built without them).
    if ! command -v btrfs >/dev/null 2>&1; then
        if [ "$HAVE_NET" = true ]; then
            apt-get install -y btrfs-progs || echo "[WARN] could not install btrfs-progs; the initramfs may lack Btrfs tools"
        else
            echo "[WARN] btrfs-progs is missing and there is no network: after the first boot run 'sudo apt install btrfs-progs && sudo update-initramfs -u'"
        fi
    fi

    echo "==> [chroot] initramfs + GRUB"
    update-initramfs -u -k all

    if command -v os-prober >/dev/null 2>&1; then
        grep -q '^GRUB_DISABLE_OS_PROBER' /etc/default/grub \
            && sed -i 's/^GRUB_DISABLE_OS_PROBER.*/GRUB_DISABLE_OS_PROBER=false/' /etc/default/grub \
            || echo 'GRUB_DISABLE_OS_PROBER=false' >> /etc/default/grub
    fi

    if [ -d /sys/firmware/efi/efivars ]; then
        grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=ubuntu --recheck
    else
        warn "efivars not visible; installing GRUB to the removable path instead."
        grub-install --target=x86_64-efi --efi-directory=/boot/efi --removable --recheck
    fi
    update-grub

    # --- verify before claiming success ---
    grep -q '^[[:space:]]*menuentry' /boot/grub/grub.cfg || { echo "FATAL: grub.cfg has no menuentry" >&2; exit 1; }
    ls /boot/initrd.img-* >/dev/null 2>&1 || { echo "FATAL: no initrd in /boot" >&2; exit 1; }
    ls /boot/efi/EFI >/dev/null 2>&1 || { echo "FATAL: nothing in /boot/efi/EFI" >&2; exit 1; }
    echo "==> [chroot] bootloader verified"

    # --- UI customization: dock at the bottom, wallpapers, accent colour ---
    # "gsettings set" cannot work here (no user session / D-Bus inside a chroot), so the
    # settings are written as SYSTEM-WIDE dconf defaults (/etc/dconf/db/local.d). The first
    # login picks them up and the user can still change everything in Settings.
    # Every key is checked against the installed schemas first: anything that does not
    # exist on this Ubuntu flavour/version (or a missing wallpaper file) is skipped.
    # Needs no internet. Never fatal.
    apply_ui_customization() {
        (
            set +eE; trap - ERR
            local f=/etc/dconf/db/local.d/00-ui-customization
            local bgdir=/usr/share/backgrounds
            local light="$bgdir/mendhak-Bluebells_Suspended_In_Time.jpg"
            local dark="$bgdir/mizuno-as-Winter_Grand_Triangle.jpg"
            local D=org.gnome.shell.extensions.dash-to-dock
            local B=org.gnome.desktop.background
            local I=org.gnome.desktop.interface
            local body="" last="" sec

            # add SCHEMA KEY GVARIANT-VALUE
            add() {
                if ! GSETTINGS_BACKEND=memory gsettings list-keys "$1" 2>/dev/null | grep -qx -- "$2"; then
                    echo "[WARN] UI: $1 $2 is not available here, skipped"
                    return 0
                fi
                sec=${1//./\/}
                if [ "$sec" != "$last" ]; then
                    [ -n "$body" ] && body+=$'\n'
                    body+="[$sec]"$'\n'
                    last=$sec
                fi
                body+="$2=$3"$'\n'
            }

            add $D dock-position "'BOTTOM'"
            add $D extend-height false
            add $D dock-fixed false
            add $D autohide true
            add $D intellihide true
            add $D icon-size-fixed true
            add $D dash-max-icon-size 48
            add $D show-mounts false
            add $D show-trash false

            local picked=false
            if [ -f "$light" ]; then add $B picture-uri "'file://$light'"; picked=true
            else echo "[WARN] UI: wallpaper not found: $light"; fi
            if [ -f "$dark" ]; then add $B picture-uri-dark "'file://$dark'"; picked=true
            else echo "[WARN] UI: wallpaper not found: $dark"; fi
            [ "$picked" = true ] && add $B picture-options "'zoom'"

            add $I accent-color "'blue'"

            if [ -z "$body" ]; then
                echo "[WARN] UI: nothing to apply (no GNOME schemas found), skipped"
                exit 0
            fi
            if ! command -v dconf >/dev/null 2>&1 && [ "$HAVE_NET" = true ]; then
                apt-get install -y dconf-cli || true
            fi
            command -v dconf >/dev/null 2>&1 || { echo "[WARN] UI: dconf not found, skipped"; exit 0; }
            mkdir -p /etc/dconf/profile /etc/dconf/db/local.d
            [ -f /etc/dconf/profile/user ] || printf 'user-db:user\n' > /etc/dconf/profile/user
            grep -q 'system-db:local' /etc/dconf/profile/user || printf 'system-db:local\n' >> /etc/dconf/profile/user
            printf '%s' "$body" > "$f"
            dconf update && echo "==> [chroot] UI customization applied" || echo "[WARN] UI: dconf update failed"
        ) || echo "[WARN] UI customization had errors (the install continues)"
    }
    if [ "${WANT_UI:-false}" = true ]; then
        apply_ui_customization
    fi

    # --- optional extras: never fatal ---
    try_install() {
        local p
        for p in "$@"; do
            apt-get install -y "$p" || echo "[WARN] could not install $p"
        done
    }
    if [ "$HAVE_NET" = true ]; then
        apt-get update -y || true
        # Everything that is downloaded/installed beyond the base system lives in the embedded extras (emit_extra_packages)
        if [ "$WANT_CODECS$WANT_DRIVERS$WANT_EXTRAS" != "falsefalsefalse" ]; then
            if [ -s /tmp/extra-packages.sh ]; then
                echo "==> [chroot] running the embedded extras"
                (
                    set +eE; trap - ERR
                    sudo()    { "$@"; }                       # we are already root here
                    apt()     { command apt -y "$@"; }        # never ask questions
                    apt-get() { command apt-get -y "$@"; }
                    # GNOME extensions: gnome_ext UUID...  = download from extensions.gnome.org + enable
                    #                   gnome_enable UUID... = only enable (e.g. installed with apt)
                    GNOME_EXT_LIST=/tmp/gnome-ext-enable.list; : > "$GNOME_EXT_LIST"
                    gnome_enable() { local u; for u in "$@"; do echo "$u" >> "$GNOME_EXT_LIST"; done; }
                    gnome_ext() {
                        local u sv info url d
                        command -v gnome-shell >/dev/null 2>&1 || { echo "[WARN] gnome-shell not found, skipping: $*"; return 0; }
                        command -v unzip >/dev/null 2>&1 && command -v curl >/dev/null 2>&1 || apt-get install unzip curl || true
                        sv=$(gnome-shell --version 2>/dev/null | grep -oE '[0-9]+' | head -n1)
                        for u in "$@"; do
                            d=/usr/share/gnome-shell/extensions/$u
                            info=$(curl -fsSL --max-time 30 "https://extensions.gnome.org/extension-info/?uuid=$u&shell_version=$sv") \
                                || { echo "[WARN] cannot reach extensions.gnome.org for $u"; continue; }
                            url=$(printf '%s' "$info" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("download_url",""))' 2>/dev/null || true)
                            [ -n "$url" ] || { echo "[WARN] $u has no version for GNOME Shell $sv"; continue; }
                            curl -fsSL --max-time 120 -o /tmp/gnome-ext.zip "https://extensions.gnome.org$url" \
                                || { echo "[WARN] download failed: $u"; continue; }
                            mkdir -p "$d"
                            if unzip -oq /tmp/gnome-ext.zip -d "$d"; then
                                if [ -d "$d/schemas" ]; then glib-compile-schemas "$d/schemas" || true; fi
                                gnome_enable "$u"
                            else
                                echo "[WARN] could not unpack $u"
                            fi
                            rm -f /tmp/gnome-ext.zip
                        done
                    }
                    . /tmp/extra-packages.sh
                    # Turn on the chosen extensions for every user, keeping Ubuntu's default ones.
                    if [ -s "$GNOME_EXT_LIST" ] && command -v dconf >/dev/null 2>&1; then
                        base=$(GSETTINGS_BACKEND=memory gsettings get org.gnome.shell enabled-extensions 2>/dev/null || echo "[]")
                        list=$(python3 - "$base" "$GNOME_EXT_LIST" <<'PY'
import sys, ast
try:
    cur = ast.literal_eval(sys.argv[1].replace("@as ", ""))
except Exception:
    cur = []
for line in open(sys.argv[2]):
    line = line.strip()
    if line and line not in cur:
        cur.append(line)
print(repr(cur))
PY
)
                        mkdir -p /etc/dconf/profile /etc/dconf/db/local.d
                        [ -f /etc/dconf/profile/user ] || printf 'user-db:user\n' > /etc/dconf/profile/user
                        grep -q 'system-db:local' /etc/dconf/profile/user || printf 'system-db:local\n' >> /etc/dconf/profile/user
                        printf '[org/gnome/shell]\nenabled-extensions=%s\n' "$list" > /etc/dconf/db/local.d/90-extra-extensions
                        dconf update || true
                    fi
                ) || echo "[WARN] extra-packages.sh had errors (the install continues)"
            else
                echo "[WARN] the embedded extras were not copied into the new system: codecs/drivers/extras skipped."
            fi
        fi
    else
        [ "$WANT_CODECS$WANT_DRIVERS$WANT_EXTRAS" != "falsefalsefalse" ] && \
            echo "[WARN] No network: codecs/drivers/extras skipped. Install them after first boot."
    fi

    # --- dock: Discover replaces Ubuntu Software (only if Discover really got installed) ---
    # Runs AFTER the extras, because that is when Discover appears. Like the UI settings it is
    # a system-wide dconf default (gsettings cannot work in a chroot). It starts from the
    # current default list of dock apps, removes every Software-store launcher and puts
    # Discover in third place. Never fatal.
    fix_dock_discover() {
        (
            set +eE; trap - ERR
            local disc=org.kde.discover.desktop f=/etc/dconf/db/local.d/50-favorite-apps
            local cur src list
            [ -f "/usr/share/applications/$disc" ] || { echo "==> [chroot] Discover not installed, dock left as is"; exit 0; }
            command -v dconf >/dev/null 2>&1 || { echo "[WARN] dock: dconf not found, skipped"; exit 0; }
            # base list: a list already preset by extra-packages.sh wins, else the system default
            src=$(grep -lE '^favorite-apps=' /etc/dconf/db/local.d/* 2>/dev/null | grep -v '/50-favorite-apps$' | tail -n1)
            if [ -n "$src" ]; then
                cur=$(grep -E '^favorite-apps=' "$src" | tail -n1 | cut -d= -f2-)
            else
                cur=$(GSETTINGS_BACKEND=memory gsettings get org.gnome.shell favorite-apps 2>/dev/null)
            fi
            [ -n "$cur" ] || { echo "[WARN] dock: could not read the favorite apps list, skipped"; exit 0; }
            list=$(python3 - "$cur" "$disc" <<'PY'
import sys, ast
cur = sys.argv[1].replace("@as ", "")
disc = sys.argv[2]
try:
    l = ast.literal_eval(cur)
except Exception:
    sys.exit(1)
drop = {"org.gnome.Software.desktop", "snap-store_snap-store.desktop",
        "ubuntu-software.desktop", "org.kde.discover.desktop"}
l = [x for x in l if x not in drop]
l.insert(min(2, len(l)), disc)
print(repr(l))
PY
) || { echo "[WARN] dock: could not parse the favorite apps list, skipped"; exit 0; }
            mkdir -p /etc/dconf/profile /etc/dconf/db/local.d
            [ -f /etc/dconf/profile/user ] || printf 'user-db:user\n' > /etc/dconf/profile/user
            grep -q 'system-db:local' /etc/dconf/profile/user || printf 'system-db:local\n' >> /etc/dconf/profile/user
            printf '[org/gnome/shell]\nfavorite-apps=%s\n' "$list" > "$f"
            dconf update && echo "==> [chroot] dock: Discover set instead of Ubuntu Software" || echo "[WARN] dock: dconf update failed"
        ) || echo "[WARN] dock fix had errors (the install continues)"
    }
    if [ "$WANT_EXTRAS" = true ]; then
        fix_dock_discover
    fi
    exit 0
}

if [ "${1:-}" = "--inner" ]; then
    inner_main
    exit 0
fi

# ============================================================
# OUTER MODE
# ============================================================
[ "$(id -u)" -eq 0 ] || { echo "Run with sudo."; exit 1; }
: >> "$LOG_FILE"
exec > >(tee -a "$LOG_FILE") 2>&1

DISK=""; DISK_NAME=""
RAW_ROOT=""; ACTIVE_DEV=""; BOOT_PART=""; EFI_PART=""
USE_LUKS=false; LUKS_OPENED=false; LUKS_PASS=""; LUKS_UUID=""
FORMAT_ROOT=false; FORMAT_BOOT=false; FORMAT_EFI=false
CREATE_EFI=false; CREATE_BOOT=false; CREATE_ROOT=false
EFI_SIZE="+512M"; BOOT_SIZE="+2G"; SIZE_TIER=none; NEED_MIN_MIB=0
NEED_GPT=false; REUSE_EFI=false; BACK_TO_MENU=false; PICK=""
MODE=""; HOME_STATE="none"; ROOT_STATE="none"; WIPE_HOME=false
REPLY_DEV=""; NEW_PART=""
RESOLV_BACKED=false; INSTALL_OK=false
FS_UUID=""; BOOT_UUID=""; EFI_UUID=""
NEW_USER=""; NEW_PASS=""; NEW_HOST="ubuntu-pc"; NEW_TZ="Africa/Cairo"
WANT_CODECS=false; WANT_DRIVERS=false; WANT_EXTRAS=true; WANT_UI=true
DONE_LUKSFMT=false; DONE_ROOTFMT=false; DONE_EFIFMT=false; DONE_BOOTFMT=false
CHANGE_LUKS_PASS=false; LUKS_OLDPASS=""; LUKS_NEWPASS=""; DONE_LUKSPASS=false
WIPE_DISK=false; DONE_WIPE=false
HOME_OLDDIR=""; OLD_AT_EXCL=""; BOOT_ODD=""
VERR=(); VWARN=()
LUKS_EXT_NAME=""; LIVE_PARTS=()
PLAN_OK=false; WARN_ACK=false
UI_W=76; UI_H=22; UI_LH=10; UI_ROWS=24; UI_DEFAULT=""

# Variables that execution steps may change; saved after every step (even a failed one)
# so that "retry" continues exactly where the step stopped. No secrets in here.
STATE_VARS=(EFI_PART BOOT_PART RAW_ROOT ACTIVE_DEV CREATE_EFI CREATE_BOOT CREATE_ROOT NEED_GPT
            LUKS_OPENED LUKS_UUID FS_UUID BOOT_UUID EFI_UUID
            DONE_LUKSFMT DONE_ROOTFMT DONE_EFIFMT DONE_BOOTFMT DONE_LUKSPASS DONE_WIPE
            HOME_STATE WIPE_HOME HOME_OLDDIR RESOLV_BACKED)

save_state() {
    local v
    ( umask 077
      for v in "${STATE_VARS[@]}"; do printf '%s=%q\n' "$v" "${!v}"; done > "$STATE_FILE" )
}

restore_resolv() {
    if [ -e "$MP/etc/resolv.conf.inst-bak" ] || [ -L "$MP/etc/resolv.conf.inst-bak" ]; then
        rm -f "$MP/etc/resolv.conf"
        mv "$MP/etc/resolv.conf.inst-bak" "$MP/etc/resolv.conf"
    fi
    RESOLV_BACKED=false
}

cleanup() {
    local rc=$?
    trap - EXIT INT TERM ERR
    set +e
    cd /
    [ "$RESOLV_BACKED" = true ] && restore_resolv
    if findmnt -rn "$MP" >/dev/null 2>&1; then
        rm -f "$MP$ENV_FILE" "$MP/tmp/installer.sh"
        sync
        umount -R "$MP" 2>/dev/null || umount -Rl "$MP" 2>/dev/null
    fi
    findmnt -rn "$TOP" >/dev/null 2>&1 && { umount "$TOP" 2>/dev/null || umount -l "$TOP" 2>/dev/null; }
    findmnt -rn "$CHK" >/dev/null 2>&1 && { umount "$CHK" 2>/dev/null || umount -l "$CHK" 2>/dev/null; }
    [ "$LUKS_OPENED" = true ] && cryptsetup close "$MAPPER" 2>/dev/null
    [ -n "$LUKS_EXT_NAME" ] && cryptsetup close "$LUKS_EXT_NAME" 2>/dev/null
    rm -f "$STATE_FILE"
    systemctl unmask --runtime udisks2 2>/dev/null
    systemctl start udisks2 2>/dev/null
    if [ "$INSTALL_OK" = true ] && [ $rc -eq 0 ]; then
        echo -e "${C_GRN}==========================================================${C_RST}"
        echo -e "${C_GRN}Installation finished and verified. Remove the USB and reboot.${C_RST}"
        echo -e "${C_GRN}Log: $LOG_FILE${C_RST}"
        echo -e "${C_GRN}==========================================================${C_RST}"
    else
        echo -e "\n${C_YEL}Installer stopped (exit code $rc). Mounts were released. Nothing else was deleted. Log: $LOG_FILE${C_RST}"
    fi
    exit $rc
}
trap cleanup EXIT
trap 'exit 130' INT TERM
trap 'echo -e "${C_RED}[ERROR] line $LINENO: $BASH_COMMAND${C_RST}" >&2' ERR

# ---------- TUI helpers (whiptail) ----------
# The UI is drawn on $TTY_DEV; selected values come back on stderr and are captured.
ui_dims() {
    local sz l c
    sz=$(stty size 2>/dev/null || true)
    l=${sz%% *}; c=${sz##* }
    [[ $l =~ ^[0-9]+$ ]] || l=24
    [[ $c =~ ^[0-9]+$ ]] || c=80
    UI_ROWS=$l
    UI_W=$((c - 6)); if [ "$UI_W" -gt 90 ]; then UI_W=90; fi; if [ "$UI_W" -lt 56 ]; then UI_W=56; fi
    UI_H=$((l - 4));  if [ "$UI_H" -gt 26 ]; then UI_H=26; fi; if [ "$UI_H" -lt 14 ]; then UI_H=14; fi
    UI_LH=$((l - 13)); if [ "$UI_LH" -gt 14 ]; then UI_LH=14; fi; if [ "$UI_LH" -lt 4 ]; then UI_LH=4; fi
}
wt_box() { whiptail --backtitle "$WT_TITLE" "$@" <"$TTY_DEV" >"$TTY_DEV" 2>&1; }
wt_val() { whiptail --backtitle "$WT_TITLE" "$@" <"$TTY_DEV" 2>&1 >"$TTY_DEV"; }

ui_msg()  { ui_dims; wt_box --title "$1" --ok-button OK --msgbox "$2" 0 "$UI_W" || true; }
# Rows a text needs at the current width (long lines wrap).
text_rows() { # $1 text
    local ln t=0 w=$((UI_W - 6))
    while IFS= read -r ln; do
        t=$((t + 1 + (${#ln} > w ? (${#ln} - 1) / w : 0)))
    done <<<"$1"
    echo "$t"
}
# $1 title, $2 text, $3 "trunc" (optional). When the text fits the screen it is a plain
# box, so the focus starts on OK and Enter closes it. Only a text that does NOT fit
# becomes scrollable (focus on the text, Tab to reach OK) - or, with "trunc", is cut.
ui_text() {
    local maxl
    ui_dims
    maxl=$((UI_H - 8))
    if [ "$(text_rows "$2")" -le "$maxl" ]; then
        wt_box --title "$1" --ok-button OK --msgbox "$2" 0 "$UI_W" || true
    elif [ "${3:-}" = trunc ]; then
        wt_box --title "$1" --ok-button OK --msgbox "$(printf '%s\n' "$2" | head -n "$maxl")${NL}... (more lines not shown)" 0 "$UI_W" || true
    else
        wt_box --title "$1" --ok-button OK --scrolltext --msgbox "$2" "$UI_H" "$UI_W" || true
    fi
}
ui_info() { ui_dims; wt_box --title "Please wait" --infobox "$1" 7 "$UI_W" || true; }

# $1 title, $2 text, then TAG ITEM pairs. Sets REPLY = chosen tag. Returns 1 on Back/Esc.
# The list height shrinks automatically when the text above it is long, so the box
# always fits the terminal (the list scrolls if needed).
ui_menu() {
    local title=$1 text=$2 lh max def=${UI_DEFAULT:-} tl=0 ln w
    shift 2
    UI_DEFAULT=""
    ui_dims
    w=$((UI_W - 6))
    while IFS= read -r ln; do
        tl=$((tl + 1 + (${#ln} > w ? (${#ln} - 1) / w : 0)))
    done <<<"$text"
    lh=$(( $# / 2 ))
    max=$((UI_ROWS - 11 - tl))
    if [ "$max" -gt 14 ]; then max=14; fi
    if [ "$max" -lt 4 ]; then max=4; fi
    if [ "$lh" -gt "$max" ]; then lh=$max; fi
    local args=(--title "$title" --ok-button OK --cancel-button Back)
    if [ -n "$def" ]; then args+=(--default-item "$def"); fi
    REPLY=$(wt_val "${args[@]}" --menu "$text" 0 "$UI_W" "$lh" "$@") || return 1
}
ui_input() { # $1 title, $2 text, $3 initial -> REPLY ; 1 on Back
    ui_dims
    REPLY=$(wt_val --title "$1" --ok-button OK --cancel-button Back --inputbox "$2" 0 "$UI_W" "${3:-}") || return 1
}
ui_pass() { # $1 title, $2 text -> REPLY ; 1 on Back
    ui_dims
    REPLY=$(wt_val --title "$1" --ok-button OK --cancel-button Back --passwordbox "$2" 0 "$UI_W") || return 1
}

# yesno "question" default(y|n)  -> 0 = yes
# yesno "question" default(y|n) ["Yes button text" "No button text"]
# The optional button texts make a choice explicit, e.g. "Yes, format @home" / "No, keep @home".
yesno() {
    local dflag=() lbl=()
    if [ "${2:-n}" = n ]; then dflag=(--defaultno); fi
    if [ -n "${3:-}" ]; then lbl+=(--yes-button "$3"); fi
    if [ -n "${4:-}" ]; then lbl+=(--no-button "$4"); fi
    ui_dims
    if wt_box --title "Question" "${dflag[@]}" "${lbl[@]}" --yesno "$1" 0 "$UI_W"; then return 0; fi
    return 1
}

# "true"/"false" -> default answer letter for yesno
dflt() { if [ "$1" = true ]; then echo y; else echo n; fi; }

ask_new_pass() { # $1 title -> REPLY ; returns 1 if the user went Back
    local p1 p2
    while true; do
        ui_pass "$1" "Enter the password:" || return 1; p1=$REPLY
        ui_pass "$1" "Confirm the password:" || return 1; p2=$REPLY
        if [ -n "$p1" ] && [ "$p1" = "$p2" ]; then REPLY=$p1; return 0; fi
        ui_msg "$1" "Empty or not matching. Try again."
    done
}

# Recoverable problem while PLANNING: tell the user and go back (nothing was changed yet).
plan_fail() { ui_msg "Cannot continue" "$*"; BACK_TO_MENU=true; }

belongs_to_disk() { [ "$(lsblk -no PKNAME "$1" 2>/dev/null | head -n1)" = "$DISK_NAME" ]; }

# Menu of the partitions of $DISK (the live USB partition is never listed).
# $1 title, $2 text, $3 allow "new" (true/false), $4 default tag -> REPLY ; 1 = Back
pick_part() {
    local items=() d sz fs lb desc n=0
    if [ "$3" = true ]; then items+=(new "NEW partition (created automatically in free space)"); n=$((n + 1)); fi
    while read -r d; do
        if [ -z "$d" ]; then continue; fi
        if is_live_part "$d"; then continue; fi
        sz=$(lsblk -dno SIZE "$d" 2>/dev/null | tr -d ' ' || true)
        fs=$(fstype_of "$d")
        lb=$(lsblk -dno LABEL "$d" 2>/dev/null || true)
        desc="${sz}  ${fs:--}${lb:+  [$lb]}"
        items+=("$d" "$desc"); n=$((n + 1))
    done < <(list_parts)
    if [ "$n" -eq 0 ]; then ui_msg "$1" "No usable partition found on $DISK."; return 1; fi
    UI_DEFAULT=${4:-}
    if ui_menu "$1" "$2" "${items[@]}"; then return 0; fi
    return 1
}

fstype_of() { blkid -s TYPE -o value "$1" 2>/dev/null || true; }

have_net() { timeout 6 getent hosts archive.ubuntu.com >/dev/null 2>&1; }

# Bytes the live system occupies (falls back to a safe guess if /rofs is an overlay).
rofs_bytes() {
    local b
    b=$(df -B1 --output=used "$ROFS" 2>/dev/null | tail -n1 | tr -d ' ' || true)
    if ! [[ $b =~ ^[0-9]+$ ]] || [ "$b" -lt $((2 * 1024 * 1024 * 1024)) ]; then b=$((6 * 1024 * 1024 * 1024)); fi
    echo "$b"
}

rofs_has_pkg() { # $1 package installed in the live image?
    awk -v pkg="$1" 'BEGIN{RS=""; FS="\n"} { if ($1=="Package: " pkg && $0 ~ /Status: install ok installed/) f=1 } END{exit f?0:1}' \
        "$ROFS/var/lib/dpkg/status" 2>/dev/null
}

# $1 device, $2 role (EFI|boot). Returns 1 (with an explanation) if the partition is
# abnormally large for that role, so the caller can ask again instead of continuing.
size_sane() {
    local dev=$1 role=$2 mib max
    mib=$(( $(lsblk -bdno SIZE "$dev" | head -n1) / 1048576 ))
    if [ "$role" = EFI ]; then max=$MAX_EFI_MIB; else max=$MAX_BOOT_MIB; fi
    if [ "$mib" -gt "$max" ]; then
        ui_msg "Partition refused" "$dev is $mib MiB, but a normal $role partition is at most $max MiB.${NL}That looks like the wrong partition (data/root?). Pick another one."
        return 1
    fi
    return 0
}
list_parts() { lsblk -nrpo NAME,TYPE "$DISK" | awk '$2=="part"{print $1}' | sort; }

# Free MiB on an unmounted partition (mounted read-only for a moment). Fails if it can't be mounted.
part_free_mib() {
    local free
    if findmnt -rn "$CHK" >/dev/null 2>&1; then umount "$CHK" 2>/dev/null || true; fi
    mkdir -p "$CHK"
    mount -o ro "$1" "$CHK" 2>/dev/null || return 1
    free=$(df -B1 --output=avail "$CHK" | tail -n1 | tr -d ' ')
    umount "$CHK" 2>/dev/null || true
    echo $(( free / 1048576 ))
}

# Does an existing ext4 partition look like a /boot? Sets BOOT_ODD to what looks foreign.
boot_looks_ok() {
    local e odd=()
    BOOT_ODD=""
    if findmnt -rn "$CHK" >/dev/null 2>&1; then umount "$CHK" 2>/dev/null || true; fi
    mkdir -p "$CHK"
    mount -o ro "$1" "$CHK" 2>/dev/null || return 0     # can't inspect: don't block
    while IFS= read -r e; do
        case "$e" in
            lost+found|grub|efi|EFI|loader|vmlinuz*|initrd*|config-*|System.map*|memtest*|*ucode*|*.img) ;;
            *) odd+=("$e") ;;
        esac
    done < <(ls -A "$CHK")
    umount "$CHK" 2>/dev/null || true
    if [ ${#odd[@]} -gt 0 ]; then BOOT_ODD="${odd[*]:0:8}"; return 1; fi
    return 0
}

is_live_part() { # $1 partition: does the live system you booted from run from it?
    local p
    for p in "${LIVE_PARTS[@]}"; do
        if [ "$p" = "$1" ]; then return 0; fi
    done
    return 1
}

# All names of a device and of everything on it (incl. the /dev/dm-N form).
dev_aliases() { # $1 device
    local n
    while read -r n; do
        echo "$n"
        readlink -f "$n"
    done < <(lsblk -nrpo NAME "$1" 2>/dev/null)
}

# Unmount EVERYTHING that lives on $1 (disk or partition), deepest mount first.
# Mounts made earlier (file manager, auto-mount, anything) never matter. The partition
# the live system runs from is skipped on purpose.
unmount_everything_on() {
    local aliases protect t
    aliases=$(dev_aliases "$1" | sort -u | tr '\n' ' ')
    protect=$(for t in "${LIVE_PARTS[@]}"; do dev_aliases "$t"; done | sort -u | tr '\n' ' ')
    while read -r t; do
        case "$t" in ""|/|/cdrom*|/rofs*|/isodevice*|/snap*|/usr*|/boot*|/etc*|/var*|"$MP"*|"$TOP"*|"$CHK"*) continue ;; esac
        umount -R "$t" 2>/dev/null || umount -l "$t" 2>/dev/null || true
    done < <(
        findmnt -rn -o TARGET,SOURCE | awk -v list="$aliases" -v prot="$protect" '
            BEGIN { n = split(list, a, " "); for (i = 1; i <= n; i++) s[a[i]] = 1
                    m = split(prot, b, " "); for (i = 1; i <= m; i++) p[b[i]] = 1 }
            { src = $2; sub(/\[.*/, "", src); if ((src in s) && !(src in p)) print $1 }' \
        | awk '{print length($0) " " $0}' | sort -rn | cut -d' ' -f2-
    )
    return 0
}

# Close LUKS mappings on $1 (retries; failures are ignored). The mapping we are
# working with (ACTIVE_DEV) is never closed here.
close_mappers_of() { # $1 device
    local m i
    while read -r m; do
        if [ -z "$m" ]; then continue; fi
        if [ -n "$ACTIVE_DEV" ] && [ "$m" = "$ACTIVE_DEV" ]; then continue; fi
        for i in 1 2 3; do
            if cryptsetup close "$m" 2>/dev/null; then break; fi
            sleep 1
        done
    done < <(lsblk -nrpo NAME,TYPE "$1" 2>/dev/null | awk '$2=="crypt"{print $1}')
    return 0
}

force_unmount_disk() {
    local d
    # swap on this disk
    while read -r d; do
        [ -n "$d" ] && swapoff "$d" 2>/dev/null || true
    done < <(swapon --noheadings --show=NAME 2>/dev/null | grep "^$DISK" || true)
    unmount_everything_on "$DISK"     # 1st: nothing may stay mounted ...
    close_mappers_of "$DISK"          # 2nd: ... so the mappings can really be closed
}

# Returns 1 if the user cancels so the caller can go back.
unlock_luks() { # $1 raw dev
    local pass ext
    unmount_everything_on "$1"
    close_mappers_of "$1"
    ext=$(lsblk -nrpo NAME,TYPE "$1" 2>/dev/null | awk '$2=="crypt"{print $1; exit}')
    if [ -n "$ext" ]; then
        # Already unlocked by something else (e.g. the file manager) and it cannot be closed: just use it.
        ui_msg "LUKS" "$1 is already unlocked as $ext - using it (no passphrase needed)."
        LUKS_EXT_NAME=$ext; ACTIVE_DEV=$ext
        return 0
    fi
    if [ -e "/dev/mapper/$MAPPER" ]; then
        if ! cryptsetup close "$MAPPER" 2>/dev/null; then ui_msg "LUKS" "/dev/mapper/$MAPPER already exists and is busy."; return 1; fi
    fi
    while true; do
        ui_pass "Unlock $1" "LUKS passphrase (Back = cancel):" || return 1
        pass=$REPLY
        [ -n "$pass" ] || return 1
        if printf '%s' "$pass" | cryptsetup open "$1" "$MAPPER" -; then
            LUKS_OPENED=true; ACTIVE_DEV=/dev/mapper/$MAPPER
            LUKS_OLDPASS=$pass
            return 0
        fi
        ui_msg "LUKS" "Wrong passphrase."
    done
}

# Delete a subvolume tree under $TOP. Refuses to touch @home unless WIPE_HOME=true.
delete_subvol_tree() {
    local name=$1 path pass
    [ -e "$TOP/$name" ] || return 0
    if [ "$name" = "@home" ] && [ "$WIPE_HOME" != true ]; then
        die "Internal safety stop: refusing to delete @home without explicit confirmation."
    fi
    if btrfs subvolume show "$TOP/$name" >/dev/null 2>&1; then
        for pass in 1 2 3; do
            while IFS= read -r path; do
                [ -n "$path" ] || continue
                btrfs property set -ts "$TOP/$path" ro false 2>/dev/null || true
                btrfs subvolume delete "$TOP/$path" >/dev/null 2>&1 || true
            done < <(btrfs subvolume list -o "$TOP/$name" 2>/dev/null | sed -n 's/^.* path //p' | sort -r)
        done
        btrfs property set -ts "$TOP/$name" ro false 2>/dev/null || true
        if ! btrfs subvolume delete "$TOP/$name" >/dev/null 2>&1; then
            warn "Subvolume $name is stubborn; emptying it first."
            rm -rf "${TOP:?}/$name"/* "${TOP:?}/$name"/.[!.]* 2>/dev/null || true
            btrfs subvolume delete "$TOP/$name" || die "Could not delete subvolume $name."
        fi
    else
        rm -rf "${TOP:?}/${name:?}"
    fi
}

# ============================================================
# 1. Pre-flight (environment only; the plan itself is validated later)
# ============================================================
preflight() {
    clear
    echo -e "${C_BLU}================ PRE-FLIGHT CHECKS ================${C_RST}"
    [ -d /sys/firmware/efi ] || die "Not booted in UEFI mode."
    ok "UEFI mode"
    [ -d "$ROFS/usr" ] || die "Live system source $ROFS not found (set ROFS=/path if different)."
    ok "Live source: $ROFS"

    local f fsn
    for f in usr/bin/bash usr/sbin/grub-install usr/sbin/update-grub usr/sbin/update-initramfs usr/sbin/useradd usr/sbin/chpasswd; do
        [ -e "$ROFS/$f" ] || die "The live image has no /$f, so the new system could not be configured. Nothing was changed."
    done
    ok "Live image contains the tools needed to configure the new system"
    if [ -d "$ROFS/usr/lib/grub/x86_64-efi" ]; then
        ok "GRUB EFI modules: found in the live image"
    elif [ -d /usr/lib/grub/x86_64-efi ]; then
        ok "GRUB EFI modules: found in the running live system (will be copied)"
    else
        warn "GRUB EFI modules not found locally; they will be installed from the internet (checked before the install starts)."
    fi

    local -A pkg=( [rsync]=rsync [cryptsetup]=cryptsetup [btrfs]=btrfs-progs [mkfs.btrfs]=btrfs-progs
        [mkfs.vfat]=dosfstools [mkfs.ext4]=e2fsprogs [blkid]=util-linux [lsblk]=util-linux
        [findmnt]=util-linux [sgdisk]=gdisk [partx]=util-linux [parted]=parted [chroot]=coreutils
        [blockdev]=util-linux [timeout]=coreutils [whiptail]=whiptail [wipefs]=util-linux )
    local t missing=()
    for t in "${!pkg[@]}"; do command -v "$t" >/dev/null 2>&1 || missing+=("${pkg[$t]}"); done
    if [ ${#missing[@]} -gt 0 ]; then
        warn "Missing packages: ${missing[*]} - trying to install"
        apt-get update -y >/dev/null 2>&1 || true
        apt-get install -y "${missing[@]}" || true
        for t in "${!pkg[@]}"; do command -v "$t" >/dev/null 2>&1 || die "Required tool '$t' is missing and could not be installed (no network?)."; done
    fi
    ok "Required tools"

    for fsn in btrfs ext4 vfat; do
        if ! grep -qw "$fsn" /proc/filesystems; then modprobe "$fsn" 2>/dev/null || true; fi
        grep -qw "$fsn" /proc/filesystems || die "This kernel cannot handle the '$fsn' filesystem."
    done
    ok "Kernel supports btrfs / ext4 / vfat"

    systemctl stop udisks2 2>/dev/null || true
    systemctl mask --runtime udisks2 2>/dev/null || true
    mkdir -p "$MP" "$TOP" "$CHK"
    if findmnt -rn "$MP" >/dev/null 2>&1; then die "$MP is already mounted. Unmount it first."; fi
}

# ============================================================
# 2. Disk selection (TUI)
# ============================================================
select_disk() { # returns 1 if cancelled
    local live_src live_disk items=() name desc prev=$DISK chosen lay maxl nl
    live_src=$(findmnt -rno SOURCE /cdrom 2>/dev/null || true)
    live_disk=""; LIVE_PARTS=()
    if [ -n "$live_src" ]; then
        live_src=${live_src%%[*}
        live_disk=$(lsblk -nrs -o NAME,TYPE "$live_src" 2>/dev/null | awk '$2=="disk"{print $1; exit}' || true)
        mapfile -t LIVE_PARTS < <(lsblk -nrps -o NAME,TYPE "$live_src" 2>/dev/null | awk '$2=="part"{print $1}')
    fi
    while read -r name; do
        if [ -z "$name" ]; then continue; fi
        if [ -n "$live_disk" ] && [ "$live_disk" = "$name" ] && [ "$(lsblk -dno TRAN "/dev/$name" 2>/dev/null || true)" = usb ]; then continue; fi
        desc=$(lsblk -dno SIZE,MODEL,TRAN "/dev/$name" 2>/dev/null | tr -s ' ' | cut -c1-58 || true)
        items+=("/dev/$name" "$desc")
    done < <(lsblk -dn -e 7,11 -o NAME,TYPE 2>/dev/null | awk '$2=="disk"{print $1}')
    if [ ${#items[@]} -eq 0 ]; then ui_msg "Disk" "No usable disk found (the live USB is never offered)."; return 1; fi
    UI_DEFAULT=$DISK
    ui_menu "Select the target disk" "Choose the disk to install on. The live USB is not listed." "${items[@]}" || return 1
    chosen=$REPLY
    lay=$(lsblk -o NAME,SIZE,FSTYPE,LABEL,MOUNTPOINTS "$chosen" 2>&1 || true)
    if [ -n "$live_disk" ] && [ "/dev/$live_disk" = "$chosen" ]; then
        lay+="${NL}${NL}The live system runs from ${LIVE_PARTS[*]:-a partition of this disk}; it is PROTECTED and cannot be touched."
    fi
    # ONE screen: the disk layout and the confirmation together. Enter = OK (default).
    # No --scrolltext here: with it the focus starts on the text, not on OK. The layout is
    # shortened to fit the screen instead, so Enter lands on OK straight away.
    ui_dims
    maxl=$((UI_H - 9))
    nl=$(printf '%s\n' "$lay" | wc -l)
    if [ "$nl" -gt "$maxl" ]; then
        lay="$(printf '%s\n' "$lay" | head -n "$maxl")${NL}... and $((nl - maxl)) more line(s)"
    fi
    if ! wt_box --title "Use $chosen ?" --yes-button OK --no-button Back \
        --yesno "Current layout of $chosen:${NL}${NL}${lay}${NL}${NL}OK = work on this disk, Back = choose another." "$UI_H" "$UI_W"; then
        return 1
    fi
    DISK=$chosen; DISK_NAME=${chosen#/dev/}
    if [ "$prev" != "$DISK" ]; then reset_plan; PLAN_OK=false; fi
    force_unmount_disk
    return 0
}

# ============================================================
# 3. Partition plan (TUI; planning only, nothing destructive here)
# ============================================================

# ---- small facts about the plan (used by the pages, the hub and the main menu) ----
sz_of() { lsblk -dno SIZE "$1" 2>/dev/null | tr -d ' ' || true; }

root_set() {
    if [ "$CREATE_ROOT" = true ]; then return 0; fi
    if [ -z "$RAW_ROOT" ]; then return 1; fi
    if [ "$MODE" = 1 ] && [ -z "$ACTIVE_DEV" ]; then return 1; fi
    return 0
}
boot_set() { [ "$CREATE_BOOT" = true ] || [ -n "$BOOT_PART" ]; }
efi_set()  { [ "$CREATE_EFI" = true ]  || [ -n "$EFI_PART" ]; }

# PLAN_OK = a mode is chosen and the three partitions (root, boot, EFI) are all decided.
refresh_plan() {
    if [ -n "$MODE" ] && root_set && boot_set && efi_set; then PLAN_OK=true; else PLAN_OK=false; fi
    return 0
}

mode_name() {
    case "$1" in
        1) echo "Reinstall (replaces only @)" ;;
        2) echo "Free space (erases nothing)" ;;
        3) echo "Manual (root is formatted)" ;;
        4) echo "WIPE ENTIRE DISK (erases everything)" ;;
        *) echo "(none)" ;;
    esac
}

# One short line per partition: what it is, its size, and what happens to it.
brief_root() {
    local l="" h="" a
    if ! root_set; then echo "(not set)"; return 0; fi
    if [ "$USE_LUKS" = true ]; then l=" +LUKS"; fi
    if [ "$CREATE_ROOT" = true ]; then echo "NEW Btrfs, rest of the free space$l"; return 0; fi
    a="${RAW_ROOT#/dev/} $(sz_of "$RAW_ROOT")$l"
    if [ "$FORMAT_ROOT" = true ]; then
        echo "$a -> FORMAT (all lost)"
    else
        case "$HOME_STATE:$WIPE_HOME" in
            none:*)   h="new @home" ;;
            *:true)   h="@home WIPED" ;;
            *)        h="@home kept" ;;
        esac
        echo "$a -> @ replaced, $h"
    fi
}
brief_boot() {
    local a
    if ! boot_set; then echo "(not set)"; return 0; fi
    if [ "$CREATE_BOOT" = true ]; then echo "NEW ${BOOT_SIZE#+}iB ext4 (free space)"; return 0; fi
    a="${BOOT_PART#/dev/} $(sz_of "$BOOT_PART")"
    if [ "$FORMAT_BOOT" = true ]; then echo "$a -> FORMAT (ext4)"; else echo "$a -> KEEP (not formatted)"; fi
}
brief_efi() {
    local a
    if ! efi_set; then echo "(not set)"; return 0; fi
    if [ "$CREATE_EFI" = true ]; then echo "NEW ${EFI_SIZE#+}iB FAT32 (free space)"; return 0; fi
    a="${EFI_PART#/dev/} $(sz_of "$EFI_PART")"
    if [ "$FORMAT_EFI" = true ]; then echo "$a -> FORMAT (FAT32)"; else echo "$a -> KEEP (not formatted)"; fi
}
plan_brief() {
    if [ "$WIPE_DISK" = true ]; then echo "!! $DISK will be COMPLETELY ERASED !!"; fi
    echo "Btrfs: $(brief_root)"
    echo "Boot : $(brief_boot)"
    echo "EFI  : $(brief_efi)"
}

# ---- mode choice ----
# Sets MODE. Changing the mode clears the partition choices. Returns 1 on Back/cancel.
choose_mode() {
    local m
    UI_DEFAULT=$MODE
    ui_menu "Installation mode for $DISK" "Choose how to install." \
        1 "REINSTALL on existing Btrfs (replaces only @, keeps @home)" \
        2 "FREE SPACE install (new EFI + boot + root, erases nothing)" \
        3 "MANUAL partitions (root is formatted, you pick all three)" \
        4 "WIPE ENTIRE DISK and install from scratch (ERASES EVERYTHING)" || return 1
    m=$REPLY
    if [ "$m" = "$MODE" ]; then return 0; fi
    if [ -n "$MODE" ] && { root_set || boot_set || efi_set; }; then
        if ! yesno "Changing the mode clears your partition choices.${NL}Continue?" y; then return 1; fi
    fi
    reset_plan
    MODE=$m
    case "$MODE" in 3) FORMAT_ROOT=true ;; *) FORMAT_ROOT=false ;; esac
    return 0
}

# Forget the Root page of mode 1 and release what it opened (mounts, LUKS mapping).
root_clear() {
    if findmnt -rn "$TOP" >/dev/null 2>&1; then umount "$TOP" 2>/dev/null || true; fi
    if [ "$LUKS_OPENED" = true ]; then cryptsetup close "$MAPPER" 2>/dev/null || true; LUKS_OPENED=false; fi
    RAW_ROOT=""; ACTIVE_DEV=""; USE_LUKS=false; LUKS_UUID=""; LUKS_PASS=""
    CHANGE_LUKS_PASS=false; LUKS_OLDPASS=""; LUKS_NEWPASS=""
    HOME_STATE=none; ROOT_STATE=none; WIPE_HOME=false; OLD_AT_EXCL=""; WARN_ACK=false
    return 0
}

# Mode 1, encrypted root: offer to change the LUKS passphrase. Planning only: the change is
# applied when the installation starts (do_filesystems), never before.
ask_change_luks_pass() {
    CHANGE_LUKS_PASS=false; LUKS_NEWPASS=""
    if ! yesno "The root partition is encrypted (LUKS).${NL}${NL}Change the encryption passphrase?${NL}${NL}  No, keep it    = the current passphrase stays (default)${NL}  Yes, change it = you set a new one (applied only when the installation starts)" n "Yes, change it" "No, keep it"; then
        return 0
    fi
    # the current passphrase is needed (it is already known if we unlocked the disk ourselves)
    while [ -z "$LUKS_OLDPASS" ]; do
        if ! ui_pass "Current LUKS passphrase" "Enter the CURRENT passphrase of $RAW_ROOT (Back = keep it unchanged):"; then
            ui_msg "LUKS" "The passphrase will stay unchanged."; return 0
        fi
        if printf '%s' "$REPLY" | cryptsetup open --test-passphrase "$RAW_ROOT" --key-file=- 2>/dev/null; then
            LUKS_OLDPASS=$REPLY
        else
            ui_msg "LUKS" "Wrong passphrase."
        fi
    done
    if ask_new_pass "New LUKS passphrase"; then
        LUKS_NEWPASS=$REPLY; CHANGE_LUKS_PASS=true
        ui_msg "LUKS" "The passphrase will be changed when the installation starts."
    else
        ui_msg "LUKS" "No new passphrase was set: it will stay unchanged."
    fi
    return 0
}

# ---- PAGE: Root, mode 1 (existing Btrfs / LUKS; only @ is replaced) ----
# Touches ONLY the root-related variables. Back/failure leaves boot and EFI alone.
page_root_m1() {
    local sel a subs
    if ! pick_part "Btrfs partition (root /)" "Choose the EXISTING Btrfs (or LUKS) ROOT partition.${NL}Only the subvolume @ inside it is replaced." false "$RAW_ROOT"; then
        return 1
    fi
    sel=$REPLY
    if [ "$sel" = "$BOOT_PART" ] || [ "$sel" = "$EFI_PART" ]; then
        ui_msg "Btrfs partition (root /)" "$sel is already chosen as /boot or EFI. Choose another partition."
        return 1
    fi
    root_clear
    RAW_ROOT=$sel
    case "$(fstype_of "$RAW_ROOT")" in
        crypto_LUKS)
            USE_LUKS=true; LUKS_UUID=$(blkid -s UUID -o value "$RAW_ROOT")
            if ! unlock_luks "$RAW_ROOT"; then
                root_clear; ui_msg "Btrfs partition (root /)" "The LUKS volume was not unlocked. The Btrfs page is NOT set."
                return 1
            fi ;;
        btrfs)
            USE_LUKS=false; ACTIVE_DEV=$RAW_ROOT ;;
        *)
            root_clear; ui_msg "Btrfs partition (root /)" "$sel is neither Btrfs nor LUKS. The Btrfs page is NOT set."
            return 1 ;;
    esac
    if [ "$(fstype_of "$ACTIVE_DEV")" != btrfs ]; then
        root_clear; ui_msg "Btrfs partition (root /)" "The unlocked volume is not Btrfs. The Btrfs page is NOT set."
        return 1
    fi

    if ! mount -o ro,subvolid=5 "$ACTIVE_DEV" "$TOP"; then
        root_clear; ui_msg "Btrfs partition (root /)" "Could not mount $sel (damaged filesystem?). Nothing was changed. The Btrfs page is NOT set."
        return 1
    fi
    subs=$(btrfs subvolume list "$TOP" 2>&1 || true)
    ROOT_STATE=none; HOME_STATE=none
    if [ -e "$TOP/@" ]; then ROOT_STATE=present; fi
    if [ -e "$TOP/@home" ]; then
        if btrfs subvolume show "$TOP/@home" >/dev/null 2>&1; then HOME_STATE=subvol; else HOME_STATE=dir; fi
    fi
    umount "$TOP"
    ui_text "Subvolumes found on $sel" "${subs:-(none)}" trunc

    if [ "$USE_LUKS" = true ]; then ask_change_luks_pass; fi

    if [ "$HOME_STATE" != none ]; then
        # The question is about DELETING, and the default button is No: just pressing Enter keeps your files.
        if yesno "An existing @home was found (your user files).${NL}${NL}Format @home?${NL}${NL}  No, keep @home    = your files stay untouched (default, recommended)${NL}  Yes, format @home = ALL user files are lost (you will be asked to confirm)" n "Yes, format @home" "No, keep @home"; then
            if ui_input "Delete @home?" "Deleting @home destroys ALL user files in it.${NL}Type DELETE-HOME to confirm (anything else keeps it):" ""; then a=$REPLY; else a=""; fi
            if [ "$a" = "DELETE-HOME" ]; then WIPE_HOME=true; else WIPE_HOME=false; ui_msg "@home" "Keeping @home."; fi
        else
            WIPE_HOME=false
        fi
    fi
    FORMAT_ROOT=false
    WARN_ACK=false
    return 0
}

# ---- PAGE: Root, mode 3 (manual: this partition is FORMATTED as Btrfs) ----
page_root_m3() {
    local sel luks=false pass=""
    if ! pick_part "Btrfs partition (root /)" "Choose the ROOT partition to FORMAT as Btrfs.${NL}EVERYTHING in it is lost (including any @home). To keep your home, use the Reinstall mode." false "$RAW_ROOT"; then
        return 1
    fi
    sel=$REPLY
    if [ "$sel" = "$BOOT_PART" ] || [ "$sel" = "$EFI_PART" ]; then
        ui_msg "Btrfs partition (root /)" "$sel is already chosen as /boot or EFI. Choose another partition."
        return 1
    fi
    if yesno "Encrypt the root partition with LUKS?" "$(dflt "$USE_LUKS")"; then
        if ! ask_new_pass "New LUKS passphrase"; then
            ui_msg "Btrfs partition (root /)" "No passphrase was set. The Btrfs page was not changed."
            return 1
        fi
        luks=true; pass=$REPLY
    fi
    RAW_ROOT=$sel; USE_LUKS=$luks; LUKS_PASS=$pass; ACTIVE_DEV=""
    FORMAT_ROOT=true; CREATE_ROOT=false
    WARN_ACK=false
    return 0
}

# ---- PAGE: /boot (modes 1 and 3). Mode 1 may also create it in free space. ----
page_boot() {
    local allow=false cands=() def="" txt sel c fmt=false
    if [ "$MODE" = 1 ]; then allow=true; fi
    mapfile -t cands < <(lsblk -nrpo NAME,FSTYPE "$DISK" | awk '$2=="ext4"{print $1}')
    if [ "$CREATE_BOOT" = true ]; then
        def=new
    elif [ -n "$BOOT_PART" ]; then
        def=$BOOT_PART
    else
        for c in "${cands[@]}"; do
            if [ "$c" != "$RAW_ROOT" ] && [ "$c" != "$EFI_PART" ] && ! is_live_part "$c"; then def=$c; break; fi
        done
        if [ -z "$def" ] && [ "$allow" = true ]; then def=new; fi
    fi
    if [ ${#cands[@]} -gt 0 ]; then
        txt="ext4 partitions found: ${cands[*]}${NL}One of them may be your old /boot."
    else
        txt="No existing /boot candidate (ext4) was found on $DISK."
    fi
    if ! pick_part "/boot partition" "$txt${NL}Choose the /boot partition (ext4, about 1-2 GiB):" "$allow" "$def"; then
        return 1
    fi
    sel=$REPLY
    if [ "$sel" = new ]; then
        BOOT_PART=""; CREATE_BOOT=true; FORMAT_BOOT=true; WARN_ACK=false
        return 0
    fi
    if [ "$sel" = "$RAW_ROOT" ] || [ "$sel" = "$EFI_PART" ]; then
        ui_msg "/boot partition" "$sel is already chosen as root/EFI. Choose another partition."
        return 1
    fi
    if ! size_sane "$sel" boot; then return 1; fi
    if [ "$(fstype_of "$sel")" != ext4 ]; then
        if ! yesno "$sel is not ext4.${NL}Format it as ext4? Everything on it is lost." y "Yes, format /boot" "No, choose another"; then return 1; fi
        fmt=true
    elif yesno "Format $sel as /boot?${NL}Formatting wipes it.${NL}(Default: Yes. Choose No to keep its files; old kernels are replaced either way.)" y "Yes, format /boot" "No, keep /boot"; then
        fmt=true
    elif ! boot_looks_ok "$sel"; then
        if ! yesno "$sel holds files that do not look like a /boot:${NL}$BOOT_ODD${NL}${NL}Use it as /boot anyway (those files stay untouched)?" n; then return 1; fi
    fi
    BOOT_PART=$sel; CREATE_BOOT=false; FORMAT_BOOT=$fmt; WARN_ACK=false
    return 0
}

# ---- PAGE: EFI (modes 1 and 3). Mode 1 may also create it in free space. ----
page_efi() {
    local allow=false efis=() def="" txt sel fmt=false
    if [ "$MODE" = 1 ]; then allow=true; fi
    mapfile -t efis < <(existing_efi_on_disk)
    if [ "$CREATE_EFI" = true ]; then
        def=new
    elif [ -n "$EFI_PART" ]; then
        def=$EFI_PART
    elif [ ${#efis[@]} -gt 0 ]; then
        def=${efis[0]}
    elif [ "$allow" = true ]; then
        def=new
    fi
    if [ ${#efis[@]} -gt 0 ]; then
        txt="EFI System Partition(s) found: ${efis[*]}"
    else
        txt="No EFI System Partition was found on $DISK."
    fi
    if ! pick_part "EFI partition" "$txt${NL}Choose the EFI partition (FAT32, 300 MiB - 2 GiB):" "$allow" "$def"; then
        return 1
    fi
    sel=$REPLY
    if [ "$sel" = new ]; then
        EFI_PART=""; CREATE_EFI=true; FORMAT_EFI=true; WARN_ACK=false
        return 0
    fi
    if [ "$sel" = "$RAW_ROOT" ] || [ "$sel" = "$BOOT_PART" ]; then
        ui_msg "EFI partition" "$sel is already chosen as root/boot. Choose another partition."
        return 1
    fi
    if ! size_sane "$sel" EFI; then return 1; fi
    if [ "$(fstype_of "$sel")" != vfat ]; then
        if ! yesno "$sel is not vfat.${NL}Format it as FAT32? Everything on it is lost." y "Yes, format EFI" "No, choose another"; then return 1; fi
        fmt=true
    elif yesno "Format $sel as EFI?${NL}Formatting wipes it, including Windows / other OS boot files.${NL}(Default: Yes. Choose No to keep it.)" y "Yes, format EFI" "No, keep EFI"; then
        fmt=true
    fi
    EFI_PART=$sel; CREATE_EFI=false; FORMAT_EFI=$fmt; WARN_ACK=false
    return 0
}

# ---- hub for modes 1 and 3: three independent pages ----
# Buttons: [ OK ] opens the highlighted line, [ Back ] leaves. The highlight moves on
# its own to the next page that is not set yet, and to "Done" when all three are set,
# so pressing Enter repeatedly walks you through the pages and then finishes.
# Returns 0 = leave, 2 = the user switched to mode 2 (the caller re-dispatches).
plan_hub() {
    local txt
    while true; do
        refresh_plan
        txt="Enter opens the highlighted line. Set Btrfs, Boot and EFI (each page is independent), then choose Done."
        if ! root_set; then UI_DEFAULT=Btrfs
        elif ! boot_set; then UI_DEFAULT=Boot
        elif ! efi_set; then UI_DEFAULT=EFI
        else UI_DEFAULT=Done; fi
        if ! ui_menu "Partitions - $(mode_name "$MODE")" "$txt" \
            Btrfs "$(brief_root)" \
            Boot  "$(brief_boot)" \
            EFI   "$(brief_efi)" \
            Mode  "Change the installation mode" \
            Check "Check the whole plan now" \
            Done  "Finish: go back to the main menu"; then
            return 0                       # Back: leave, everything set so far is kept
        fi
        case "$REPLY" in
            Btrfs) if [ "$MODE" = 1 ]; then page_root_m1 || true; else page_root_m3 || true; fi ;;
            Boot)  page_boot || true ;;
            EFI)   page_efi || true ;;
            Mode)  if choose_mode; then
                       if [ "$MODE" = 2 ] || [ "$MODE" = 4 ]; then refresh_plan; return 2; fi
                   fi ;;
            Check) refresh_plan
                   if [ "$PLAN_OK" != true ]; then
                       ui_msg "Check" "Set all three pages first (Btrfs, Boot, EFI)."
                   elif validate_plan; then
                       ui_msg "Check" "All checks passed. Nothing has been changed."
                   fi ;;
            Done)  refresh_plan
                   if [ "$PLAN_OK" != true ]; then
                       if yesno "Not all three pages are set yet.${NL}Leave anyway?" n; then return 0; fi
                   elif validate_plan; then
                       return 0
                   elif yesno "The plan has problems (see the message above).${NL}Leave anyway and fix it later?" n; then
                       return 0
                   fi ;;
        esac
    done
}

# ---- helpers: find / create the EFI and /boot partitions ----

# Largest contiguous free region on $DISK, in bytes (GPT/MBR; 0 if none).
largest_free_bytes() {
    parted -ms "$DISK" unit B print free 2>/dev/null \
        | awk -F: '$5 ~ /^free/ {gsub(/B/,"",$4); if ($4+0>m) m=$4+0} END{print m+0}'
}

# Prints EFI System partitions (vfat) found on $DISK, one per line.
existing_efi_on_disk() {
    local d t
    while read -r d t; do
        if [ "${t,,}" = "$EFI_PARTTYPE" ] && [ "$(fstype_of "$d")" = vfat ]; then echo "$d"; fi
    done < <(lsblk -nrpo NAME,PARTTYPE "$DISK" | awk 'NF==2')
    return 0
}

# Decide sizes from free bytes. $1 free bytes, $2 need EFI (true/false), $3 need boot.
decide_sizes() {
    local free_mib=$(( $1 / 1048576 )) min=0 good=0
    if [ "$2" = true ]; then min=$((min + MIN_EFI_MIB));  good=$((good + GOOD_EFI_MIB));  fi
    if [ "$3" = true ]; then min=$((min + MIN_BOOT_MIB)); good=$((good + GOOD_BOOT_MIB)); fi
    NEED_MIN_MIB=$((min + ALIGN_SLACK_MIB))
    if [ "$free_mib" -ge $((good + ALIGN_SLACK_MIB)) ]; then
        SIZE_TIER=comfortable; EFI_SIZE="+${GOOD_EFI_MIB}M"; BOOT_SIZE="+${GOOD_BOOT_MIB}M"
    elif [ "$free_mib" -ge "$NEED_MIN_MIB" ]; then
        SIZE_TIER=minimum; EFI_SIZE="+${MIN_EFI_MIB}M"; BOOT_SIZE="+${MIN_BOOT_MIB}M"
    else
        SIZE_TIER=none
    fi
    return 0
}

# Mode 2: install into FREE SPACE only. Nothing existing is formatted or deleted.
plan_mode2() {
    local pt free bigeff existing_efi="" efis=() txt
    pt=$(blkid -p -s PTTYPE -o value "$DISK" 2>/dev/null || true)
    if [ -z "$pt" ]; then
        if [ -n "$(list_parts)" ] || [ -n "$(blkid -p -s TYPE -o value "$DISK" 2>/dev/null || true)" ]; then
            plan_fail "$DISK has no recognizable partition table but contains data. Use manual mode."; return 0
        fi
        NEED_GPT=true
        ui_msg "Blank disk" "The disk is blank: a new GPT table will be created."
    elif [ "$pt" != gpt ]; then
        plan_fail "$DISK uses a '$pt' partition table. Auto mode needs GPT (use manual mode)."; return 0
    fi

    mapfile -t efis < <(existing_efi_on_disk)
    existing_efi=${efis[0]:-}
    bigeff=$((2 * 1024 * 1024 * 1024 + MIN_ROOT_BYTES))
    if [ -n "$existing_efi" ] && ! size_sane "$existing_efi" EFI; then
        ui_msg "EFI partition" "$existing_efi will NOT be reused; a new EFI partition will be created instead."
        existing_efi=""
    fi
    if [ -n "$existing_efi" ] && yesno "An existing EFI partition was found ($existing_efi).${NL}Reuse it? (recommended, it is NOT formatted)" y; then
        REUSE_EFI=true; EFI_PART=$existing_efi; FORMAT_EFI=false
    else
        bigeff=$((bigeff + 512 * 1024 * 1024)); FORMAT_EFI=true
    fi

    while true; do
        if [ "$NEED_GPT" = true ]; then free=$(lsblk -bdno SIZE "$DISK"); else free=$(largest_free_bytes); fi
        if [ "$free" -ge "$bigeff" ]; then break; fi
        txt="Not enough free space ($((free / 1024 / 1024 / 1024)) GiB). At least $((bigeff / 1024 / 1024 / 1024)) GiB are needed in ONE free block.${NL}Free up space with GParted (shrink/delete ANOTHER partition) from this live session."
        if ! ui_menu "Not enough free space" "$txt" r "Re-check free space"; then
            BACK_TO_MENU=true; return 0
        fi
    done

    EFI_SIZE="+512M"; BOOT_SIZE="+2G"
    if [ "$REUSE_EFI" = true ]; then CREATE_EFI=false; else CREATE_EFI=true; fi
    CREATE_BOOT=true; CREATE_ROOT=true
    FORMAT_ROOT=true; FORMAT_BOOT=true     # only the NEW partitions
    if yesno "Encrypt the new root partition with LUKS?" n; then
        if ask_new_pass "New LUKS passphrase"; then
            USE_LUKS=true; LUKS_PASS=$REPLY
        else
            plan_fail "No LUKS passphrase was set."; return 0
        fi
    fi
}

# Is any partition of the live system (the one we booted from) on $DISK?
disk_has_live_part() {
    local p
    for p in "${LIVE_PARTS[@]}"; do
        if [ -n "$p" ] && belongs_to_disk "$p"; then return 0; fi
    done
    return 1
}

# Asks the user to type the disk name. $1 = dialog title. Returns 1 if the user goes Back.
wipe_confirm() {
    local name=${DISK#/dev/}
    while true; do
        ui_input "$1" "THE WHOLE DISK $DISK WILL BE ERASED.${NL}Type the disk name ($name) to confirm (Back = cancel):" "" || return 1
        if [ "$REPLY" = "$name" ] || [ "$REPLY" = "$DISK" ]; then return 0; fi
        ui_msg "$1" "'$REPLY' does not match '$name'. Try again."
    done
}

# Mode 4: ERASE THE WHOLE DISK, then install with the free-space method on the blank disk.
# Planning only: nothing is touched here. The disk is really wiped later (do_partitioning),
# and only after the second typed confirmation on the final install screen.
plan_mode4() {
    local bytes need rofs lay txt
    if disk_has_live_part; then
        plan_fail "$DISK holds the live system you booted from. It cannot be wiped."; return 0
    fi
    bytes=$(lsblk -bdno SIZE "$DISK" 2>/dev/null || echo 0)
    rofs=$(rofs_bytes)
    need=$(( (512 + 2048 + 256) * 1048576 + (rofs > MIN_ROOT_BYTES ? rofs : MIN_ROOT_BYTES) ))
    if [ "$bytes" -lt "$need" ]; then
        plan_fail "$DISK is only $((bytes / 1073741824)) GiB; a full install needs about $((need / 1073741824 + 1)) GiB."; return 0
    fi
    lay=$(lsblk -o NAME,SIZE,FSTYPE,LABEL "$DISK" 2>&1 | head -n 8 || true)
    txt="ALL DATA ON $DISK WILL BE DESTROYED: every partition, every operating system, every file.${NL}${NL}Current layout:${NL}${lay}${NL}${NL}Afterwards the disk gets a NEW GPT with 3 new partitions (EFI 512 MiB, /boot 2 GiB, Btrfs = the rest) and Ubuntu is installed in them.${NL}Nothing is erased until you press INSTALL and confirm once more.${NL}${NL}Continue?"
    ui_dims
    if ! wt_box --title "WIPE ENTIRE DISK" --yes-button Continue --no-button Back --defaultno --yesno "$txt" "$UI_H" "$UI_W"; then
        BACK_TO_MENU=true; return 0
    fi
    if ! wipe_confirm "Wipe $DISK (confirmation 1 of 2)"; then BACK_TO_MENU=true; return 0; fi

    WIPE_DISK=true; NEED_GPT=true; REUSE_EFI=false
    CREATE_EFI=true; CREATE_BOOT=true; CREATE_ROOT=true
    FORMAT_ROOT=true; FORMAT_BOOT=true; FORMAT_EFI=true
    EFI_SIZE="+512M"; BOOT_SIZE="+2G"
    if yesno "Encrypt the new root partition with LUKS?" n; then
        if ask_new_pass "New LUKS passphrase"; then
            USE_LUKS=true; LUKS_PASS=$REPLY
        else
            plan_fail "No LUKS passphrase was set."; return 0
        fi
    fi
}

# Mode 4, run again: keep, re-plan, or change mode. Returns like plan_mode2_run.
plan_mode4_run() {
    if [ "$PLAN_OK" = true ] && [ "$MODE" = 4 ]; then
        if ! ui_menu "Wipe-disk plan" "$(plan_brief)" \
            k "Keep this plan" r "Plan again (asks for the disk name again)" m "Change the installation mode"; then
            return 0
        fi
        case "$REPLY" in
            k) return 0 ;;
            m) reset_plan; return 2 ;;
        esac
    fi
    reset_plan; MODE=4
    BACK_TO_MENU=false
    plan_mode4
    if [ "$BACK_TO_MENU" = true ]; then reset_plan; return 2; fi
    refresh_plan
    while true; do
        if validate_plan; then return 0; fi
        if ! ui_menu "The plan has problems" "Fix the cause, then re-check." \
            r "Re-check now" m "Plan again from the mode menu"; then
            reset_plan; return 1
        fi
        if [ "$REPLY" = m ]; then reset_plan; return 2; fi
    done
}

reset_plan() {
    if [ "$LUKS_OPENED" = true ]; then cryptsetup close "$MAPPER" 2>/dev/null || true; LUKS_OPENED=false; fi
    if findmnt -rn "$TOP" >/dev/null 2>&1; then umount "$TOP" 2>/dev/null || true; fi
    MODE=""
    RAW_ROOT=""; ACTIVE_DEV=""; BOOT_PART=""; EFI_PART=""
    USE_LUKS=false; LUKS_PASS=""; LUKS_UUID=""
    CHANGE_LUKS_PASS=false; LUKS_OLDPASS=""; LUKS_NEWPASS=""
    FORMAT_ROOT=false; FORMAT_BOOT=false; FORMAT_EFI=false
    CREATE_EFI=false; CREATE_BOOT=false; CREATE_ROOT=false
    EFI_SIZE="+512M"; BOOT_SIZE="+2G"; SIZE_TIER=none; NEED_MIN_MIB=0
    NEED_GPT=false; REUSE_EFI=false; BACK_TO_MENU=false; WIPE_DISK=false
    HOME_STATE=none; ROOT_STATE=none; WIPE_HOME=false
    OLD_AT_EXCL=""; BOOT_ODD=""; LUKS_EXT_NAME=""
    PLAN_OK=false; WARN_ACK=false
}

# ============================================================
# 3b. Validate the whole plan BEFORE anything is touched
# ============================================================
verr()  { VERR+=("$*"); }
vwarn() { VWARN+=("$*"); }

validate_plan() {
    VERR=(); VWARN=()
    local d mib ss emin free need rofs rootb avail room out m mt txt pt freeb
    ui_info "Checking the plan (nothing is changed)..."

    if [ "$(blockdev --getro "$DISK" 2>/dev/null || echo 0)" = 1 ]; then verr "$DISK is read-only."; fi

    # the three partitions must be three different ones
    if [ -n "$RAW_ROOT" ] && { [ "$RAW_ROOT" = "$BOOT_PART" ] || [ "$RAW_ROOT" = "$EFI_PART" ]; }; then
        verr "The root partition $RAW_ROOT is also chosen as /boot or EFI. Change the Boot or EFI page."
    fi
    if [ -n "$BOOT_PART" ] && [ "$BOOT_PART" = "$EFI_PART" ]; then
        verr "$BOOT_PART is chosen as both /boot and EFI. Change one of the pages."
    fi

    for d in "$RAW_ROOT" "$BOOT_PART" "$EFI_PART"; do
        if [ -n "$d" ]; then
            if [ ! -b "$d" ]; then
                verr "$d does not exist any more."
            elif is_live_part "$d"; then
                verr "$d holds the live system you booted from; it is protected. Choose another partition."
            else
                mt=$(findmnt -rn -S "$d" -o TARGET 2>/dev/null | head -n1 || true)
                if [ -n "$mt" ]; then
                    unmount_everything_on "$d"      # release it automatically
                    mt=$(findmnt -rn -S "$d" -o TARGET 2>/dev/null | head -n1 || true)
                    if [ -n "$mt" ]; then verr "$d is still mounted at $mt and could not be released (something is using it)."; fi
                fi
            fi
        fi
    done

    rofs=$(rofs_bytes)
    need=$(( rofs > MIN_ROOT_BYTES ? rofs : MIN_ROOT_BYTES ))

    # ---- EFI ----
    if [ -n "$EFI_PART" ] && [ -b "$EFI_PART" ]; then
        mib=$(( $(lsblk -bdno SIZE "$EFI_PART") / 1048576 ))
        ss=$(blockdev --getss "$EFI_PART" 2>/dev/null || echo 512)
        emin=64
        if [ "$ss" -ge 4096 ]; then emin=260; fi
        if [ "$FORMAT_EFI" = true ] && [ "$mib" -lt "$emin" ]; then
            verr "$EFI_PART is only ${mib} MiB; FAT32 needs at least ${emin} MiB on this disk."
        fi
        if [ "$FORMAT_EFI" != true ]; then
            free=$(part_free_mib "$EFI_PART" || true)
            if [ -z "$free" ]; then
                vwarn "Could not inspect $EFI_PART; its free space was not checked."
            elif [ "$free" -lt 15 ]; then
                verr "EFI partition $EFI_PART has only ${free} MiB free (GRUB needs ~15 MiB). Free some space in it."
            fi
        fi
    fi

    # ---- /boot ----
    if [ -n "$BOOT_PART" ] && [ -b "$BOOT_PART" ]; then
        mib=$(( $(lsblk -bdno SIZE "$BOOT_PART") / 1048576 ))
        if [ "$mib" -lt "$MIN_EXIST_BOOT_MIB" ]; then
            verr "$BOOT_PART is only ${mib} MiB; /boot needs at least ${MIN_EXIST_BOOT_MIB} MiB (kernel + initrd)."
        fi
    fi

    # ---- root space ----
    if [ "$MODE" = 3 ] && [ -b "$RAW_ROOT" ]; then
        rootb=$(lsblk -bdno SIZE "$RAW_ROOT")
        if [ "$rootb" -lt $((need + 256 * 1024 * 1024)) ]; then
            verr "$RAW_ROOT is $((rootb / 1048576)) MiB; the system needs about $(( (need + 256 * 1024 * 1024) / 1048576 )) MiB."
        fi
    fi
    if [ "$MODE" = 1 ] && [ -n "$ACTIVE_DEV" ]; then
        if mount -o ro,subvolid=5 "$ACTIVE_DEV" "$TOP" 2>/dev/null; then
            avail=$(df -B1 --output=avail "$TOP" | tail -n1 | tr -d ' ')
            room=$avail
            if [ -e "$TOP/@" ]; then
                if [ -z "$OLD_AT_EXCL" ]; then
                    ui_info "Measuring the old @ to know how much space deleting it frees (read-only, up to 2 min)..."
                    OLD_AT_EXCL=$(timeout 120 btrfs filesystem du -s --raw "$TOP/@" 2>/dev/null | awk 'END{ if (NF>=2) print $2+0; else print -1 }' || true)
                    if [ -z "$OLD_AT_EXCL" ]; then OLD_AT_EXCL=-1; fi
                fi
                if [ "$OLD_AT_EXCL" -ge 0 ]; then room=$((avail + OLD_AT_EXCL)); fi
            fi
            umount "$TOP"
            if [ "$room" -lt $((need + 256 * 1024 * 1024)) ]; then
                m="After deleting the old @ only ~$((room / 1048576)) MiB would be free; the new system needs ~$(( (need + 256 * 1024 * 1024) / 1048576 )) MiB. Free space in @home or elsewhere on that volume."
                if [ "$OLD_AT_EXCL" = -1 ] && [ "$ROOT_STATE" = present ]; then
                    vwarn "Could not measure the old @, space may be tight. $m"
                else
                    verr "$m"
                fi
            fi
        else
            verr "Could not mount $ACTIVE_DEV read-only to check its free space."
        fi
    fi

    # ---- mode 4: the whole disk is wiped ----
    if [ "$MODE" = 4 ]; then
        if [ "$WIPE_DISK" != true ]; then
            verr "Wipe mode is not confirmed. Plan it again."
        elif [ ! -b "$DISK" ]; then
            verr "$DISK does not exist any more."
        elif disk_has_live_part; then
            verr "$DISK holds the live system you booted from; it cannot be wiped."
        else
            mib=$(( $(lsblk -bdno SIZE "$DISK") / 1048576 ))
            emin=$(( 512 + 2048 + (need + 256 * 1024 * 1024) / 1048576 ))
            if [ "$mib" -lt "$emin" ]; then
                verr "$DISK is only ${mib} MiB; a full install needs about ${emin} MiB."
            fi
        fi
    fi

    # ---- free space for NEW EFI / boot partitions (mode 1; mode 2 checks it while planning) ----
    if [ "$MODE" = 1 ] && { [ "$CREATE_EFI" = true ] || [ "$CREATE_BOOT" = true ]; }; then
        pt=$(blkid -p -s PTTYPE -o value "$DISK" 2>/dev/null || true)
        freeb=0; SIZE_TIER=none
        if [ "$pt" = gpt ]; then
            freeb=$(largest_free_bytes)
            decide_sizes "$freeb" "$CREATE_EFI" "$CREATE_BOOT"
        fi
        if [ "$SIZE_TIER" = none ]; then
            if [ "$pt" != gpt ]; then
                verr "$DISK uses a '${pt:-unknown}' partition table: new partitions can only be created automatically on GPT disks. Pick existing EFI / boot partitions instead."
            else
                verr "Not enough free space on $DISK for the NEW EFI/boot partition(s): largest free block $((freeb / 1048576)) MiB, minimum needed ${NEED_MIN_MIB} MiB. Free space with GParted (shrink/delete ANOTHER partition, not the Btrfs one), or pick existing partitions."
            fi
        elif [ "$SIZE_TIER" = minimum ] && [ "$CREATE_BOOT" = true ]; then
            vwarn "Limited free space: minimum sizes will be used. A 1 GiB /boot holds about 3 kernels; run 'sudo apt autoremove' now and then."
        fi
    fi

    # ---- partition table health when we are going to write to it ----
    if [ "$CREATE_EFI" = true ] || [ "$CREATE_BOOT" = true ] || [ "$CREATE_ROOT" = true ]; then
        if [ "$NEED_GPT" != true ]; then
            out=$(sgdisk -v "$DISK" 2>&1 || true)
            if ! grep -q 'No problems found' <<<"$out"; then
                vwarn "The GPT on $DISK reports problems (see: sudo sgdisk -v $DISK). Repairing it first with GParted/gdisk is safer."
            fi
        fi
    fi

    # ---- LUKS ----
    if [ "$USE_LUKS" = true ]; then
        if ! modprobe dm_crypt 2>/dev/null; then verr "The kernel cannot load dm_crypt (needed for LUKS)."; fi
    fi

    if [ ${#VERR[@]} -gt 0 ]; then
        txt="The plan cannot be carried out as it is:"
        for m in "${VERR[@]}"; do txt+="${NL}  x $m"; done
        txt+="${NL}${NL}Fix the cause (GParted in another terminal works), or change the pages in Partitions, then try again."
        ui_text "Plan check failed" "$txt"
        return 1
    fi
    if [ ${#VWARN[@]} -gt 0 ] && [ "$WARN_ACK" != true ]; then
        txt="Warnings:"
        for m in "${VWARN[@]}"; do txt+="${NL}  ! $m"; done
        txt+="${NL}${NL}Continue despite the warnings?"
        yesno "$txt" n || return 1
        WARN_ACK=true
    fi
    return 0
}

# Mode 2 only, run again: keep, re-plan, or change mode.
# Returns 0 = done, 1 = leave Partitions, 2 = back to the mode menu.
plan_mode2_run() {
    if [ "$PLAN_OK" = true ] && [ "$MODE" = 2 ]; then
        if ! ui_menu "Free-space plan" "$(plan_brief)" \
            k "Keep this plan" r "Plan again" m "Change the installation mode"; then
            return 0
        fi
        case "$REPLY" in
            k) return 0 ;;
            m) reset_plan; return 2 ;;
        esac
    fi
    reset_plan; MODE=2
    BACK_TO_MENU=false
    plan_mode2
    if [ "$BACK_TO_MENU" = true ]; then reset_plan; return 2; fi
    refresh_plan
    while true; do
        if validate_plan; then return 0; fi
        if ! ui_menu "The plan has problems" "Fix the cause (for example with GParted in another terminal), then re-check." \
            r "Re-check now" m "Plan again from the mode menu"; then
            reset_plan; return 1
        fi
        if [ "$REPLY" = m ]; then reset_plan; return 2; fi
    done
}

# Entry point of the "Partitions" menu item.
run_plan() {
    local rc
    if [ -z "$DISK" ]; then ui_msg "Partitions" "Select the disk first."; return 1; fi
    while true; do
        if [ -z "$MODE" ]; then
            if ! choose_mode; then refresh_plan; return 1; fi
        fi
        rc=0
        if [ "$MODE" = 2 ]; then
            plan_mode2_run || rc=$?
            if [ "$rc" -eq 2 ]; then continue; fi
            refresh_plan
            return "$rc"
        fi
        if [ "$MODE" = 4 ]; then
            plan_mode4_run || rc=$?
            if [ "$rc" -eq 2 ]; then continue; fi
            refresh_plan
            return "$rc"
        fi
        plan_hub || rc=$?
        if [ "$rc" -eq 2 ]; then continue; fi
        refresh_plan
        return 0
    done
}

# ============================================================
# 4. Options (each one can be changed again from the main menu)
# ============================================================

# When a home is KEPT, the username should match one of its folders; otherwise the
# user would get a new empty home and the old files would stay unused under the old name.
match_user_to_home() {
    local homes=() h items=()
    if [ "$MODE" != 1 ] || [ "$HOME_STATE" = none ] || [ "$WIPE_HOME" = true ]; then return 0; fi
    if [ -z "$ACTIVE_DEV" ] || [ -z "$NEW_USER" ]; then return 0; fi
    if ! mount -o ro,subvolid=5 "$ACTIVE_DEV" "$TOP" 2>/dev/null; then return 0; fi
    mapfile -t homes < <(find "$TOP/@home" -mindepth 1 -maxdepth 1 -type d ! -name '.*' ! -name 'lost+found' -printf '%f\n' 2>/dev/null | sort)
    umount "$TOP"
    if [ ${#homes[@]} -eq 0 ]; then return 0; fi
    for h in "${homes[@]}"; do
        if [ "$h" = "$NEW_USER" ]; then return 0; fi
    done
    for h in "${homes[@]}"; do items+=("$h" "Log in with your old files in /home/$h"); done
    items+=("__new__" "Keep '$NEW_USER' with a NEW EMPTY home")
    if ui_menu "Kept @home" "Your kept @home has these folders: ${homes[*]}${NL}'$NEW_USER' is not one of them, so it would get a NEW EMPTY home and your old files would stay unused. Which name do you want?" "${items[@]}"; then
        if [ "$REPLY" != "__new__" ] && [[ $REPLY =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]; then
            NEW_USER=$REPLY
            ui_msg "Username" "Username set to '$NEW_USER' (matches the kept home)."
        fi
    fi
    return 0
}

ask_username() { # returns 1 if the user went Back (old value kept)
    local u
    while true; do
        ui_input "Username" "Lowercase letters, digits, _ or - (max 32)." "$NEW_USER" || return 1
        u=$REPLY
        if [[ $u =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]; then break; fi
        ui_msg "Username" "Invalid name. Use lowercase letters, digits, _ or - (max 32)."
    done
    NEW_USER=$u
    match_user_to_home
    return 0
}

ask_password() {
    if [ -z "$NEW_USER" ]; then ui_msg "Password" "Set the username first."; return 1; fi
    if ask_new_pass "Password for $NEW_USER"; then
        NEW_PASS=$REPLY
        if [ "${#NEW_PASS}" -lt 8 ]; then
            ui_msg "Password" "This password is shorter than 8 characters. It is accepted, but a longer one is safer (you can change it later with: passwd)."
        fi
    fi
    return 0
}

ask_hostname() {
    local h
    while true; do
        ui_input "Hostname" "Letters, digits and - only (max 63)." "$NEW_HOST" || return 1
        h=$REPLY
        if [[ $h =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,62})$ ]]; then NEW_HOST=$h; return 0; fi
        ui_msg "Hostname" "Invalid hostname."
    done
}

ask_timezone() {
    local z
    while true; do
        ui_input "Timezone" "For example Africa/Cairo, Europe/Berlin, America/New_York." "$NEW_TZ" || return 1
        z=$REPLY
        if [[ $z != *..* ]] && [ -f "/usr/share/zoneinfo/$z" ]; then NEW_TZ=$z; return 0; fi
        ui_msg "Timezone" "Unknown timezone: $z"
    done
}

ask_codecs() {
    if yesno "Install restricted media codecs (ubuntu-restricted-extras)?${NL}Needs internet." "$(dflt "$WANT_CODECS")"; then WANT_CODECS=true; else WANT_CODECS=false; fi
}
ask_drivers() {
    if yesno "Install proprietary hardware drivers?${NL}Needs internet." "$(dflt "$WANT_DRIVERS")"; then WANT_DRIVERS=true; else WANT_DRIVERS=false; fi
}
ask_extras() {
    if yesno "Power-user extras (ZRAM, Timeshift, Discover, Flatpak, your own programs)?${NL}Needs internet." "$(dflt "$WANT_EXTRAS")"; then WANT_EXTRAS=true; else WANT_EXTRAS=false; fi
}

ask_ui() {
    local txt
    txt="UI customization - apply these Ubuntu desktop settings on the new system?${NL}"
    txt+="${NL}  - Dock: at the bottom, auto-hide, icons 48 px, no mounts / trash icons"
    txt+="${NL}  - Wallpaper: Bluebells (light) / Winter Grand Triangle (dark), zoom"
    txt+="${NL}  - Accent colour: blue"
    txt+="${NL}${NL}Needs no internet. You can change all of it later in Settings."
    if yesno "$txt" "$(dflt "$WANT_UI")"; then WANT_UI=true; else WANT_UI=false; fi
}

# Everything that needs internet is checked NOW, not in the middle of the install.
# Returns 0 = fine, 1 = the user went Back.
validate_options() {
    local why hard txt w items
    while true; do
        why=(); hard=false
        if ! ls "$ROFS"/boot/vmlinuz-* >/dev/null 2>&1; then
            why+=("a kernel (the live image has none to copy)"); hard=true
        fi
        if [ ! -d "$ROFS/usr/lib/grub/x86_64-efi" ] && [ ! -d /usr/lib/grub/x86_64-efi ]; then
            why+=("GRUB EFI modules (grub-efi-amd64-bin, needed for the bootloader)"); hard=true
        fi
        if [ "$USE_LUKS" = true ] && ! rofs_has_pkg cryptsetup-initramfs; then
            why+=("cryptsetup-initramfs (needed to unlock the encrypted disk at boot)"); hard=true
        fi
        if [ "$WANT_CODECS" = true ];  then why+=("restricted media codecs"); fi
        if [ "$WANT_DRIVERS" = true ]; then why+=("proprietary drivers"); fi
        if [ "$WANT_EXTRAS" = true ];  then why+=("power-user extras"); fi
        if [ ${#why[@]} -eq 0 ]; then return 0; fi
        ui_info "Checking the internet connection..."
        if have_net; then return 0; fi

        txt="NO INTERNET. The install needs it for:"
        for w in "${why[@]}"; do txt+="${NL}  - $w"; done
        items=(r "Re-check (connect Wi-Fi / cable first)")
        if [ "$hard" != true ]; then items+=(c "Continue WITHOUT the optional extras (install them after the first boot)"); fi
        if ! ui_menu "No internet" "$txt" "${items[@]}"; then return 1; fi
        if [ "$REPLY" = c ]; then WANT_CODECS=false; WANT_DRIVERS=false; WANT_EXTRAS=false; return 0; fi
    done
}

# ============================================================
# 5. Summary, review and final confirmation
# ============================================================
typed_confirm() { # $1 device ; returns 1 if the user gives up
    local name=${1#/dev/}
    while true; do
        ui_input "Confirm erase" "Type '$name' to confirm it will be ERASED (Back = abort):" "" || return 1
        if [ "$REPLY" = "$name" ]; then return 0; fi
        ui_msg "Confirm erase" "Does not match."
    done
}

summary_text() {
    echo "Disk              : $DISK"
    if [ "$WIPE_DISK" = true ]; then
        echo "WHOLE DISK        : ERASED - every partition and all data on $DISK is destroyed"
        echo "Partition table   : NEW GPT with 3 new partitions"
    elif [ "$NEED_GPT" = true ]; then echo "Partition table   : NEW GPT (blank disk)"; fi
    if [ "$CREATE_ROOT" = true ]; then
        echo "Btrfs partition   : NEW, uses the rest of the free space"
    else
        echo "Btrfs partition   : $RAW_ROOT ($(sz_of "$RAW_ROOT")) $([ "$FORMAT_ROOT" = true ] && echo "-> FORMATTED (everything on it incl. any @home is lost)" || echo "(kept, not formatted)")"
    fi
    if [ "$CREATE_BOOT" = true ]; then
        echo "Boot partition    : NEW ${BOOT_SIZE#+}iB, created in free space"
    else
        echo "Boot partition    : $BOOT_PART ($(sz_of "$BOOT_PART")) $([ "$FORMAT_BOOT" = true ] && echo "-> FORMATTED" || echo "(kept, only old kernels replaced)")"
    fi
    if [ "$CREATE_EFI" = true ]; then
        echo "EFI partition     : NEW ${EFI_SIZE#+}iB, created in free space"
    else
        echo "EFI partition     : $EFI_PART ($(sz_of "$EFI_PART")) $([ "$FORMAT_EFI" = true ] && echo "-> FORMATTED" || echo "(kept, not formatted)")"
    fi
    echo "LUKS encryption   : $USE_LUKS"
    if [ "$CHANGE_LUKS_PASS" = true ]; then echo "LUKS passphrase   : will be CHANGED to the new one you entered"; fi
    if [ "$MODE" = 1 ]; then
        echo "Subvolume @       : $([ "$ROOT_STATE" = present ] && echo "existing one DELETED and recreated" || echo "created")"
        case "$HOME_STATE:$WIPE_HOME" in
            none:*)     echo "Subvolume @home   : will be created (empty)" ;;
            *:true)     echo "Subvolume @home   : DELETED (you typed DELETE-HOME)" ;;
            subvol:*)   echo "Subvolume @home   : KEPT untouched" ;;
            dir:*)      echo "Subvolume @home   : KEPT (plain folder -> copied into a new @home subvolume, original kept as @home.olddir-<date>)" ;;
        esac
        echo "Other subvolumes  : untouched"
    elif [ "$MODE" = 2 ]; then
        echo "Existing data     : NOTHING existing is erased"
    else
        echo "Subvolume @home   : created empty on the new filesystem"
    fi
    echo "User / host / tz  : $NEW_USER / $NEW_HOST / $NEW_TZ"
    echo "Codecs / drivers / extras : $WANT_CODECS / $WANT_DRIVERS / $WANT_EXTRAS"
    echo "UI customization  : $WANT_UI"
}

# Every EXISTING partition that will be erased is listed in ONE warning box: OK = go on,
# Cancel = back to the main menu. Small partitions (under 5 GiB: EFI, /boot) need nothing
# more. A BIG partition (5 GiB or more, normally the Btrfs root) still has to be
# confirmed by typing its name. Returns 1 if the user gives up, 0 to go ahead.
SMALL_ERASE_BYTES=$((5 * 1024 * 1024 * 1024))
final_confirm() {
    local risky=() big=() r txt sz lay
    if [ "$WIPE_DISK" = true ]; then
        lay=$(lsblk -o NAME,SIZE,FSTYPE,LABEL "$DISK" 2>&1 | head -n 8 || true)
        txt="!!! WHOLE DISK WILL BE ERASED !!!${NL}${NL}Disk: $DISK  ($(lsblk -dno SIZE,MODEL "$DISK" 2>/dev/null | tr -s ' ' | cut -c1-40 || true))${NL}${lay}${NL}${NL}EVERYTHING on this disk will be destroyed and Ubuntu installed from scratch.${NL}OK = continue to the last confirmation.   Cancel = go back, nothing is changed."
        ui_dims
        if ! wt_box --title "FINAL WARNING" --yes-button OK --no-button Cancel --defaultno --yesno "$txt" "$UI_H" "$UI_W"; then
            ui_msg "Cancelled" "Nothing was changed."; return 1
        fi
        if ! wipe_confirm "Wipe $DISK (confirmation 2 of 2)"; then
            ui_msg "Aborted" "Not confirmed. Nothing was changed."; return 1
        fi
        return 0
    fi
    if [ "$FORMAT_ROOT" = true ] && [ -n "$RAW_ROOT" ] && [ "$CREATE_ROOT" != true ]; then risky+=("$RAW_ROOT"); fi
    if [ "$FORMAT_BOOT" = true ] && [ -n "$BOOT_PART" ] && [ "$CREATE_BOOT" != true ]; then risky+=("$BOOT_PART"); fi
    if [ "$FORMAT_EFI" = true ]  && [ -n "$EFI_PART" ]  && [ "$CREATE_EFI" != true ];  then risky+=("$EFI_PART"); fi
    if [ ${#risky[@]} -eq 0 ]; then return 0; fi

    txt="These EXISTING partitions will be ERASED:"
    for r in "${risky[@]}"; do
        txt+="${NL}  $r  size=$(lsblk -dno SIZE "$r")  fs=$(fstype_of "$r")  label=$(lsblk -dno LABEL "$r")"
        sz=$(lsblk -dnbo SIZE "$r" 2>/dev/null | tr -d ' ' || true)
        if ! [[ $sz =~ ^[0-9]+$ ]] || [ "$sz" -ge "$SMALL_ERASE_BYTES" ]; then big+=("$r"); fi
    done
    txt+="${NL}${NL}OK = erase them and continue.   Cancel = go back, nothing is changed."
    if [ ${#big[@]} -gt 0 ]; then
        txt+="${NL}(Big partitions need you to type their name next.)"
    fi
    ui_dims
    if ! wt_box --title "WARNING" --yes-button OK --no-button Cancel --defaultno --yesno "$txt" 0 "$UI_W"; then
        ui_msg "Cancelled" "Nothing was changed."
        return 1
    fi
    for r in "${big[@]}"; do
        if ! typed_confirm "$r"; then ui_msg "Aborted" "Not confirmed. Nothing was changed."; return 1; fi
    done
    return 0
}

# Everything needed is set? Re-check, show the summary, confirm. 0 = go ahead.
do_review_install() {
    local miss=""
    refresh_plan
    if [ -z "$DISK" ]; then miss+="${NL}  - Disk"; fi
    if [ "$PLAN_OK" != true ]; then
        if [ -z "$MODE" ]; then miss+="${NL}  - Partitions (choose a mode)"; else
            if ! root_set; then miss+="${NL}  - Partitions: Btrfs page"; fi
            if ! boot_set; then miss+="${NL}  - Partitions: Boot page"; fi
            if ! efi_set;  then miss+="${NL}  - Partitions: EFI page"; fi
        fi
    fi
    if [ -z "$NEW_USER" ]; then miss+="${NL}  - Username"; fi
    if [ -z "$NEW_PASS" ]; then miss+="${NL}  - Password"; fi
    if [ -n "$miss" ]; then ui_msg "Not ready yet" "Please set first:$miss"; return 1; fi

    validate_plan || return 1
    validate_options || return 1

    ui_dims
    local rtxt st=()
    rtxt="$(summary_text)${NL}${NL}Start the installation?"
    if [ "$(text_rows "$rtxt")" -gt $((UI_H - 7)) ]; then st=(--scrolltext); fi
    if ! wt_box --title "Review - nothing has been changed yet" "${st[@]}" --yes-button Install --no-button Back --defaultno \
        --yesno "$rtxt" "$UI_H" "$UI_W"; then
        return 1
    fi
    final_confirm || return 1
    return 0
}

# ============================================================
# 5b. Main menu (archinstall style)
# ============================================================
yn() { if [ "$1" = true ]; then echo "yes"; else echo "no"; fi; }

lbl_disk() {
    if [ -z "$DISK" ]; then echo "(not selected)"; return 0; fi
    echo "$DISK  $(lsblk -dno SIZE,MODEL "$DISK" 2>/dev/null | tr -s ' ' | cut -c1-40 || true)"
}

# Value shown next to "Partitions": the mode and how many of the 3 pages are set.
lbl_plan() {
    local n=0 name
    if [ -z "$MODE" ]; then echo "(not planned yet)"; return 0; fi
    if root_set; then n=$((n + 1)); fi
    if boot_set; then n=$((n + 1)); fi
    if efi_set;  then n=$((n + 1)); fi
    case "$MODE" in 1) name="Reinstall" ;; 2) name="Free space" ;; 4) name="WIPE DISK" ;; *) name="Manual" ;; esac
    if [ "$n" -eq 3 ]; then echo "$name - ready (3/3 set)"; else echo "$name - $n/3 set"; fi
}

main_menu() { # returns 0 when the user confirmed the installation
    local sel="" pw txt
    # Internet found -> Codecs / Drivers / Extras start as YES, otherwise NO.
    # Nothing is downloaded here; the install itself re-checks the connection.
    ui_info "Checking the internet connection..."
    if have_net; then
        WANT_CODECS=true; WANT_DRIVERS=true; WANT_EXTRAS=true
    else
        WANT_CODECS=false; WANT_DRIVERS=false; WANT_EXTRAS=false
    fi
    while true; do
        pw="(not set)"; if [ -n "$NEW_PASS" ]; then pw="********"; fi
        refresh_plan
        txt="Enter = open, Esc = quit. Nothing changes until INSTALL.${NL}$(plan_brief)"
        UI_DEFAULT=$sel
        if ui_menu "Ubuntu Btrfs Installer" "$txt" \
            Disk        "$(lbl_disk)" \
            Partitions  "$(lbl_plan)" \
            Username    "${NEW_USER:-(not set)}" \
            Password    "$pw" \
            Hostname    "$NEW_HOST" \
            Timezone    "$NEW_TZ" \
            Codecs      "$(yn "$WANT_CODECS") (needs internet)" \
            Drivers     "$(yn "$WANT_DRIVERS") (needs internet)" \
            Extras      "$(yn "$WANT_EXTRAS") (needs internet)" \
            "UI customization" "$(yn "$WANT_UI") (dock, wallpaper, accent)" \
            INSTALL     "Review and start the installation" \
            Quit        "Leave without installing"; then
            sel=$REPLY
        else
            sel=Quit
        fi
        case "$sel" in
            Disk)       select_disk || true ;;
            Partitions) run_plan || true
                        if [ "$PLAN_OK" = true ] && [ -n "$NEW_USER" ]; then match_user_to_home; fi ;;
            Username)   ask_username || true ;;
            Password)   ask_password || true ;;
            Hostname)   ask_hostname || true ;;
            Timezone)   ask_timezone || true ;;
            Codecs)     ask_codecs;  validate_options || true ;;
            Drivers)    ask_drivers; validate_options || true ;;
            Extras)     ask_extras;  validate_options || true ;;
            "UI customization") ask_ui ;;
            INSTALL)    if do_review_install; then return 0; fi ;;
            Quit)       if yesno "Quit the installer?${NL}Nothing has been changed." y; then exit 0; fi ;;
        esac
    done
}

# ============================================================
# 6. Execution - every step stops IN PLACE on failure (retry / shell / abort)
# ============================================================
run_step() { # $1 title, $2 function
    local title=$1 fn=$2 rc c
    while true; do
        msg "$title"
        set +e
        (
            set -Ee
            trap 'save_state' EXIT
            trap 'echo -e "${C_RED}[ERROR] line $LINENO: $BASH_COMMAND${C_RST}" >&2' ERR
            "$fn"
        )
        rc=$?
        set -e
        if [ -f "$STATE_FILE" ]; then . "$STATE_FILE"; fi
        if [ $rc -eq 0 ]; then ok "$title - done"; return 0; fi
        if [ $rc -ge 128 ]; then exit "$rc"; fi

        while true; do
            echo -e "\n${C_RED}=== STEP FAILED: $title ===${C_RST}"
            echo "Everything done so far is kept. Fix the cause, then choose:"
            echo "  r) retry this step (continues where it stopped)"
            echo "  s) open a shell to fix it (type 'exit' to come back here)"
            echo "  a) abort (all mounts are released, nothing else is deleted)"
            read -r -p "Choice [r/s/a]: " c
            case "$c" in
                s|S) echo -e "${C_CYN}Shell opened. Type 'exit' to return to the installer.${C_RST}"
                     bash -i </dev/tty >/dev/tty 2>&1 || true ;;
                a|A) die "Aborted by user at step: $title" ;;
                *)   break ;;
            esac
        done
    done
}

part_dev() { if [[ $DISK_NAME =~ [0-9]$ ]]; then echo "${DISK}p$1"; else echo "${DISK}$1"; fi; }

wait_dev() { # $1 device node must appear
    local i
    for i in $(seq 1 20); do
        if [ -b "$1" ]; then return 0; fi
        partx -a "$DISK" 2>/dev/null || true
        partx -u "$DISK" 2>/dev/null || true
        partprobe "$DISK" 2>/dev/null || true
        udevadm settle
        sleep 1
    done
    die "Partition $1 did not appear. Check 'lsblk'; once it exists, choose retry."
}

# Creates ONE partition in free space. The partition number/device is fixed BEFORE
# sgdisk runs, and the flag is cleared right after, so a retry never creates it twice.
create_part() { # $1 end spec, $2 type code, $3 label, $4 partition var, $5 create-flag var
    local n=1 dev used
    used=$(sgdisk -p "$DISK" 2>/dev/null | awk '$1 ~ /^[0-9]+$/ {print $1}' || true)
    while grep -qx "$n" <<<"$used"; do n=$((n + 1)); done
    dev=$(part_dev "$n")
    sgdisk -n "$n:0:$1" -t "$n:$2" -c "$n:$3" "$DISK" >/dev/null
    printf -v "$4" '%s' "$dev"
    printf -v "$5" '%s' false
    wait_dev "$dev"
    if [ "$WIPE_DISK" = true ]; then wipefs -a -f "$dev" >/dev/null 2>&1 || true; fi
}

# Mode 4 only. Destroys EVERYTHING on $DISK (partition table, signatures, LVM/md/LUKS layers).
# Runs once: DONE_WIPE is saved, so a retry never wipes the partitions created afterwards.
wipe_whole_disk() {
    local p t
    msg "WIPING the whole disk $DISK (all partitions and data are destroyed)"
    if disk_has_live_part; then die "$DISK holds the live system; refusing to wipe it."; fi
    force_unmount_disk
    # LVM / md / LUKS layers on top of this disk, deepest first
    while read -r p t; do
        case "$t" in
            raid*|md) if command -v mdadm >/dev/null 2>&1; then mdadm --stop "$p" 2>/dev/null || true; fi ;;
            *)        dmsetup remove --retry "$p" 2>/dev/null || true ;;
        esac
    done < <(lsblk -nrpo NAME,TYPE "$DISK" 2>/dev/null | awk '$2!="disk" && $2!="part"' | tac)
    # old filesystem signatures inside every partition, then the partition table itself
    while read -r p; do
        wipefs -a -f "$p" >/dev/null 2>&1 || true
    done < <(lsblk -nrpo NAME,TYPE "$DISK" 2>/dev/null | awk '$2=="part"{print $1}')
    sgdisk --zap-all "$DISK" >/dev/null 2>&1 || true
    wipefs -a -f "$DISK" >/dev/null 2>&1 || warn "wipefs reported a problem on $DISK (checking below)."
    partx -d "$DISK" 2>/dev/null || true
    partprobe "$DISK" 2>/dev/null || true
    udevadm settle
    if [ -n "$(lsblk -nrpo NAME,TYPE "$DISK" 2>/dev/null | awk '$2=="part"{print $1}')" ]; then
        die "The old partitions of $DISK are still there (something is using the disk). Release it, then choose retry."
    fi
    ok "Disk $DISK wiped"
}

do_partitioning() {
    local p
    if [ "$WIPE_DISK" = true ] && [ "$DONE_WIPE" != true ]; then
        wipe_whole_disk
        DONE_WIPE=true
    fi
    if [ "$CREATE_EFI" = true ] || [ "$CREATE_BOOT" = true ] || [ "$CREATE_ROOT" = true ]; then
        if [ "$NEED_GPT" = true ]; then sgdisk -o "$DISK" >/dev/null; NEED_GPT=false; fi
        if [ "$CREATE_EFI" = true ];  then create_part "$EFI_SIZE"  ef00 EFI-System EFI_PART  CREATE_EFI;  fi
        if [ "$CREATE_BOOT" = true ]; then create_part "$BOOT_SIZE" 8300 Linux-Boot BOOT_PART CREATE_BOOT; fi
        if [ "$CREATE_ROOT" = true ]; then create_part 0            8300 Linux-Root RAW_ROOT  CREATE_ROOT; fi
    fi
    for p in "$EFI_PART" "$BOOT_PART" "$RAW_ROOT"; do
        if [ -n "$p" ]; then wait_dev "$p"; fi
    done
    ok "EFI=$EFI_PART  BOOT=$BOOT_PART  ROOT=$RAW_ROOT"
}

do_filesystems() {
    local d mt kf_old kf_new
    force_unmount_disk
    if [ "$CHANGE_LUKS_PASS" = true ] && [ "$DONE_LUKSPASS" != true ]; then
        msg "Changing the LUKS passphrase of $RAW_ROOT"
        kf_old=$(mktemp); kf_new=$(mktemp)
        chmod 600 "$kf_old" "$kf_new"
        printf '%s' "$LUKS_OLDPASS" > "$kf_old"
        printf '%s' "$LUKS_NEWPASS" > "$kf_new"
        if cryptsetup luksChangeKey --batch-mode --key-file "$kf_old" "$RAW_ROOT" "$kf_new"; then
            rm -f "$kf_old" "$kf_new"
            DONE_LUKSPASS=true
            LUKS_OLDPASS=$LUKS_NEWPASS
            ok "LUKS passphrase changed"
        else
            rm -f "$kf_old" "$kf_new"
            die "Could not change the LUKS passphrase. Nothing else was changed yet; fix the cause and choose retry."
        fi
    fi
    for d in "$RAW_ROOT" "$BOOT_PART" "$EFI_PART"; do
        if [ -n "$d" ]; then
            mt=$(findmnt -rn -S "$d" -o TARGET 2>/dev/null | head -n1 || true)
            if [ -n "$mt" ]; then die "$d is still mounted at $mt. Unmount it, then choose retry."; fi
        fi
    done
    if [ "$FORMAT_ROOT" = true ] && [ "$DONE_ROOTFMT" != true ]; then
        if [ "$USE_LUKS" = true ]; then
            if [ "$DONE_LUKSFMT" != true ]; then
                msg "Creating LUKS container on $RAW_ROOT"
                printf '%s' "$LUKS_PASS" | cryptsetup luksFormat --batch-mode --type luks2 "$RAW_ROOT" -
                DONE_LUKSFMT=true
            fi
            if [ "$LUKS_OPENED" != true ]; then
                if [ -e "/dev/mapper/$MAPPER" ]; then cryptsetup close "$MAPPER" || die "/dev/mapper/$MAPPER is busy."; fi
                printf '%s' "$LUKS_PASS" | cryptsetup open "$RAW_ROOT" "$MAPPER" -
                LUKS_OPENED=true
            fi
            LUKS_UUID=$(blkid -s UUID -o value "$RAW_ROOT")
            ACTIVE_DEV=/dev/mapper/$MAPPER
        else
            ACTIVE_DEV=$RAW_ROOT
        fi
        msg "Formatting root as Btrfs"
        mkfs.btrfs -f -L ubuntu "$ACTIVE_DEV"
        DONE_ROOTFMT=true
    fi
    if [ "$FORMAT_EFI" = true ] && [ "$DONE_EFIFMT" != true ]; then
        msg "Formatting EFI"; mkfs.vfat -F32 "$EFI_PART"; DONE_EFIFMT=true
    fi
    if [ "$FORMAT_BOOT" = true ] && [ "$DONE_BOOTFMT" != true ]; then
        msg "Formatting /boot"; mkfs.ext4 -F -L ubuntu-boot "$BOOT_PART"; DONE_BOOTFMT=true
    fi
    udevadm settle
    FS_UUID=$(blkid -s UUID -o value "$ACTIVE_DEV")
    BOOT_UUID=$(blkid -s UUID -o value "$BOOT_PART")
    EFI_UUID=$(blkid -s UUID -o value "$EFI_PART")
    if [ -z "$FS_UUID" ] || [ -z "$BOOT_UUID" ] || [ -z "$EFI_UUID" ]; then die "Could not read one of the UUIDs."; fi
    if [ "$USE_LUKS" = true ] && [ -z "$LUKS_UUID" ]; then LUKS_UUID=$(blkid -s UUID -o value "$RAW_ROOT"); fi
}

do_subvolumes() {
    local avail
    if findmnt -rn "$TOP" >/dev/null 2>&1; then umount "$TOP"; fi
    mount -o subvolid=5 "$ACTIVE_DEV" "$TOP"
    # --- @home first: protect it ---
    if [ "$WIPE_HOME" = true ]; then delete_subvol_tree "@home"; WIPE_HOME=false; HOME_STATE=none; fi
    case "$HOME_STATE" in
        none)
            if [ ! -e "$TOP/@home" ]; then btrfs subvolume create "$TOP/@home" >/dev/null; fi
            HOME_STATE=subvol ;;
        dir)
            msg "@home is a plain folder; converting safely (original is kept)"
            if [ -z "$HOME_OLDDIR" ]; then HOME_OLDDIR="@home.olddir-$(date +%Y%m%d%H%M%S)"; fi
            if [ ! -e "$TOP/$HOME_OLDDIR" ]; then mv "$TOP/@home" "$TOP/$HOME_OLDDIR"; fi
            if ! btrfs subvolume show "$TOP/@home" >/dev/null 2>&1; then btrfs subvolume create "$TOP/@home" >/dev/null; fi
            cp -a --reflink=auto "$TOP/$HOME_OLDDIR/." "$TOP/@home/"
            HOME_STATE=subvol ;;
        subvol)
            ok "Keeping existing @home untouched" ;;
    esac
    # --- @ : delete even if stubborn, then recreate ---
    if [ -e "$TOP/@" ]; then msg "Removing old @ (including nested subvolumes)"; delete_subvol_tree "@"; fi
    btrfs subvolume create "$TOP/@" >/dev/null
    avail=$(df -B1 --output=avail "$TOP" | tail -n1 | tr -d ' ')
    if [ "$avail" -lt "$MIN_ROOT_BYTES" ]; then
        die "Only $((avail / 1024 / 1024 / 1024)) GiB free on the Btrfs volume; need at least $((MIN_ROOT_BYTES / 1024 / 1024 / 1024)). Free space (shell option), then retry."
    fi
    umount "$TOP"
}

mnt() { # $1 target, rest = mount args (device included)
    local t=$1; shift
    if findmnt -rn "$t" >/dev/null 2>&1; then return 0; fi
    mkdir -p "$t"
    mount "$@" "$t"
}

do_mounts() {
    msg "Mounting target (root, boot, efi, home) BEFORE copying"
    mnt "$MP"          -o "$BTRFS_OPTS,subvol=@" "$ACTIVE_DEV"
    mnt "$MP/boot"     "$BOOT_PART"
    mnt "$MP/boot/efi" "$EFI_PART"
    mnt "$MP/home"     -o "$BTRFS_OPTS,subvol=@home" "$ACTIVE_DEV"
    # old kernels from a previous install would be stale
    if [ "$FORMAT_BOOT" != true ]; then
        rm -f "$MP"/boot/vmlinuz-* "$MP"/boot/initrd.img-* "$MP"/boot/config-* "$MP"/boot/System.map-* \
              "$MP"/boot/vmlinuz "$MP"/boot/vmlinuz.old "$MP"/boot/initrd.img "$MP"/boot/initrd.img.old 2>/dev/null || true
    fi
}

do_copy() {
    local rc=0 t
    for t in "$MP" "$MP/boot" "$MP/boot/efi" "$MP/home"; do
        findmnt -rn "$t" >/dev/null 2>&1 || die "$t is not mounted; refusing to copy (it would fill the live RAM disk). Retry the mount step."
    done
    msg "Copying live system (offline) - this takes a while (a retry resumes quickly)"
    rsync -aHAX --numeric-ids --info=progress2 \
        --exclude='/proc/*' --exclude='/sys/*' --exclude='/dev/*' --exclude='/run/*' \
        --exclude='/tmp/*' --exclude='/mnt/*' --exclude='/media/*' --exclude='/cdrom/*' \
        --exclude='/home/*' --exclude='/boot/efi/*' --exclude='/swapfile' --exclude='/swap.img' \
        "$ROFS/" "$MP/" || rc=$?
    if [ $rc -ne 0 ] && [ $rc -ne 24 ]; then die "rsync failed (exit $rc). If the disk is full, free space and retry."; fi
    mkdir -p "$MP"/{proc,sys,dev,run,tmp,mnt,media}
    chmod 1777 "$MP/tmp"
    ls "$MP"/boot/vmlinuz-* >/dev/null 2>&1 || warn "No kernel in /boot after copy; the chroot step will try to install one (needs internet)."
    ok "Copy finished"
}

do_chroot_prepare() {
    if [ ! -d "$MP/usr/lib/grub/x86_64-efi" ] && [ -d /usr/lib/grub/x86_64-efi ]; then
        msg "Copying GRUB EFI modules from the running live system"
        mkdir -p "$MP/usr/lib/grub"
        cp -a /usr/lib/grub/x86_64-efi "$MP/usr/lib/grub/"
    fi
    if ! findmnt -rn "$MP/dev" >/dev/null 2>&1; then
        mount --rbind /dev "$MP/dev"; mount --make-rslave "$MP/dev"
    fi
    if ! findmnt -rn "$MP/proc" >/dev/null 2>&1; then mount -t proc proc "$MP/proc"; fi
    if ! findmnt -rn "$MP/sys" >/dev/null 2>&1; then mount -t sysfs sysfs "$MP/sys"; fi
    if ! findmnt -rn "$MP/sys/firmware/efi/efivars" >/dev/null 2>&1; then
        mount -t efivarfs efivarfs "$MP/sys/firmware/efi/efivars" 2>/dev/null || warn "Could not mount efivarfs inside chroot."
    fi
    if ! findmnt -rn "$MP/run" >/dev/null 2>&1; then
        mount --bind /run "$MP/run"; mount --make-rslave "$MP/run"
    fi
    if [ "$RESOLV_BACKED" != true ]; then
        if [ -e "$MP/etc/resolv.conf" ] || [ -L "$MP/etc/resolv.conf" ]; then mv "$MP/etc/resolv.conf" "$MP/etc/resolv.conf.inst-bak"; fi
        RESOLV_BACKED=true
        cp -L /etc/resolv.conf "$MP/etc/resolv.conf" 2>/dev/null || echo "nameserver 1.1.1.1" > "$MP/etc/resolv.conf"
    fi
}

# ---------- the extras (codecs, NVIDIA, video player, CopyQ, ZRAM, Timeshift, Flatpak, Discover) ----------
# Embedded here so the installer is ONE file. It is written into the new system's /tmp and
# sourced inside the chroot by inner_main. To add your own programs, edit the text between
# the two markers below (the quoted marker means nothing in it is expanded by this script).
emit_extra_packages() {
cat <<'INSTALLER_EXTRA_PACKAGES_END'
#!/usr/bin/env bash
# ============================================================
# extra-packages.sh  -  runs INSIDE the chroot of the new system.
# It is sourced by ubuntu-btrfs-installer (same folder). Root already,
# no questions asked (sudo/apt/apt-get are wrapped by the installer).
# Variables from the installer: WANT_CODECS WANT_DRIVERS WANT_EXTRAS NEW_USER
# Helpers from the installer:   gnome_ext UUID...  /  gnome_enable UUID...
# Nothing here is fatal: a missing package is just skipped with a [WARN]/[INFO].
#
# NOTE: the installer runs this file with "set -u" and "pipefail" still ON,
# so every variable below is read with a default (${VAR:-...}) and no
# "cmd | grep -q" pipelines are used (they can fail with SIGPIPE).
# ============================================================
export DEBIAN_FRONTEND=noninteractive
WANT_CODECS=${WANT_CODECS:-false}
WANT_DRIVERS=${WANT_DRIVERS:-false}
WANT_EXTRAS=${WANT_EXTRAS:-false}
NEW_USER=${NEW_USER:-}

# ---------- helpers ----------
# Is the package really installed (not just "config files left")?
is_installed() {
    local st
    st=$(dpkg-query -W -f='${Status}' "$1" 2>/dev/null || true)
    [ "$st" = "install ok installed" ]
}

# Does apt know a installable version of the package on this Ubuntu?
pkg_ok() {
    local cand
    cand=$(apt-cache policy "$1" 2>/dev/null | awk '/Candidate:/ {print $2; exit}')
    [ -n "$cand" ] && [ "$cand" != "(none)" ]
}

# Install packages ONE BY ONE: a package that does not exist on this Ubuntu
# version never blocks the others.
install_each() {
    local p
    for p in "$@"; do
        if is_installed "$p"; then continue; fi
        if pkg_ok "$p"; then
            apt-get install -y "$p" || echo "[WARN] could not install $p"
        else
            echo "[INFO] $p is not available on this Ubuntu, skipped"
        fi
    done
}

# (the installer already ran "apt-get update" right before this file)

# ============================================================
# 1) Media codecs (fixes "Missing media codecs - AV1 decoder")
# ============================================================
if [ "$WANT_CODECS" = true ] || [ "$WANT_EXTRAS" = true ]; then
    # accept the licences so ubuntu-restricted-extras never stops to ask
    echo "ttf-mscorefonts-installer msttcorefonts/accepted-mscorefonts-eula select true" | debconf-set-selections 2>/dev/null || true
    echo "ubuntu-restricted-extras ubuntu-restricted-extras/accepted-eula select true" | debconf-set-selections 2>/dev/null || true

    install_each ubuntu-restricted-extras

    # GStreamer (used by the GNOME video player): good / bad / ugly / libav
    # "bad" + libav + dav1d/aom = H.264, H.265, AV1 inside mp4 / webm / mkv
    install_each gstreamer1.0-plugins-base gstreamer1.0-plugins-good \
                 gstreamer1.0-plugins-bad  gstreamer1.0-plugins-ugly \
                 gstreamer1.0-libav        gstreamer1.0-gl \
                 gstreamer1.0-pipewire     gstreamer1.0-vaapi \
                 gstreamer1.0-plugin-dav1d gstreamer1.0-plugins-rs

    # AV1 decoder libraries (names change between Ubuntu releases: all are tried)
    install_each libdav1d7 libdav1d6 libdav1d5 libaom3 libaom0 \
                 libavcodec-extra ffmpeg libheif1 libde265-0 libx265-199

    # hardware video decoding (VA-API) - safe on any machine
    install_each intel-media-va-driver-non-free mesa-va-drivers va-driver-all vainfo

    # forget the old (empty) codec cache so the player sees the new plugins at once
    rm -rf /root/.cache/gstreamer-1.0 2>/dev/null || true
    if [ -n "$NEW_USER" ]; then rm -rf "/home/$NEW_USER/.cache/gstreamer-1.0" 2>/dev/null || true; fi
fi

# ============================================================
# 2) Drivers
# ============================================================
# NVIDIA is handled in 3 layers so a failure in the chroot never breaks the install:
#   a) install the recommended driver for the kernel that is REALLY installed on the
#      new system (not the live kernel), preferring prebuilt signed modules
#   b) rebuild initramfs + grub so nouveau is blacklisted and the driver loads
#   c) if nothing could be installed here, a one-time service retries at first boot
nvidia_installed() {
    dpkg-query -W -f='${Package} ${Status}\n' 'nvidia-driver-*' 'linux-modules-nvidia-*' 2>/dev/null \
        | awk '/install ok installed/ {f=1} END {exit f ? 0 : 1}'
}

install_gpu_drivers() {
    local kver has_nv=0 sb=""
    install_each ubuntu-drivers-common pciutils mokutil

    # newest kernel installed in the new /boot (uname -r would be the live USB kernel)
    kver=$(ls /boot/vmlinuz-* 2>/dev/null | sed 's#.*/vmlinuz-##' | sort -V | tail -n1 || true)
    echo "==> [drivers] kernel of the new system: ${kver:-unknown}"

    has_nv=$(lspci -nn 2>/dev/null | awk 'tolower($0) ~ /(vga|3d|display).*10de:/ {n++} END {print n+0}' || echo 0)
    if [ "$has_nv" -eq 0 ]; then
        echo "==> [drivers] no NVIDIA GPU detected here; letting ubuntu-drivers decide"
    else
        echo "==> [drivers] NVIDIA GPU detected"
        # headers only matter when the driver has to be built with DKMS
        if [ -n "$kver" ]; then install_each "linux-headers-$kver"; fi
    fi

    if command -v ubuntu-drivers >/dev/null 2>&1; then
        ubuntu-drivers install || ubuntu-drivers autoinstall \
            || echo "[WARN] ubuntu-drivers found nothing to install (or it failed)"
    fi

    if nvidia_installed; then
        echo "==> [drivers] NVIDIA driver installed"
        # Wayland / GNOME needs KMS from the NVIDIA module
        mkdir -p /etc/modprobe.d
        echo "options nvidia-drm modeset=1" > /etc/modprobe.d/nvidia-drm-modeset.conf
        sb=$(mokutil --sb-state 2>/dev/null || true)
        case "$sb" in
            *enabled*)
                if [ -d /var/lib/dkms/nvidia ]; then
                    echo "[WARN] Secure Boot is ON and the driver is built with DKMS: at the first boot a blue"
                    echo "       MOK screen appears -> choose 'Enroll MOK' and use the password you were asked for."
                fi ;;
        esac
        # nouveau must be out of the initramfs, and grub must see the final state
        update-initramfs -u -k all || echo "[WARN] drivers: update-initramfs failed"
        update-grub || echo "[WARN] drivers: update-grub failed"
    elif [ "$has_nv" -gt 0 ]; then
        echo "[WARN] NVIDIA driver was NOT installed here; it will be retried at the first boot (needs internet)."
        mkdir -p /var/lib /usr/local/sbin /etc/systemd/system/multi-user.target.wants
        : > /var/lib/nvidia-firstboot-needed
        cat > /usr/local/sbin/nvidia-firstboot.sh <<'EOF'
#!/bin/bash
# One-time: install the NVIDIA driver at the first boot if the installer could not.
[ -e /var/lib/nvidia-firstboot-needed ] || exit 0
if nvidia-smi >/dev/null 2>&1; then rm -f /var/lib/nvidia-firstboot-needed; exit 0; fi
if ! timeout 10 getent hosts archive.ubuntu.com >/dev/null 2>&1; then exit 0; fi   # retry next boot
export DEBIAN_FRONTEND=noninteractive
apt-get update -y || true
if ubuntu-drivers install; then
    rm -f /var/lib/nvidia-firstboot-needed
    update-initramfs -u -k all || true
    echo "NVIDIA driver installed - please reboot once." | tee /var/log/nvidia-firstboot.log
fi
exit 0
EOF
        chmod 755 /usr/local/sbin/nvidia-firstboot.sh
        cat > /etc/systemd/system/nvidia-firstboot.service <<'EOF'
[Unit]
Description=Install the NVIDIA driver once (first boot)
After=network-online.target
Wants=network-online.target
ConditionPathExists=/var/lib/nvidia-firstboot-needed

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/nvidia-firstboot.sh

[Install]
WantedBy=multi-user.target
EOF
        ln -sf /etc/systemd/system/nvidia-firstboot.service /etc/systemd/system/multi-user.target.wants/nvidia-firstboot.service
    fi
}

if [ "$WANT_DRIVERS" = true ]; then
    install_gpu_drivers || echo "[WARN] driver step had errors (the install continues)"
fi

# ============================================================
# 3) Power-user extras
# ============================================================
if [ "$WANT_EXTRAS" = true ]; then

    # ---- GNOME video player ----
    # Newer Ubuntu: "Showtime" (org.gnome.Showtime)  -  older Ubuntu: "Totem" (Videos).
    # Showtime is tried first; if it does not exist here, Totem is installed instead.
    if pkg_ok showtime; then
        install_each showtime
    else
        install_each totem totem-plugins
    fi
    # Make it the default for video files. Only written when the system has no
    # /etc/xdg/mimeapps.list yet (never overwrites an existing one); the user's own
    # choices in Settings always win over it.
    vplayer=""
    if [ -f /usr/share/applications/org.gnome.Showtime.desktop ]; then
        vplayer=org.gnome.Showtime.desktop
    elif [ -f /usr/share/applications/org.gnome.Totem.desktop ]; then
        vplayer=org.gnome.Totem.desktop
    fi
    if [ -n "$vplayer" ] && [ ! -e /etc/xdg/mimeapps.list ]; then
        {
            echo "[Default Applications]"
            for mt in video/mp4 video/x-matroska video/webm video/x-msvideo video/quicktime \
                      video/mpeg video/ogg video/x-flv video/3gpp; do
                echo "$mt=$vplayer"
            done
        } > /etc/xdg/mimeapps.list
    fi

    # ---- CopyQ (clipboard manager) ----
    install_each copyq copyq-plugins
    if command -v copyq >/dev/null 2>&1; then
        # start with the session; xcb platform so it also works on Wayland (Xwayland)
        mkdir -p /etc/xdg/autostart
        cat > /etc/xdg/autostart/copyq.desktop <<'EOF'
[Desktop Entry]
Type=Application
Name=CopyQ
Comment=Clipboard manager
Exec=env QT_QPA_PLATFORM=xcb copyq
Icon=copyq
Terminal=false
X-GNOME-Autostart-enabled=true
EOF
    fi

    # ---- CopyQ keyboard shortcut: Super+V opens/closes the clipboard history ----
    # (GNOME custom shortcut as a system-wide default; works on Wayland too.
    #  GNOME's own notifications shortcut is moved from Super+V to Super+Shift+V
    #  so the two do not clash; Super+M still opens notifications as well.)
    if is_installed copyq; then
        install_each dconf-cli
        if command -v dconf >/dev/null 2>&1; then
            mkdir -p /etc/dconf/profile /etc/dconf/db/local.d
            [ -f /etc/dconf/profile/user ] || printf 'user-db:user\n' > /etc/dconf/profile/user
            grep -q 'system-db:local' /etc/dconf/profile/user || printf 'system-db:local\n' >> /etc/dconf/profile/user
            cat > /etc/dconf/db/local.d/70-copyq-shortcut <<'EOF'
[org/gnome/shell/keybindings]
toggle-message-tray=['<Super><Shift>v', '<Super>m']

[org/gnome/settings-daemon/plugins/media-keys]
custom-keybindings=['/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/copyq/']

[org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/copyq]
name='CopyQ'
command='env QT_QPA_PLATFORM=xcb copyq toggle'
binding='<Super>v'
EOF
            dconf update || echo "[WARN] CopyQ shortcut: dconf update failed"
        fi
    fi

    # ---- ZRAM (compressed swap in RAM) ----
    install_each systemd-zram-generator
    if is_installed systemd-zram-generator; then
        mkdir -p /etc/systemd
        cat > /etc/systemd/zram-generator.conf <<'EOF'
[zram0]
zram-size = ram / 2
compression-algorithm = zstd
swap-priority = 100
EOF
    else
        install_each zram-tools
    fi

    # ---- Timeshift (snapshots; works with the @ / @home Btrfs layout) ----
    install_each timeshift btrfs-progs cron
    # Default Timeshift settings so it works out of the box (no first-run wizard needed):
    # Btrfs mode, snapshots of @ (the system) only - @home (your files) is NOT included.
    # Schedule: keep 5 daily + 2 weekly snapshots (change the two numbers to taste).
    TS_DAILY=5
    TS_WEEKLY=2
    if is_installed timeshift && [ -n "${FS_UUID:-}" ]; then
        TS_PARENT=""
        if [ "${USE_LUKS:-false}" = true ]; then TS_PARENT=${LUKS_UUID:-}; fi
        mkdir -p /etc/timeshift
        cat > /etc/timeshift/timeshift.json <<EOF
{
  "backup_device_uuid" : "$FS_UUID",
  "parent_device_uuid" : "$TS_PARENT",
  "do_first_run" : "false",
  "btrfs_mode" : "true",
  "include_btrfs_home_for_backup" : "false",
  "include_btrfs_home_for_restore" : "false",
  "stop_cron_emails" : "true",
  "schedule_monthly" : "false",
  "schedule_weekly" : "true",
  "schedule_daily" : "true",
  "schedule_hourly" : "false",
  "schedule_boot" : "false",
  "count_monthly" : "2",
  "count_weekly" : "$TS_WEEKLY",
  "count_daily" : "$TS_DAILY",
  "count_hourly" : "6",
  "count_boot" : "5",
  "snapshot_size" : "0",
  "snapshot_count" : "0",
  "date_format" : "%Y-%m-%d %H:%M:%S",
  "exclude" : [],
  "exclude-apps" : []
}
EOF
        echo "==> [chroot] Timeshift: Btrfs mode, $TS_DAILY daily + $TS_WEEKLY weekly snapshots"
    fi

    # ---- Flatpak + Flathub ----
    install_each flatpak
    if command -v flatpak >/dev/null 2>&1; then
        flatpak remote-add --if-not-exists --system flathub https://dl.flathub.org/repo/flathub.flatpakrepo \
            || echo "[WARN] could not add the Flathub remote (add it after first boot)"
    fi

    # ---- Discover (the installer then puts it in the dock instead of Ubuntu Software) ----
    install_each plasma-discover plasma-discover-backend-flatpak

    # ---- your own programs: add more lines here ----
    # install_each vlc htop git
    # gnome_ext appindicatorsupport@rgcjonas.gmail.com
fi

echo "==> extra-packages.sh finished"
INSTALLER_EXTRA_PACKAGES_END
}

do_chroot_run() {
    local v rc=0
    cp "$SCRIPT_PATH" "$MP/tmp/installer.sh"; chmod 700 "$MP/tmp/installer.sh"
    # the extras are part of this installer (see emit_extra_packages above): no second file needed
    emit_extra_packages > "$MP/tmp/extra-packages.sh"; chmod 700 "$MP/tmp/extra-packages.sh"
    (
        umask 077
        for v in NEW_USER NEW_PASS NEW_HOST NEW_TZ USE_LUKS LUKS_UUID FS_UUID BOOT_UUID EFI_UUID \
                 WANT_CODECS WANT_DRIVERS WANT_EXTRAS WANT_UI MAPPER BTRFS_OPTS; do
            printf '%s=%q\n' "$v" "${!v}"
        done > "$MP$ENV_FILE"
    )
    chroot "$MP" /bin/bash /tmp/installer.sh --inner || rc=$?
    rm -f "$MP$ENV_FILE" "$MP/tmp/installer.sh" "$MP/tmp/extra-packages.sh"      # never leave the password on the new disk
    if [ $rc -ne 0 ]; then die "Configuring the new system failed (exit $rc). See the messages above."; fi
    restore_resolv
}

# The initramfs must be able to open the disk at boot. Reads the newest initrd of the new
# system: Btrfs support is expected, and with LUKS the unlock (crypt) part is REQUIRED.
# Output is captured in a variable first (no "cmd | grep -q": that can fail with SIGPIPE).
check_initrd() {
    local img rel out="" tool=""
    img=$(ls "$MP"/boot/initrd.img-* 2>/dev/null | sort -V | tail -n1 || true)
    if [ -z "$img" ]; then return 0; fi
    rel=/boot/${img##*/}
    if chroot "$MP" sh -c 'command -v lsinitrd' >/dev/null 2>&1; then tool=lsinitrd
    elif chroot "$MP" sh -c 'command -v lsinitramfs' >/dev/null 2>&1; then tool=lsinitramfs
    else warn "No tool to inspect the initramfs; check skipped."; return 0; fi
    out=$(chroot "$MP" "$tool" "$rel" 2>/dev/null || true)
    if [ -z "$out" ]; then warn "Could not read $rel; initramfs check skipped."; return 0; fi
    if ! grep -qi 'btrfs' <<<"$out"; then
        warn "The initramfs $rel does not seem to contain Btrfs support. If the system does not boot, run: sudo update-initramfs -u -k all"
    fi
    if [ "$USE_LUKS" = true ] && ! grep -qi 'crypt' <<<"$out"; then
        die "The initramfs $rel has NO disk-unlock (crypt) part although the root is encrypted: the system would not boot. Open a shell (s), run: chroot $MP update-initramfs -u -k all   then choose retry."
    fi
    ok "Initramfs checked ($rel)"
}

do_verify() {
    local f efi_ok=false
    grep -q "$FS_UUID" "$MP/etc/fstab"   || die "fstab does not contain the root UUID."
    grep -q "$BOOT_UUID" "$MP/etc/fstab" || die "fstab does not contain the /boot UUID."
    ls "$MP"/boot/vmlinuz-* >/dev/null 2>&1       || die "No kernel in the new /boot."
    ls "$MP"/boot/initrd.img-* >/dev/null 2>&1    || die "No initrd in the new /boot."
    [ -s "$MP/boot/grub/grub.cfg" ]               || die "grub.cfg is missing or empty."
    for f in "$MP/boot/efi/EFI/ubuntu/shimx64.efi" "$MP/boot/efi/EFI/ubuntu/grubx64.efi" "$MP/boot/efi/EFI/BOOT/BOOTX64.EFI"; do
        if [ -e "$f" ]; then efi_ok=true; fi
    done
    if [ "$efi_ok" != true ]; then die "No GRUB EFI binary found in the EFI partition."; fi
    if [ "$USE_LUKS" = true ] && [ ! -s "$MP/etc/crypttab" ]; then die "crypttab is empty although LUKS is used."; fi
    check_initrd
    ok "Installed system verified"
}

main() {
    preflight
    main_menu                # archinstall-style TUI; returns after you confirm INSTALL
    clear
    echo -e "${C_BLU}================ INSTALLING ================${C_RST}"
    run_step "Preparing the disk and creating partitions"  do_partitioning
    run_step "Creating filesystems"               do_filesystems
    run_step "Preparing subvolumes"               do_subvolumes
    run_step "Mounting the target"                do_mounts
    run_step "Copying the live system"            do_copy
    run_step "Preparing the chroot"               do_chroot_prepare
    run_step "Configuring the new system"         do_chroot_run
    run_step "Final verification"                 do_verify
    INSTALL_OK=true
}
if [ "${INSTALLER_SOURCE_ONLY:-}" != 1 ]; then main; fi
