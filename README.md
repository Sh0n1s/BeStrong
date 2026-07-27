# bestrong-infrastructure

Terraform-defined Azure infrastructure for the containerized BeStrong backend:
an App Service (Linux container), Azure Container Registry, Key Vault, Azure
SQL, an Azure Files share mounted as a folder, a VNet with service endpoints,
Log Analytics + Application Insights, and remote Terraform state. The stack
creates its own resource group and deploys to any Azure subscription; changes
ship through a trunk-based Azure DevOps pipeline (see **CI/CD** below).
The project originally targeted the Pluralsight Azure cloud sandbox — the
PowerShell lifecycle scripts in `scripts/` still implement that per-session
workflow and remain useful as a local manual path.

## Repository structure

```
.
├── terraform/
│   ├── bootstrap/          # Per-session remote-state backend (storage account
│   │                       #   + tfstate container); runs with local state by design
│   └── stack/              # The whole infrastructure; one concern per file
│       ├── locals.tf       #   naming, tags, per-session random suffix
│       ├── network.tf      #   VNet + subnets (app integration, reserved PE subnet)
│       ├── app.tf          #   App Service plan + Linux Web App for Containers
│       ├── acr.tf          #   Azure Container Registry (Basic)
│       ├── keyvault.tf     #   Key Vault, default-Deny firewall, access policies
│       ├── sql.tf          #   SQL server + DB, firewall, flag-gated private endpoint
│       ├── storage.tf      #   Storage account + "userfiles" Azure Files share
│       └── monitoring.tf   #   Log Analytics + App Insights + diagnostic settings
├── app/                    # Minimal Node.js health-probe container (GET /health
│                           #   checks SQL, the file-share mount, and App Insights)
├── scripts/
│   ├── deploy.ps1          # Full provisioning lifecycle, zero to running app
│   ├── test.ps1            # 24-check acceptance suite
│   └── destroy.ps1         # Teardown + local cleanup
├── .github/workflows/
│   └── ci.yml              # Static checks: fmt, validate, tflint, checkov
└── azure-pipelines.yml     # Azure DevOps CI/CD: PR -> plan, main -> apply + image
```

## Prerequisites

| Tool | Version | Notes |
|---|---|---|
| Azure CLI (`az`) | current | logged in to the target subscription |
| Terraform | >= 1.5 | azurerm provider ~> 4.0 |
| Docker Desktop | current | local image build and push (ACR Tasks unavailable) |
| PowerShell | 5.1+ | scripts are Windows PowerShell 5.1 compatible |
| sqlcmd | optional | enables the optional SQL schema step in deploy |

## Quickstart

```powershell
az login                  # sign in as the sandbox user
.\scripts\deploy.ps1      # provision everything, ~20-30 minutes total
.\scripts\test.ps1        # run the acceptance suite
.\scripts\destroy.ps1     # tear everything down
```

- **deploy.ps1** discovers the sandbox session (subscription, playground
  resource group, your public IP), bootstraps the remote-state backend,
  runs `terraform apply` on the stack, builds and pushes the sample image
  via ACR admin credentials, then polls `/health` until it returns
  `"status":"ok"`. Supports `-PlanOnly` and `-SkipImage`. Safe to re-run
  after any failure.
- **test.ps1** runs 24 acceptance checks: 18 positive assertions
  (app health, TLS/HTTPS settings, VNet topology, firewall rules,
  diagnostics), 4 negative probes that temporarily remove the deployer-IP
  allow rule and require SQL / Key Vault / Storage access to fail (plus an
  unauthenticated ACR pull expecting 401), and 2 final checks proving the
  remote state blob exists and `terraform plan` reports no changes.
- **destroy.ps1** destroys the stack, optionally the state backend
  (`-IncludeBootstrap`), and removes all local session artifacts. It never
  deletes the platform-owned playground resource group. `-Force` skips the
  confirmation prompt.

## Configuration

The three per-session inputs — `subscription_id`, `resource_group_name`,
`deployer_ip` — have no defaults on purpose. `deploy.ps1` discovers them live
and writes them to `.session/session.auto.tfvars` (git-ignored), together with
`.session/backend.hcl` for the remote-state backend. You never edit these by
hand; `terraform/stack/terraform.tfvars.example` documents the shape.

