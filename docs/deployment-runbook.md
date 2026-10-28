# Deployment Runbook

This runbook covers deploying the PoC via **GitHub Actions**, **Azure DevOps Pipelines**, or an
interactive **local Windows workstation**. The workstation process follows the same deployment
sequence as the pipelines; platform-specific authentication and commands are called out
explicitly.

> **Scope note:** This document describes the deployment procedure and the offline validation that
> has been performed on it. It does **not** assert that a live deployment against Azure has been
> executed as part of producing this documentation — live validation is a customer-attended step
> described in [Live validation](#live-validation) and must be run and confirmed in your own
> subscription before relying on it.

## Prerequisites

Confirm every item in [customer-prerequisites.md](customer-prerequisites.md) is complete before
starting. You will need:
- Target subscription ID, resource group name, region.
- For pipeline deployment, an Azure AD App Registration (or the ability to create one) per
  environment.
- For local deployment, a user account that can authenticate with Azure CLI.
- Contributor (or narrower custom role) on the target resource group for the pipeline identity or
  local user. The principal also needs permission to create the workspace managed identity's role
  assignment; see [customer-prerequisites.md](customer-prerequisites.md#3-least-privilege-rbac-inputs).

## Workload identity federation setup

Perform once per environment (dev/test/prod), for whichever platform(s) you use.

### Shared steps (both platforms)

1. Create (or reuse) an Azure AD **App Registration** for the environment, e.g.
   `synapse-poc-<env>-deploy`.
2. Note its **Application (client) ID**, **Directory (tenant) ID**.
3. Assign the deployment role (see [architecture.md](architecture.md#least-privilege-rbac)) to
   this App Registration's service principal, **scoped to the target resource group** — not the
   subscription.

### GitHub Actions

1. Obtain the numeric GitHub **Organization ID** and **Repository ID** required by the Azure
   portal. Install [GitHub CLI](https://cli.github.com/) if needed, then authenticate with a
   GitHub account that can access the repository:

   ```console
   gh auth login
   gh api repos/griffith-computing/synapse-demo --jq "{organizationId: .owner.id, repositoryId: .id}"
   ```

   Replace `griffith-computing/synapse-demo` if deploying from a different repository.
   The command returns the repository owner's numeric ID and the repository's numeric ID, for
   example (illustrative values only):

   ```json
   {
     "organizationId": 12345678,
     "repositoryId": 987654321
   }
   ```

   - Copy `organizationId` into the portal's **Organization ID** field.
   - Copy `repositoryId` into the portal's **Repository ID** field.
   - These are GitHub numeric IDs, not names, `node_id` values, or Azure identifiers.
   - Use the double quotes shown above in both PowerShell and Windows Command Prompt
     (`cmd.exe`). Single quotes do not group arguments in Command Prompt and can cause
     `accepts 1 arg(s), received 4`.
   - If GitHub returns `404`, confirm the repository name and that the account used by
     `gh auth login` has access; private repositories can return `404` for unauthorized requests.

2. In the App Registration, add a **federated credential**:
   - Federated credential scenario: *GitHub Actions deploying Azure resources*.
   - Organization/repository: `griffith-computing/synapse-demo`.
   - Organization ID / Repository ID: the numeric values obtained above.
   - Entity type: **Environment** (recommended, ties the credential to a GitHub Environment with
     required reviewers) — subject becomes
     `repo:griffith-computing/synapse-demo:environment:<env>`.
     The portal may include the numeric IDs in the generated subject; its format must match
     the subject emitted by GitHub for your repository.
     Alternatively use *Branch* (`ref:refs/heads/<branch>`) if environments are not used.
3. In the GitHub repository settings, create a matching **Environment** named `<env>` (e.g. `dev`,
   `test`, `prod`) and configure:
   - Environment **secrets** `AZURE_CLIENT_ID`, `AZURE_TENANT_ID`, `AZURE_SUBSCRIPTION_ID` for
     infrastructure deployment. The current infrastructure workflow reads `secrets`, not `vars`.
     If an environment secret is unavailable, deployment and rollback fall back to the
     environment-prefixed repository secret, e.g. `dev_AZURE_CLIENT_ID`. Configure these under
     **Settings > Secrets and variables > Actions > Repository secrets**. The calling workflows
     explicitly forward only the matching environment's fallback secrets.
   - The artifact publication and rollback workflows use the same environment secrets and
     matching environment-prefixed repository-secret fallbacks.
   - These values are identifiers, not credentials; a client secret is never created or stored.
4. Workflows in `.github/workflows/` use `azure/login@v2` with `client-id`/`tenant-id`/
   `subscription-id` inputs and `permissions: id-token: write` at the job level to request the
   OIDC token.

If infrastructure login reports that `client-id` or `tenant-id` is missing, inspect the
**Validate Azure login configuration** step. It reports the repository, target environment,
workflow commit, run attempt, and whether each required login secret is present, without
printing secret values. It checks the resolved environment-secret/repository-secret fallback.
Check secrets in that exact repository/environment, not just repository variables or a different
environment. Environment secrets are read by the reusable job's
`environment` binding and do not require `secrets: inherit`; repository secrets would need
explicit forwarding or inheritance from the calling workflow. Start a new run on the updated
commit to use workflow changes; re-running an older run does not update its workflow definition.
If this check passes but login still fails, inspect the new Azure error before changing RBAC or
federation settings.

### Azure DevOps

1. In Azure DevOps, create a new **service connection** of type *Azure Resource Manager* →
   *Workload Identity federation (automatic or manual)*.
   - *Automatic* lets Azure DevOps create the App Registration and federated credential for you.
   - *Manual* lets you point the service connection at the App Registration created in the shared
     steps above (recommended so the same identity/RBAC model is reused across both platforms).
2. Scope the service connection to the target subscription/resource group.
3. Name the service connection to match the environment, e.g. `synapse-poc-<env>-connection`, and
   reference it from the corresponding stage in `azure-pipelines/`.
4. Configure an Azure DevOps **Environment** (`Pipelines > Environments`) named `<env>` with
   approvals/checks if promotion gating is required (see
   [Promotion across environments](#promotion-across-environments)).
5. Add secret pipeline variables named `sqlAdministratorPassword.dev`,
  `sqlAdministratorPassword.test`, and `sqlAdministratorPassword.prod`. The deployment template
  maps only the matching value to `SYNAPSE_SQL_ADMIN_PASSWORD` for its Azure CLI task.

For GitHub Actions, add `SYNAPSE_SQL_ADMIN_PASSWORD` as a secret on each `dev`, `test`, and `prod`
GitHub Environment, or use repository secrets `dev_SYNAPSE_SQL_ADMIN_PASSWORD`,
`test_SYNAPSE_SQL_ADMIN_PASSWORD`, and `prod_SYNAPSE_SQL_ADMIN_PASSWORD` as fallbacks.
Do not define passwords as variables or commit them to a parameter file.

The deployment identity also requires the **Synapse Artifact Publisher** role on each target
workspace. Resource-group Contributor covers ARM deployment but does not grant Synapse data-plane
artifact publication access. Grant **Storage Blob Data Contributor** on the PoC storage account so
the artifact pipeline can seed the packaged raw sample CSV.

## Environment configuration

### Workspace identity from infrastructure outputs

`infra/main.bicep` generates the workspace name from the prefix, environment, and a
resource-group-derived suffix. A deployment label or a GitHub variable does not override that
resource name. Both pipeline platforms now deploy under the stable ARM deployment name
`synapse-<env>` (for example, `synapse-dev`), and artifact publication/rollback resolve that exact
deployment with `scripts/Get-SynapseDeploymentOutputs.ps1`. Both platforms' private connectivity and
preflight checks use those same outputs. No `SYNAPSE_WORKSPACE_NAME` GitHub variable or
`workspaceName.*` Azure DevOps variable is required.

For an environment deployed by an older workflow, run infrastructure deployment from the updated
commit once before publishing artifacts. This records the canonical deployment outputs and
reapplies the same deterministic resources, rather than creating a separately named workspace.
If the previous run failed only while configuring private connectivity, the new deployment
retries connectivity against the workspace Bicep actually created. Start a new workflow run;
rerunning an older run retains its old workflow definition.

The resolver fails if the named deployment is missing, unsuccessful, or lacks required outputs;
it never selects an arbitrary workspace or falls back to the old configured name. Retain the
`synapse-<env>` deployment record while the environment is in use. Local deployments below query
their exact `$deploymentName` instead and do not update the pipeline's canonical record.

### Shared Windows jumpbox and GitHub runner

GitHub deploy/publish/rollback execution requires one shared Windows runner. Packaging, PR
validation, and shared bootstrap stay GitHub-hosted. Azure DevOps uses its own private Windows
agent and hosted bootstrap, described in [Deploying via Azure DevOps](#deploying-via-azure-devops).
Run from protected `main`; configure environment deployment-branch restrictions and required
reviewers for `runner`, `dev`, `test`, and `prod`. The shared runner is for trusted code only.
Do not add PR jobs or fork checkouts to it. Environment approval is not VM-level isolation.

#### One-time configuration

1. Have an administrator create a dedicated shared resource group in West US 3 and register
   `Microsoft.Compute` and `Microsoft.Network`. The workflow deliberately does not create the
   resource group or grant itself permissions.
2. Create a shared-infrastructure Entra service principal with a GitHub OIDC federated credential
   matching the `runner` GitHub Environment. Grant Contributor on the shared resource group and
   subscription-level reads for `Microsoft.Compute/skus/read` and
   `Microsoft.Compute/locations/usages/read` (or an approved metadata-reader role).
3. Create/install a GitHub App on this repository with **Repository permissions >
   Administration: Read and write**. Store its private key in GitHub, not Azure or the VM.
   Ordinary `GITHUB_TOKEN` cannot create repository-runner registration tokens. Follow
   [Set the runner GitHub App private key](#set-the-runner-github-app-private-key) below.
4. Configure these settings:

   | Setting | Location |
   | --- | --- |
   | `RUNNER_RESOURCE_GROUP` | Repository Actions variable (recommended); shared resource group name. Environment variables can override it; use the same value in `runner`, `dev`, `test`, and `prod`. |
   | `RUNNER_APP_ID` | Repository Actions variable; GitHub App ID |
   | `AZURE_CLIENT_ID`, `AZURE_TENANT_ID`, `AZURE_SUBSCRIPTION_ID` | `runner` Environment secrets; alternatively repository secrets `RUNNER_AZURE_CLIENT_ID`, `RUNNER_AZURE_TENANT_ID`, `RUNNER_AZURE_SUBSCRIPTION_ID` |
   | `RUNNER_ADMIN_PASSWORD` | `runner` Environment secret or repository secret; strong local Windows administrator password |
   | `RUNNER_APP_PRIVATE_KEY` | `runner` Environment secret or repository secret; GitHub App PEM private key |
   | `RUNNER_VM_SIZE` | Optional repository variable; defaults to `Standard_B2as_v2` |
   | `RUNNER_ADMIN_USERNAME` | Optional repository variable; defaults to `runneradmin` |
   | `RUNNER_VNET_CIDR` | Optional repository variable; defaults to `10.42.0.0/16` |
   | `RUNNER_BASTION_CIDR` | Optional repository variable; defaults to `10.42.0.0/26` |
   | `RUNNER_SUBNET_CIDR` | Optional repository variable; defaults to `10.42.1.0/24` |
   | `RUNNER_ENDPOINT_CIDR` | Optional repository variable; defaults to `10.42.2.0/24` |

   Approve CIDRs before the first deployment. `AzureBastionSubnet` must be /26 or larger.
   Do not change existing subnet address ranges without a separate network migration.
5. Grant each environment deployment identity permissions for the shared connectivity deployment:
   deployment read/write, private endpoint and zone-group create/read/write, subnet join,
   DNS-zone join and any endpoint-created NIC operations. Also allow endpoint connection approval
   on its environment's Storage/Synapse resources. A dedicated custom role is preferable;
   Contributor on the shared RG is simpler for a PoC but grants VM control as well.
6. Retain each publishing identity's **Storage Blob Data Contributor** and **Synapse Artifact
   Publisher** assignments. A runner's network location does not grant either permission.

#### Set the runner GitHub App private key

`RUNNER_APP_PRIVATE_KEY` is the private key of the GitHub App used to register this repository's
self-hosted runner. It is **not** an Azure credential, an SSH key, the App's client secret, or a
runner registration token. The bootstrap workflow uses it with `RUNNER_APP_ID` to create a
short-lived installation access token, then requests a runner registration token. The App
private key stays in GitHub Actions; only the registration token is sent to the VM.

1. Open the App owner's GitHub **Settings > Developer settings > GitHub Apps** (use organization
   settings for an organization-owned App). Create a dedicated App if needed, or select **Edit**
   on the existing runner App. A runner-only App does not need an active webhook; disable
   **Active** under Webhook if creating one without a webhook receiver.
2. Under **Permissions & events > Repository permissions**, set **Administration** to
   **Read and write** and save. Under **Install App**, install the App on the repository's
   owner account and select **Only select repositories**, including this repository. If changing
   an existing installation's permissions, have its owner approve the new permissions.
3. On the App's **General** page, copy the **App ID** (not the Client ID). In this repository,
   open **Settings > Secrets and variables > Actions > Variables > New repository variable**.
   Set `RUNNER_APP_ID` to that ID.
4. Return to the App's **General > Private keys** section and select **Generate a private key**.
   GitHub downloads a `.pem` file. Treat this file as a credential: do not commit it, paste it
   into workflow YAML, or put it on the runner VM.
5. Store the **entire contents** of the downloaded PEM file as an Actions **secret**, preserving
   its line breaks and the `-----BEGIN RSA PRIVATE KEY-----` and
   `-----END RSA PRIVATE KEY-----` lines. Do not base64-encode it, surround it with quotes, or
   replace line breaks with literal `\n` text. Choose one location:
   - **Recommended:** repository **Settings > Environments > runner > Environment secrets >
     Add environment secret**, named `RUNNER_APP_PRIVATE_KEY`. This makes the key available to
     the bootstrap job after the protected `runner` Environment's approval rules are satisfied.
   - **Repository fallback:** **Settings > Secrets and variables > Actions > Secrets >
     New repository secret**, with the same name, `RUNNER_APP_PRIVATE_KEY`.

   The caller in [deploy.yml](../.github/workflows/deploy.yml) passes the repository secret:

   ```yaml
   RUNNER_APP_PRIVATE_KEY: ${{ secrets.RUNNER_APP_PRIVATE_KEY }}
   ```

   Leave that expression unchanged; it references the stored secret rather than containing the
   key itself. The reusable [deploy-runner.yml](../.github/workflows/deploy-runner.yml) declares
   `environment: runner`, so a secret defined on that Environment takes precedence over the
   passed repository secret. An Environment-only key is supported; it does not need to be
   duplicated as a repository secret. Do not put it on `dev`, `test`, or `prod`, since those
   Environments are not used by the bootstrap job.
6. Run **Actions > Deploy shared runner > Run workflow** from `main`, approve the `runner`
   Environment if required, and verify that **Create repository administration token** and
   **Register Windows runner service** succeed. Confirm the runner is online in repository
   **Settings > Actions > Runners** with the `synapse-private` label.

If **Validate bootstrap configuration** reports a missing `RUNNER_APP_PRIVATE_KEY`, check the
secret's exact name and scope above. If token creation fails, check that `RUNNER_APP_ID` matches
the App that generated the key, the full PEM was saved, the App is installed on this repository,
and its Administration permission has been approved. Never print the key to troubleshoot it.

To rotate the key, generate another private key for the same App, update the secret in the
location used by the bootstrap job, and verify a successful bootstrap before deleting the old
key from the App's **Private keys** list. If both Environment and repository secrets exist,
update or remove the unused copy to avoid a stale fallback. Handle the downloaded file using
your organization's credential-storage policy and remove any unneeded local copy.

See GitHub's [private-key management documentation](https://docs.github.com/en/apps/creating-github-apps/authenticating-with-a-github-app/managing-private-keys-for-github-apps)
for key generation and revocation guidance.

#### Deployment and recovery

Run [Deploy shared runner](../.github/workflows/deploy-runner.yml) manually from main for initial
bootstrap or recovery. [Deploy](../.github/workflows/deploy.yml) also calls it before scheduling
dev deployment; packaging runs independently. A failed bootstrap prevents promotion.

The runner resource group is read directly from `${{ vars.RUNNER_RESOURCE_GROUP }}`, not a
workflow input. Set it under repository **Settings > Secrets and variables > Actions >
Variables > New repository variable**, named `RUNNER_RESOURCE_GROUP`, with the existing shared
resource group name as its value. This supplies the same default to bootstrap, promotion,
and rollback.

Environment-scoped variables take precedence over the repository variable. Bootstrap uses the
protected `runner` Environment; private-connectivity deployment and rollback use the target
`dev`, `test`, or `prod` Environment. If using Environment variables instead, configure
`RUNNER_RESOURCE_GROUP` with the same shared resource group name in all four Environments under
**Settings > Environments > [environment] > Environment variables**. Setting it only on
`runner` does not make it available to the other Environments. Bootstrap fails its configuration
check before Azure deployment if the variable is missing.

The shared deployment is named `shared-runner`; keep that name because connectivity resolves its
outputs. It uses [the shared template](../infra/runner/main.bicep), not environment parameter files.
Shared what-if precedes deployment. SKU restrictions and regional/family quota are checked again,
but passing those checks does not guarantee instantaneous Azure allocation capacity.

If bootstrap reports that the VM SKU is unavailable or restricted, inspect the blocking
restriction details in the error. The shared VM has no availability zone, so zone-only
restrictions do not block it; a location restriction covering `westus3` still does.
Check the selected SKU using the same subscription as the bootstrap identity:

```powershell
az vm list-skus --location westus3 --resource-type virtualMachines --size Standard_B2as_v2 --all --output json
az vm list-usage --location westus3 --output table
```

For a genuine regional/subscription restriction, request SKU access from Azure or set
`RUNNER_VM_SIZE` in the repository Actions variables (or the `runner` Environment override)
to an approved Windows x64/Trusted Launch-compatible size with sufficient regional and family
quota, then start a new run on the updated `main` commit. Quota and SKU access are separate
checks; increasing quota does not necessarily remove `NotAvailableForSubscription`.
The bootstrap deliberately does not silently switch sizes or regions.

Prerequisites are installed by [Initialize-GitHubRunner.ps1](../scripts/Initialize-GitHubRunner.ps1).
PowerShell/Git/runner downloads use official release metadata and SHA256 asset digests; the
Azure CLI installer requires a valid Microsoft Authenticode signature. A missing digest or
invalid signature is an error, not a bypass. Bicep is made available to the service account.
Review version changes as part of maintenance; bootstrap uses current stable release metadata.

The workflow mints the registration token only after installation. It sends that token using
Azure **managed** Run Command `protectedParameters`, never ordinary parameters or template
outputs. Hosted temporary payloads are removed in `finally`; completed Run Command resources
are deleted. Failed command resources are retained for diagnosis. Never echo protected payloads
or upload them as artifacts. Only trusted administrators should have VM Run Command permission.

Registration runs the service as `NT AUTHORITY\NETWORK SERVICE`, with modify access to
`C:\actions-runner`. Existing matching registration is reused and its stopped service restarted;
mismatched/broken registration fails explicitly. Runner updates remain enabled. The workflow
checks GitHub status is online with `synapse-private`, not just that Azure reports VM success.
For an abandoned registration after VM replacement, remove the stale runner in repository
**Settings > Actions > Runners** before retrying; do not silently replace another runner.

Each environment deployment subsequently applies
[connectivity.bicep](../infra/runner/connectivity.bicep) into the shared RG, using the workspace's
actual default data lake resource ID. Endpoint deployments are named `connectivity-dev`,
`connectivity-test`, and `connectivity-prod`; DNS zones and links are shared and owned only by
the bootstrap template. Target regions are preserved, including checked-in East US 2 test/prod.
The private-connectivity control plane uses the currently checked-out shared orchestration,
including during environment rollback; environment rollback does not roll back the shared VM,
network, or connectivity template. Environment Bicep/artifacts remain immutable packages.

Deploy the infrastructure stream before starting the independently triggered artifact stream.
Publication checks private DNS and TCP for Storage blob/dfs and Synapse Dev before uploading.
If the runner is offline, jobs wait in GitHub's runner queue; rerun hosted bootstrap rather
than waiting for a self-hosted job to repair itself. Job execution timeouts do not bound GitHub's
runner queue wait.

#### Bastion, networking and acceptance checks

- Open the VM in Azure Portal, choose **Connect > Bastion**, and use the approved local VM
  credentials. Basic provides browser RDP; no VM public IP or public RDP rule exists.
- NAT Gateway provides explicit outbound access. Permit GitHub/Actions artifact/log/release
  endpoints and redirects, Entra ID, Azure management, Microsoft installers and Windows updates.
  NAT is not an egress-filtering firewall. Follow the current
  [GitHub domain requirements](https://docs.github.com/en/actions/reference/runners/self-hosted-runners#communication)
  when enterprise filtering is applied.
- On the VM, check the `actions.runner.*` service and GitHub's online runner status. Then run:

  ```powershell
  .\scripts\Test-RunnerPrivateConnectivity.ps1 `
    -StorageAccountName '<actual-account>' -WorkspaceName '<actual-workspace>' -IncludeSql
  ```

  Repeat for dev/test/prod. The command rejects public DNS results and checks TCP reachability;
  deployment/publication then verifies actual authorized operations. Check private endpoint
  approval, zone groups and VNet links if DNS is public or connections fail.
- Validate a real infrastructure deployment, raw seed upload, Synapse publication, smoke tests,
  and a redeployment/recovery path. Verify environment approval gates and that PR validation is
  still GitHub-hosted. Record these live results separately; offline tests cannot prove them.
- Do not disable public access merely because these runner tests pass. Synapse runtime-to-storage
  access, other users/tools, and any Key Vault dependencies need their own validation first.
- Keep the VM running for unattended jobs. If explicitly deallocated for savings, restart it
  before queuing work. VM deallocation does not stop Bastion, NAT or private endpoint charges.
  Operators own OS updates, reboots and runner maintenance; drain the runner before maintenance.

#### West US 3 sizing and cost

The selected `Standard_B2as_v2` has 2 vCPU / 8 GiB and Windows retail Consumption pricing of
USD **0.0844/hour**, verified through the Azure Retail Prices API. It is appropriate for
intermittent PowerShell/Azure CLI deployments, not heavy builds. B-series CPU credits limit
sustained load; resize to `Standard_D2as_v5` if continuous work makes that a problem.

| Checked size | vCPU / RAM | Windows USD/hour |
| --- | --- | ---: |
| Standard_B2als_v2 | 2 / 4 GiB | 0.0468 |
| Standard_B2s | 2 / 4 GiB | 0.0496 |
| Standard_B2as_v2 | 2 / 8 GiB | 0.0844 |
| Standard_B2ms | 2 / 8 GiB | 0.0912 |
| Standard_D2as_v5 | 2 / 8 GiB | 0.1780 |
| Standard_D2s_v5 | 2 / 8 GiB | 0.1880 |

All six were listed without subscription restrictions and with sufficient family quota in the
selected subscription when checked. This is not an allocation guarantee or a fixed-price quote.
Basic Bastion adds USD **0.19/hour** while provisioned, making VM + Bastion USD **0.2744/hour**
before disk, NAT Gateway/processing, Standard public IPs, private endpoints/processing and traffic
(including cross-region traffic). Confirm current rates/discounts in the
[Azure Pricing Calculator](https://azure.microsoft.com/pricing/calculator/).

Each environment has an infrastructure parameter file and an artifact override file:

```
infra/parameters/dev.bicepparam
config/dev.json
```

The Bicep parameter file controls Azure location, naming, networking, and optional resources. The
JSON file contains non-secret Synapse artifact overrides, for example:

```json
{
  "environmentName": "dev",
  "synapseArtifacts": {
    "parameters": {
      "LS_AdlsGen2_ManagedIdentity_properties_typeProperties_url": "{{STORAGE_ACCOUNT_DFS_ENDPOINT}}"
    }
  }
}
```

Infrastructure pipelines pass `infra/parameters/<env>.bicepparam` to Bicep. The matching
`config/<env>.json` is consumed only by Synapse artifact publication for property overrides.
Keep customer-identifying values (subscription ID, tenant ID) in pipeline-level variables rather
than either committed configuration format.

## Deploying from a local Windows workstation

Use this path for an interactive dev deployment from a clean checkout. It deploys the same Bicep
template and Synapse artifacts as the pipelines, but authenticates as your signed-in Azure user
instead of using workload identity federation.

### 1. Install and verify local tools

Install:

- Git.
- Windows PowerShell 5.1 or PowerShell 7.
- [Azure CLI](https://learn.microsoft.com/cli/azure/install-azure-cli-windows), including its
  Bicep support.

Open PowerShell in the repository root and verify the tools:

```powershell
git --version
$PSVersionTable.PSVersion
az version
az bicep version
az synapse --help
```

If `az bicep version` reports that Bicep is not installed, run `az bicep install`. If Azure CLI
prompts to install an extension for `az synapse`, accept the prompt and then rerun
`az synapse --help`.

### 2. Set the local deployment inputs

From the repository root, set values for the target dev environment. Use a lowercase
alphanumeric `namePrefix` of 2-10 characters because the Bicep template derives resource names
from it.

```powershell
$subscriptionId = '<subscription-id>'
$resourceGroupName = 'rg-synapse-poc-dev'
$location = 'eastus2'
$environmentName = 'dev'
$namePrefix = 'syn'
$deploymentName = "synapse-local-$environmentName-$([DateTime]::UtcNow.ToString('yyyyMMddHHmmss'))"

$templateFile = Join-Path $PWD 'infra\main.bicep'
$templateParametersFile = Join-Path $PWD 'infra\parameters\dev.bicepparam'
$artifactConfigFile = Join-Path $PWD 'config\dev.json'
```

The `config/dev.json` file supplies Synapse artifact overrides, while
`infra/parameters/dev.bicepparam` supplies the infrastructure parameters. Set `$location` and
`$namePrefix` above to the same values as the Bicep parameter file, or pass them as explicit
overrides in the commands below as shown.

### 3. Sign in and prepare the Azure scope

```powershell
az login
if ($LASTEXITCODE -ne 0) { throw 'Azure CLI login failed.' }

az account set --subscription $subscriptionId
if ($LASTEXITCODE -ne 0) { throw "Cannot select subscription $subscriptionId." }

az account show --query '{subscription:name, subscriptionId:id, tenantId:tenantId}' -o table

$requiredProviders = @(
    'Microsoft.Synapse',
    'Microsoft.Storage',
    'Microsoft.KeyVault',
    'Microsoft.OperationalInsights',
    'Microsoft.Insights',
    'Microsoft.ManagedIdentity'
)
foreach ($provider in $requiredProviders) {
    $registrationState = az provider show `
        --namespace $provider `
        --subscription $subscriptionId `
        --query registrationState `
        -o tsv
    if ($LASTEXITCODE -ne 0) { throw "Cannot read registration state for $provider." }
    if ($registrationState -ne 'Registered') {
        az provider register `
            --namespace $provider `
            --subscription $subscriptionId `
            --wait
        if ($LASTEXITCODE -ne 0) { throw "Cannot register resource provider $provider." }
    }
}

az group create --name $resourceGroupName --location $location --subscription $subscriptionId
if ($LASTEXITCODE -ne 0) { throw "Cannot create or access resource group $resourceGroupName." }
```

Confirm the displayed subscription and tenant before continuing. Provider registration requires
subscription-level permission and may take several minutes the first time. The resource group
command is idempotent: it creates the group if it does not exist and returns the existing group
otherwise. The provider and role requirements are detailed in
[customer-prerequisites.md](customer-prerequisites.md#1-azure-subscription-and-resource-group)
and [customer-prerequisites.md](customer-prerequisites.md#3-least-privilege-rbac-inputs).

### 4. Supply the SQL administrator password securely

The dev Bicep parameter file reads the password from the
`SYNAPSE_SQL_ADMIN_PASSWORD` process environment variable. Prompt for it rather than placing it
in command history, a parameter file, or source control:

```powershell
$securePassword = Read-Host 'Synapse SQL administrator password' -AsSecureString
$temporaryCredential = [System.Management.Automation.PSCredential]::new(
    'unused',
    $securePassword
)
$env:SYNAPSE_SQL_ADMIN_PASSWORD = $temporaryCredential.GetNetworkCredential().Password
Remove-Variable securePassword, temporaryCredential
```

Use a password that meets Azure SQL complexity requirements. The environment variable exists only
in this PowerShell process and is removed explicitly in step 9.

### 5. Preview the infrastructure changes

Run the repository's deployment wrapper in what-if mode. The `-WorkspaceName` value is only a
local label used by the script for logging; the actual workspace name is generated by Bicep and
is read from the deployment outputs after deployment.

```powershell
.\scripts\Deploy-SynapseWorkspace.ps1 `
    -ResourceGroupName $resourceGroupName `
    -WorkspaceName "$namePrefix-$environmentName" `
    -TemplateFile $templateFile `
    -TemplateParametersFile $templateParametersFile `
    -SubscriptionId $subscriptionId `
    -DeploymentName $deploymentName `
    -AdditionalParameters @(
        "environmentName=$environmentName",
        "namePrefix=$namePrefix",
        "location=$location"
    ) `
    -DryRun

if ($LASTEXITCODE -ne 0) { throw 'Infrastructure what-if failed; do not deploy.' }
```

Review all creates, modifications, and deletions. Resolve unexpected changes before continuing.
What-if calls Azure but does not apply the changes.

### 6. Deploy the infrastructure

Remove `-DryRun` and use the same deployment name and inputs:

```powershell
.\scripts\Deploy-SynapseWorkspace.ps1 `
    -ResourceGroupName $resourceGroupName `
    -WorkspaceName "$namePrefix-$environmentName" `
    -TemplateFile $templateFile `
    -TemplateParametersFile $templateParametersFile `
    -SubscriptionId $subscriptionId `
    -DeploymentName $deploymentName `
    -AdditionalParameters @(
        "environmentName=$environmentName",
        "namePrefix=$namePrefix",
        "location=$location"
    )

if ($LASTEXITCODE -ne 0) { throw 'Infrastructure deployment failed.' }
```

The deployment is incremental and its resource names are deterministic for the resource group,
environment, and prefix. Re-running the command with the same inputs updates the existing
resources rather than creating a second workspace.

### 7. Resolve deployment outputs and publish Synapse artifacts

Read the generated workspace name and storage DFS endpoint from the exact deployment just
completed, then publish the version-controlled artifacts in dependency order:

```powershell
$deploymentOutputsJson = az deployment group show `
    --resource-group $resourceGroupName `
    --name $deploymentName `
    --subscription $subscriptionId `
    --query properties.outputs `
    -o json
if ($LASTEXITCODE -ne 0) { throw "Cannot read outputs for deployment $deploymentName." }

$deploymentOutputs = $deploymentOutputsJson | ConvertFrom-Json
$workspaceName = $deploymentOutputs.synapseWorkspaceName.value
$storageDfsEndpoint = $deploymentOutputs.storageAccountDfsEndpoint.value
if (-not $workspaceName -or -not $storageDfsEndpoint) {
    throw 'The deployment did not return the required Synapse workspace and storage outputs.'
}

.\scripts\Publish-SynapseArtifacts.ps1 `
    -ArtifactsRoot (Join-Path $PWD 'synapse') `
    -ConfigFile $artifactConfigFile `
    -WorkspaceName $workspaceName `
    -SubscriptionId $subscriptionId `
    -TokenValues "STORAGE_ACCOUNT_DFS_ENDPOINT=$storageDfsEndpoint"

if ($LASTEXITCODE -ne 0) { throw 'Synapse artifact publication failed.' }
```

Do not substitute the local workspace label from steps 5-6 here. Artifact publication must use
the actual `$workspaceName` returned by Bicep.
SQL script artifacts are published with `az rest` to the Synapse data-plane SQL Scripts API
(`2020-12-01`), using a temporary UTF-8 JSON payload that preserves the resolved query, folder,
result limit, connection settings, and other script metadata. The explicit Synapse token audience
is `https://dev.azuresynapse.net`. This avoids the `az synapse sql-script create --result-limit`
integer-enum parser bug (`'int' object has no attribute 'lower'`) without dropping the result limit.
Other artifact kinds continue to use `az synapse <kind> create`.

### 8. Prepare and run smoke tests

The checked-in `tests/fixtures/smoke-tests.sample.json` file is an illustrative fixture: it uses
the placeholder workspace `synws` and pipeline `sample-pipeline`. Create a temporary resolved copy
for this deployment instead of editing the fixture:

```powershell
$smokeTestsPath = Join-Path $env:TEMP "synapse-smoke-tests-$deploymentName.json"
$smokeTests = Get-Content '.\tests\fixtures\smoke-tests.sample.json' -Raw | ConvertFrom-Json

foreach ($test in $smokeTests) {
    if ($test.Type -eq 'AzCommand') {
        for ($index = 0; $index -lt $test.Command.Count; $index++) {
            if ($test.Command[$index] -eq 'synws') {
                $test.Command[$index] = $workspaceName
            }
            if ($test.Command[$index] -eq 'sample-pipeline') {
                $test.Command[$index] = 'PL_CopyRawToCurated'
            }
        }
    }
    if ($test.Type -eq 'HttpCheck') {
        $test.Url = "https://$workspaceName.dev.azuresynapse.net"
    }
}

$smokeTests | ConvertTo-Json -Depth 10 | Set-Content $smokeTestsPath -Encoding UTF8
.\scripts\Invoke-SynapseSmokeTests.ps1 -TestDefinitionsPath $smokeTestsPath
if ($LASTEXITCODE -ne 0) { throw 'One or more Synapse smoke tests failed.' }
```

The sample includes a mutating test that starts `PL_CopyRawToCurated`. Confirm any required sample
data is present before running it, or remove that test from the temporary copy when the deployment
session is intended to be read-only. A skipped test is reported as skipped, not passed.

### 9. Confirm success and clear local secrets

```powershell
az synapse workspace show `
    --name $workspaceName `
    --resource-group $resourceGroupName `
    --subscription $subscriptionId `
    --query '{name:name, provisioningState:provisioningState, connectivityEndpoints:connectivityEndpoints}' `
    -o json

Remove-Item Env:\SYNAPSE_SQL_ADMIN_PASSWORD -ErrorAction SilentlyContinue
Remove-Item $smokeTestsPath -ErrorAction SilentlyContinue
```

Confirm the workspace reports `Succeeded`, review the smoke-test summary, and complete the checks
under [Live validation](#live-validation). Use [Cleanup](#cleanup) when the PoC environment is no
longer required.

## Deploying via GitHub Actions

1. Run `.github/workflows/deploy.yml` to package `infra/` and promote the immutable infrastructure
  package through dev, test, and prod. It performs package verification, OIDC login, Bicep
  what-if, and deployment only.
2. After the workspace exists, run `.github/workflows/publish-artifacts.yml`. It packages
  `synapse/`, `config/`, and `sample/` once, then uses `publish-artifacts-environment.yml` to promote the same
  package through dev, test, and prod.
3. Each artifact publication verifies checksums, reads the existing workspace's ADLS endpoint,
  applies `config/<env>.json`, runs `Publish-SynapseArtifacts.ps1`, and executes smoke tests after
  resolving the fixture's workspace, pipeline, and web endpoint placeholders.
4. Push path filters invoke only the affected release stream. Both workflows also support manual
  dispatch. Required reviewers on each GitHub Environment gate its deployment or publication job.

## Deploying via Azure DevOps

### Register and protect the pipelines

1. Connect the existing **GitHub repository** to the ADO project using its GitHub integration.
   Authorize repository checkout and restrict repository/service-connection/pool use to the
   intended pipelines. Source does not move to Azure Repos; existing GitHub Actions stay intact.
2. Register these YAML entry points as separate pipelines:
   - `azure-pipelines/validate.yml` (hosted PR/main offline checks);
   - `azure-pipelines/deploy-runner.yml` (manual bootstrap/repair);
   - `azure-pipelines/deploy.yml` (bootstrap, package, infra promotion);
   - `azure-pipelines/publish-artifacts.yml` (package and artifact promotion);
   - `azure-pipelines/rollback.yml` and `azure-pipelines/rollback-artifacts.yml` (manual).
3. Replace placeholders in [the variable template](../azure-pipelines/templates/variables.yml).
   Set `deployPipelineId` and `synapseArtifactPipelineId` to the respective numeric pipeline
   definition IDs for prior-build downloads. Service-connection and agent-pool names are
   compile-time YAML configuration: edit the template, not runtime/UI overrides.
4. Pre-create an organization self-hosted pool named by `runnerPool`, expose it to this project,
   and authorize only the four release/rollback pipelines that use it. Bootstrap itself uses
   hosted Ubuntu and requires pool administration, not a private-agent job slot.
5. Create ADO Environments `runner`, `dev`, `test`, and `prod`. Configure **Branch control**
   to allow protected `refs/heads/main`, **Exclusive lock**, and required approvals (especially
   test/prod). Templates use `lockBehavior: sequential`: a later run waits rather than canceling
   an earlier run at the lock. Checks are configured in the UI, not created by YAML.
6. Protect main in GitHub and require the ADO validation status. YAML PR triggers here apply
   to the GitHub-connected repository. Disable fork access to secrets and protected resources.
   Keep untrusted PRs on hosted agents. Explicit pool authorization and resource checks are
   required even though mutating templates also contain main-branch conditions.

### Bootstrap identity, settings, and registration

- Have an administrator create `runnerResourceGroup` in the same subscription as the environment
  resource groups. Use a dedicated ADO resource group/VM, not the existing GitHub runner's
  group. The same Bicep topology is reused, not the GitHub runner registration.
- Create the WIF ARM service connection named by `serviceConnection.runner`; authorize the
  bootstrap and infrastructure pipelines. Grant shared-RG Contributor plus the subscription
  SKU/quota metadata reads used by `Deploy-SharedRunner.ps1`.
- Set the runner location, Windows VM size, admin username, and non-overlapping VNet/subnet
  ranges in the variable template. Defaults are West US 3, Windows Server 2022 x64,
  `Standard_B2as_v2`, and the same Bastion/NAT/private endpoint layout as the GitHub bootstrap.
- Define secret `runnerAdminPassword` on both bootstrap and infrastructure pipelines. Define
  `sqlAdministratorPassword.dev`, `.test`, and `.prod` on infrastructure deploy/rollback
  pipelines. Share secrets through an explicitly authorized variable group if desired;
  no variable group is referenced automatically.
- `runnerRegistrationAuth: JobToken` is the default. Bootstrap explicitly maps
  `System.AccessToken` and uses Bearer authentication for ADO REST. The Windows configuration
  command accepts that OAuth token through `--auth pat` and `VSTS_AGENT_INPUT_TOKEN`, as documented
  in [Windows agent unattended configuration](https://learn.microsoft.com/en-us/azure/devops/pipelines/agents/windows-agent?view=azure-devops#unattended-config).
  Grant the job's actual build-service identity (normally `<project> Build Service (<org>)`
  with project-scoped job authorization) **Administrator on this specific agent pool**.
  Keep job authorization project-scoped; do not broaden organization-wide permissions.
  This grant applies to every pipeline using that build identity, not just bootstrap.
  Use it only in a trusted project; otherwise isolate bootstrap in a trusted project or use
  the explicit PAT mode with a protected variable group and branch checks. A main-branch
  condition in this template alone does not constrain other YAML using the same identity.
- If customer policy prevents job-token pool administration, explicitly set
  `runnerRegistrationAuth: PAT` and define secret `runnerRegistrationPat` on both bootstrap
  callers. Use a short-lived PAT with **Agent Pools (read, manage)**, owned by an identity with
  Administrator permission on only the intended pool. There is no automatic credential
  fallback. Revoke it after bootstrap; supply a fresh credential for later bootstrap runs.
  The registered agent uses its own listener/job credentials, not the bootstrap PAT.
- Bootstrap obtains Windows x64 agent metadata from ADO's
  `/_apis/distributedtask/packages/agent/win-x64` route (the platform is a path segment,
  not a query parameter), validates the official HTTPS download
  host and SHA256, installs shared prerequisites without installing a GitHub runner, and
  registers a Network Service Windows service. The token is sent only in protected managed
  Run Command parameters and a temporary guest environment variable, not command-line arguments.
  The service exposes `SYNAPSE_PRIVATE_AGENT=true`; jobs demand this plus Windows x64.
- A matching running registration is reused without restarting it; a stopped matching service
  is started. A different organization/pool/name is rejected. Bootstrap waits up to 15 minutes
  for assigned pool work before provisioning; drain the pool before planned maintenance or
  VM configuration changes so new work cannot race setup. Main-branch infra CI is batched
  behind an active infra run. Bootstrap polls the
  exact agent's online/enabled status and capabilities and fails after a bounded wait.

Azure deployment authentication remains WIF-based in both modes. Registration authorization is
an ADO permission, not an Azure RBAC grant. A PAT fallback means bootstrap is not fully secret-free.
Allow outbound HTTPS for Azure DevOps agent, artifact, log, and agent-download endpoints,
GitHub checkout/releases, Entra ID, ARM, and Microsoft installers/updates; use Microsoft's
[ADO networking guidance](https://learn.microsoft.com/en-us/azure/devops/organizations/security/allow-list-ip-url?view=azure-devops).
An ARM service connection does not provide private network access.

### Deploy, publish, and roll back

1. Run manual bootstrap once and repeat it to verify idempotence. Confirm the Windows agent
   is online in the pool and has all three demanded capabilities. Failed commands remain in
   Azure for diagnosis; completed Run Command resources/local protected payloads are removed.
2. Run infrastructure deployment from main. Hosted bootstrap and packaging are independent;
   Deploy_Dev waits for both. The same verified infra package then promotes dev -> test -> prod.
   Each private job performs WIF-authenticated what-if/deployment, resolves canonical Bicep
   outputs, reconciles private endpoints/DNS, and verifies private DNS/TCP access.
3. Give each environment deployment identity permission on the shared RG to read/deploy
   connectivity, join the endpoint subnet/DNS zones, and create endpoints/zone groups/NICs,
   plus endpoint approval on target Storage/Synapse resources. Shared-RG Contributor is a
   broad PoC option; a custom connectivity role is preferable. Keep existing environment
   deployment/role-assignment and publication/data-plane grants.
4. Run artifact publication only after infrastructure and its private connectivity exist and
   the publishing identity has workspace/storage data-plane access. It packages `synapse/`,
   `config/`, and `sample/` once. Each private stage resolves outputs, verifies the private
   path **before** upload/publication, seeds the sample, publishes, and runs resolved smoke
   tests. It never bootstraps the VM or invokes Bicep.
5. Run either manual rollback from main with `targetEnvironment`, an explicit `sourceRunId`,
   and its exact `packageVersion`. Infrastructure rollback skips what-if, verifies/selects
   the old infra package, redeploys, and reconciles/checks connectivity. Artifact rollback
   republishes the old artifact package without changing infrastructure.

All deployment jobs disable implicit artifact downloads and use build/job/attempt-specific
temporary directories, rejecting ambiguous packages, version mismatches, and pre-existing
extraction directories. The matching job directory is cleaned on completion. Configure ADO
project/run **retention for at least 90 days**, including retained release runs, so rollback
packages survive; GitHub's artifact retention field has no direct ADO YAML equivalent.

Shared environment locks serialize both release streams and both rollback entry points **within
ADO**. They do not coordinate with GitHub Actions locks. Designate one CI platform as deployment
authority for a customer environment; do not run both platforms against the same environment
concurrently. Unrelated GitHub Actions files have not been retired.

### Validation and operations

Offline checks compile both runner templates, run the existing runner topology tests, and run
`tests/Test-AzureDevOpsPipelines.ps1` for pipeline contracts and mocked agent/package behavior.
Preview/validate all six pipelines in the customer ADO project before execution, including both
current/prior artifact branches and all environment parameter choices. Offline checks do not
prove ADO template expansion, pool permissions, or live Azure access.

Customer-attended acceptance must verify bootstrap/rerun, private endpoint DNS/TCP, identical
package versions through dev/test/prod, smoke tests, both prior-build rollback paths, main/PR
restrictions, and queuing under an exclusive lock. Test artifact-only and infrastructure/helper
path filters separately. Do not claim live acceptance from offline test results.

For failures, inspect pool/queue authorization and the selected registration identity first.
Check the `vstsagent.*` service, machine PATH/PowerShell 7/Azure CLI/Bicep, and required capabilities
if jobs remain queued. Repair a mismatched registration explicitly rather than using `--replace`.
For private-path failures, check endpoint approval, private DNS zone groups/VNet links, shared-RG
RBAC, and the canonical successful `synapse-<env>` deployment outputs. For rollback downloads,
check pipeline definition ID, source run ID, build permissions, package version, and retention.
Stop/reboot/update only the intended drained agent; keep automatic agent updates enabled.
To retire ADO, remove its pool registration, revoke bootstrap credentials, and delete only its
designated shared resource group after reviewing private endpoint dependencies. Do not remove
GitHub's separate runner group or environment data as part of agent cleanup.

## Promotion across environments

- Each release stream promotes its own **same build artifact / same commit SHA** from `dev` to
  `test`, then `prod`; neither stream rebuilds between environments.
- GitHub Actions invokes a reusable environment workflow once per environment. Azure DevOps uses
  sequential environment stages. Both preserve the package checksum and version across the chain.
- The artifact package contains all environment configuration files, but publication selects only
  the matching `config/<env>.json`. Infrastructure and artifact versions can advance independently.
- A commit that changes both streams can queue both pipelines. Their shared per-environment lock
  prevents simultaneous mutation but does not guarantee infrastructure runs first. Complete the
  infrastructure promotion before approving artifact stages, or rerun the artifact pipeline after
  infrastructure succeeds.

## Rollback semantics and limits

- **Infrastructure (infra/):** Azure Resource Manager/Bicep deployments are declarative. "Rollback"
  in practice means **re-running deployment with the previous known-good template + parameters
  (identified by prior commit SHA)**, which reconciles the resource group back to that state for
  resources managed by the template. This is a *forward* deployment of an old definition, not a
  true transactional rollback.
- **What this does *not* undo:**
  - Data-plane changes (data written into ADLS Gen2, rows inserted into SQL pools, notebook
    outputs) are **not** reverted by re-deploying infrastructure. There is no automated data
    rollback in this PoC.
  - Deployments use ARM incremental mode. Removing a resource from a template does not delete the
    existing Azure resource, and redeploying an older template does not restore data lost through
    an explicit deletion. Resource deletion and data recovery require separate procedures.
  - Azure AD federated credentials and RBAC role assignments created manually during setup are
    **not** managed by the IaC templates unless explicitly included, so they are not part of the
    rollback/redeploy cycle.
- **Synapse artifacts (synapse/):** SQL scripts/notebooks/pipelines are typically deployed via
  idempotent "publish" operations. Use `rollback-artifacts.yml` on the selected CI platform to
  verify and republish a package from a prior artifact-pipeline run without invoking Bicep.
  Republishing does not restore data written by pipelines and does not delete workspace artifacts
  that are absent from the selected package; explicit deletion lifecycle support is out of scope.
- **Recommendation:** treat rollback as "redeploy last known-good commit," communicate to the
  customer that it is not a live traffic-safe rollback (there is no blue/green or slot-swap in
  this PoC), and avoid demoing destructive template changes without a throwaway resource group.

## Offline validation

Available in the repository and used as noted below:

- **What-if analysis:** infrastructure pipelines run `az deployment group what-if` before
  deployment to preview resource changes.
- **Repository checks:** validation pipelines run `Test-SynapseRepository.ps1 -Offline` for
  required paths, JSON parsing, secret warnings, and package manifest integrity.
- **Pipeline YAML validation:** Azure DevOps validates YAML when a pipeline is registered or run;
  GitHub validates workflow structure when pushed. Run `actionlint` locally when available.
- **Unit-level script checks:** helper scripts under `scripts/` include basic self-checks (e.g.
  `-WhatIf` support in PowerShell scripts) runnable without Azure credentials.

All of the above can be run **without** any Azure credentials except `validate`/`what-if`, which
require read access to the target subscription but make no changes.

## Live validation

Live validation is the customer-attended step of actually running the pipeline end-to-end against
a real subscription and confirming the workspace is reachable and functional. This has **not** been
performed as part of producing this documentation. Recommended live validation checklist:

1. Run the deploy pipeline (either platform) against the `dev` environment.
2. Confirm the Synapse workspace and Synapse Studio are reachable (`https://<workspace>.dev.azuresynapse.net`
   returns the studio).
3. Run `scripts/` smoke checks (or the pipeline's built-in post-deploy step) to confirm expected
   linked services, sample pipeline, and sample data are present.
4. Execute the sample notebook/SQL script from `synapse/` and confirm expected row counts/output.
5. Confirm diagnostic logs are flowing to Log Analytics (if enabled).
6. Record the environment, region, and commit SHA validated, for the customer's records.

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| `AADSTS70021: No matching federated identity record found` | Federated credential subject doesn't match the actual GitHub Environment/branch or ADO service connection issuer/subject | Re-check subject string matches exactly (case-sensitive), including environment name |
| `AuthorizationFailed` on deployment | Deployment identity lacks role assignment at the resource group scope, or assignment hasn't propagated yet (can take a few minutes) | Confirm role assignment scope/role; wait and retry |
| Pipeline succeeds but Synapse Studio unreachable | Public network access disabled, or agent/runner has no network path (private networking enabled) | Confirm `infra/parameters/<env>.bicepparam` networking values match intent; use a self-hosted agent with network access if private |
| `what-if`/`validate` fails with resource provider error | Required resource provider not registered in subscription | Register providers listed in [customer-prerequisites.md](customer-prerequisites.md#1-azure-subscription-and-resource-group) |
| Dedicated SQL pool cost higher than expected | Pool left running (not paused) | Ensure `enableDedicatedSqlPool` is `false` unless needed; pause pool manually if enabled; see [Cleanup](#cleanup) |
| GitHub Actions job can't request OIDC token | Missing `permissions: id-token: write` on the job | Add the permission block to the workflow job |
| Azure DevOps service connection fails validation | Workload identity federation not enabled for the organization, or manual federated credential subject mismatch | Confirm with org admin; compare issuer/subject on both sides |
| Local `az` command targets the wrong tenant or subscription | A cached Azure CLI context is active | Run `az account show`, then repeat `az login --tenant <tenant-id>` and `az account set --subscription <subscription-id>` |
| Local resource group or deployment command returns `AuthorizationFailed` | The signed-in user lacks the required resource-group role, or cannot create the workspace managed identity's role assignment | Confirm the roles in [customer-prerequisites.md](customer-prerequisites.md#3-least-privilege-rbac-inputs), activate any required PIM role, and sign in again |
| Local deployment succeeds but artifact publication uses the wrong workspace | The label passed to `Deploy-SynapseWorkspace.ps1 -WorkspaceName` was reused instead of the Bicep output | Query the named deployment and use `properties.outputs.synapseWorkspaceName.value` |
| Artifact publication reports an unresolved `STORAGE_ACCOUNT_DFS_ENDPOINT` token | The storage endpoint was not read from the same successful infrastructure deployment | Query `properties.outputs.storageAccountDfsEndpoint.value` by the exact `$deploymentName` and rerun publication |
| Local smoke tests look for `synws` or `sample-pipeline` | The illustrative fixture was run without resolving its placeholder values | Follow the temporary-copy preparation in [Prepare and run smoke tests](#8-prepare-and-run-smoke-tests) |

## Cleanup

To avoid ongoing cost after a demo/PoC session:

1. Run the teardown script/pipeline in `scripts/` (or the corresponding `.github/workflows/` /
   `azure-pipelines/` cleanup job), which deletes the target resource group.
2. If a dedicated SQL pool was enabled, confirm it is deleted (deleting the resource group deletes
   it, but if only pausing was intended mid-demo, explicitly resume/pause status should be
   checked beforehand).
3. Remove the federated credential and App Registration if the environment will not be reused (or
   retain them if further demos are planned with the same customer).
4. Confirm any Azure DevOps service connection or GitHub Environment secrets tied to the torn-down
   environment are removed or clearly marked inactive to avoid confusion in future sessions.
5. Verify in the Azure portal (Cost Management) that no billable resources remain under the
   target resource group/subscription scope used for the PoC.
