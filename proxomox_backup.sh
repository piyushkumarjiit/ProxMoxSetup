

#
# community scripts post-install to ensure you can update and install from normal repos
    bash -c "$(curl -fsSL https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/tools/pve/post-pve-install.sh)"

sudo apt update
sudo apt install -y fsarchiver
# USe lsblk to find proxmox install drive as well as USB drive
lsblk
# 1. Format the main partition on the USB. This is done only once.
sudo mkfs.ext4 /dev/sdf3

# 2. Create the mount point
sudo mkdir -p /mnt/usb_vault

# 3. Mount it
sudo mount /dev/sdf3 /mnt/usb_vault

# backup using fsarchiver
sudo fsarchiver -A -j4 savefs /mnt/usb_vault/proxmox_vanilla.fsa /dev/sdc2 /dev/mapper/pve-root

# check the size
ls -lh /mnt/usb_vault/proxmox_vanilla.fsa

# Config backup
sudo tar -cvzf /mnt/usb_vault/config_only_vanilla.tar.gz /etc/pve /etc/network/interfaces /etc/modules /etc/default/grub

Preparation: Boot into a Live USB

Plug in a standard Ubuntu or Debian Live USB into your Dell R720.
Restart the server and press F11 to enter the Boot Manager.
Select the Live USB to boot into a "Try Ubuntu" session.
Once in the desktop, open a Terminal.
Locate and Mount your "Vault" USB. You need to access the .fsa file stored on your 15GB USB drive. Also, remember that in the Live Environment, /dev/mapper/pve-root might not show up automatically.You may need to run this command in the Live terminal to "wake up" the LVM partitions:

sudo vgchange -ay

# Identify your drives
lsblk

# 1. Create a mount point
sudo mkdir -p /mnt/vault

# 2. Mount the 15GB USB partition (previously /dev/sdf3)
# Note: In a Live environment, the letter might change (e.g., /dev/sdb3)
sudo mount /dev/sdX3 /mnt/vault

This step is the "reverse" of the backup. It will decompress the file and stream it directly onto your Proxmox boot drive.
# Replace /dev/sdc2 and /dev/mapper/pve-root with the actual paths 
# as they appear in the Live Environment.
sudo fsarchiver restfs /mnt/vault/proxmox_vanilla.fsa \
    id=0,dest=/dev/sdc2 \
    id=1,dest=/dev/mapper/pve-root
id=0: This refers to the first partition inside the archive (your EFI boot files).
id=1: This refers to the second partition inside the archive (your Root OS).

Finalize and Reboot
sudo umount /mnt/vault


If you are still able to boot into Proxmox but just want to undo a specific configuration mistake (like a broken network bridge), you don't need the full image.
# Run this ONLY if you are inside Proxmox and just want to fix configs
sudo tar -xvzf /mnt/usb_vault/config_only_vanilla.tar.gz -C /