#!/bin/bash

# mailcow.sh - bash script to install mailcow and related software

# Set Bash strict modes
set -xeuo pipefail

# Set umask
umask 0022

# Define Globals
PARAMS=""

function Mailcow_Install() {
	# Check environment 
	mailcow_hostname=${MAILCOW_HOSTNAME} mailcow_tz=${MAILCOW_TZ} mount_device=${MOUNT_DEVICE}
	[[ "$${mailcow_hostname:-}" && "$${mailcow_tz:-}" && "$${mount_device:-}" ]] || { echo "Variable not set"; exit 1; }
	
	#Set mailcow environment variables for unattended installation
	export MAILCOW_HOSTNAME=$mailcow_hostname MAILCOW_TZ=$mailcow_tz

	# Guard against udev race condition
	if [[ $(/bin/findmnt -nr -o target -S $mount_device) ]]; then
		#Set volume location
		mnt_dir=$(/bin/findmnt -nr -o target -S $mount_device)
	else
		echo "Error mount not found!"; exit 1;
	fi

        # Install docker-compose
        curl -L https://github.com/docker/compose/releases/download/$(curl -Ls https://www.servercow.de/docker-compose/latest.php)/docker-compose-$(uname -s)-$(uname -m) > /usr/local/bin/docker-compose
        chmod +x /usr/local/bin/docker-compose

	# Update Docker storage location
	echo -e "{  \"data-root\": \"$mnt_dir/docker\" }" | tee /etc/docker/daemon.json
	systemctl restart docker

	if [[ -d /opt/mailcow-dockerized ]]; then
		# Shutdown mailcow
		cd /opt/mailcow-dockerized/ && sudo docker-compose down; cd;
		# Remove any previous installation
		rm -rf /opt/mailcow-dockerized
	fi
	
	# Clone mailcow repo
	git clone https://github.com/mailcow/mailcow-dockerized /opt/mailcow-dockerized
	cd /opt/mailcow-dockerized && ./generate_config.sh

	# Check for previous config and restore otherwise backup new config required to save DB credentials
	if [[ -f $mnt_dir/mailcow.conf ]]; then
		mv ./mailcow.conf ./mailcow.orig;
		cp $mnt_dir/mailcow.conf .;
	else
		cp mailcow.conf $mnt_dir/;
	fi

	# Bind mailcow to floating IP address
	sed -i -E 's/^#SNAT_TO_SOURCE=.*$|^SNAT_TO_SOURCE=.*$/SNAT_TO_SOURCE=${FLOATING_IPV4}/g' ./mailcow.conf
	# Disable IP check for acme-mailcow when using floating IP
	sed -i -E 's/^#SKIP_IP_CHECK=.*$|^SKIP_IP_CHECK=.*$/SKIP_IP_CHECK=y/g' ./mailcow.conf
}


function Mailcow_Update() {
	echo "Upgrading Mailcow"

        if [[ -d /opt/mailcow-dockerized ]]; then
		cd /opt/mailcow-dockerized && echo 'y' | ./update.sh --check

		if [ $? -eq 0 ]; then
			echo "Updating updater..."
			cd /opt/mailcow-dockerized && git fetch origin master
			cd /opt/mailcow-dockerized && git checkout origin/master update.sh
			echo "Installing updates"
			cd /opt/mailcow-dockerized && echo 'y' | ./update.sh
			echo "Collecting Garbage"
			cd /opt/mailcow-dockerized && echo 'y' | ./update.sh --gc
			echo "Check containers are running"
			docker ps && docker system df
			echo "Executing - docker system prune"
			docker system prune && docker system df
		else
			echo "No updates are available!"
			exit 3
		fi
	else
		exit 1
	fi
}


function Backup_Install() {
	#DEFINE GLOBALS
	mailcow_backup_dir=${MAILCOW_BACKUP_DIR} mailcow_backup_file=${MAILCOW_BACKUP_FILE} mailcow_backup_size=${MAILCOW_BACKUP_SIZE}

	# Check environment 
	[[ "$${mailcow_backup_dir:-}" && "$${mailcow_backup_file:-}" && "$${mailcow_backup_size:-}" ]] || { echo "Variable not set"; exit 1; }

	#Set volume location
	mnt_dir=$(echo "$mailcow_backup_dir" |sed -e "s/^\///; s/\/$//; s/\//-/g;")

	# Test for backup mount
	[[ ! -d "$mailcow_backup_dir" ]] && mkdir -p $mailcow_backup_dir

	# Test for backup disk and free space and then create backup disk
	if [[ ! -f "$mailcow_backup_file" && $mailcow_backup_size -lt $(df |grep "/$" |awk '{ print $4/(1024*1024) }' | cut -d. -f1) ]]; then
		# Create disk
		dd if=/dev/zero of=$mailcow_backup_file bs=1G count=$mailcow_backup_size

		# Format Disk
		mkfs.ext4 $mailcow_backup_file

	else
		echo "Backup disk exists"
	fi

	#Install mount script
	if [[ ! -f "/etc/systemd/system/$mnt_dir.mount" ]]; then
		echo "[Unit]
		Description=Mount Backup Volume $mailcow_backup_file

		[Mount]
		What=$mailcow_backup_file
		Where=$mailcow_backup_dir
		Options=defaults,loop,noexec,nosuid,nofail,noatime,rw
		Type=ext4

		[Install]
		WantedBy = multi-user.target" | tee /etc/systemd/system/$mnt_dir.mount
		systemctl daemon-reload
		systemctl enable $mnt_dir.mount
		systemctl start $mnt_dir.mount
	else
		echo "Backup volume mount script exists"
	fi
}

while (( "$#" )); do
	case "$1" in
	mailcow_install)
		echo "Mailcow Install"
		Mailcow_Install 
		shift
		;;
	mailcow_update)
		echo "Mailcow Update"
		Mailcow_Update
		shift
		;;
	mailcow_backup)
		echo "Mailcow Backup"
		#Mailcow_Backup
		shift
		;;
	backup_install)
		echo "Backup Install"
		Backup_Install
		shift
		;;
	-*|--*=) # unsupported flags
		echo "Error: Unsupported argument $1" >&2
		exit 1
		;;
	*) # preserve unhandled arguments
		PARAMS="$PARAMS $1"
		shift
		;;
	esac
done

# Flag unhandled arguements
[[ ! -z "$${PARAMS}" ]] && { echo "Unhandled arguements are: $PARAMS"; exit 1; } || exit 0;
