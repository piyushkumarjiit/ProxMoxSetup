# -------------------------------------------------------------------------
# FILE: docker-dev-tools.sh
# ROLE: Internal LXC Environment Provisioner
#
# DESCRIPTION:
# Executed inside the LXC to install the complete AI development stack.
# Configures Docker Engine, the NVIDIA Container Toolkit, and optimizes 
# the environment for VS Code Remote development (SSH and Inotify).
#
# HARDWARE COMPATIBILITY:
# - Targets NVIDIA Container Toolkit for Pascal-architecture GPUs.
# - Configures CDI and NVIDIA-runtime as the default Docker provider.
# -------------------------------------------------------------------------

#!/bin/bash
# container-setup.sh - Runs inside the LXC

echo "--- Internal: Updating System & Locales ---"
apt update && apt install -y locales curl gpg openssh-server git build-essential
locale-gen en_US.UTF-8
update-locale LANG=en_US.UTF-8
ldconfig

echo "--- Internal: Installing Docker ---"
curl -fsSL https://get.docker.com -o get-docker.sh && sh get-docker.sh

echo "--- Internal: Installing NVIDIA Container Toolkit ---"
curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list | \
  sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' | \
  tee /etc/apt/sources.list.d/nvidia-container-toolkit.list

apt update && apt install -y nvidia-container-toolkit

echo "--- Internal: Configuring Docker Runtime & CDI ---"
# Force NVIDIA runtime to be the default for Docker
nvidia-ctk runtime configure --runtime=docker --set-as-default
# Disable cgroups check which often causes LXC-Docker friction
nvidia-ctk config --set nvidia-container-cli.no-cgroups --in-place

systemctl restart docker

echo "--- Internal: Final GPU Validation ---"
# Test 1: Direct LXC check
nvidia-smi

# Test 2: Docker Passthrough check
docker run --rm --gpus all --security-opt apparmor=unconfined nvidia/cuda:12.6.3-base-ubuntu24.04 nvidia-smi


echo "--- Installing SSH Server & Tools ---"

# Enable root login (required for most LXC dev setups)
sed -i 's/#PermitRootLogin prohibit-password/PermitRootLogin yes/' /etc/ssh/sshd_config
sed -i 's/#PasswordAuthentication yes/PasswordAuthentication yes/' /etc/ssh/sshd_config

# Start SSH
systemctl enable ssh
systemctl restart ssh

echo "--- Environment Prep for VS Code ---"
# Increase file watch limits (prevents VS Code from crashing on large projects)
echo "fs.inotify.max_user_watches=524288" >> /etc/sysctl.conf
sysctl -p

echo "DONE: Container is ready for connection."
