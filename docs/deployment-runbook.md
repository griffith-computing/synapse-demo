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

1. In the App Registration, add a **federated credential**:
   - Federated credential scenario: *GitHub Actions deploying Azure resources*.
   - Organization/repository: `griffith-computing/synapse-demo`.
   - Entity type: **Environment** (recommended, ties the credential to a GitHub Environment with
     required reviewers) — subject becomes
     `repo:griffith-computing/synapse-demo:environment:<env>`.
     Alternatively use *Branch* (`ref:refs/heads/<branch>`) if environments are not used.
2. In the GitHub repository settings, create a matching **Environment** named `<env>` (e.g. `dev`,
   `test`, `prod`) and add repository/environment secrets or variables:
   - `AZURE_CLIENT_ID`, `AZURE_TENANT_ID`, `AZURE_SUBSCRIPTION_ID` (these are identifiers, not
     secrets — a client secret is never created or stored).
3. Workflows in `.github/workflows/` use `azure/login@v2` with `client-id`/`tenant-id`/
   `subscription-id` inputs and `permissions: id-token: write` at the job level to request the
   OIDC token.

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
GitHub Environment. Do not define it as a repository variable or commit it to a parameter file.

The deployment identity also requires the **Synapse Artifact Publisher** role on each target
workspace. Resource-group Contributor covers ARM deployment but does not grant Synapse data-plane
artifact publication access. Grant **Storage Blob Data Contributor** on the PoC storage account so
the artifact pipeline can seed the packaged raw sample CSV.

## Environment configuration

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

1. Register `azure-pipelines/deploy.yml` and `azure-pipelines/publish-artifacts.yml` as separate
  Azure DevOps pipelines. Set their numeric definition IDs in `azure-pipelines/rollback.yml` and
  `synapseArtifactPipelineId` in `azure-pipelines/templates/variables.yml` for prior-run downloads.
2. Run the infrastructure pipeline first when provisioning or changing Azure resources. It
  packages and deploys only `infra/`.
3. Run the artifact pipeline after the workspace exists. It packages `synapse/`, `config/`, and `sample/`
  once and promotes that package through the `Publish_Dev`, `Publish_Test`, and `Publish_Prod`
  stages without invoking Bicep.
4. Environment **checks/approvals** gate both streams. Path filters ensure ordinary artifact
  updates do not trigger the infrastructure pipeline.

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
