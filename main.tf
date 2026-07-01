# stratum-factory-gcp-gce-instance/main.tf
#
# FACTORY MODULE — Parameterized GCE VM instances for STRATUM node roles.
#
# STATELESS & INPUT-ONLY. State owned by the calling Wrapper.
# Creates N google_compute_instance resources (and optional data disks) from the
# instances list(object) input. Supports all three STRATUM dev node roles:
#   bastion/DNS (e2-micro, always-on, external IP)
#   k3s         (n2d-highmem-16, spot)
#   Containerlab (n2d-highmem-8, spot, nested-virt — D-ENV-22)
#
# Consumed by the Wrapper as:
#   source = "git::https://github.com/apellini/stratum-factory-gcp-gce-instance.git?ref=v<semver>"

# ── Local helpers ─────────────────────────────────────────────────────────────
# Flatten all per-instance attached_disk entries into a single keyed map for
# independent google_compute_disk resources, then attach them via dynamic blocks.
locals {
  # { "<instance-name>-<disk-name>" => { instance_name, zone, name, size_gb, type } }
  attached_disk_map = {
    for item in flatten([
      for i in var.instances : [
        for d in i.attached_disks : {
          key           = "${i.name}-${d.name}"
          instance_name = i.name
          zone          = i.zone
          disk_name     = d.name
          size_gb       = d.size_gb
          type          = d.type
        }
      ]
    ]) : item.key => item
  }
}

# ── Optional data disks ───────────────────────────────────────────────────────
# One persistent disk per attached_disk entry across all instances.
resource "google_compute_disk" "data" {
  for_each = local.attached_disk_map

  project = var.project_id
  name    = "${var.name_prefix}-${each.value.instance_name}-${each.value.disk_name}"
  zone    = each.value.zone
  size    = each.value.size_gb
  type    = each.value.type

  description = "STRATUM ${var.environment} data disk ${each.value.disk_name} for ${each.value.instance_name} — managed by OpenTofu (stratum-factory-gcp-gce-instance)"

  labels = merge(var.tags, {
    environment = var.environment
    managed_by  = "opentofu"
  })
}

# ── GCE VM instances ──────────────────────────────────────────────────────────
resource "google_compute_instance" "vm" {
  for_each = { for i in var.instances : i.name => i }

  project      = var.project_id
  name         = "${var.name_prefix}-${each.value.name}"
  machine_type = each.value.machine_type
  zone         = each.value.zone
  tags         = each.value.network_tags
  description  = "STRATUM ${var.environment} ${each.value.name} node — managed by OpenTofu (stratum-factory-gcp-gce-instance)"

  deletion_protection = false

  # ── Boot disk ────────────────────────────────────────────────────────────────
  boot_disk {
    initialize_params {
      image = each.value.boot_image
      size  = each.value.boot_disk_size_gb
      type  = each.value.boot_disk_type
    }
  }

  # ── Attached data disks ───────────────────────────────────────────────────────
  dynamic "attached_disk" {
    for_each = { for d in each.value.attached_disks : d.name => d }
    content {
      source = google_compute_disk.data["${each.value.name}-${attached_disk.value.name}"].id
    }
  }

  # ── Network interfaces ────────────────────────────────────────────────────────
  # First entry is nic0 (default route). GCP requires each NIC to be in a distinct VPC.
  dynamic "network_interface" {
    for_each = each.value.network_interfaces
    content {
      subnetwork = network_interface.value.subnetwork
      network_ip = network_interface.value.network_ip

      dynamic "access_config" {
        for_each = network_interface.value.assign_external_ip ? [1] : []
        content {
          nat_ip = network_interface.value.external_ip
        }
      }
    }
  }

  # ── Scheduling ────────────────────────────────────────────────────────────────
  # spot=true  → SPOT preemptible (k3s and Containerlab nodes, per-session teardown)
  # spot=false → STANDARD always-on (bastion/DNS node, free-tier e2-micro)
  scheduling {
    preemptible                 = each.value.spot
    automatic_restart           = !each.value.spot
    provisioning_model          = each.value.spot ? "SPOT" : "STANDARD"
    instance_termination_action = each.value.spot ? "STOP" : null
  }

  # ── Nested virtualisation ─────────────────────────────────────────────────────
  # Required by the Containerlab node for vrnetlab (QEMU inside Docker) — D-ENV-22.
  # Enabled only on N2/N2D/C2/C3 machine families; not supported on E2.
  dynamic "advanced_machine_features" {
    for_each = each.value.enable_nested_virtualization ? [1] : []
    content {
      enable_nested_virtualization = true
    }
  }

  # ── Service account ───────────────────────────────────────────────────────────
  # k3s and Containerlab nodes use the compute SA for GCS bootstrap cache access.
  # Omitted for the bastion (e2-micro free tier, no GCS writes needed).
  dynamic "service_account" {
    for_each = each.value.service_account_email != null ? [1] : []
    content {
      email  = each.value.service_account_email
      scopes = each.value.service_account_scopes
    }
  }

  # ── Metadata / startup script ─────────────────────────────────────────────────
  # Pass-through inputs; bootstrap logic lives in external Helm/OpenTofu artifacts (HLD).
  # ssh-keys entry lives in metadata map — never hardcoded.
  metadata                = each.value.metadata
  metadata_startup_script = each.value.metadata_startup_script

  # ── Labels ───────────────────────────────────────────────────────────────────
  labels = merge(var.tags, each.value.labels, {
    environment = var.environment
    managed_by  = "opentofu"
  })
}
