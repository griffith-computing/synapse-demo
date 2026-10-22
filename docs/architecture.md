# Architecture

## Overview

This PoC deploys an Azure Synapse Analytics workspace and its supporting resources using
Infrastructure-as-Code (IaC), with a CI/CD layer that can run on **either** GitHub Actions or
Azure DevOps Pipelines against the same `infra/`, `synapse/`, and `config/` sources. The two
pipeline implementations are kept functionally equivalent so a customer can adopt whichever
platform they already standardize on. GitHub deployment jobs additionally use the shared
Windows runner described below; Azure DevOps agent networking remains independently configured.

```
                 ┌─────────────────────────────────────────────────────┐
                 │                 Source control (this repo)         │
                 │  infra/  synapse/  config/  scripts/                │
                 │  .github/workflows/        azure-pipelines/         │
                 └───────────────┬───────────────────┬─────────────────┘
                                 │                     │
                     GitHub Actions OIDC        Azure DevOps OIDC
                     (workload identity)        (workload identity)
                                 │                     │
                                 ▼                     ▼
                     ┌───────────────────────────────────────┐
                     │        Azure AD App Registration        │
                     │  (federated credential, no client secret)│
                     └───────────────────┬───────────────────┘
                                         │ least-privilege role assignment
                                         ▼
     ┌───────────────────────────────────────────────────────────────────┐
     │                         Target Resource Group                     │
     │                                                                   │
     │   ┌───────────────────┐   ┌───────────────────┐   ┌─────────────┐ │
     │   │ Synapse Workspace  │──▶│ ADLS Gen2 (primary)│  │ Key Vault    │ │
     │   │ (Spark + SQL pools)│   │  filesystem store   │  │ (secrets/certs)│
     │   └─────────┬─────────┘   └───────────────────┘   └─────────────┘ │
     │             │                                                     │
     │             ▼                                                     │
     │   ┌───────────────────┐   ┌───────────────────┐                   │
     │   │ Managed VNet /     │   │ Log Analytics /    │                   │
     │   │ Managed Private    │   │ Diagnostic Settings│                   │
     │   │ Endpoints (opt-in) │   └───────────────────┘                   │
     │   └───────────────────┘                                           │
     └───────────────────────────────────────────────────────────────────┘
```

## Components

| Component | Purpose | Source |
|---|---|---|
| Synapse workspace | Analytics compute (serverless SQL, dedicated SQL pool optional, Spark pools) | `infra/` |
| ADLS Gen2 storage account | Primary workspace filesystem + landing zone for demo datasets | `infra/` |
| Key Vault | Secrets/connection strings referenced by Synapse linked services | `infra/` |
| RBAC role assignments | Scoped, least-privilege grants for the deployment identity and workspace managed identity | `infra/` |
| Synapse artifacts | SQL scripts, notebooks, pipelines, linked services, datasets | `synapse/` |
| Infrastructure parameters | Per-environment Azure naming, sizing, and feature toggles | `infra/parameters/` |
| Artifact overrides | Per-environment Synapse artifact property overrides | `config/` |
| Pipelines | Build → validate → deploy → (promote) workflow, duplicated for both platforms | `.github/workflows/`, `azure-pipelines/` |
| Validation/cleanup helpers | Offline template validation, smoke checks, teardown | `scripts/` |

## Independent release streams

GitHub Actions and Azure DevOps each implement two release streams with separate triggers and
rollback paths:

| Release stream | Package contents | Trigger | Deployment behavior |
|---|---|---|---|
| Infrastructure | `infra/` | Infrastructure and owned orchestration changes | Runs Bicep what-if and deployment; never publishes workspace artifacts |
| Synapse artifacts | `synapse/`, `config/`, `sample/` | Workspace artifact, configuration, sample-data, and owned publishing changes | Requires an existing workspace; publishes data-plane artifacts without invoking Bicep |

Each stream builds one immutable, checksummed package and promotes that exact package through
dev, test, and prod. Existing GitHub Environments and Azure DevOps Environments provide approval
gates and prevent concurrent changes to the same environment. Artifact publication reads the
workspace's configured ADLS Gen2 endpoint from `defaultDataLakeStorage.accountUrl`, applies the
matching `config/<env>.json`, and publishes only files extracted from the verified package.

## Identity and RBAC model

### Shared Windows runner network

[The shared template](../infra/runner/main.bicep) deploys a Windows Server 2022 x64
`Standard_B2as_v2` VM in a dedicated West US 3 resource group, separate from environment
lifecycle/rollback. It has no public IP. Basic Bastion provides browser RDP through a dedicated
`AzureBastionSubnet`; a NAT Gateway supplies explicit outbound internet access for GitHub,
Azure APIs and prerequisite downloads. The runner subnet accepts RDP only from Bastion.

