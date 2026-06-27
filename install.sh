#!/usr/bin/env bash
set -euo pipefail

BLOCK_SIZE=4096
NVME_CTRL=/dev/nvme0
NVME_NS=/dev/nvme0n1
BOOT_PARTITION=/dev/nvme0n1p1
ROOT_PARTITION=/dev/nvme0n1p2

SYS_TIMEZONE=Europe/Berlin
SYS_LOCALES=('en_US.UTF-8 UTF-8' 'de_DE.UTF-8 UTF-8')
SYS_LANG=en_US.UTF-8
SYS_KEYMAP=us
SYS_HOSTNAME=vulcan4
USERNAME=euli

usage() {
	cat <<EOF
Options:
  --sanitize     NVMe block erase and namespace format
  --partition    recreate GPT: EFI + Linux root
  --create-luks  recreate LUKS container
EOF
}

SANITIZE=0
PARTITION=0
CREATE_LUKS=0

while [[ $# -gt 0 ]]; do
	case "$1" in
	-h | --help)
		usage
		exit 0
		;;
	--sanitize)
		SANITIZE=1
		PARTITION=1
		CREATE_LUKS=1
		;;
	--partition)
		PARTITION=1
		CREATE_LUKS=1
		;;
	--create-luks)
		CREATE_LUKS=1
		;;
	*)
		echo "Unknown argument: $1" >&2
		usage
		exit 1
		;;
	esac
	shift
done

bootctl status | grep -F 'Secure Boot'
read -rp "Have you disabled Secure Boot? (YES/no/reboot) " confirm
case "$confirm" in
YES)
	;;
reboot)
	systemctl reboot --firmware-setup
	exit 0
	;;
*)
	exit 1
	;;
esac

echo "DANGER: this will erase all data"
read -rp "Type ERASE to continue: " confirm
[[ "$confirm" == "ERASE" ]] || exit 1

if ((SANITIZE)); then
	await_sanitize() {
		local ssi
		while true; do
			ssi="$(nvme sanitize-log "$NVME_CTRL" | awk '/\(SSI\)/ { print $NF }')"
			case "$ssi" in
			0) return 0 ;;
			[1-9]*) sleep 2 ;;
			*)
				echo "Unexpected SSI value: '$ssi'" >&2
				return 1
				;;
			esac
		done
	}

	echo "Sanitizing $NVME_CTRL... (this might take a minute)"
	nvme sanitize "$NVME_CTRL" -a start-block-erase
	await_sanitize

	echo "Formatting $NVME_NS..."
	nvme format -b "$BLOCK_SIZE" "$NVME_NS"

	udevadm settle
	lsblk -o NAME,TYPE,SIZE,LOG-SEC,PHY-SEC "$NVME_NS"
fi

if ((PARTITION)); then
	echo "Partitioning $NVME_NS..."
	sgdisk --zap-all "$NVME_NS"
	sgdisk -n 1:0:+1G -t 1:ef00 -c 1:efi "$NVME_NS"
	sgdisk -n 2:0:0 -t 2:8304 -c 2:root "$NVME_NS"
	partprobe "$NVME_NS"
	udevadm settle

	lsblk -o NAME,SIZE,TYPE,PARTTYPE,PARTLABEL "$NVME_NS"
fi

if ((CREATE_LUKS)); then
	echo "Creating LUKS container..."
	cryptsetup luksFormat "$ROOT_PARTITION"
fi

echo "Formatting partitions..."
[[ -e /dev/mapper/root ]] || cryptsetup open "$ROOT_PARTITION" root
mkfs.ext4 -F /dev/mapper/root
mkfs.fat -F 32 "$BOOT_PARTITION"

lsblk -o NAME,SIZE,TYPE,FSTYPE "$NVME_NS"

echo "Mounting partitions..."
mount /dev/mapper/root /mnt
mount --mkdir "$BOOT_PARTITION" /mnt/boot

findmnt -R /mnt

echo "Installing Arch..."
pacstrap -K /mnt \
	base base-devel linux linux-firmware \
	amd-ucode nvidia-open \
	iwd neovim sbctl sudo \
	bash-completion fd fzf git less man-db man-pages openssh \
    cups pipewire pipewire-alsa pipewire-audio pipewire-pulse wireplumber \
    alacritty firefox fuzzel mako sway swaybg swayidle ttf-ibm-plex wl-clipboard #\
#   grim slurp sway-contrib xdg-desktop-portal xdg-desktop-portal-wlr

echo "Configuring system..."
sed -i '/^OPTIONS=/s/\<debug\>/!debug/' /mnt/etc/makepkg.conf

echo "Setting up time, locale and keymap..."
ln -sf "/usr/share/zoneinfo/$SYS_TIMEZONE" /mnt/etc/localtime
arch-chroot /mnt hwclock --systohc
arch-chroot /mnt systemctl enable systemd-timesyncd.service

for locale in "${SYS_LOCALES[@]}"; do
	sed -i "s/^#${locale}/${locale}/" /mnt/etc/locale.gen
done
arch-chroot /mnt locale-gen

echo "LANG=$SYS_LANG" >/mnt/etc/locale.conf
echo "KEYMAP=$SYS_KEYMAP" >/mnt/etc/vconsole.conf

echo "Setting up networking..."
echo "$SYS_HOSTNAME" >/mnt/etc/hostname

