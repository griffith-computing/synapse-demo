# synapse-demo

Proof-of-concept (PoC) for deploying Azure Synapse Analytics via Infrastructure-as-Code, deployable
through either **GitHub Actions** or **Azure DevOps Pipelines**, using **workload identity
federation** (no long-lived secrets) and **least-privilege RBAC**.

This PoC has been reviewed and approved for customer-facing delivery. It demonstrates a
repeatable deployment pattern, not a production-hardened reference architecture — see
[docs/demo-script.md](docs/demo-script.md#poc-shortcuts-vs-production-hardening) for the gap list.

## Quickstart

1. Read [docs/customer-prerequisites.md](docs/customer-prerequisites.md) and gather the listed
   Azure AD, subscription, and naming inputs before scheduling a deployment session.
2. Follow [docs/architecture.md](docs/architecture.md) to understand what gets deployed and why.
3. Execute [docs/deployment-runbook.md](docs/deployment-runbook.md) to stand up the environment
   using either pipeline, validate it offline, and (optionally, customer-attended) validate it live.
4. Use [docs/demo-script.md](docs/demo-script.md) to run the customer walkthrough, including
   discovery questions and cleanup.

> **Validation status:** All steps in this repository have been validated offline (template
> lint and unit-level checks). Azure what-if requires authenticated subscription access and is not
> an offline operation. No step has been executed against a
> live Azure subscription as part of authoring this documentation. Live validation is a customer-
> attended activity described in the runbook and must be performed before any production claim.

## Repository map

Paths below are the expected layout for this PoC. Some may not exist yet in a fresh checkout —
each pipeline and script references these locations as its contract.

| Path                     | Purpose                                                                 |
|--------------------------|--------------------------------------------------------------------------|
| `infra/`                 | Bicep/ARM (or Terraform) templates for Synapse workspace, storage, networking, and RBAC assignments |
| `synapse/`               | Synapse artifacts — SQL scripts, Spark notebooks, pipelines/datasets, linked services |
| `config/`                | Per-environment overrides for Synapse workspace artifact publication |
| `scripts/`               | Helper scripts for validation, smoke tests, and cleanup (PowerShell/bash) |
| `.github/workflows/`     | GitHub Actions pipeline definitions (build/validate/deploy/promote) |
| `azure-pipelines/`       | Azure DevOps pipeline definitions (build/validate/deploy/promote) |
| `docs/`                  | This documentation set (owned independently of the infra/pipeline code) |

## Release pipelines

Both supported CI platforms use two independent build-once, promote-everywhere release streams:

- The infrastructure pipeline packages only `infra/` and deploys Bicep through dev, test, and
   prod. Changes limited to `synapse/` or `config/` do not trigger it.
- The artifact pipeline packages `synapse/`, `config/`, and `sample/`, then publishes the same immutable
   package through dev, test, and prod without redeploying infrastructure. The target workspace
   must already exist.

Infrastructure and Synapse artifacts also have separate rollback entry points, so a prior artifact
package can be republished without changing Azure resources.

## Documentation set

- [docs/architecture.md](docs/architecture.md) — components, identity/RBAC model, environment
  topology, private networking extension points.
- [docs/customer-prerequisites.md](docs/customer-prerequisites.md) — access, subscription,
  naming, and cost inputs required from the customer before deployment.
- [docs/deployment-runbook.md](docs/deployment-runbook.md) — step-by-step deployment via GitHub
  Actions and Azure DevOps, promotion, rollback, validation, troubleshooting, cleanup.
- [docs/demo-script.md](docs/demo-script.md) — customer discovery questions, live walkthrough
  script, PoC-vs-production gap list.