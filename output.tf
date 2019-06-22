# output.tf - all output variables are declared here
output "tf_floating_ipv4" {
  value = "${hcloud_floating_ip.master.ip_address}"
}
output "tf_host_ipv4" {
  value = "${hcloud_server.mailcow.ipv4_address}"
}
output "tf_volume_device" {
  value = "${hcloud_volume.data.linux_device}"
}
output "tf_dns_ptr" {
  value = "${hcloud_rdns.floating_master.dns_ptr}"
}
