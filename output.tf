# output.tf - all output variables are declared here
output "floating_ipv4" {
  value = "${hcloud_floating_ip.master.ip_address}"
}
output "host_ipv4" {
  value = "${hcloud_server.mailcow.ipv4_address}"
}

output "volume_device" {
  value = "${hcloud_volume.data.linux_device}"
}
