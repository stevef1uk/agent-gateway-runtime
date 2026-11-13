# Azure implementation plan

This plan turns the Azure proposal into a testable, scripted delivery. Users
provide a non-secret environment/account config; scripts provision or select
the Neon database and drive Terraform for Azure. Application behavior,
database integration, and container composition are tested locally before any
Azure apply. This checkout has no Agent Gateway application source, container
build files, Terraform, or complete installer. Phase 1 has started with a
non-secret Neon config validator and read-only existing-project status helper;
this is not database provisioning or application integration.

## Design review and decisions

The proposed service layout is a reasonable starting point: four separate
Container Apps in one Consumption environment, `authz` on internal ingress,
the other required endpoints on HTTPS ingress, and Neon as the default
PostgreSQL provider. These items must be resolved before treating the design as
deployable:

1. **Neon-backed OIDC sessions are required for web scale-to-zero.** The
   current web image keeps OIDC state and sessions in process memory. A restart
   or scale-to-zero between sign-in and callback can lose state. Implement
   shared durable OIDC transaction/state and server-side session storage in the
   existing Neon PostgreSQL database before configuring `web` with minimum
   replicas zero. Setting `DATABASE_URL` for Agent Gateway domain data does not
   provide this feature. Until the new web image is deployed and passes the
   scale-to-zero acceptance test, keep at least one web replica warm; that only
   mitigates scale-down and does not survive process restart.
2. **The image contract is not yet a deployment contract.** Obtain the exact
   release manifest for all four licensed images and verify ports, health
   paths, environment variable names, secret file paths, startup behavior,
   resource requirements, and supported persistence settings. If a new Azure
   image must be built, add the requested `_a` suffix to its release tag; for
   example, use `<version>_a` and optionally publish `latest_a` as a convenience
   alias. Terraform must reference the immutable digest, never the mutable
   `latest_a` alias. Record the release provenance.
3. **Neon integration is an early implementation gate.** The user must have a
   Neon project/database, but creation and setup should be scripted where the
   Neon API supports it. The script must also support selecting an existing
   project/database, check ownership and region, and avoid logging credentials.
   Verify service persistence and OIDC session storage against a real
   non-production Neon database early, not only against local PostgreSQL.
   Exercise startup migrations, pooled/direct connections, TLS, connection
   limits, restart durability, and audit/session retention.
4. **Public endpoints need explicit access policies.** Decide which callers
   need the web console, token endpoint, and Gateway API. Specify authentication,
   authorization, domains, Entra redirect/callback URLs, forwarded-header
   trust, CORS if used, and outbound destinations. `authz` must remain internal.
   Do not rely on an unspecified edge service as the only protection.
5. **User config, Neon provisioning, and secret delivery need a safe contract.**
   Commit a template config and installer, not an account-specific config or
   secret values. Keep Neon API keys, generated database credentials, customer
   private keys, signed licence tokens, JWT secrets, and OIDC client secrets
   out of Git, command arguments, Terraform plans/state, outputs, and logs.
   Prefer writing generated runtime credentials directly to Key Vault and
   exposing only Key Vault references to Container Apps.
6. **The cost estimate is not a cap.** It excludes several potentially material
   charges, including Log Analytics, egress to Neon, networking, registry,
   Key Vault operations, and edge protection. Azure budgets alert; they do not
   stop spending. Refresh prices and set operational alerts/quotas before a
   pilot.

## Phases and test gates

Do not advance a phase until its exit gate passes. Neon-backed OIDC sessions
are required before the low-cost scale-to-zero goal can be enabled. Until that
phase passes and its image is deployed, keep `web` min replicas = 1.

### Phase 0 — Freeze contracts and define the user config

**Work**

- Select the source repositories and owners for application changes; this
  proposal branch does not contain those sources.
- Inventory the exact licensed image digests and vendor release manifest.
- Record each service's port, health/readiness behavior, required environment,
  mounted files, persistence needs, migration behavior, and expected memory/CPU.
- Decide public endpoint/domain and caller policy for each app, Entra app
  registration and callback URIs, database endpoint mode, data region, and
  pilot/production networking boundary.
- Confirm Neon as the shared session-store target, how session data is
  separated from domain data, and the connection/credential contract. Use a
  warm web replica only as the temporary mode before durable session support
  ships.
