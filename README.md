## Mailcow with Terraform and Hetzner Cloud
Cloudctl-mailcow is a menu driven program to provision, maintain and monitor a [mailcow](https://mailcow.email) server hosted in Hetzner cloud. Multiple options can customised for your installation - see installation below.

## Installation

### Prerequisites
- Local linux based host with Terraform and bash for provisioning and remote management of your mailcow server.
- A Hetzner account and API token for Hetzner cloud (you can create this in their cloud console: Access --> API Tokens --> Generate API Token.
- SSH key(s) - these will be used for access to your mailcow server. You can generate your keys with: $ ssh-keygen -o -a 100 -t ed25519 -f ./id_ed25519_mailcow_user -C "name@clienthost"
- Fully qualified domain name (FQDN) - your mailserver will need a rDNS (PTR) entry for the floating IP.
- Note: This program will provision infrastructure through Hetzner cloud and costs may be incurred. Please use at your own risk.

### Quick Start
```sh
$ git clone https://github.com/hobbsAU/cloudctl-mailcow.git
$ cd cloudctl-mailcow
$ cp mailcow.conf.sample mailcow.conf
$ vim mailcow.conf
$ ./cloudctl-mailcow
```

## Design

### cloudctl-mailcow Menu
cloudctl-mailcow is used for three main functions Deploy, Manage and Monitor.

The "Deploy" menu is used to provision all mailcow infrastructure including server, volume, mailcow software, and backup scripts. The Deploy menu is also used to remove any existing infrastructure items as well.

The "Manage" menu is used for mailcow maintenance operations including updating, backup, start/stop, and server updates.

The "Monitor" menu is used for viewing mailcow logs, backup logs, and cloud-init logs.

### Environment provisioning
Infrastructure provisioning is handled by Terraform. 

The Terraform resource configuration file is called "hcloud.tf" and found in the root directory of the project.

The Terraform file creates the following if they do not already exist:
- Virtual cloud server instance that includes
  - O/S definition - this must be "debian-9" for cloudctl-mailcow to function correctly.
  - instance type
  - location
  - adds ssh keys
- Virtual cloud persistent volume including size and format
- Bootstrap O/S configuration using cloud-init and a cloud-config format yaml file
- Floating IP address - this is used for your mailcow server and you will most likely need to whitelist this (see whitelisting section below).

### Initial environment configuration
Environment configuration is handled by cloud-init. 

The primary configuration file is called "userdata.yml", and is written in cloud-config yaml format. It can be found in the templates subdirectory of the project.

This includes:
- Updated package lists and base package updates
- Required packages
- User configuration with SSH key provisioning
- Security hardening
- Docker configuration
- SWAP partition
- Loading additional provisioning scripts onto the cloud server

This config file is limied to 32K (Hetzner imposed userdata API limit). Using the gzip and base64 options in template_cloudinit_config did not work - the base64 data was available however the cloud-init process on the virtual cloud server did not decode. Another option would be to use a custom handler https://cloudinit.readthedocs.io/en/latest/topics/format.html. Instead I am using gzip+base64 within each write_files directive within the cloud-config script minimising the space each script requires.

### O/S configuration
O/S configuration is handled by a Bash shell script. This script is executed by cloud-init. 

The configuration file is called "system.sh", and is written in Bash with strict modes enabled. It can be found in the templates subdirectory of the project.

This scipt includes:
- Required packages
- Shell customisations
- Security hardening
- Docker configuration
- Volume mounting
- Network configuration
- Backup configuration
- Additional provisioning scripts


### Mailcow installation and configuration
Mailcow installation is handled by its own script "mailcow.sh" executed on the remote cloud instance via cloudctl-mailcow. 

This scipt includes:
- Required packages
- Mailcow installer
- Mailcow updater
- Backup installer for a borgbackup compatible backup repository


### Mailcow updates
Mailcow updates are handled by the cloudctl-mailcow menus.


### Mailcow backup/restore
Coming soon..

## Whitelisting
Coming soon..