mkdir -p /mnt/etc/iwd
cat >/mnt/etc/iwd/main.conf <<'EOF'
[General]
EnableNetworkConfiguration=true
EOF
arch-chroot /mnt systemctl enable iwd.service

ln -sf ../run/systemd/resolve/stub-resolv.conf /mnt/etc/resolv.conf
arch-chroot /mnt systemctl enable systemd-resolved.service

echo "Setting up bootloader..."
sed -i 's/^HOOKS=.*/HOOKS=(base systemd autodetect microcode modconf kms keyboard keymap sd-vconsole block sd-encrypt filesystems fsck)/' /mnt/etc/mkinitcpio.conf
cat >/mnt/etc/mkinitcpio.d/linux.preset <<'EOF'
# mkinitcpio preset file for the 'linux' package
ALL_kver="/boot/vmlinuz-linux"
PRESETS=('default')
default_uki="/boot/EFI/BOOT/BOOTx64.EFI"
EOF

mkdir -p /mnt/etc/kernel /mnt/boot/EFI/BOOT
: >/mnt/etc/kernel/cmdline
arch-chroot /mnt mkinitcpio -P

echo "Setting up users..."
echo '%wheel ALL=(ALL:ALL) ALL' >/mnt/etc/sudoers.d/wheel
chmod 440 /mnt/etc/sudoers.d/wheel
arch-chroot /mnt useradd -m -G wheel -s /bin/bash "$USERNAME"

echo "Set a password for root user"
arch-chroot /mnt passwd
echo "Set a password for $USERNAME"
arch-chroot /mnt passwd "$USERNAME"

echo "Finalizing networking setup..."
mkdir -p /mnt/var/lib/iwd
cp -a /var/lib/iwd/. /mnt/var/lib/iwd/

echo "Generating post-install scripts..."

cat >"/mnt/home/$USERNAME/secure_boot.sh" <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail

[[ $EUID -eq 0 ]] || { echo "Run as root" >&2; exit 1; }

echo "Current Secure Boot status:"
sbctl status

read -rp "Is Secure Boot in Setup Mode? (YES/no) " confirm
[[ "$confirm" == "YES" ]] || exit 1
echo "Setting up keys..."
sbctl create-keys
sbctl enroll-keys -m
sbctl sign -s /boot/EFI/BOOT/BOOTx64.EFI
sbctl verify

rm -- "$0"

echo "Restarting in 5 seconds."
echo "Enable Secure Boot in firmware setup."
sleep 5
systemctl reboot --firmware-setup
SCRIPT

cat >"/mnt/home/$USERNAME/enroll_tpm.sh" <<SCRIPT
#!/usr/bin/env bash
set -euo pipefail

[[ \$EUID -eq 0 ]] || { echo "Run as root" >&2; exit 1; }

echo "Current Secure Boot status:"
sbctl status
read -rp "Secure Boot should be enabled before enrolling TPM. Proceed? (YES/no) " confirm
[[ "\$confirm" == "YES" ]] || exit 1

echo "Enrolling TPM2 unlock..."
systemd-cryptenroll --tpm2-device=auto --tpm2-pcrs=7 "$ROOT_PARTITION"
systemd-cryptenroll "$ROOT_PARTITION"

rm -- "\$0"
echo "DONE!"
SCRIPT

cat >"/mnt/home/$USERNAME/post_install.sh" <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail

mkdir -p "$HOME/.config" "$HOME/Downloads" "$HOME/Documents" "$HOME/Pictures" "$HOME/Projects" 
cat >"$HOME/.config/user-dirs.dirs" <<'EOF'
XDG_DOCUMENTS_DIR="$HOME/Documents"
XDG_DOWNLOAD_DIR="$HOME/Downloads"
XDG_PICTURES_DIR="$HOME/Pictures"
XDG_PROJECTS_DIR="$HOME/Projects"
EOF

ssh-keygen -t ed25519
systemctl enable --user ssh-agent.service
cat ~/.ssh/id_ed25519.pub
read -rp "Add key to GitHub and type CONTINUE " confirm
[[ "$confirm" == "CONTINUE" ]] || exit 1

git clone --bare git@github.com:beerChili/dot.git "$HOME/Projects/dot"
rm -f "$HOME/.bashrc" "$HOME/.bash_profile" "$HOME/.bash_logout"
git --git-dir="$HOME/Projects/dot" --work-tree="$HOME" checkout

git clone https://aur.archlinux.org/aurutils.git /tmp/aurutils
makepkg -si -p /tmp/aurutils/PKGBUILD
rm -rf /tmp/aurutils
sudo tee -a /etc/pacman.conf >/dev/null <<EOF
[aur]
SigLevel = Optional TrustAll
Server = file:///var/lib/aur
EOF
sudo mkdir -p /var/lib/aur
sudo chown "$USER:$USER" /var/lib/aur
repo-add /var/lib/aur/aur.db.tar
aur repo aur
aur sync aurutils 

reboot
SCRIPT

chmod +x /mnt/home/"$USERNAME"/*.sh
arch-chroot /mnt chown "$USERNAME:$USERNAME" /home/"$USERNAME"/*.sh

echo "DONE!"
echo "Unmounting..."
umount -R /mnt
cryptsetup close root
echo "Rebooting in 5 seconds..."
sleep 5
reboot