Feature flags (`terraform/stack/variables.tf`):

| Variable | Default | Purpose |
|---|---|---|
| `enable_application_insights` | `true` | Application Insights + its app settings; off-switch in case the resource type is denied |
| `enable_sql_private_endpoint` | `false` | Optional Private Link demo for SQL, using the reserved subnet; enable after a green baseline |
| `enable_app_identity` | `false` | System-assigned managed identity for the Web App; stays off because the sandbox denies identities |

`image_tag` selects the container image tag the Web App pulls; `deploy.ps1`
passes the git short SHA automatically (fallback `v1`). Sizing knobs
(`app_service_sku`, `sql_database_sku`, `location`, quotas, log retention)
all have sandbox-safe defaults.

## Sandbox constraints and design choices

The Pluralsight sandbox imposes hard limits; the design embraces them rather
than fighting them:

| Constraint | Resulting design |
|---|---|
| Resource group is pre-created and platform-owned | Consumed via a `data` source, never created or deleted |
| No managed identities, role assignments, or service principals | ACR admin credentials for image pull/push; SQL authentication with a generated password stored in Key Vault |
| ACR capped at Basic SKU | Public registry endpoint; protection is authentication only (verified by a negative probe) |
| 4-hour session TTL | Everything is re-runnable from zero; Terraform state lives inside the sandbox and dies with it |
| SKU and region allowlists | B1 App Service plan, Basic SQL DTU, `eastus` default region |
| Network baseline | Service endpoints + strict default-Deny PaaS firewalls (deployer IP + app subnet only); the flag-gated SQL private endpoint proves Private Link also works |

## Security notes

- `.gitignore` is treated as a security control: Terraform state, plan files,
  real `*.tfvars`, `backend.hcl`, and the whole `.session/` directory never
  reach the repository — only `*.example` templates are committed.
- Secrets never touch disk or logs: the state access key travels via the
  `ARM_ACCESS_KEY` environment variable, ACR and SQL credentials stay in
  process memory, and the SQL admin password lives in Key Vault.
- The sample app's `/health` endpoint returns short, secret-free diagnostics
  only — no stack traces, connection strings, or credentials.
- The acceptance suite includes negative probes: external access to SQL,
  Key Vault, and Storage from a non-allowlisted IP must fail, and an
  anonymous ACR pull must be rejected. A successful connection during a
  probe window fails the suite.
- CI runs with zero cloud credentials: `terraform fmt` / `validate`
  (`-backend=false`), tflint with the azurerm ruleset, and checkov, with
  every accepted deviation annotated inline in the Terraform code.

## CI/CD (Azure DevOps)

Trunk-based flow driven by `azure-pipelines.yml`:

| Event | Stage | Steps |
|---|---|---|
| Pull request to `main` | Validate | `terraform init` -> `validate` -> `plan` (nothing applied) |
| Push / merge to `main` | Deploy | `terraform init` -> `validate` -> `apply`, then build & push the sample image (tag = commit short SHA) and smoke-check `/health` |

One-time setup in Azure DevOps (org `BeStrongTest`, project `BeStrong`):

1. Run `terraform/bootstrap` once locally (creates `rg-bestrong-tfstate` + the
   state storage account; note the `state_storage_account_name` output).
2. Install the free **Terraform** marketplace extension (Microsoft DevLabs).
3. Create a **GitHub** service connection (grants pipeline access to this repo).
4. Create an **Azure Resource Manager** service connection named
   `bestrong-azure`: classic service principal
   (`az ad sp create-for-rbac --role Contributor --scopes /subscriptions/<id>`),
   entered manually - no secrets ever live in this repository.
5. Create the pipeline from the existing `azure-pipelines.yml` and set the
   pipeline variable `backendStorageAccount` to the bootstrap output from step 1.

The hosted agent's egress IP is discovered on every run and passed as
`-var deployer_ip`, so the Key Vault / SQL / Storage firewalls admit the agent
for exactly that run. GitHub Actions (`ci.yml`) keeps running the credential-free
static checks on every push independently of Azure DevOps.
