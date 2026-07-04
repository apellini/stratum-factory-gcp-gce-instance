# stratum-factory-gcp-gce-instance/variables.tf
#
# FACTORY pattern: all configuration received as input. NOTHING is hardcoded.
# Every variable carries a strict validation block.

variable "environment" {
  description = "Deployment environment. Must be one of the approved environment names."
  type        = string

  validation {
    condition     = contains(["dev", "stage", "main"], var.environment)
    error_message = "environment must be one of: dev, stage, main."
  }
}

variable "project_id" {
  description = "GCP project ID to deploy into. Must be non-empty with no whitespace."
  type        = string

  validation {
    condition     = length(var.project_id) > 0 && !can(regex("\\s", var.project_id))
    error_message = "project_id must be a non-empty string with no whitespace."
  }
}

variable "name_prefix" {
  description = "Prefix applied to all resource names. 3–24 lowercase alphanumeric or hyphens, starts with a letter."
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{2,23}$", var.name_prefix))
    error_message = "name_prefix must be 3–24 chars, start with a letter, lowercase alphanumeric or hyphens only."
  }
}

# tflint-ignore: terraform_unused_declarations
variable "tags" {
  description = "Map of labels applied to all resources (merged with per-instance labels). Keys and values must be non-empty strings."
  type        = map(string)
  default     = {}

  validation {
    condition     = alltrue([for k, v in var.tags : length(k) > 0 && length(v) > 0])
    error_message = "All tag keys and values must be non-empty strings."
  }
}

