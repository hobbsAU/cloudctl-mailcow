#!/bin/bash

# system.sh - bash script to configure O/S related setting and software
# Note: this file is rendered by Terraform $${ ... } sequence is an interpolation

#Set Bash strict modes
set -xeuo pipefail

	# UMASK for security
	umask 077

	# Remove password without locking account
	usermod -p '*' ${SSH_USER}
  
	# Setup aliases, prompts and fix ethernet
	sed -i -e '/^#alias ll/s/^#//' /home/${SSH_USER}/.bashrc
	sed -i -e '/^# export LS_OPTIONS/s/^#//' /root/.bashrc
	sed -i -e '/^# alias ll/s/-l/-al/' -e '/^# alias ll/s/^#//' /root/.bashrc
	echo "PS1='$${debian_chroot:+($debian_chroot)}\[\033[01;32m\]\u@\h\[\033[00m\]:\[\033[01;34m\]\w\[\033[00m\]\$ '" >>/root/.bashrc
	echo -e "set mouse-=a\nsyntax on" > ~/.vimrc

	# Remove unwanted/conflicting packages
	systemctl stop exim4 || echo "Failed to stop exim4"
	apt-get purge -y --auto-remove exim4 || echo "Failed to remove exim4"

	# Hetzner networking changes (fix ethernet and move to static IP to disable DHCP)
	sed -i 's/eth0:0/eth0/g' /etc/network/interfaces.d/50-cloud-init.cfg
	sed -i "s/^iface eth0 inet dhcp/iface eth0 inet static\n    address $(curl -s http://169.254.169.254/latest/meta-data/public-ipv4)\n    netmask 255.255.255.255\n    gateway 172.31.1.1/g" /etc/network/interfaces.d/50-cloud-init.cfg

	# Configure Floating IP
	cat <<-"EOF" > /etc/network/interfaces.d/60-my-floating-ip.cfg
	auto eth0:1
	iface eth0:1 inet static
	    address ${FLOATING_IPV4}
	    netmask 32
	EOF
	chmod 0644 /etc/network/interfaces.d/60-my-floating-ip.cfg
	systemctl daemon-reload; systemctl restart networking.service

	# Configure SSH umask
	if [[ "grep -q 'session    optional     pam_umask.so umask=0077' /etc/pam.d/sshd" ]];  then
	cat <<-EOF >> /etc/pam.d/sshd
	# Setting UMASK for all ssh based connections (ssh, sftp, scp)
	session    optional     pam_umask.so umask=0077
	EOF
	fi

	# Configure SSH
	cat <<-EOF > /etc/ssh/sshd_config
	Port ${SSH_PORT}
	AddressFamily inet
	ListenAddress $(ip -o route get to 1 | sed -n 's/.*src \([0-9.]\+\).*/\1/p')
	Protocol 2
	KexAlgorithms curve25519-sha256@libssh.org
	HostKey /etc/ssh/ssh_host_ed25519_key
	Ciphers chacha20-poly1305@openssh.com
	MACs hmac-sha2-512-etm@openssh.com,hmac-sha2-256-etm@openssh.com
	PermitRootLogin no
	StrictModes yes
	MaxAuthTries 3
	PubkeyAuthentication yes
	AuthorizedKeysFile      .ssh/authorized_keys
	HostbasedAuthentication no
	X11Forwarding no
	AllowTcpForwarding no
	AllowAgentForwarding no
	IgnoreRhosts yes
	PasswordAuthentication no
	PermitEmptyPasswords no
	ChallengeResponseAuthentication no
	UsePrivilegeSeparation sandbox
	LogLevel VERBOSE
	AllowUsers ${SSH_USER} 
	ClientAliveInterval 300
	ClientAliveCountMax 3
	UsePAM yes
	AuthenticationMethods publickey
	EOF
        chmod 0400 /etc/ssh/sshd_config
        systemctl restart sshd.service

	# Clear out old ssh keys
	/bin/rm -v /etc/ssh/ssh_host_*
	dpkg-reconfigure openssh-server
        systemctl restart sshd.service

	# Install and configure fail2ban
	apt-get install -y --install-recommends fail2ban
	cat <<-"EOF" > /etc/fail2ban/jail.d/jail-debian.local
	[sshd]
	enabled = true
	port = ${SSH_PORT}
	maxretry = 3
	findtime = 43200
	bantime = 86400
	[sshd-ddos]
	enabled = true
	port = ${SSH_PORT}
	maxretry = 3
	findtime = 43200
	bantime = 86400
	EOF
	chmod 0644 /etc/fail2ban/jail.d/jail-debian.local
	systemctl restart fail2ban.service

	# Setup Hetzner cloud automount - we use the content from /var/lib/cloud/instances/xxxxxx/vendor-cloud-config.txt vendor-data write_files 
	# content here as the user-data write directives seem to interfere and override the vendor-data ones. 
	cat <<-"EOF" > /etc/udev/rules.d/99-hcloud-automount.rules
	# Check if it is a Hetzner Cloud Volume
	ACTION!="add", GOTO="FINISH"
	SUBSYSTEM!="block", GOTO="FINISH"
	ENV{ID_VENDOR}!="HC", GOTO="FINISH"
	ENV{ID_MODEL}!="Volume", GOTO="FINISH"
	# Abort unless the user explicitly requests this feature
	#   The API returns a success code when the automount option is active.
	#   This is just a oneshot url with an expiry of just a few minutes.
	#   On any error (404 on the URL, no curl installed, or timeout, ...) the rule
	#   will abort
	IMPORT{program}="/bin/sh -c 'curl --max-time 1 --fail 169.254.169.254/_internal/v1/volumes/$env{ID_SERIAL_SHORT} > /dev/null 2>&1 && echo HC_CONFIGURE=yes'"
	ENV{HC_CONFIGURE}!="yes", GOTO="FINISH"
	ENV{MOUNT_PATH}="/mnt/%E{ID_VENDOR}_%E{ID_MODEL}_%E{ID_SERIAL_SHORT}"
	ENV{SOURCE_PATH}="/dev/disk/by-id/%E{ID_BUS}-%E{ID_SERIAL}"
	RUN{program}+="/bin/mkdir -p %E{MOUNT_PATH}"
	# Create an fstab entry
	RUN{program}+="/bin/sh -c 'grep -q %E{SOURCE_PATH} /etc/fstab || echo %E{SOURCE_PATH} %E{MOUNT_PATH} %E{ID_FS_TYPE} discard,nofail,defaults 0 0 >> /etc/fstab'"
	# Manually trigger the fstab to systemd.mount generator
	RUN{program}+="/bin/systemctl daemon-reload"
	# Activates the new rule
	RUN{program}+="/bin/systemctl restart local-fs.target"
	LABEL="FINISH"
	EOF
	systemctl daemon-reload
	udevadm control --reload
	udevadm trigger -c add -s block -p ID_VENDOR=HC --verbose -p ID_MODEL=Volume
	udevadm settle -t 15 # required to block script until mount is complete otherwise it's possible to enter a race condition

# Exit gracefully
exit 0
