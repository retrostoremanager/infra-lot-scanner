# infra-lot-scanner

Azure Bicep IaC for `fn-lot-scanner`'s hosting: Key Vault, Storage Account (also backs
the `lot-scan-photos` blob container and `lot-scan-identify` queue), Function App
Service Plan (consumption), and the Function App itself.

This repo does **not** provision the `lotscanner` Postgres database or server — that
lives on `db-gamedb`'s existing Flexible Server, provisioned by `infra-gamedb`'s
`main.bicep` (see `retrostoremanager/lot-scanner`'s
`specs/001-lot-scan-review/research.md` #5 for the cost rationale). This repo only
provisions the compute/secrets layer and wires a connection string to that existing
database.

## Resources

| Resource | Purpose |
|---|---|
| `lot-scanner-kv-<env>` | Key Vault — `AnthropicApiKey`, `JwtAuthenticationSecretKey` (set directly by `main.bicep`), `LotScannerDbConnectionString` (set by the deploy workflow, see below) |
| `lotscannerstg<env>` | Storage Account — Function App storage + blob/queue |
| `lot-scanner-func-plan-<env>` / `lot-scanner-func-<env>` | Consumption Function App running `fn-lot-scanner` (.NET 10 isolated worker) |

## Why the connection string isn't set entirely in Bicep

`AnthropicApiKey` and `JwtAuthenticationSecretKey` are simple secret values, so
`main.bicep` writes them to Key Vault directly. The lotscanner Postgres connection
string needs `db-gamedb`'s admin password — a secret `infra-gamedb`'s deploy already
holds — interpolated into a connection string, so (matching `infra-gamedb`'s own
`GameDbConnectionString` pattern) it's constructed and written to Key Vault by this
repo's GitHub Actions workflow instead of inline Bicep.

## Known gotcha (inherited from infra-gamedb)

The GitHub Actions service principal deploying this template needs **User Access
Administrator** (or **Owner**), not just **Contributor**, on the resource group —
`main.bicep` creates Key Vault role assignments, which Contributor alone can't do. See
`infra-gamedb`'s README for how that service principal was originally set up; this repo
can reuse the same principal with an additional role assignment scoped to
`lot-scanner-rg-dev`.

## Required GitHub secrets (this repo)

| Secret | Purpose |
|---|---|
| `AZURE_CREDENTIALS`, `AZURE_SUBSCRIPTION_ID` | Azure login for the deploy workflow |
| `ANTHROPIC_API_KEY` | Claude API key |
| `JWT_AUTHENTICATION_SECRET_KEY` | Must match `fn-mystore`'s configured value |
| `POSTGRES_ADMIN_PASSWORD` | Same value used in `infra-gamedb` (same Postgres server) |
| `GH_ACTIONS_SP_OBJECT_ID` | Object ID of the deploying service principal, for the Key Vault role grant |

## Status

Not yet deployed — this is Bicep + workflow only. Deploying requires the secrets above
to be set on this repo and the service principal's RBAC confirmed, same "built, deploy
blocked on keys" pattern as other RSM services.
