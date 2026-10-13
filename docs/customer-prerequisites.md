# Customer Prerequisites

Everything in this document should be gathered **before** a deployment session is scheduled.
Missing items are the most common cause of delay on day-of deployment.

## 1. Azure subscription and resource group

- [ ] Target Azure **subscription ID** (PoC should use a non-production subscription/resource
      group where possible).
- [ ] Confirmation the subscription has the following **resource providers registered**:
      `Microsoft.Synapse`, `Microsoft.Storage`, `Microsoft.KeyVault`, `Microsoft.OperationalInsights`,
      `Microsoft.Insights`, `Microsoft.ManagedIdentity`.
- [ ] Naming convention / prefix the customer wants reflected in resource names (used to populate
      `infra/parameters/<env>.bicepparam`).
- [ ] Preferred Azure **region** (must support Synapse and align with any data residency
      requirements).

## 2. Azure AD / Entra ID access

- [ ] Ability for the deployment engineer (or customer admin) to create an **App Registration**
      per environment, or an existing one the customer wants reused.
- [ ] Ability to configure a **federated credential** on that App Registration (requires
      `Application Administrator` or `Cloud Application Administrator` role, or equivalent
      custom role, in Azure AD — not just Azure RBAC).
- [ ] Decision on which repository/pipeline platform will be used: **GitHub Actions**, **Azure
      DevOps**, or both (affects which federated credential subject identifiers are configured —
      see [deployment-runbook.md](deployment-runbook.md#workload-identity-federation-setup)).
- [ ] If Azure DevOps: confirmation the organization allows creating an **ARM service connection
      with workload identity federation** (some organizations restrict service connection
      creation to project admins).

## 3. Least-privilege RBAC inputs

The deployment identity needs, at minimum, the following **scoped to the target resource group**
(not subscription-wide):

| Role | Scope | Purpose |
|---|---|---|
| Contributor (or narrower custom role — see [architecture.md](architecture.md#least-privilege-rbac)) | Target resource group | Deploy Synapse, storage, Key Vault |
| User Access Administrator *(optional, only if the pipeline assigns RBAC to the workspace managed identity)* | Target resource group | Grant the Synapse managed identity data-plane roles |
| Key Vault Secrets Officer / Administrator | Target Key Vault | Seed secrets consumed by linked services |
| Synapse Artifact Publisher | Target Synapse workspace | Publish linked services, datasets, pipelines, and SQL scripts through the artifact pipeline |
| Storage Blob Data Contributor | PoC storage account | Seed the versioned raw sample CSV during artifact publication |

- [ ] Confirm who on the customer side can **grant** these role assignments (an Owner or User
      Access Administrator on the resource group).
- [ ] Confirm whether the customer's policy requires **PIM-eligible** rather than standing
      assignments for any human operators.
- [ ] Confirm each CI deployment identity has the **Synapse Artifact Publisher** workspace role;
      Azure resource-group Contributor alone does not grant Synapse data-plane publication access.

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