- Define the user-created environment config schema: Azure tenant/subscription,
  region and resource names; Neon existing-project selection or project-create
  settings; database/role names; web domains and OIDC callback URLs; image
  digests; replica limits; and Key Vault references. Never put API keys,
  passwords, licence tokens, or private keys in this file.
- The initial Azure user config template is `azure-config.example.json`.
  Users copy it to the ignored `azure-config.json`; no deployment command
  consumes it until the installer phase is implemented.
- Agree on image tagging: Azure-built release tags end in `_a` (for example
  `<version>_a`); `latest_a` may be a moving alias, but deployments use digests.
- Set explicit retention, backup/recovery, audit, cost alert, and teardown
  requirements.

**Test / exit gate**

- Check every required image can be pulled by an authorized operator and its
  digest and manifest are recorded.
- Validate the manifest against actual container startup and `/healthz` (or
  the documented health endpoint) in a disposable local run.
- Validate the example config with no cloud credentials; reject missing
  required fields and any detected secret values.
- No unresolved placeholders remain for ports, paths, environment names,
  callback URLs, database settings, public routes, secret formats, or owners.

### Phase 1 — Provision Neon and prove application database integration

**Current implementation baseline**

- `config/neon.example.json` defines the initial non-secret Neon selection
  contract. `scripts/neon_setup.py ... validate` validates that contract, and
  `... status` reads sanitized metadata for an existing project using
  `NEON_API_KEY` from the process environment.
- Project/database/role creation, secret delivery, database migrations, and
  Agent Gateway PostgreSQL and OIDC/session adapters are not implemented.
  Application-side work is blocked until the corresponding application source
  and release/image contract are available in this repository or an identified
  upstream repository.

**Work**

- Add an idempotent Neon setup command driven by the user config. It should
  support selecting an existing project/database or creating a dedicated
  non-production project/database and least-privilege app role. Use the Neon
  API or a maintained provider/CLI after confirming it supports the required
  operations. The initial status-only helper is not a substitute for these
  operations. Read the Neon API key from the process environment or a secure
  interactive login, never from the committed example config.
- Make create/status operations safe to repeat and report resource IDs and
  non-secret connection metadata. Require explicit confirmation for
  billable-project creation and destructive database/project deletion. Never
  print generated passwords or full connection strings.
- Provision generated database credentials directly to the configured Key
  Vault when Azure identity is available. For local development, store
  credentials in an ignored local secret file with restrictive permissions or
  a secret manager; never write them to tracked config or Terraform state.
- Implement/test Agent Gateway PostgreSQL persistence and migrations against a
  disposable local PostgreSQL first, then the dedicated Neon development
  database. Use TLS, verify the Neon direct endpoint for migrations and select
  a pooled runtime endpoint only after its compatibility is proven.
- Implement OIDC transaction state (including nonce and PKCE verifier when
  used) and server-side web sessions in the same Neon database, using isolated
  tables/schema and least-privilege access as appropriate. Define bounded
  expiry and cleanup, atomic one-time transaction consumption, replay
  protection, logout/revocation, and behavior when the database is unavailable.
- Keep only a protected opaque session identifier in the browser using
  `Secure`, `HttpOnly`, and appropriate `SameSite` cookie attributes. Do not
  persist provider tokens unless documented product behavior requires them.
- Ensure multiple web instances share cookie/session-signing configuration and
  require no in-memory state to complete callbacks. Document the web session
  database setting and secret contract.
- Make database startup and migrations safe across multiple service replicas.
- Build and publish a new web image only if the existing image cannot be
  configured to use the implementation. Tag Azure-built artifacts with the
  agreed `_a` suffix (for example `<version>_a`; optional `latest_a` alias),
  record the immutable digest, and document upgrade and rollback. Rebuild other
  service images only if their own code or runtime contract changes.

**Local and Neon test gate**

- Neon config validation, create/select, status, and safe rerun tests pass with
  mocked API responses. Tests cover permission errors, wrong account/project,
  partial failure, and refusal to delete without confirmation.
- Run all SQL migrations and persistence tests against a local PostgreSQL
  container from an empty database and an upgrade fixture.
- Run the same migration and CRUD/restart tests against a dedicated Neon
  development database using TLS. Verify role grants, direct migration
  connection, runtime pooler behavior, connection limits, Neon cold wake-up,
  and that session/audit data survives app restarts.
- Unit/integration tests cover successful sign-in, invalid/missing/replayed
  state, expiration, logout/revocation, cookie flags, concurrent callbacks,
  process restart, a second web instance, and database errors.