Shared private DNS zones and VNet links are created once. The separately deployed
[connectivity template](../infra/runner/connectivity.bicep) creates Storage blob/dfs and Synapse
Dev/Sql/SqlOnDemand private endpoints for each environment, even when target resources are in
East US 2. It does not relocate resources or disable public access. Synapse's managed VNet
is separate; private endpoints for this runner do not establish the integration runtime's
outbound storage access.

[Hosted bootstrap](../.github/workflows/deploy-runner.yml) installs prerequisites and registers
the Windows service using a short-lived GitHub App-derived registration token, delivered through
protected Azure managed Run Command parameters. GitHub App credentials never go onto the VM.
Completed Run Command resources and local payload files are removed; failed commands are retained
for diagnosis. Azure VM administrators can control the runner and must be trusted accordingly.

Packaging and PR validation remain GitHub-hosted. Only protected-main environment deployment,
publication and their reusable rollback jobs run on labels
`[self-hosted, Windows, X64, synapse-private]`. Per-environment OIDC/approvals remain in effect.
One persistent repository runner serializes work but is not a security boundary between
environments. It must not run untrusted code. Runner/OS update responsibility belongs to the
operator, and automatic runner updates must remain allowed.

### Workload identity federation

Both pipelines authenticate to Azure **without stored client secrets**:

- **GitHub Actions**: uses OpenID Connect (OIDC) to request a short-lived token from GitHub's
  token issuer, exchanged for an Azure AD access token via a **federated credential** configured
  on the App Registration (subject matches `repo:<org>/<repo>:environment:<env>` or
  `repo:<org>/<repo>:ref:refs/heads/<branch>`, scoped per environment).
- **Azure DevOps**: uses an **Azure Resource Manager service connection configured for workload
  identity federation** (the ADO-native equivalent of OIDC), which similarly avoids storing a
  client secret in the service connection.

Both approaches map to the *same* Azure AD App Registration pattern (one per environment is
recommended) so the RBAC story below applies identically.

### Least-privilege RBAC

- The deployment identity (App Registration / service principal) is granted **Contributor scoped
  to the target resource group only** — never subscription-level Owner/Contributor.
- Where the deployment only needs to deploy specific resource types, a **custom role** restricted
  to the required `Microsoft.Synapse/*`, `Microsoft.Storage/*`, `Microsoft.KeyVault/*`, and
  `Microsoft.Authorization/roleAssignments/write` (needed only if the pipeline itself assigns
  RBAC) actions is preferred over built-in Contributor. See
  [customer-prerequisites.md](customer-prerequisites.md#least-privilege-rbac-inputs) for the
  exact role list requested from the customer.
- The **Synapse workspace's system-assigned managed identity** is separately granted narrow data
  plane roles (e.g. `Storage Blob Data Contributor` on only the workspace's own filesystem), not
  on the whole storage account estate.
- Break-glass/interactive access (customer admins) is expected to use **Azure AD PIM-eligible**
  role assignments rather than standing Owner access; this PoC does not configure PIM itself but
  is compatible with it.

## Environment topology and configuration

- Environments are modeled as Bicep parameter files in `infra/parameters/` and matching Synapse
  artifact overrides in `config/`, not as separate repositories or branches.
- Infrastructure deployment selects `infra/parameters/<env>.bicepparam`; artifact publication
  selects `config/<env>.json` from its independently versioned package.
- GitHub Actions maps environments to **GitHub Environments** (enabling required reviewers and
  environment-scoped federated credentials); Azure DevOps maps them to **Environments** with
  approvals/checks configured on the corresponding stage.
- See [deployment-runbook.md](deployment-runbook.md#environment-configuration) for the concrete
  file schema and [deployment-runbook.md](deployment-runbook.md#promotion-across-environments) for
  how a build is promoted dev → test → prod.

## Private networking extension points

Environment parameters retain **public network access enabled** during the shared-runner
transition (see [demo-script.md](demo-script.md#poc-shortcuts-vs-production-hardening)).
The runner's private path is deployed independently; further hardening requires validating
all clients and runtime paths:

- **Managed VNet for Synapse**: `infra/` parameters include a toggle to enable Synapse's managed
  VNet and managed private endpoints to storage/Key Vault; disabled by default in the PoC config.
- **Private endpoints**: the shared runner connectivity template provides Storage and Synapse
  private endpoints. Key Vault private connectivity is not added by that template.
- **Self-hosted integration runtime**: for on-premises or private source connectivity, the
  `synapse/` linked service definitions are structured so a self-hosted IR can be substituted for
  the Azure IR without changing pipeline/dataset definitions.
- **Pipeline agents**: GitHub deployment jobs use the shared Windows runner. Azure DevOps needs
  an independently network-connected agent for private data-plane access; an ARM service
  connection alone does not provide network line of sight.

Disabling public access and hardening runtime-to-storage/Key Vault paths are separate from
establishing the runner's private endpoint connectivity.
