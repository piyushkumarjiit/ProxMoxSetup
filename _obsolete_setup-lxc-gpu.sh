#!/bin/bash
# setup-lxc-gpu.sh - Run INSIDE the LXC (e.g., ID 105)

echo "--- 1. Updating System & Installing Essentials ---"
apt update && apt install -y curl git gpg coreutils

echo "--- 2. Adding NVIDIA Container Toolkit Repository ---"
curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list | \
  sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' | \
  tee /etc/apt/sources.list.d/nvidia-container-toolkit.list
apt update

echo "--- 3. Installing NVIDIA Container Toolkit ---"
apt install -y nvidia-container-toolkit

echo "--- 4. Installing Docker Engine ---"
if ! command -v docker &> /dev/null; then
    curl -fsSL https://get.docker.com -o get-docker.sh
    sh get-docker.sh
else
    echo "Docker already installed, skipping..."
fi

echo "--- 5. Configuring Docker for NVIDIA Runtime ---"
nvidia-ctk runtime configure --runtime=docker
systemctl restart docker

echo "--- 6. Final Verification ---"
echo "Testing GPU visibility within Docker..."
docker run --rm --gpus all nvidia/cuda:12.4.1-base-ubuntu22.04 nvidia-smi
