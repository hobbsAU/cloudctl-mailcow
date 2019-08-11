#!/bin/bash

# mailcow.sh - bash script to install mailcow and related software

# Set Bash strict modes
set -xeuo pipefail

# Set umask
umask 0077

# Define Globals
PARAMS=""

function Mailcow_Install() {
	# Check environment and set mailcow environment variables for unattended installation
	[[ "${tf_volume_device:-}" ]] || { echo "Variable tf_volume_device not set"; exit 1; }
	[[ "${tf_floating_ipv4:-}" ]] || { echo "Variable tf_floating_ipv4 not set"; exit 1; }
	[[ "${tf_dns_ptr:-}" ]] && export MAILCOW_HOSTNAME=$tf_dns_ptr || { echo "Variable tf_dns_ptr not set"; exit 1; } 
	[[ -f /etc/timezone ]] && export MAILCOW_TZ=`cat /etc/timezone` || { echo "Cannot find timezone"; exit 1; }

	# Guard against udev race condition
	if [[ $(/bin/findmnt -nr -o target -S ${tf_volume_device}) ]]; then
		#Set volume location
		mnt_dir=$(/bin/findmnt -nr -o target -S ${tf_volume_device})
	else
		echo "Error mount not found!"; exit 1;
	fi

	# Set umask
	umask 0022

        # Install docker-compose
        curl -L https://github.com/docker/compose/releases/download/$(curl -Ls https://www.servercow.de/docker-compose/latest.php)/docker-compose-$(uname -s)-$(uname -m) > /usr/local/bin/docker-compose
        chmod +x /usr/local/bin/docker-compose

	# Update Docker storage location
	echo -e "{  \"data-root\": \"${mnt_dir}/docker\" }" | tee /etc/docker/daemon.json
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
	if [[ -f ${mnt_dir}/mailcow.conf ]]; then
		mv ./mailcow.conf ./mailcow.orig;
		cp ${mnt_dir}/mailcow.conf .;
	else
		cp mailcow.conf ${mnt_dir}/;
	fi

	# Bind mailcow to floating IP address
	sed -i -E "s/^#SNAT_TO_SOURCE=.*$|^SNAT_TO_SOURCE=.*$/SNAT_TO_SOURCE=${tf_floating_ipv4}/g" ./mailcow.conf
	# Disable IP check for acme-mailcow when using floating IP
	sed -i -E 's/^#SKIP_IP_CHECK=.*$|^SKIP_IP_CHECK=.*$/SKIP_IP_CHECK=y/g' ./mailcow.conf
	# Remove unnecessary and insecure ports
	#sed -i -E 's/^#SMTPS_PORT=.*$|^SMTPS_PORT=.*$/SMTPS_PORT=127.0.0.1:465/g' ./mailcow.conf
	sed -i -E 's/^#IMAP_PORT=.*$|^IMAP_PORT=.*$/IMAP_PORT=127.0.0.1:143/g' ./mailcow.conf
	sed -i -E 's/^#POP_PORT=.*$|^POP_PORT=.*$/POP_PORT=127.0.0.1:110/g' ./mailcow.conf

	# Harden ciphers
	sed -i 's/^\([[:blank:]]*\)ssl_cipher.*/\1ssl_ciphers \x27ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-SHA384:ECDHE-ECDSA-AES128-SHA256\x27;/g' /opt/mailcow-dockerized/data/conf/nginx/site.conf

	# Set umask
	umask 0077
}


function Mailcow_Update() {

	[[ "${tf_volume_device:-}" ]] || { echo "Variable tf_volume_device not set"; exit 1; }

	# Guard against udev race condition
	if [[ $(/bin/findmnt -nr -o target -S ${tf_volume_device}) ]]; then
		#Set volume location
		mnt_dir=$(/bin/findmnt -nr -o target -S ${tf_volume_device})
	else
		echo "Error mount not found!"; exit 1;
	fi

        if [[ -d /opt/mailcow-dockerized ]]; then
		echo "Checking for mailcow updates."
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
			docker system prune -f && docker system df
			docker pull hobbsau/borgmatic
			[[ -f ${mnt_dir}/mailcow.conf ]] && { mv ${mnt_dir}/mailcow.conf ${mnt_dir}/mailcow.conf.bak; cp /opt/mailcow-dockerized/mailcow.conf ${mnt_dir}/mailcow.conf; } || \
			{ cp /opt/mailcow-dockerized/mailcow.conf ${mnt_dir}/mailcow.conf; }
		else
			echo "No updates are available!"
			exit 3
		fi
	else
		exit 1
	fi
}


