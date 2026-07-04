# Factory Module: `stratum-factory-gcp-gce-instance`

Provisions parameterized GCE VM instances for STRATUM node roles.

## Purpose

Creates one or more `google_compute_instance` resources (and optional attached data disks)
from a single `instances = list(object(...))` input. Designed for the three STRATUM dev
environment node roles (HLD G-COMPUTE):

| Role | Machine type | Scheduling | Special |
|------|--------------|-----------|---------|
| bastion / DNS / VPN | `e2-micro` | always-on (standard, free tier) | external static IP |
| k3s node | `n2d-highmem-16` | spot/preemptible | compute SA for GCS cache |
| Containerlab | `n2d-highmem-8` | spot/preemptible | nested-virt (D-ENV-22) |

The module supports multi-NIC instances (each `network_interfaces` entry = one GCP NIC, bound
to a distinct VPC) and IP forwarding (`can_ip_forward`) for NAT-gateway / router use cases.

## Usage

```hcl
module "dev_gce" {
  source = "git::https://github.com/apellini/stratum-factory-gcp-gce-instance.git?ref=v0.3.0"

  environment = "dev"
  project_id  = "stratum-dev-sandbox"
  name_prefix = "stratum-dev"

  instances = [
    # ── bastion / DNS / VPN — dual-NIC NAT gateway (D-INFRA-11) ─────────────────
    {
      name           = "bastion"
      machine_type   = "e2-micro"
      zone           = "europe-west1-b"
      boot_image     = "ubuntu-os-cloud/ubuntu-2404-lts-amd64"
      boot_disk_size_gb = 10
      can_ip_forward = true          # required for iptables MASQUERADE / NAT
      network_tags   = ["bastion"]
      network_interfaces = [
        {
          subnetwork         = module.dev_subnet_ext.subnet_self_link  # nic0 — external VPC
          assign_external_ip = true
          external_ip        = module.dev_address.address              # reserved static IP
        },
        {
          subnetwork = module.dev_subnet_int.subnet_self_link           # nic1 — internal VPC
          network_ip = "10.100.0.2"                                     # static; matches route next_hop_ip
        },
      ]
    },
    # ── k3s node ────────────────────────────────────────────────────────────────
    {
      name         = "k3s"
      machine_type = "n2d-highmem-16"
      zone         = "europe-west1-b"
      boot_image   = "ubuntu-os-cloud/ubuntu-2404-lts-amd64"
      boot_disk_size_gb = 400
      spot         = true
      service_account_email = module.dev_iam.service_account_emails["compute"]
      network_interfaces = [{
        subnetwork = module.dev_subnet.subnet_self_link
      }]
    },
    # ── Containerlab (nested-virt) ───────────────────────────────────────────────
    {
      name                         = "containerlab"
      machine_type                 = "n2d-highmem-8"
      zone                         = "europe-west1-b"
      boot_image                   = "ubuntu-os-cloud/ubuntu-2404-lts-amd64"
      boot_disk_size_gb            = 100
      spot                         = true
      enable_nested_virtualization = true
      service_account_email        = module.dev_iam.service_account_emails["compute"]
      network_interfaces = [{
        subnetwork = module.dev_subnet.subnet_self_link
      }]
    },
  ]

  tags = { environment = "dev", managed_by = "opentofu" }
}
```

## Inputs

| Name | Type | Required | Validation | Description |
|------|------|----------|------------|-------------|
| `environment` | `string` | yes | `dev`, `stage`, or `main` | Deployment environment |
| `project_id` | `string` | yes | non-empty, no whitespace | GCP project ID |
| `name_prefix` | `string` | yes | 3–24 chars, `^[a-z][a-z0-9-]{2,23}$` | Resource name prefix |
| `tags` | `map(string)` | optional | all keys/values non-empty | Labels applied to all resources |
| `instances` | `list(object)` | yes | ≥1 entry; see fields below | VM definitions |

### Per-instance fields

