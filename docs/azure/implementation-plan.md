# Azure implementation roadmap

The public Azure deployment package is implemented: it includes the Bicep
template, guarded lifecycle wrapper, example configuration, and Key Vault
secret uploader. The supervised development trial successfully exercised the
Console, Policy/Rego page, Telegram configuration, and wizard-managed Emotion
service. This roadmap records the design choices and practical checks for
deploying the public tooling with a release-owner image manifest.

Use the [deployment guide](../Azure-Deployment-Guide.md) for the operator
workflow. The remaining roadmap focuses on confirming the selected release
images and customer-specific Azure integrations in the target environment.
Application images are supplied as immutable releases by the release owner.

The Neon helper streamlines Neon project selection or provisioning and writes
local credentials. Complete the database and OIDC checks in the deployment
checklist with the release images and target environment.

## Deployment design and validation checklist

The deployment uses four separate
Container Apps in one Consumption environment, `authz` on internal ingress,
the other required endpoints on HTTPS ingress, and Neon as the default
PostgreSQL provider. Use the checklist to configure and validate each
environment:

1. **Confirm Azure OIDC behavior before web scale-to-zero.** During the
   development trial, the application used shared PostgreSQL-backed OIDC
   transaction/session state and cross-instance tests passed. Keep at least
   one web replica while bringing up an environment; test callback and restart
   behavior with the exact deployed image before enabling scale-to-zero.
2. **Prepare the release manifest.** Obtain the exact release
   manifest for all licensed images and verify ports, health
   paths, environment variable names, secret file paths, startup behavior,
   resource requirements, and supported persistence settings. The application
   source is proprietary; users of this repository cannot build or modify
   these images. Deployment config must reference the release owner's
   immutable digest, never a mutable tag. Record release provenance.
3. **Configure Neon integration.** Select or provision a Neon project/database
   and confirm ownership, region, and credentials. Verify service persistence
   and OIDC session storage against a non-production Neon database. Exercise
   startup migrations, pooled/direct connections, TLS, connection limits,
   restart durability, and audit/session retention.
4. **Set public endpoint access policies.** Decide which callers
   need the web console, token endpoint, and Gateway API. Specify authentication,
   authorization, domains, Entra redirect/callback URLs, forwarded-header
   trust, CORS if used, and outbound destinations. `authz` must remain internal.
   Do not rely on an unspecified edge service as the only protection.
5. **Protect configuration and secrets.** Keep account-specific config and
   secret values out of Git, command arguments, deployment parameters, outputs,
   and logs. The public wrapper uploads local secret files to Key Vault and
   exposes Key Vault references to Container Apps; obtain the application
   licence asset from the release owner.
6. **Plan and monitor spend.** The cost estimate excludes additional charges
   such as Azure Monitor log ingestion, egress to Neon, networking, private
   registry, Key Vault operations, and edge protection. Azure budgets provide
   alerts rather than spending caps. Refresh prices and set operational alerts
   and quotas before a pilot.

## Deployment roadmap

Use these steps to prepare the release and validate an environment. Neon-backed
OIDC sessions and image-specific callback checks inform the scale-to-zero
configuration; keep `web` at one minimum replica until those checks pass.

### Phase 0 — Freeze contracts and define the user config

**Work**

- Coordinate application changes and release details with the release owner.
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
- The canonical template is
  `deploy/azure/azure-config.example.json`; copy it to the ignored
  `deploy/azure/azure-config.json`, which `scripts/deploy_azure.py` consumes.
- Agree on the release manifest and digest distribution with the image owner.
  Users do not build the proprietary application images.
- Set explicit retention, backup/recovery, audit, cost alert, and teardown
  requirements.

**Test / exit gate**

- Check every required image can be pulled by an authorized operator and its
  digest and manifest are recorded.
