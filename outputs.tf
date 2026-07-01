# stratum-factory-gcp-gce-instance/outputs.tf

output "instance_ids" {
  description = <<-EOT
    Map of instance name to the unique resource ID of each google_compute_instance.
    Type: map(string).
    Example: { "bastion" = "projects/stratum-dev-sandbox/zones/europe-west1-b/instances/stratum-dev-bastion" }
    Use instance IDs to reference GCE instances in other GCP API calls.
  EOT
  value       = { for name, vm in google_compute_instance.vm : name => vm.id }
}

output "instance_self_links" {
  description = <<-EOT
    Map of instance name to the self-link URI of each google_compute_instance.
    Type: map(string).
    Example: { "bastion" = "https://www.googleapis.com/compute/v1/projects/stratum-dev-sandbox/zones/europe-west1-b/instances/stratum-dev-bastion" }
    Use self-links to reference instances in GCP IAM bindings or instance groups.
  EOT
  value       = { for name, vm in google_compute_instance.vm : name => vm.self_link }
}

output "instance_names" {
  description = <<-EOT
    Map of instance name to the fully-qualified GCP resource name.
    Type: map(string).
    Example: { "bastion" = "stratum-dev-bastion", "k3s" = "stratum-dev-k3s" }
  EOT
  value       = { for name, vm in google_compute_instance.vm : name => vm.name }
}

output "internal_ips" {
  description = <<-EOT
    Map of instance name to the nic0 (first network interface) internal IP address.
    Type: map(string).
    Example: { "bastion" = "10.100.0.5", "k3s" = "10.100.0.6", "containerlab" = "10.100.0.7" }
    Use to configure DNS records (stratum.dev. zone) and inter-node SSH/gRPC connections.
  EOT
  value       = { for name, vm in google_compute_instance.vm : name => vm.network_interface[0].network_ip }
}

output "external_ips" {
  description = <<-EOT
    Map of instance name to the nic0 external (NAT) IP address. Empty string for instances with no access_config.
    Type: map(string).
    Example: { "bastion" = "34.90.12.34", "k3s" = "", "containerlab" = "" }
    The bastion external IP matches the reserved static address (stratum-factory-gcp-address output).
  EOT
  value = {
    for name, vm in google_compute_instance.vm : name =>
    length(vm.network_interface[0].access_config) > 0 ? vm.network_interface[0].access_config[0].nat_ip : ""
  }
}
