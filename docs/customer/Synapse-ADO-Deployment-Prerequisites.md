# Synapse PoC - Azure DevOps Deployment Prerequisites

Use this checklist to confirm your environment is ready for deployments through Azure DevOps pipelines. Complete each item **before** the deployment session; missing items are the most common cause of day-of delays. Never store passwords or secrets in this document.

## 1. Contacts

Know who can act on each of these so access requests are resolved quickly.

- [ ] Identified: Organization name.
- [ ] Identified: Primary technical contact (name / email).
- [ ] Identified: Azure subscription admin (Owner / User Access Administrator).
- [ ] Identified: Entra ID admin (App Registrations / federated credentials).
- [ ] Identified: Azure DevOps admin (Project Administrator).

## 2. Azure subscription and resource groups

One set of values per environment. Resource groups must exist before deployment; the pipelines do not create them.

- [ ] For each environment (dev, test, prod), have identified: Subscription ID; Resource group name; Azure region; Naming prefix.
- [ ] Target resource group exists for every environment in scope (dev / test / prod).
- [ ] Region supports Azure Synapse and meets data-residency requirements.
- [ ] Resource providers registered: Microsoft.Synapse, Microsoft.Storage, Microsoft.KeyVault, Microsoft.OperationalInsights, Microsoft.Insights, Microsoft.ManagedIdentity, Microsoft.Compute, Microsoft.Network.

## 3. Microsoft Entra ID (deployment identity)

One App Registration (service principal) per environment, or an existing one you wish to reuse.

- [ ] For each environment (dev, test, prod), have identified: Application (client) ID; Directory (tenant) ID; Service principal object ID.
- [ ] Someone with Application Administrator / Cloud Application Administrator (or equivalent) can add a federated credential.
- [ ] Federated credential issuer/subject match the Azure DevOps service connection (generated when the connection is created).

_Note: use the service principal (Enterprise application) object ID for RBAC assignments, not the App Registration object ID._

## 4. Azure DevOps configuration

- [ ] Identified: Azure DevOps organization URL.
- [ ] Identified: Project name.
- [ ] Organization policy allows creating Azure Resource Manager service connections that use Workload Identity federation (no client secret).
- [ ] For each environment (dev, test, prod), have identified: Service connection name (default: sc-synapse-{env}-wif).
- [ ] One WIF service connection per environment, scoped to that environment's resource group, and authorized for the pipelines.
- [ ] Azure DevOps Environments named exactly dev, test and prod exist.
- [ ] Approvals / checks configured on test and prod Environments (and exclusive lock, if desired).
- [ ] Secret pipeline variables defined: sqlAdministratorPassword.dev, sqlAdministratorPassword.test, sqlAdministratorPassword.prod. (Never store the values in the repo or in this document.)
- [ ] Pipelines created from azure-pipelines/: validate.yml, deploy.yml, publish-artifacts.yml, rollback.yml, rollback-artifacts.yml.
- [ ] Identified: Publish-artifacts pipeline definition ID (used by artifact rollback).
- [ ] Placeholders in azure-pipelines/templates/variables.yml replaced (service connections, subscription IDs, resource groups, workspace names) or overridden.
- [ ] Agent pool: Microsoft-hosted ubuntu-latest is permitted (default). If self-hosted agents are required, have the pool name and agent access ready.
- [ ] Identified: Self-hosted agent pool name (if applicable).

## 5. Access (RBAC)

Grant at the narrowest scope. Resource-management roles go on the target resource group, not the subscription.

- [ ] Contributor (or approved custom role) on the target resource group - deployment identity.
- [ ] User Access Administrator (or custom role allowing role assignments) on the target resource group - the template assigns storage access to the Synapse managed identity.
- [ ] Key Vault Secrets Officer on the Key Vault (only if Key Vault is deployed).
- [ ] AFTER infrastructure deploy: Synapse Artifact Publisher on the Synapse workspace for the publishing identity (resource-group Contributor does not grant this).
- [ ] AFTER infrastructure deploy: Storage Blob Data Contributor on the storage account for the publishing identity (sample data upload).
- [ ] Identified: Person who can grant these role assignments.
- [ ] PIM-eligible (rather than standing) access is required for human operators.

## 6. Network

- [ ] Public network access to Synapse/Storage is acceptable for the PoC.
- [ ] Private networking is required from the start (Microsoft-hosted agents cannot reach private endpoints; a self-hosted agent inside the network will be needed - confirm the approach before deployment).
- [ ] Agents can reach management.azure.com, login.microsoftonline.com, dev.azure.com and the region's Synapse/Storage endpoints.
- [ ] Identified: IP ranges to allow-list (VPN / corporate egress).

## 7. Optional components

Decide which of these are in scope so the environment parameters can be set accordingly.

- [ ] Key Vault (deployKeyVault)
- [ ] Apache Spark pool (deploySparkPool)
- [ ] Diagnostic settings (deployDiagnostics) - requires an existing Log Analytics workspace
- [ ] Identified: Log Analytics workspace resource ID (if diagnostics enabled).
- [ ] Dedicated SQL pool (billed hourly while running - not deployed by default)

## 8. After the first infrastructure deployment

Complete after the first infrastructure deployment; the artifact publish pipeline depends on these.

- [ ] For each environment (dev, test, prod), have identified: Synapse workspace name (deployment output); Storage account name.
- [ ] Workspace and storage names entered in variables.yml for each environment.
- [ ] Publishing identity granted Synapse Artifact Publisher and Storage Blob Data Contributor (section 5).

