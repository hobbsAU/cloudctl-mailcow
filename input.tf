# input.tf - All variables are declared here and defined elsewhere in secrets.tfvars

# hcloud provider variables
variable "hcloud_token" {}
variable "hcloud_ssh_keyfile" {}
variable "hcloud_server" {}
variable "hcloud_os" {}
variable "hcloud_ipname" {}
variable "hcloud_location" {}
variable "hcloud_volumesize" {}
variable "hcloud_volumename" {}
variable "hcloud_volumeformat" {}
variable "hcloud_servername" {}
variable "hcloud_ssh_port" {}
variable "hcloud_ssh_user" {}
variable "hcloud_ssh_allowedkeys" {}

# mailcow varirables
variable "mailcow_hostname" {}
variable "mailcow_tz" {}
variable "mailcow_backup_dir" {}
variable "mailcow_backup_file" {}
variable "mailcow_backup_size" {}