- Validate the manifest against actual container startup and `/readyz` (or
  the release's documented health endpoint) in a disposable run.
- Validate the example config with no cloud credentials; reject missing
  required fields and any detected secret values.
- No unresolved placeholders remain for ports, paths, environment names,
  callback URLs, database settings, public routes, secret formats, or owners.

### Phase 1 — Provision Neon and prove application database integration

**Current implementation baseline**

- `config/neon.example.json` defines the non-secret Neon selection contract.
  `scripts/neon_setup.py ... validate`, `status`, and `setup` validate config,
  inspect sanitized project metadata, and provision/select the configured
  project, database, and application role. `destroy` deletes only a project
  recorded as created by this tool, with explicit project-ID confirmation.
- The application source and image build files remain proprietary. The public
  repo includes the Key Vault uploader, but users cannot inspect or modify
  application-side PostgreSQL/OIDC behavior here.

**Work**

- The Neon helper is implemented. It supports selecting an existing
  project/database or creating a dedicated non-production project/database
  and application role. It reads `NEON_API_KEY` from the process environment,
  never from the committed example config.
- Make create/status operations safe to repeat and report resource IDs and
  non-secret connection metadata. Require exact-name confirmation for
  project creation, exact-ID confirmation for mutations to existing projects,
  and exact locally recorded project-ID confirmation for destroy. Never print
  generated passwords or full connection strings.
- For local development, store the generated database URL in an ignored local
  credentials file with mode `0600`; never write it to tracked config or
  deployment parameters. `scripts/deploy_azure.py upload-secrets` transfers it
  to the configured Key Vault without printing the value.
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
- If an image change is necessary, the proprietary application owner must
  implement and publish it. Public-repo users consume the release owner's
  immutable digests; they do not build or modify the application images.

**Local and Neon test gate**

- Neon config validation, create/select, status, and safe rerun tests pass with
  mocked API responses. Tests cover permission errors, wrong project/region,
  partial failure, ownership-only teardown, and refusal to delete without
  exact confirmation.
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

### Phase 3 — Public Azure installer

The Bicep-based installer is implemented and available in this repository:

- `deploy/azure/main.bicep` declares the managed environment, four apps,
  internal-only `authz`, HTTPS ingress, readiness checks, Key Vault secret
  references, and optional private-registry pulls.
- `scripts/deploy_azure.py` validates tenant/subscription and digest-pinned
  image config, uploads local secret files to Key Vault without putting
  values in command arguments, runs What-If, and requires exact confirmations
  for apply and destroy.
- `deploy/azure/azure-config.example.json` is the canonical non-secret config
  template; its user copy is gitignored.
- The script creates no remote Terraform state. It scopes ARM deployment to
  a dedicated app resource group and separately owns the Emotion demo group.
  It does not create/delete Neon, the Key Vault, or Entra resources.

Use the deployment guide to run the installer with release-approved image
digests. The acceptance checklist covers image ports and readiness, Key Vault
RBAC, registry access, Entra sign-in, persistence, wizard-managed Emotion, and
ownership-aware teardown.

### Phase 4 — Operator deployment and acceptance

Use the [deployment guide](../Azure-Deployment-Guide.md) for the public Bicep
workflow. Prepare a dedicated non-production subscription and resource groups,
release-owner image digests, an RBAC-enabled Key Vault, Neon credentials, and
Entra configuration. The installer deploys `web` and `authz` with one minimum
replica and `gateway` and
`tokensvc` with zero minimum replicas.

**Azure smoke / acceptance gate**

- Review the Azure What-If preview and verify only the dedicated resources
  are changed.
- Verify HTTPS, public routes, internal-only `authz`, Entra OIDC callback,
  service-to-service calls, and database TLS.
- Repeat the app behavior tests against the deployed endpoints, including
  policy enforcement, persistence, and wizard-managed Emotion creation and
  deletion.
- Exercise cold starts and scale-to-zero for the apps configured with a zero
  minimum. Keep `web` warm until its cold-callback behavior is verified.
- Confirm session migrations, expiry, logs/metrics, alarms, backup/audit
  behavior, and egress controls. Verify no secret or session contents appear
  in output or logs.
- Inspect actual cost/usage and revise the estimate; alerting is not a hard
  cap.
- Run the guarded destroy, verify only deployment-owned resource groups and
  tool-created Key Vault secrets were removed, then repeat apply in a clean
  dedicated environment.

**Completion:** record the live test results and review costs and security
settings before promoting the environment.

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
- Establish image promotion, What-If review, approval, deployment rollback,
  secret rotation, and disaster-recovery procedures.

**Production release gate**

- CI gates from Phases 1–3 are green; production What-If is reviewed and
  approved; credentials and licensed activation material are provisioned
  through the agreed secret path.
- Run a limited canary, verify the production sign-in and policy path, monitor
  errors/latency/scale/cost, and confirm rollback before increasing traffic.
- Complete a restore/rollback exercise before declaring the service operational.

Do not use mutable tags such as `latest` as production image references.
Resolve a tested release to its immutable digest and put that digest in the
user config used for the reviewed What-If. A later image change requires the
same image and integration test gates.

## Deployment boundary

The deployment wrapper is the repeatable Azure interface. It validates the
user's non-secret config and Azure context, provisions Azure resources scoped
to dedicated groups, and presents an ARM What-If before deployment. After
provisioning, use the live acceptance checklist above to confirm the release
images, Entra sign-in, Neon integration, and Emotion wizard in your environment.
