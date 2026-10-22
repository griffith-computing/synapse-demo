# Customer Prerequisites

Everything in this document should be gathered **before** a deployment session is scheduled.
Missing items are the most common cause of delay on day-of deployment.

## 1. Azure subscription and resource group

- [ ] Target Azure **subscription ID** (PoC should use a non-production subscription/resource
      group where possible).
- [ ] An **existing target resource group per environment** (`dev`, `test`, `prod`), with its
      name and region recorded. Have a customer administrator create it before assigning the
      deployment identity's resource-group-scoped roles. The infrastructure pipeline uses
      resource-group deployments; it does **not** create the resource group.
- [ ] Confirmation the subscription has the following **resource providers registered**:
      `Microsoft.Synapse`, `Microsoft.Storage`, `Microsoft.KeyVault`, `Microsoft.OperationalInsights`,
      `Microsoft.Insights`, `Microsoft.ManagedIdentity`.
- [ ] Naming convention / prefix the customer wants reflected in resource names (used to populate
      `infra/parameters/<env>.bicepparam`).
- [ ] Preferred Azure **region** (must support Synapse and align with any data residency
      requirements).

### Resource readiness by pipeline

| Resource | Before the infrastructure pipeline | Before the Synapse artifact pipeline |
|---|---|---|
| Azure subscription and target resource group | Must already exist; required providers must be registered | Must exist and contain the deployed workspace |
| Entra App Registration, service principal, and federated credential | Must be configured with the deployment permissions below | Must be configured for the publishing identity, with workspace and storage data-plane permissions |
| Synapse workspace and its system-assigned managed identity | Created by the infrastructure template; do not manually pre-create for a new environment | Must already exist; run infrastructure deployment first |
| ADLS Gen2 storage account and filesystems | Template creates the account, workspace default filesystem, and `raw`/`curated` filesystems | Must already exist; publication uploads sample data into `raw` |
| Key Vault | Created only when `deployKeyVault` is enabled | Required only for linked services that use it; referenced secrets must already be populated |
| Spark pool | Created only when `deploySparkPool` is enabled | Required only for artifacts that depend on that pool |
| Log Analytics workspace | Must already exist if `deployDiagnostics` is enabled; provide its resource ID as `logAnalyticsWorkspaceId` | Not required for publication itself |

The current [infrastructure template](../infra/main.bicep) creates diagnostic settings, not a
Log Analytics workspace. The pipeline identity's federated credential and its own role
assignments are bootstrap prerequisites, not resources created by this template.

- [ ] Confirm optional resources and dependent artifacts agree with the selected environment's
      [infrastructure parameters](../infra/parameters/) and [artifact configuration](../config/).
- [ ] After the first infrastructure deployment, record the actual `synapseWorkspaceName`
      output and storage account name. Configure the artifact pipeline to use that workspace;
      do not use a placeholder or assume the template accepts an arbitrary workspace name.

## 2. Azure AD / Entra ID access

- [ ] Ability for the deployment engineer (or customer admin) to create an **App Registration**
      per environment, or an existing one the customer wants reused.
- [ ] Record the **Application (client) ID**, **Directory (tenant) ID**, and the associated
      **service principal object ID**. Use the client ID for pipeline login and the service
      principal object ID for Azure RBAC assignments; the App Registration object ID is different.
- [ ] Ability to configure a **federated credential** on that App Registration (requires
      `Application Administrator` or `Cloud Application Administrator` role, or equivalent
      custom role, in Azure AD — not just Azure RBAC).