variable "instances" {
  description = <<-EOT
    List of GCE VM instances to provision. Each entry creates one google_compute_instance.
    Instance names must be unique within the list (used as for_each keys).

    Required per-instance fields: name, machine_type, zone, boot_image, network_interfaces (>=1).
    All other fields are optional with sensible defaults.

    network_interfaces:
      - subnetwork           (required) GCP subnetwork self-link URI.
      - network_ip           (optional, default null) Static internal IP; null = auto-assigned.
      - assign_external_ip   (optional, default false) Set true to attach an access_config (external IP).
      - external_ip          (optional, default null) Reserved static external IP to bind (nat_ip).
                             Requires assign_external_ip = true. Null = ephemeral IP when assign_external_ip = true.

    Scheduling:
      - spot                 (optional, default false) true = SPOT preemptible; false = STANDARD always-on.

    Nested virtualisation (Containerlab node only):
      - enable_nested_virtualization (optional, default false) Enables nested-virt via advanced_machine_features.
                                     Requires an N2/N2D/C2/C3 machine family (D-ENV-22).

    Serial console access (D-INFRA-23):
      - enable_serial_console (optional, default false) Injects two GCP metadata keys into the instance:
                              "serial-port-enable" = "true"         → enables interactive login via
                                  `gcloud compute connect-to-serial-port` (requires ssh-key in metadata).
                              "serial-port-logging-enable" = "true" → streams boot/serial output to
                                  Cloud Logging and the GCP Console "Serial port" tab.
                              Merged on top of the caller-supplied metadata map; caller keys are preserved.

    Boot disk:
      - boot_disk_size_gb    (optional, default 20)          Must be >= 10.
      - boot_disk_type       (optional, default pd-balanced)  pd-balanced | pd-ssd | pd-standard (D-ENV-12: prefer pd-balanced).

    Service account:
      - service_account_email  (optional, default null) SA email to attach. Null = no SA block.
      - service_account_scopes (optional, default ["cloud-platform"]) OAuth2 scopes.

    Attached data disks:
      - attached_disks  (optional, default []) List of {name, size_gb, type (default pd-balanced)}.
                        Creates one google_compute_disk per entry and attaches it to the instance.

    IP forwarding:
      - can_ip_forward  (optional, default false) Enables IP forwarding at the hypervisor level.
                        Required when the VM acts as a NAT gateway or IP router (D-INFRA-11).
                        GCP drops forwarded packets at the hypervisor unless this is true.

    Metadata / bootstrap:
      - metadata                (optional, default {})   Instance metadata map (e.g. ssh-keys). Never hardcode secrets.
      - metadata_startup_script (optional, default null) Startup script content. Bootstrap logic lives in external artifacts (HLD).

    Per-instance labels:
      - labels  (optional, default {}) Merged with var.tags + {environment, managed_by}.
  EOT
  type = list(object({
    name         = string
    machine_type = string
    zone         = string
    boot_image   = string

    network_interfaces = list(object({
      subnetwork         = string
      network_ip         = optional(string, null)
      assign_external_ip = optional(bool, false)
      external_ip        = optional(string, null)
    }))

    spot                         = optional(bool, false)
    enable_nested_virtualization = optional(bool, false)
    enable_serial_console        = optional(bool, false)

    boot_disk_size_gb = optional(number, 20)
    boot_disk_type    = optional(string, "pd-balanced")

    network_tags = optional(list(string), [])

    can_ip_forward = optional(bool, false)

    service_account_email  = optional(string, null)
    service_account_scopes = optional(list(string), ["cloud-platform"])

    attached_disks = optional(list(object({
      name    = string
      size_gb = number
      type    = optional(string, "pd-balanced")
    })), [])

    metadata                = optional(map(string), {})
    metadata_startup_script = optional(string, null)

    labels = optional(map(string), {})
  }))

  # ── Instance-level validations ────────────────────────────────────────────────

  validation {
    condition     = length(var.instances) > 0
    error_message = "instances must contain at least one instance definition."
  }

  validation {
    condition     = alltrue([for i in var.instances : length(i.name) > 0 && can(regex("^[a-z][a-z0-9-]{0,61}$", i.name))])
    error_message = "Each instance name must start with a lowercase letter and contain only lowercase letters, digits, or hyphens (max 62 chars)."
  }

  validation {
    condition     = alltrue([for i in var.instances : length(i.machine_type) > 0])
    error_message = "Each instance machine_type must be a non-empty string (e.g. n2d-highmem-16)."
  }

  validation {
    condition     = alltrue([for i in var.instances : can(regex("^[a-z]+-[a-z]+[0-9]+-[a-z]$", i.zone))])
    error_message = "Each instance zone must be a valid GCP zone string (e.g. europe-west1-b)."
  }

  validation {
    condition     = alltrue([for i in var.instances : length(i.boot_image) > 0])
    error_message = "Each instance boot_image must be a non-empty string (e.g. ubuntu-os-cloud/ubuntu-2404-lts-amd64)."
  }

  validation {
    condition     = alltrue([for i in var.instances : i.boot_disk_size_gb >= 10])
    error_message = "Each instance boot_disk_size_gb must be >= 10."
  }

  validation {
    condition     = alltrue([for i in var.instances : contains(["pd-balanced", "pd-ssd", "pd-standard"], i.boot_disk_type)])
    error_message = "Each instance boot_disk_type must be one of: pd-balanced, pd-ssd, pd-standard."
  }

  # ── NIC-level validations ─────────────────────────────────────────────────────

  validation {
    condition     = alltrue([for i in var.instances : length(i.network_interfaces) >= 1])
    error_message = "Each instance must have at least one network_interface entry."
  }

  validation {
    condition = alltrue(flatten([
      for i in var.instances : [
        for nic in i.network_interfaces :
        can(regex("^https://www\\.googleapis\\.com/compute/v1/projects/.+/regions/.+/subnetworks/.+$", nic.subnetwork))
      ]
    ]))
    error_message = "Each network_interface subnetwork must be a valid GCP subnetwork self-link URI (https://www.googleapis.com/compute/v1/projects/.../regions/.../subnetworks/...)."
  }

  validation {
    condition = alltrue(flatten([
      for i in var.instances : [
        for nic in i.network_interfaces :
        nic.external_ip == null ? true : can(regex("^([0-9]{1,3}\\.){3}[0-9]{1,3}$", nic.external_ip))
      ]
    ]))
    error_message = "Each network_interface external_ip, when set, must be a valid IPv4 address (e.g. 34.90.12.34)."
  }
}