- Run the web image locally with PostgreSQL; verify no secrets or session
  contents are exposed in logs or browser storage.

**Exit gate:** tests pass in CI and the published image contract makes Neon
session storage explicit. Neon create/select automation and DB integration
must pass before building the full Azure infrastructure. Do not enable zero
minimum replicas before the deployed image passes the Phase 4 cold-callback
test. Until then keep a warm web replica.

### Phase 2 — Build a repeatable local four-service integration environment

**Work**

- Add a non-production local harness (for example Docker Compose) using the
  same pinned image digests and configuration contract intended for Azure.
- Include disposable PostgreSQL and a test OIDC provider or isolated Entra test
  tenant flow. Use synthetic licence/test keys only; never production
  activation material. Exercise the same session-store interface and
  migrations used with Neon.
- Exercise the service-to-service routes and health dependencies without
  exposing `authz`.

**Local test gate**

- All four containers become healthy from a clean start and after restart.
- `gateway`, `tokensvc`, and `web` reach `authz`; an external test client cannot
  reach `authz`.
- Complete OIDC login/callback/logout (including the selected session mode),
  obtain/revoke a test delegation, and verify allowed, denied, and
  approval-held requests go through the Gateway policy enforcement point.
- Simulate a web process restart and a second web replica between OIDC start and
  callback; both must use the shared PostgreSQL session store successfully.
- Verify audit/persistence survives a service restart, and capture cold-start,
  timeout, memory, and connection-pool baselines.
- Test missing/invalid secrets and database outage; failures should be closed,
  explicit, and diagnosable.

**Exit gate:** repeatable local test command passes from a clean checkout and
produces no reliance on a developer's real credentials or cloud resources.

### Phase 3 — Implement the config-driven installer and Terraform

**Work**

- Add a pinned Terraform and AzureRM provider version plus committed provider
  lock file. Keep modules small and explicit: resource group/diagnostics,
  Container Apps environment, identity/secrets, and the four apps.
- Extend the committed `azure-config.example.json` and document updating the
  gitignored `azure-config.json`; test the ignore rule. It holds non-secret
  account/environment-specific values: tenant and subscription IDs, location,
  resource/environment names, domain and callback URLs, image references,
  replica bounds, logging retention, and Key Vault secret names/IDs. The same
  config drives Neon selection/provisioning and Azure deployment.
- Add a scripted entry point (for example `./scripts/azure.sh --config
  azure-config.json neon|plan|apply|destroy`) with separate
  `neon` and Azure lifecycle subcommands. It validates the config, checks
  `az account show` against the configured tenant/subscription, runs Terraform
  with the selected workspace/backend, shows the plan, requires explicit
  approval before billable creation/apply/destroy, and emits only non-secret
  endpoints and resource identifiers. It must not silently select the current
  Azure subscription.
- Keep credentials, private keys, signed licence tokens, `DATABASE_URL`, and
  OIDC client secrets out of the config file. Provision values separately to
  Key Vault; the config may reference vault/resource IDs and secret names, not
  secret contents. Never print secret values or put them in Terraform outputs.
- Parameterize subscription/tenant, region, image digests, ingress, replica
  bounds, CPU/memory, logging retention, and external database configuration.
- Keep `authz` internal-only; make externally reachable ingress opt-in and
  narrowly configured. Add least-privilege managed identity and Key Vault
  secret references. Do not manage secret values as Terraform inputs.
- Exclude Neon and other existing external resources from Terraform ownership.
  Add explicit safeguards against accidental deletion of managed persistent
  resources if the Azure PostgreSQL option is later selected.
- Define remote Terraform state (encrypted Azure Storage, restricted identity,
  locking, versioning/recovery) before shared environments. Use local state
  only for isolated developer validation.

**Local test gate (no Azure apply)**

- `terraform fmt -check -recursive`
- `terraform init -backend=false -lockfile=readonly`
- `terraform validate`
- `terraform test` with provider mocks for module/default/invalid-input and
  security invariants, including internal-only `authz`, replica settings,
  secret references, region, and image digests.
- Run the installer config-validation and `plan` modes with a safe sample
  config, no Azure credentials, and mocked or offline Terraform inputs. Verify
  missing/unknown fields, malformed IDs, and unsafe `latest_a` deployment
  references fail before apply. Verify a mismatched active Azure subscription
  is rejected and apply/destroy require explicit confirmation.
