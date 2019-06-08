# hcloud.tf - Terraform provisioning script for mailcow on Hetzner Cloud

# Define Hetzner cloud provider
provider "hcloud" {
  token = "${var.hcloud_token}"
}

# Define SSH keys
resource "hcloud_ssh_key" "default" {
  name = "Terraform Key"
  public_key = "${file("${var.hcloud_ssh_keyfile}")}"
}

data "template_file" "mailcow_config" {
  template = "${file("templates/mailcow.sh")}"
  vars = {
    MOUNT_DEVICE = "${hcloud_volume.data.linux_device}"
    MAILCOW_HOSTNAME = "${var.mailcow_hostname}"
    MAILCOW_TZ = "${var.mailcow_tz}"
    MAILCOW_BACKUP_DIR = "${var.mailcow_backup_dir}"
    MAILCOW_BACKUP_FILE = "${var.mailcow_backup_file}"
    MAILCOW_BACKUP_SIZE = "${var.mailcow_backup_size}"
    FLOATING_IPV4 = "${hcloud_floating_ip.master.ip_address}"
  }
}

data "template_file" "system_config" {
  template = "${file("templates/system.sh")}"
  vars = {
    SSH_USER = "${var.hcloud_ssh_user}"
    SSH_PORT = "${var.hcloud_ssh_port}"
    FLOATING_IPV4 = "${hcloud_floating_ip.master.ip_address}"
  }
}

# Cloud-init template used for bootstrapping server
data "template_file" "broker_cloudinit" {
  template = "${file("templates/userdata.yml")}"
  vars = {
    MAILCOW_TZ = "${var.mailcow_tz}"
    SSH_USER = "${var.hcloud_ssh_user}"
    HCLOUD_SSH_ALLOWEDKEYS = "${var.hcloud_ssh_allowedkeys}"
    CONTENT_MAILCOW = "${base64gzip(data.template_file.mailcow_config.rendered)}"
    CONTENT_SYSTEM = "${base64gzip(data.template_file.system_config.rendered)}"
    }
  }


# Define server instance
resource "hcloud_server" "mailcow" {
  name = "${var.hcloud_servername}"
  image = "${var.hcloud_os}"
  server_type = "${var.hcloud_server}"
  location = "${var.hcloud_location}"
  ssh_keys = ["${hcloud_ssh_key.default.id}"]
  user_data = "${data.template_file.broker_cloudinit.rendered}"
}

# Define storage volume
resource "hcloud_volume" "data" {
  name = "${var.hcloud_volumename}" 
  location = "${var.hcloud_location}"
  size     = var.hcloud_volumesize
  format = "${var.hcloud_volumeformat}"
}

# Attach storage volume to server instance
resource "hcloud_volume_attachment" "main" {
  volume_id = "${hcloud_volume.data.id}"
  server_id = "${hcloud_server.mailcow.id}"
  automount = true
}

# Define floating IPv4 address
resource "hcloud_floating_ip" "master" {
  type = "ipv4"
  home_location = "${var.hcloud_location}"
  description = "${var.hcloud_ipname}"
}

# Setup RDNS for Floating IP
resource "hcloud_rdns" "floating_master" {
  floating_ip_id = "${hcloud_floating_ip.master.id}"
  ip_address = "${hcloud_floating_ip.master.ip_address}"
  dns_ptr = "${var.mailcow_hostname}"
}

# Attach floating IPv4 to server instance
resource "hcloud_floating_ip_assignment" "main" {
  floating_ip_id = "${hcloud_floating_ip.master.id}"
  server_id = "${hcloud_server.mailcow.id}"
}

