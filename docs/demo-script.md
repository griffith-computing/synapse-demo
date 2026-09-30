# Demo Script

Use this script to run a structured customer-facing walkthrough of the PoC. It assumes a `dev`
environment has already been deployed and **live-validated** by the delivery team following
[deployment-runbook.md](deployment-runbook.md#live-validation) before the customer session —
do not run a first-time live deployment during the live customer meeting.

## Before the session

- Confirm [customer-prerequisites.md](customer-prerequisites.md) items are complete.
- Confirm the `dev` environment is deployed and has passed the live validation checklist.
- Have both the GitHub Actions run and the Azure DevOps pipeline run (if demoing both platforms)
  available to show, even if only one was used for this customer's actual deployment.
- Have a rollback/cleanup plan ready in case the customer asks to see it live (see
  [deployment-runbook.md](deployment-runbook.md#cleanup)).

## Customer discovery

Open the session with these questions (mirrored in
[customer-prerequisites.md](customer-prerequisites.md#7-customer-discovery-questions)) to tailor
the rest of the walkthrough:

1. Which CI/CD platform do you want to see first — GitHub Actions or Azure DevOps — or both?
2. Do you already run workload identity federation (OIDC) anywhere today, or would this be a new
   pattern for your team?
3. How do you currently handle RBAC for deployment identities — standing Contributor, PIM,
   custom roles?
4. What environments matter most to you for this conversation (just dev, or the full promotion
   chain to prod)?
5. Is private networking a near-term requirement, or is public-endpoint PoC acceptable for now?
6. What's your timeline for moving from PoC to a production rollout?

Capture answers — they determine which sections below to emphasize or skip.

## Walkthrough

1. **Repository tour** (5 min)
   - Show the repository map in the root `README.md`.
   - Point out `infra/`, `synapse/`, `config/`, `scripts/`, `.github/workflows/`,
     `azure-pipelines/` and explain the dual-platform pipeline design.

2. **Identity and RBAC** (5–10 min)
   - Show the federated credential configuration on the App Registration (no client secret
     stored anywhere).
   - Show the role assignment scoped to the resource group only.
   - Reference [architecture.md](architecture.md#identity-and-rbac-model) for the full model.

3. **Trigger a deployment** (10–15 min)
   - Kick off the workflow/pipeline for `dev` (or `test`, if already promoted) live, showing:
     - Build/lint stage.
     - Offline validate / what-if output (call out explicitly that this step makes no changes).
     - Deploy stage authenticating via OIDC/workload identity federation — no secrets visible in
       logs.
     - Post-deploy smoke checks passing.
   - If time is limited, show a **previously completed** run instead of a live one, and be explicit
     that this is a recording of a prior live-validated run, not a new live deployment being
     narrated as if unverified.

4. **Inspect the deployed workspace** (5–10 min)
   - Open Synapse Studio, show the sample pipeline/notebook/SQL script from `synapse/`.
   - Run the sample artifact and show output, tying it back to the `config/<env>.json` values used.

5. **Promotion (if relevant to discovery answers)** (5 min)
   - Show how the same commit/artifact promotes from `dev` to `test` via
     [deployment-runbook.md#promotion-across-environments](deployment-runbook.md#promotion-across-environments),
     calling out the approval gate.

6. **Rollback discussion** (5 min)
   - Walk through [deployment-runbook.md#rollback-semantics-and-limits](deployment-runbook.md#rollback-semantics-and-limits)
     verbally rather than performing a live destructive rollback. Be explicit: rollback here means
     redeploying a known-good commit, and does **not** restore data-plane changes.

7. **Q&A and gap discussion** (open-ended)
   - Use the [PoC shortcuts vs production hardening](#poc-shortcuts-vs-production-hardening)
     table below to set accurate expectations.

8. **Cleanup** (as needed)
   - If the customer wants the environment removed at the end of the session, run the cleanup
     step from [deployment-runbook.md#cleanup](deployment-runbook.md#cleanup) and confirm in the
     portal that resources are gone.

## PoC shortcuts vs production hardening

Be transparent about what this PoC intentionally simplifies, and what a production rollout would
add. Use this table verbatim if asked "what's different for production?":

| Area | PoC shortcut | Production hardening |
|---|---|---|
| Networking | Public network access enabled on Synapse/storage/Key Vault for demo simplicity | Managed VNet + private endpoints for all data-plane resources; no public network access (see [architecture.md](architecture.md#private-networking-extension-points)) |
| Identity scope | One deployment App Registration per environment, resource-group scoped | Formal identity governance: naming standards, ownership records, periodic access reviews, possibly PIM-eligible for any human-triggered stages |
| Approvals | Environment approval gates optional/minimal in the PoC pipelines | Mandatory multi-approver gates before `prod`, branch protection, required status checks, signed commits |
| Secrets/config | `config/*.json` kept simple and non-sensitive; secrets (if any) via pipeline variables | Centralized secret management (Key Vault references in pipeline variable groups), rotation policies |
| Rollback | Redeploy known-good commit; no data-plane rollback | Backup/restore strategy for data-plane (storage soft-delete/versioning, SQL pool restore points), documented RTO/RPO |
| Monitoring | Basic diagnostic settings, short retention | Full observability: alerting, Azure Monitor workbooks, cost anomaly alerts, SLA-backed on-call |
| Cost controls | Dedicated SQL pool off by default, short Spark auto-pause | Autoscale policies, budgets/alerts, reserved capacity evaluation for steady-state workloads |
| Disaster recovery | Single region, no DR | Multi-region or paired-region DR strategy depending on RTO/RPO requirements |
| Compliance | Not scoped for regulated data | Data classification, encryption key management (customer-managed keys), audit logging retention aligned to compliance requirements |
| Testing | Offline template validation + basic smoke checks | Full integration/regression test suite, data quality checks, load testing |

Always pair this table with a reminder that the PoC's purpose is to prove the **deployment
pattern** (dual CI/CD platform support, workload identity federation, least-privilege RBAC), not
to serve as a production deployment as-is.

## After the session

- Record which discovery answers were captured and any follow-up commitments.
- If the customer wants the PoC environment left running, confirm an owner and a teardown date to
  avoid unmanaged cost (see [customer-prerequisites.md#6-cost-expectations](customer-prerequisites.md#6-cost-expectations)).
- Otherwise, run cleanup per [deployment-runbook.md#cleanup](deployment-runbook.md#cleanup).