- Verify Neon status and dry-run modes need no API key; live create reads
  `NEON_API_KEY` from the process environment or secure login, targets only the
  configured project/region, and never prints credentials.
- Verify the sample config contains no credential values and is not the
  gitignored user config. Secret scanning must cover the config, generated
  files, plans, and test fixtures.
- Run a Terraform linter and IaC security scanner; review every finding and
  document accepted exceptions.
- Generate a plan only with synthetic non-secret values and verify no secret
  values appear in plan output.

**Exit gate:** checks pass without Azure credentials; all public exposure,
identity, secret, diagnostic, and cost-related resources are represented in
the reviewed plan; an operator can run the scripted workflow from a clean
checkout using only a non-secret user config. Terraform is not considered
locally deployed merely because `validate` succeeds.

### Phase 4 — Disposable Azure development deployment

**Work**

- Use a dedicated non-production subscription/resource group and remote state.
- Run the scripted installer with the user-created non-production config and
  apply the reviewed plan with the minimum required Azure permissions.
- Start with pinned images, conservative replica ceilings, short diagnostic
  retention, and the agreed web OIDC mode. Keep production credentials and
  customer activation material out of development.
- Use the staged scripted order: provision/bootstrap remote Terraform state
  and Key Vault, provision/select Neon and write generated runtime credentials
  to Key Vault, then apply the Container Apps configuration. Initially keep
  `web` at minimum 1 while checking connectivity and migrations; only set
  minimum 0 after the deployed image contains Neon session support.
- Do not provision optional Azure PostgreSQL, Redis, ACR, NAT, WAF, or other
  billed services unless a documented test or requirement needs them.

**Azure smoke / acceptance gate**

- Review `terraform plan` before apply; after apply, compare actual resources
  with Terraform state and confirm no out-of-scope resources were created.
- Verify HTTPS, only intended public routes, internal-only `authz`, OIDC
  callback URL, service-to-service calls, and database TLS.
- Repeat the Phase 2 functional tests against the deployed endpoints.
- Exercise scale-to-zero and cold starts. Create OIDC state, wait until `web`
  has scaled to zero, then complete the callback on the cold-started app; verify
  a different replica can subsequently resume the session. Repeat with Neon's
  compute suspended or cold, and record callback latency and failure behavior.
- Confirm session migrations are applied safely, session rows expire/are
  cleaned up, and no secret or session contents appear in Terraform state,
  container logs, or browser storage.
- Verify logs/metrics, alarms, backup/audit behavior, and egress rules.
- Inspect actual cost/usage and revise the estimate; alerting is not a hard cap.

**Exit gate:** signed-off test evidence and cost/security review. Destroy the
disposable deployment and verify expected resources are removed, retained
data/logs are understood, and a fresh apply can recreate the environment.

### Phase 5 — Production readiness and controlled promotion

**Work**

- Reassess residency, private networking, DNS, egress, access restrictions,
  threat model, backup/restore, retention, support, capacity, and availability.
- Confirm the Neon project created or selected by the script meets plan limits,
  TLS, pooled/direct connection, egress, region, backup, and recovery
  requirements. Use Azure PostgreSQL only if Neon does not meet a documented
  requirement, and separately design and price its network/database resources.
- Set production replica ceilings and minimums from load evidence; configure
  budgets and alerts, with an owner and response procedure.
- Establish image promotion, Terraform plan review, approval, state backup,
  rollback, secret rotation, and disaster-recovery procedures.

**Production release gate**

- CI gates from Phases 1–3 are green; production Terraform plan is reviewed
  and approved; credentials and licensed activation material are provisioned
  through the agreed secret path.
- Run a limited canary, verify the production sign-in and policy path, monitor
  errors/latency/scale/cost, and confirm rollback before increasing traffic.
- Complete a restore/rollback exercise before declaring the service operational.

Do not promote a `latest_a` alias as the production image reference. Resolve the
tested release tag to its digest and put that digest in the user config used for
the reviewed Terraform plan. A later image change requires the same image and
integration test gates.

## Terraform deployment boundary

The config-driven installer is the intended repeatable interface. It
provisions/selects Neon first, validates the user's non-secret account and
environment config, then drives Terraform after the application and container
contracts have been verified locally. Terraform cannot prove the four
containers work together, validate a real Entra callback, or guarantee Neon
compatibility; those are application/local integration and disposable Azure
acceptance tests above. A successful Terraform plan is necessary but not
sufficient for production deployment.
