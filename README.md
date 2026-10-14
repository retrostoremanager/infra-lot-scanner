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
| `lot-scanner-func-plan-<env>` / `lot-scanner-func-<env>` | **Windows** Consumption Function App running `fn-lot-scanner` (.NET 10 isolated worker) |

## Windows, not Linux (reverted 2026-10-13)

Briefly tried Linux Consumption (2026-10-08/09) to work around Windows Consumption's
.NET 10 isolated-worker placeholder gap (IIS tried to specialize a `DOTNET-ISOLATED_8.0`/
`6.0` placeholder into running a .NET 10 app and crashed immediately — every request
came back as a blank `400`). That turned out to be the wrong fix: this subscription had
**never run a Linux Consumption Function App before** (confirmed via `az appservice plan
list` — every other plan here, gamedb's and mystore's, is Windows), and every Linux
attempt failed identically afterward — including a fully isolated test in a different
region with a brand-new storage account, created via `az functionapp create` instead of
Bicep, which still got stuck (ARM reports "Running", every HTTP request `503`s) while
this same subscription's existing Windows Consumption apps responded instantly. Reverted
to Windows, which is proven reliable here, and retrying .NET 10 on Windows — placeholder
availability can change day to day. See project memory / git history for the full
two-session investigation if this needs revisiting.

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

**Live and working on Windows Consumption + .NET 10 as of 2026-10-14.** The entire
Linux-Consumption detour (2026-10-08/09) and the "maybe it's a platform/subscription
issue" investigation that followed were chasing a red herring: the real blocker was a
bug in the *test tooling* used to validate the deployment, not in this infrastructure or
in `fn-lot-scanner`'s code. A hand-rolled JWT-minting script written on Windows left a
raw `\r` (carriage return) embedded at the end of every test Bearer token (`dotnet run >
token.txt` writes CRLF; `tr -d '\n'` only stripped the LF). An embedded CR inside an HTTP
header value is invalid and gets rejected — producing a blank `400 Bad Request` on
*every* request that included that token, which looked exactly like a platform-level
rejection. Confirmed by testing the same malformed token against `fn-mystore`'s proven,
long-running production app — it showed the identical blank `400`. Fixing the test
script (`tr -d '\r\n'` instead of `tr -d '\n'`) immediately revealed the app was working
correctly: `GET /api/lot-scans/{nonexistent-id}` returns the correct `404`, auth/routing
all function as designed on the first real, cleanly-tested Windows + .NET 10 deploy.

Separately confirmed (unrelated to this app): `api-gamedb`'s own `/api/games` and
`/api/pricing/lookup` endpoints 500 directly when queried, with no lot-scanner code in
the path — `/api/health` reports its DB as connected, but any real query fails. This
will block `fn-lot-scanner`'s catalog-search proxy specifically, but is a pre-existing
`api-gamedb` bug to fix in that repo, not here.

`app-lot-scanner` (the frontend) still needs `EXPO_PUBLIC_API_BASE_URL` pointed at
`https://lot-scanner-func-dev.azurewebsites.net` and a real employee login flow before
an actual device can use it end-to-end.
