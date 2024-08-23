#!/bin/bash

echo "Step 1 – Checking the System for Swap Information"
sudo swapon --show
free -h

echo "Step 2 – Checking Available Space on the Hard Drive Partition"
df -h

echo "Step 3 – Creating a Swap File"
sudo fallocate -l 4G /swapfile
ls -lh /swapfile

echo "Step 4 – Enabling the Swap File"
sudo chmod 600 /swapfile
ls -lh /swapfile
sudo mkswap /swapfile
sudo swapon /swapfile
sudo swapon --show
free -h

echo "Step 5 – Making the Swap File Permanent"
sudo cp /etc/fstab /etc/fstab.bak
echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab
