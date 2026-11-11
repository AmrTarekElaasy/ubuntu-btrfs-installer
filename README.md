# Ubuntu 26.04 Btrfs Installer

A single-file, offline installer that puts Ubuntu on **Btrfs** (`@` + `@home` subvolumes) with a separate ext4 `/boot` and an EFI partition. It runs from the Ubuntu live session with an archinstall-style text menu, copies the live system to disk, and configures it, with safety checks at every step.

> **Warning:** this tool partitions and formats disks. Read the modes below, and test it in a virtual machine first.

## Features

- **One file.** Everything (installer + extras) is inside `ubuntu-26.04-btrfs-installer.sh`.
- **Btrfs layout:** `@` (root) and `@home` (user data), mounted with `noatime,compress=zstd:1`.
- **Separate `/boot` (ext4) and EFI (FAT32)** partitions, GRUB for UEFI (Secure Boot chain installed when online).
- **Optional LUKS2 encryption** of the root partition.
- **Menu-driven (whiptail):** every item shows its current value; nothing is touched until you choose **INSTALL**, review the summary and confirm.
- **Plan is validated before anything changes:** tools, live image, free space, partitions, internet (when needed).
- **Never lose progress:** if a step fails during installation it stops in place. Fix the problem (a shell can be opened from the installer) and choose **retry**; finished work is not redone.
- **Offline copy:** the system is copied from the live image (`/rofs`); the internet is only needed for the optional extras.

## Installation modes

| # | Mode | What it does |
|---|------|--------------|
| 1 | **Reinstall** on existing Btrfs | Replaces only the subvolume `@`. `@home` is kept unless you type `DELETE-HOME`. EFI and `/boot` can be reused, recreated, or created in free space. |
| 2 | **Free space** | Creates new EFI + `/boot` + root partitions in free space only. **Erases nothing.** An existing EFI partition can be reused without formatting. |
| 3 | **Manual** | You pick the three partitions. Root is formatted. |
| 4 | **Wipe entire disk** | Erases the whole disk, creates a new GPT (EFI 512 MiB, `/boot` 2 GiB, Btrfs = rest). You must type the disk name twice. |

The live USB itself is never offered as a target.

## Requirements

- Boot the **Ubuntu live ISO in UEFI mode** (the live image must contain `/rofs`).
- Run as root from the live session.
- A target disk (GPT for modes 1 and 2 when creating new partitions) with enough space (about 12 GiB minimum for root).
- Internet only if you want codecs, drivers or extras (the installer checks this before it starts).

Tested on Ubuntu 26.04 (GNOME).

## Usage

```bash
wget https://raw.githubusercontent.com/AmrTarekElaasy/ubuntu-btrfs-installer/main/ubuntu-26.04-btrfs-installer.sh &&
sudo chmod +x ubuntu-26.04-btrfs-installer.sh &&
sudo ./ubuntu-26.04-btrfs-installer.sh

```

Then, in the menu: choose the **Disk**, plan the **Partitions**, set **Username / Password / Hostname / Timezone**, toggle the options you want, and choose **INSTALL**. When it finishes, remove the USB and reboot.

The log is written to `/var/log/ubuntu-btrfs-installer.log`.

## Options and extras

| Option | What it does |
|--------|--------------|
| **Codecs** | `ubuntu-restricted-extras`, GStreamer plugins, AV1 decoders (dav1d), ffmpeg, VA-API drivers. |
| **Drivers** | Installs the recommended proprietary drivers for the installed kernel. For NVIDIA it retries once at first boot if it could not finish inside the installer. |
| **Extras** | GNOME video player (Showtime/Totem), CopyQ (clipboard manager, **Super+V**), ZRAM , Timeshift, Flatpak + Flathub, Discover. |
| **UI customization** | Dock at the bottom with auto-hide, wallpapers, blue accent colour. Applied as system-wide dconf defaults. |

### Timeshift defaults

Timeshift is pre-configured for Btrfs mode

### Keyboard shortcuts

CopyQ opens with **Super+V**. GNOME's notification list moves to **Super+Shift+V** (Super+M still works).

## Customizing

Open `ubuntu-26.04-btrfs-installer.sh` and search for `emit_extra_packages`. Everything installed beyond the base system lives there. To add programs, add a line such as:

```bash
install_each vlc htop git
```

## Safety notes

- Mode 2 erases nothing; mode 1 only deletes `@`; modes 3 and 4 erase what you confirm by typing its name.
- Partitions in use by the live system are protected.
- If something fails, the installer releases all mounts and nothing else is deleted.

## Troubleshooting

- **No internet during install:** the optional extras are skipped; install them after the first boot.
- **NVIDIA driver missing after boot:** run `sudo ubuntu-drivers install` and reboot (with Secure Boot, enroll the MOK key when asked).
- **Other OS not in the GRUB menu:** run `sudo update-grub`, or boot it from the firmware boot menu.

## Disclaimer

This software formats and partitions disks. It is provided **as is, without any warranty**: you use it at your own risk. Always back up your data and try it in a virtual machine first.


## Contributing

Issues and pull requests are welcome. If you report a problem, please attach the log file `/var/log/ubuntu-btrfs-installer.log` and say which installation mode you used.

## License

Released under the [MIT License](LICENSE): free to use, copy, modify and share, as long as the license notice is kept.