- [ ] Decision on which repository/pipeline platform will be used: **GitHub Actions**, **Azure
      DevOps**, or both (affects which federated credential subject identifiers are configured —
      see [deployment-runbook.md](deployment-runbook.md#workload-identity-federation-setup)).
- [ ] If Azure DevOps: confirmation the organization allows creating an **ARM service connection
      with workload identity federation** (some organizations restrict service connection
      creation to project admins).

### GitHub Actions configuration

- [ ] Create GitHub Environments named `dev`, `test`, and `prod` for the configured promotion
      stages, with approval rules as required.
- [ ] Add a federated credential matching each repository/environment. Obtain the numeric
      GitHub organization and repository IDs using the GitHub CLI instructions in
      [the deployment runbook](deployment-runbook.md#github-actions). These are not Azure IDs.
- [ ] Configure the following under **Repository Settings > Environments > &lt;env&gt;**:

| Name | Where to obtain the value | Required GitHub configuration in the current workflows |
|---|---|---|
| `AZURE_CLIENT_ID` | App Registration > Overview > Application (client) ID | Environment **secret** for infrastructure deployment; environment **variable** for artifact publication |
| `AZURE_TENANT_ID` | App Registration > Overview > Directory (tenant) ID | Environment **secret** for infrastructure deployment; environment **variable** for artifact publication |
| `AZURE_SUBSCRIPTION_ID` | Azure subscription > Overview > Subscription ID | Environment **secret** for infrastructure deployment; environment **variable** for artifact publication |
| `AZURE_RESOURCE_GROUP` | Existing target resource group name | Environment **variable** for both pipelines |
| `SYNAPSE_WORKSPACE_NAME` | Infrastructure deployment output `synapseWorkspaceName` | Environment **variable** for both pipelines; must match the template-generated name |
| `SYNAPSE_SQL_ADMIN_PASSWORD` | Customer-provided SQL administrator password meeting Synapse password requirements | Environment **secret** for infrastructure deployment |

The Azure identifiers are not credentials, but the current
[infrastructure workflow](../.github/workflows/deploy-environment.yml) reads them from
`secrets`, while the [artifact workflow](../.github/workflows/publish-artifacts-environment.yml)
reads them from `vars`. When using both, configure the same values in **both** locations.
GitHub secrets and variables are separate: setting one does not populate the other. Missing
client/tenant values cause `azure/login` to fail before federation or RBAC is checked.
No Azure client secret is needed or should be created.

#### Repository-secret fallback for infrastructure deployment and rollback

Environment secrets take precedence. If one is unavailable, the infrastructure workflows use
the corresponding repository secret prefixed with the target environment:

| Environment secret | Repository fallback for `dev` |
|---|---|
| `AZURE_CLIENT_ID` | `dev_AZURE_CLIENT_ID` |
| `AZURE_TENANT_ID` | `dev_AZURE_TENANT_ID` |
| `AZURE_SUBSCRIPTION_ID` | `dev_AZURE_SUBSCRIPTION_ID` |
| `SYNAPSE_SQL_ADMIN_PASSWORD` | `dev_SYNAPSE_SQL_ADMIN_PASSWORD` |

- [ ] For a personal demo using repository secrets, add these under **Settings > Secrets and
      variables > Actions > Repository secrets**. Use `test_` and `prod_` prefixes for the
      corresponding stages. Secret names are case-insensitive.
- [ ] Confirm the account's GitHub plan supports the required environment features.
      [Private-repository environment secrets require GitHub Pro for personal accounts, or an
      eligible organization plan](https://docs.github.com/en/actions/how-tos/deploy/configure-and-manage-deployments/manage-environments#prerequisites).
      Repository fallback does not enable otherwise unavailable environment protection rules.
- [ ] Where environment variables are unavailable, configure `AZURE_RESOURCE_GROUP` and
      `SYNAPSE_WORKSPACE_NAME` as repository Actions variables for a single-environment demo.
      These unprefixed repository variables are shared by all stages; do not promote to
      test/prod unless their resource-group/workspace configuration is separately supported.

The fallback applies to infrastructure deployment and rollback, including SQL administrator
password injection. Artifact publication still reads Azure identifiers from `vars` and requires
its own variable configuration. Repository fallback values are explicitly forwarded by callers;
the reusable workflow does not automatically receive all repository secrets.

### Azure DevOps configuration

- [ ] Create and authorize a workload-identity-federated Azure Resource Manager service
      connection for each environment, scoped to its target resource group.
- [ ] Set the service connection names, subscription IDs, resource group names, and actual
      workspace names in [the shared pipeline variables](../azure-pipelines/templates/variables.yml)
      or the supported pipeline overrides; replace all placeholder values.
- [ ] Create Azure DevOps Environments matching the deployment stages and configure approvals.
- [ ] Define secret pipeline variables `sqlAdministratorPassword.dev`,
      `sqlAdministratorPassword.test`, and `sqlAdministratorPassword.prod` for infrastructure
      deployment. Do not commit passwords to parameter files or variable templates.

## 3. Least-privilege RBAC inputs

Grant resource-management permissions at the **target resource group**, not subscription-wide.
Grant resource-specific and data-plane permissions at the narrower scopes listed below:

| Role | Scope | Purpose |
|---|---|---|
| Contributor (or narrower custom role — see [architecture.md](architecture.md#least-privilege-rbac)) | Target resource group | Deploy Synapse, storage, Key Vault |
| User Access Administrator (or a custom role permitting the required role assignments) | Target resource group | Required by the current infrastructure template to grant the Synapse managed identity storage access; Contributor alone cannot create role assignments |
| Key Vault Secrets Officer / Administrator | Target Key Vault | Seed secrets consumed by linked services |
| Synapse Artifact Publisher | Target Synapse workspace | Publish linked services, datasets, pipelines, and SQL scripts through the artifact pipeline |
| Storage Blob Data Contributor | PoC storage account | Seed the versioned raw sample CSV during artifact publication |

- [ ] Confirm who on the customer side can **grant** these role assignments (an Owner or User
      Access Administrator on the resource group).
- [ ] Confirm whether the customer's policy requires **PIM-eligible** rather than standing
      assignments for any human operators.
- [ ] Confirm each CI deployment identity has the **Synapse Artifact Publisher** workspace role;
      Azure resource-group Contributor alone does not grant Synapse data-plane publication access.
- [ ] After infrastructure deployment and before the first artifact publication, have an
      authorized administrator grant the publishing identity its Synapse workspace role and
      **Storage Blob Data Contributor** on the deployed storage account. The template grants
      storage access to the **workspace managed identity**, not to the pipeline identity.

## 4. Network and firewall

- [ ] Confirm whether **public network access** is acceptable for the PoC (default assumption —
      see [demo-script.md](demo-script.md#poc-shortcuts-vs-production-hardening)) or whether
      private networking must be enabled from the start (see
      [architecture.md](architecture.md#private-networking-extension-points)).
- [ ] If pipelines run on self-hosted agents/runners, confirm outbound network access from those
      agents to `management.azure.com`, `login.microsoftonline.com`, and the target region's
      Synapse/Storage endpoints.
- [ ] IP allow-listing requirements for any customer VPN/corporate egress ranges that need SQL/
      Spark endpoint access during the demo.

## 5. Data and content for the demo

- [ ] Sample dataset(s) the customer wants used (or confirmation the PoC's built-in sample data is
      acceptable) — see [demo-script.md](demo-script.md).
- [ ] Any sensitivity/classification constraints on data used during the demo (PoC should not use
      production or regulated data).

## 6. Cost expectations

Azure Synapse PoC costs vary by SKU and how long resources are left running. Order-of-magnitude
guidance to set expectations (actual pricing varies by region/currency and should be confirmed
with the Azure Pricing Calculator at deployment time — figures below are **not a quote**):

| Resource | Notes | Approx. driver |
|---|---|---|
| Synapse serverless SQL pool | Pay-per-query (per TB scanned); no idle cost | Recommended default for PoC |
| Synapse dedicated SQL pool (if enabled) | Billed **per hour while running**, including when idle — must be paused | Largest single cost risk; see cleanup steps |
| Apache Spark pool | Billed for active + auto-pause interval only | Auto-pause configured short (e.g. 5–15 min) in PoC config |
| ADLS Gen2 storage | Consumption-based, capacity + transactions | Minimal for PoC-scale sample data |
| Key Vault | Per-operation, negligible at PoC scale | — |
| Log Analytics / diagnostics | Ingestion + retention based | Minimal if retention kept short |

**Cost-control defaults baked into this PoC:**
- Dedicated SQL pool is **not** deployed unless explicitly enabled in
      `infra/parameters/<env>.bicepparam`.
- Spark pools use short auto-pause windows by default.
- Teardown/cleanup (see [deployment-runbook.md](deployment-runbook.md#cleanup)) is provided to
  remove all billable resources promptly after the demo.

## 7. Customer discovery questions

Use these to scope the engagement before deployment (also referenced in
[demo-script.md](demo-script.md#customer-discovery)):

1. What existing CI/CD platform(s) does your team use — GitHub Actions, Azure DevOps, or both?
2. Do you already have an Azure AD App Registration / service principal pattern you standardize
   on, or should we create one per environment for this PoC?
3. What environments do you need represented (dev/test/prod, or fewer)?
4. Is private networking (no public endpoints) a hard requirement, or acceptable to defer past the
   PoC?
5. Who owns granting RBAC on the target subscription/resource group, and what is their
   availability during the deployment window?
6. Is there an existing sample/non-sensitive dataset you'd like used in the demo?
7. What is the expected teardown timeline after the PoC (same day, same week)?
8. Are there data residency or compliance constraints (e.g. region restrictions) that affect
   resource placement?
