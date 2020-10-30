#!/usr/bin/env bash

VERSION=$(cut -f4 -d\  /etc/redhat-release)
sudo tee -a /etc/yum.repos.d/CentOS-Vault.repo <<EOF
# Need to be able to download old kernel headers & devel
[C$VERSION-base]
name=CentOS-$VERSION - Base
baseurl=http://vault.centos.org/$VERSION/os/\$basearch/
gpgcheck=1
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-CentOS-7
enabled=1

[C$VERSION-updates]
name=CentOS-$VERSION - Updates
baseurl=http://vault.centos.org/$VERSION/updates/\$basearch/
gpgcheck=1
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-CentOS-7
enabled=1
EOF
sudo yum install kernel-devel-$(uname -r) kernel-headers-$(uname -r) -y
curl -O https://developer.download.nvidia.com/compute/cuda/repos/rhel7/x86_64/cuda-repo-rhel7-9.2.88-1.x86_64.rpm
sudo rpm --install cuda-repo-rhel7-9.2.88-1.x86_64.rpm
# Add Extra Packages for Enterprise Linux (EPEL)
# The NVIDIA driver RPM packages depend on other external packages, such as DKMS and libvdpau. # Those packages are only available on third-party repositories, such as EPEL
sudo yum install https://dl.fedoraproject.org/pub/epel/epel-release-latest-7.noarch.rpm -y
sudo yum install cuda -y