function Backup_Install() {
	# Check environment 
	[[ "${backup_dir:-}" && "${backup_file:-}" && "${backup_size:-}" && "${backup_repo:-}" && "${backup_hostkey:-}" && "${backup_sshkey_private:-}" && "${backup_repo_passphrase:-}" ]] || { echo "Variable not set"; exit 1; }

	# Test for backup mount
	[[ ! -d "${backup_dir}" ]] && mkdir -p ${backup_dir} || echo "Backup mount point exists."

	# Test for backup disk and free space and then create backup disk
	if [[ ! -f "${backup_file}" && ${backup_size} -lt $(df |grep "/$" |awk '{ print $4/(1024*1024) }' | cut -d. -f1) ]]; then
		# Create disk
		dd if=/dev/zero of=${backup_file} bs=1G count=${backup_size}
		# Format Disk
		mkfs.ext4 ${backup_file}
	else
		echo "Backup disk exists"
	fi

	# Install mount
	if [[ "grep -q ${backup_file} /etc/fstab" ]]; then
		echo "${backup_file} ${backup_dir} ext4 defaults,loop,noexec,nosuid,nofail,noatime,rw 0 0" | tee -a /etc/fstab
		systemctl daemon-reload && systemctl restart local-fs.target
	else
		echo "Backup volume mount script exists"
	fi

	# Load Mailcow variables
	[[ -f /opt/mailcow-dockerized/mailcow.conf ]] && source /opt/mailcow-dockerized/mailcow.conf || { echo "mailcow.conf doesn't exist."; exit 1; }
	CMPS_PRJ=$(echo ${COMPOSE_PROJECT_NAME} | tr -cd "[A-Za-z-_]")

	# Install borgmatic
	docker pull hobbsau/borgmatic

	# Add config directories
	[[ ! -d "/etc/borg" ]] && mkdir -p /etc/borg
	[[ ! -d "/etc/borgmatic" ]] && mkdir -p /etc/borgmatic
	[[ ! -d "~/.ssh" ]] && mkdir -p ~/.ssh

	# Install borgmatic conf
	[[ ! -f "/etc/borgmatic/config.yaml" ]] && echo "Copying borgmatic config" || echo "Overwriting borgmatic config"
	cat <<-EOF > /etc/borgmatic/config.yaml
	location:
	    source_directories:
	        - /backup

	    repositories:
	        - ${backup_repo}

	    exclude_patterns:
	        - 'dovecot-uidlist.lock'
	        - ~/*/.cache

	    exclude_caches: true
	    exclude_if_present: .nobackup

	storage:
	    #compression: auto,zstd
	    archive_name_format: '{hostname}-{now}'

	retention:
	    keep_daily: 3
	    keep_weekly: 4
	    keep_monthly: 12
	    keep_yearly: 2
	    prefix: '{hostname}-'

	consistency:
	    checks:
	        # uncomment to always do integrity checks. (takes long time for large repos)
	        - repository
	        - archives
	        #- disabled

	    check_last: 3
	    prefix: '{hostname}-'

	hooks:
	    # List of one or more shell commands or scripts to execute before creating a backup.
	    before_backup:
	        - echo "`date` --- Starting backup ---"

	    after_backup:
	        - echo "`date` --- Finished backup ---"
	EOF

	# Install repo key
	[[ ! -f "/etc/borg/repokey" ]] && echo "Copying repo key" || echo "Overwriting repo key"
	cat "/opt/scripts/${backup_repo_passphrase}" > /etc/borg/repokey
	chmod 600 /etc/borg/repokey

	# Install ssh key
	[[ ! -f "/root/.ssh/id_borg" ]] && echo "Copying ssh id" || echo "Overwriting ssh id"
	cat "/opt/scripts/${backup_sshkey_private}" > /root/.ssh/id_borg
	chmod 600 /root/.ssh/id_borg

	# Install borg backup host keys and test
	local hostname=${backup_repo%:*}; hostname=${hostname#*@};
	local keytype="$(echo ${backup_hostkey} | awk '{ print $1 }')"
	local pubkey="$(echo ${backup_hostkey} | awk '{ print $2 }')"
	[[ $(ssh-keygen -F "${hostname}" |grep "${pubkey}") ]] && echo "Backup host authenticated." || \
	{ echo "Installing host key."; ssh-keyscan -H -t ${keytype} ${hostname} | tee -a /root/.ssh/known_hosts; }

	# Install borgmatic systemd script
	[[ ! -f "/etc/systemd/system/borgmatic.service" ]] && echo "Installing systemd borgmatic.service" || echo "Overwriting systemd borgmatic.service"
	cat <<-EOF > /etc/systemd/system/borgmatic.service
	[Unit]
	Description=borg backup

	[Service]
	Type=oneshot
	ExecStart=/usr/bin/docker run \
	  --rm -t --name hobbsau-borgmatic --hostname %H \
	  -e TZ=${system_tz} \
	  -e BORG_PASSCOMMAND='cat /root/.config/borg/repokey' \
	  -e BORG_RSH='ssh -i /root/.ssh/id_borg' \
	  -v /etc/borg:/root/.config/borg \
	  -v /var/borgcache:/root/.cache/borg \
	  -v /etc/borgmatic:/root/.config/borgmatic:ro \
	  -v /root/.ssh:/root/.ssh \
	  -v $(docker volume ls -qf name=${CMPS_PRJ}_vmail-vol-1):/backup/vmail:ro \
	  -v ${backup_dir}:/backup/mailcow:ro \
	  hobbsau/borgmatic --stats --verbosity 1
	EOF

	[[ ! -f "/etc/systemd/system/borgmatic.timer" ]] && echo "Installing systemd borgmatic.timer" || echo "Overwriting systemd borgmatic.timer"
	cat <<-"EOF" > /etc/systemd/system/borgmatic.timer
	[Unit]
	Description=Run borg backup

	[Timer]
	OnCalendar=*-*-* 23:00:00
	Persistent=true

	[Install]
	WantedBy=timers.target
	EOF

	# Install mailcow backup systemd script
	[[ ! -f "/etc/systemd/system/mcbackup.service" ]] && echo "Installing systemd mcbackup.service" || echo "Overwriting systemd mcbackup.service"
	cat <<-EOF > /etc/systemd/system/mcbackup.service
	[Unit]
	Description=mailcow backup

	[Service]
	Type=oneshot
	Environment=MAILCOW_BACKUP_LOCATION=${backup_dir}
	ExecStart=/opt/mailcow-dockerized/helper-scripts/backup_and_restore.sh backup crypt redis rspamd postfix mysql
	EOF

	[[ ! -f "/etc/systemd/system/mcbackup.timer" ]] && echo "Installing systemd mcbackup.timer" || echo "Overwriting systemd mcbackup.timer"
	cat <<-"EOF" > /etc/systemd/system/mcbackup.timer
	[Unit]
	Description=Run mcbackup

	[Timer]
	OnCalendar=*-*-* 22:50:00
	Persistent=true

	[Install]
	WantedBy=timers.target
	EOF

	# Enable systemd services
	if [[ -f "/etc/systemd/system/borgmatic.service" ]] && [[ -f "/etc/systemd/system/mcbackup.service" ]]; then
	systemctl daemon-reload
	systemctl enable borgmatic.timer
	systemctl start borgmatic.timer
	systemctl enable mcbackup.timer
	systemctl start mcbackup.timer
	fi

}

Mailcow_Backup() {

systemctl start mcbackup.service && systemctl start borgmatic.service

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
		Mailcow_Backup
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
		PARAMS="${PARAMS} $1"
		shift
		;;
	esac
done

# Flag unhandled arguements
[[ ! -z "${PARAMS}" ]] && { echo "Unhandled arguments are: ${PARAMS}"; exit 1; } || exit 0;