| Field | Type | Default | Validation | Description |
|-------|------|---------|------------|-------------|
| `name` | `string` | — | `^[a-z][a-z0-9-]{0,61}$` | Instance name suffix (resource = `name_prefix-name`) |
| `machine_type` | `string` | — | non-empty | GCP machine type (e.g. `n2d-highmem-16`) |
| `zone` | `string` | — | `^[a-z]+-[a-z]+[0-9]+-[a-z]$` | GCP zone (e.g. `europe-west1-b`) |
| `boot_image` | `string` | — | non-empty | Boot disk image (e.g. `ubuntu-os-cloud/ubuntu-2404-lts-amd64`) |
| `network_interfaces` | `list(object)` | — | ≥1; valid subnetwork self-link | NIC definitions; nic0 = default route |
| `spot` | `bool` | `false` | — | `true` = SPOT preemptible scheduling |
| `enable_nested_virtualization` | `bool` | `false` | — | Enables nested-virt (N2/N2D/C2/C3 only — D-ENV-22) |
| `enable_serial_console` | `bool` | `false` | — | Enables GCP serial console access (D-INFRA-23). Sets `serial-port-enable=true` (interactive login via `gcloud compute connect-to-serial-port`, requires ssh-key in `metadata`) and `serial-port-logging-enable=true` (boot/serial output in Cloud Logging + GCP Console "Serial port" tab) |
| `boot_disk_size_gb` | `number` | `20` | `>= 10` | Boot disk size in GB |
| `boot_disk_type` | `string` | `pd-balanced` | `pd-balanced`, `pd-ssd`, `pd-standard` | Boot disk type (D-ENV-12: prefer pd-balanced) |
| `network_tags` | `list(string)` | `[]` | — | Network tags (drive firewall rule targeting) |
| `can_ip_forward` | `bool` | `false` | — | Enables IP forwarding — required when the VM is a NAT gateway or router (D-INFRA-11) |
| `service_account_email` | `string` | `null` | — | SA email to attach; `null` = no service_account block |
| `service_account_scopes` | `list(string)` | `["cloud-platform"]` | — | OAuth2 scopes |
| `attached_disks` | `list(object)` | `[]` | — | Extra data disks: `{name, size_gb, type}` |
| `metadata` | `map(string)` | `{}` | — | Instance metadata (e.g. `ssh-keys`); never hardcode secrets |
| `metadata_startup_script` | `string` | `null` | — | Startup script (bootstrap logic lives in external artifacts) |
| `labels` | `map(string)` | `{}` | — | Per-instance labels (merged with `tags`) |

### Per-NIC fields (`network_interfaces` entries)

| Field | Type | Default | Validation | Description |
|-------|------|---------|------------|-------------|
| `subnetwork` | `string` | — | valid subnetwork self-link URI | GCP subnetwork self-link |
| `network_ip` | `string` | `null` | — | Static internal IP; `null` = auto-assigned |
| `assign_external_ip` | `bool` | `false` | — | `true` = add `access_config` (external IP) |
| `external_ip` | `string` | `null` | valid IPv4 when set | Reserved static external IP (nat_ip); `null` = ephemeral |

## Outputs

| Name | Type | Description |
|------|------|-------------|
| `instance_ids` | `map(string)` | Instance name → resource ID |
| `instance_self_links` | `map(string)` | Instance name → self-link URI |
| `instance_names` | `map(string)` | Instance name → fully-qualified GCP name |
| `internal_ips` | `map(string)` | Instance name → nic0 internal IP |
| `external_ips` | `map(string)` | Instance name → nic0 external IP (empty string if none) |

## Factory rules applied

- **Stateless** — no local state, no remote state reads, no `terraform_remote_state`
- **Input-only** — all configuration via `variables.tf`; nothing hardcoded in resources
- **Strict validation** — every variable and every list field validated; multi-block fields
  use `alltrue([for ... : ...])` with clear error messages
- **No secrets** — SSH keys and tokens arrive via `metadata` input only; never hardcoded
- **Documented for humans and RAG** — this README + inline HCL comments

## Release

```hcl
source = "git::https://github.com/apellini/stratum-factory-gcp-gce-instance.git?ref=v0.3.0"
```

### Changelog

| Version | Changes |
|---------|---------|
| `v0.3.0` | Add `enable_serial_console` — sets `serial-port-enable` + `serial-port-logging-enable` metadata keys (D-INFRA-23) |
| `v0.2.0` | Add `can_ip_forward` to instance contract (D-INFRA-11) |
| `v0.1.0` | Initial release — multi-NIC, spot, nested-virt, attached disks |
