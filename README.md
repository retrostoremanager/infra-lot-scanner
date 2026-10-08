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
| `lot-scanner-func-plan-<env>` / `lot-scanner-func-<env>` | **Linux** Consumption Function App running `fn-lot-scanner` (.NET 10 isolated worker) |

## Why this is a Linux plan, unlike gamedb/mystore's Windows ones

Windows Consumption's placeholder pool only has .NET 6/8 isolated-worker images
available as of 2026-10-08 (confirmed live via the Function App's own
`LogFiles/eventlog.xml`: IIS tried to specialize a `DOTNET-ISOLATED_8.0`/`6.0`
placeholder into running a .NET 10 app, which crashed it immediately — every request
came back as a blank `400` with no routing-level or application-level error, because
the host itself was healthy but could never reach a running worker). `az functionapp
list-runtimes` lists `dotnet-isolated 10` as supported, but that reflects the platform
roadmap, not what's actually rolled out to every Windows Consumption scale unit yet.
Linux Consumption picks up new isolated-worker runtimes faster, so switching OS (not
downgrading the .NET version) is what actually unblocks .NET 10 here. Revisit Windows
once Microsoft rolls out a .NET 10 placeholder — nothing else about this setup depends
on the OS choice.

## Secrets: set directly, not as Key Vault references

`Anthropic__ApiKey` and `JwtAuthentication__SecretKey` are set as **literal values** in
the Function App's app settings (from the same secure Bicep params that also write them
to Key Vault for visibility/rotation) rather than as `@Microsoft.KeyVault(...)`
references. Isolated-worker Function Apps don't reliably resolve Key Vault references
at runtime — confirmed directly: both showed up as the literal unresolved reference
string via `az functionapp config appsettings list` and had to be patched with real
values before auth/AI calls worked. `ConnectionStrings__lotscanner` still goes through
Key Vault + a workflow sync step (see below) since it needs `infra-gamedb`'s admin
password at deploy time, not something `main.bicep` has access to directly.

## Known gotcha (inherited from infra-gamedb)

The GitHub Actions service principal deploying this template needs **User Access
Administrator** (or **Owner**), not just **Contributor**, on the resource group —
`main.bicep` creates Key Vault role assignments, which Contributor alone can't do. See
`infra-gamedb`'s README for how that service principal was originally set up; this repo
can reuse the same principal with an additional role assignment scoped to
`lot-scanner-rg-dev`. The same applies to *your own* account if you want to read secrets
from `lot-scanner-kv-dev` directly (e.g. for local debugging) — `enableRbacAuthorization:
true` means nobody gets implicit access, not even the deployer, until a role is granted.

## Required GitHub secrets (this repo)

| Secret | Purpose |
|---|---|
| `AZURE_CREDENTIALS`, `AZURE_SUBSCRIPTION_ID` | Azure login for the deploy workflow |
| `ANTHROPIC_API_KEY` | Claude API key |
| `JWT_AUTHENTICATION_SECRET_KEY` | Must match `fn-mystore`'s configured value |
| `POSTGRES_ADMIN_PASSWORD` | Same value used in `infra-gamedb` (same Postgres server) |
| `GH_ACTIONS_SP_OBJECT_ID` | Object ID of the deploying service principal, for the Key Vault role grant |

## Status

Redeploying to Linux Consumption as of 2026-10-08 (see above) after discovering Windows
Consumption can't yet run a .NET 10 isolated worker here. `lotscanner-dev`'s schema is
already applied directly via `db-lot-scanner/migrations/`. Once the Linux redeploy is
confirmed working, `app-lot-scanner` (the frontend) still needs
`EXPO_PUBLIC_API_BASE_URL` pointed at this Function App and a real employee login flow
before an actual device can use it end-to-end.
