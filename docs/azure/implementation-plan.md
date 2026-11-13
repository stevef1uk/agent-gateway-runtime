# Azure implementation plan

This plan turns the Azure proposal into a testable, staged delivery. It assumes
Terraform will provision Azure resources, while application behavior and
container integration are tested locally before any Azure apply. The current
`azure` branch contains documentation only: it has no application source,
container build files, Terraform, or local integration harness.

## Design review and decisions

The proposed service layout is a reasonable starting point: four separate
Container Apps in one Consumption environment, `authz` on internal ingress,
the other required endpoints on HTTPS ingress, and Neon as the default
PostgreSQL provider. These items must be resolved before treating the design as
deployable:

1. **OIDC sessions conflict with web scale-to-zero.** The current web image
   keeps OIDC state and sessions in process memory. A restart or scale-to-zero
   between sign-in and callback can lose state. For the target scale-to-zero
   design, implement and release shared durable session/state storage first.
   Until then, use a minimum of one web replica and explicitly accept that a
   process restart can still invalidate a sign-in. Do not describe a warm
   replica as durable-session support.
2. **The image contract is not yet a deployment contract.** Obtain the exact
   release manifest for all four licensed images and verify ports, health
   paths, environment variable names, secret file paths, startup behavior,
   resource requirements, and supported persistence settings. Pin production
   images by digest and record the release provenance.
3. **Database behavior needs compatibility evidence.** Verify that every
   service requiring persistence supports the selected Neon endpoint and TLS
   settings. Exercise startup migrations, concurrent service startup, pooled
   connections, connection limits under scale-out, restart durability, and
   audit retention. If startup migrations race, add a controlled migration
   step or documented serialization before deployment.
4. **Public endpoints need explicit access policies.** Decide which callers
   need the web console, token endpoint, and Gateway API. Specify authentication,
   authorization, domains, Entra redirect/callback URLs, forwarded-header
   trust, CORS if used, and outbound destinations. `authz` must remain internal.
   Do not rely on an unspecified edge service as the only protection.
5. **Secret delivery and Terraform state need a safe contract.** Keep customer
   private keys, signed licence tokens, JWT secrets, OIDC client secrets, and
   database URLs out of Git, command arguments, Terraform plans/state, outputs,
   and CI logs. Prefer Key Vault references with managed identity; verify the
   image can consume the secret as the required environment value or mounted
   file. Define how initial secret material is provisioned and rotated.
6. **The cost estimate is not a cap.** It excludes several potentially material
   charges, including Log Analytics, egress to Neon, networking, registry,
   Key Vault operations, and edge protection. Azure budgets alert; they do not
   stop spending. Refresh prices and set operational alerts/quotas before a
   pilot.

## Phases and test gates

Do not advance a phase until its exit gate passes. Keep the low-cost
scale-to-zero goal conditional on the OIDC session phase; the temporary
alternative is `web` min replicas = 1.

### Phase 0 — Freeze service, identity, network, and release contracts

**Work**

- Select the source repositories and owners for application changes; this
  proposal branch does not contain those sources.
- Inventory the exact licensed image digests and vendor release manifest.
- Record each service's port, health/readiness behavior, required environment,
  mounted files, persistence needs, migration behavior, and expected memory/CPU.
- Decide public endpoint/domain and caller policy for each app, Entra app
  registration and callback URIs, database endpoint mode, data region, and
  pilot/production networking boundary.
- Choose the OIDC operating mode: durable shared sessions before scale-to-zero,
  or warm web replica until that support ships.
- Set explicit retention, backup/recovery, audit, cost alert, and teardown
  requirements.

**Test / exit gate**

- Check every required image can be pulled by an authorized operator and its
  digest and manifest are recorded.
- Validate the manifest against actual container startup and `/healthz` (or
  the documented health endpoint) in a disposable local run.
- No unresolved placeholders remain for ports, paths, environment names,
  callback URLs, database settings, public routes, secret formats, or owners.

### Phase 1 — Implement required application behavior

**Work**

- Implement web OIDC state and server-side session persistence in a shared
  PostgreSQL store if scale-to-zero is required. Keep only a protected,
  opaque session cookie in the browser. Add expiry, secure cookie attributes,
  CSRF/state validation, one-time callback handling, and safe session
  invalidation according to the existing application design.
- Make database startup and migrations safe across multiple service replicas.
- Document supported environment/configuration, schema changes, connection
  pooling, health/readiness, and secret file contracts.
- Build and publish a new, versioned web image. Record its digest and upgrade
  or rollback procedure.

**Local test gate**

- Unit tests cover successful sign-in, invalid/missing/replayed state,
  expiration, logout/revocation, cookie flags, and database errors.
- PostgreSQL integration tests verify persistence across process restart and
  that a second web instance can complete the callback and continue the
  session.
- Migration tests cover empty database, supported upgrade, repeated startup,
  and concurrent startup behavior for all services that migrate.
- Run the web image locally with PostgreSQL; verify no secrets or session
  contents are exposed in logs or browser storage.

**Exit gate:** tests pass in CI and the published image contract makes shared
session support explicit. If this phase is deferred, the deployment must use a
warm web replica and must not claim reliable sign-in across process restarts.

### Phase 2 — Build a repeatable local four-service integration environment

**Work**

- Add a non-production local harness (for example Docker Compose) using the
  same pinned image digests and configuration contract intended for Azure.
- Include disposable PostgreSQL and a test OIDC provider or isolated Entra test
  tenant flow. Use synthetic licence/test keys only; never production
  activation material.
- Exercise the service-to-service routes and health dependencies without
  exposing `authz`.

**Local test gate**

- All four containers become healthy from a clean start and after restart.
- `gateway`, `tokensvc`, and `web` reach `authz`; an external test client cannot
  reach `authz`.
- Complete OIDC login/callback/logout (including the selected session mode),
  obtain/revoke a test delegation, and verify allowed, denied, and
  approval-held requests go through the Gateway policy enforcement point.
- Verify audit/persistence survives a service restart, and capture cold-start,
  timeout, memory, and connection-pool baselines.
- Test missing/invalid secrets and database outage; failures should be closed,
  explicit, and diagnosable.

**Exit gate:** repeatable local test command passes from a clean checkout and
produces no reliance on a developer's real credentials or cloud resources.

### Phase 3 — Implement Terraform modules and static checks

**Work**

- Add a pinned Terraform and AzureRM provider version plus committed provider
  lock file. Keep modules small and explicit: resource group/diagnostics,
  Container Apps environment, identity/secrets, and the four apps.
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
- Run a Terraform linter and IaC security scanner; review every finding and
  document accepted exceptions.
- Run secret scanning over source, plans, generated files, and test fixtures.
- Generate a plan only with synthetic non-secret values and verify no secret
  values appear in plan output.

**Exit gate:** checks pass without Azure credentials; all public exposure,
identity, secret, diagnostic, and cost-related resources are represented in
the reviewed plan. Terraform is not considered locally deployed merely because
`validate` succeeds.

### Phase 4 — Disposable Azure development deployment

**Work**

- Use a dedicated non-production subscription/resource group and remote state.
- Apply the reviewed plan with the minimum required Azure permissions.
- Start with pinned images, conservative replica ceilings, short diagnostic
  retention, and the agreed web OIDC mode. Keep production credentials and
  customer activation material out of development.
- Do not provision optional Azure PostgreSQL, Redis, ACR, NAT, WAF, or other
  billed services unless a documented test or requirement needs them.

**Azure smoke / acceptance gate**

- Review `terraform plan` before apply; after apply, compare actual resources
  with Terraform state and confirm no out-of-scope resources were created.
- Verify HTTPS, only intended public routes, internal-only `authz`, OIDC
  callback URL, service-to-service calls, and database TLS.
- Repeat the Phase 2 functional tests against the deployed endpoints.
- Exercise scale-to-zero and cold starts; if shared sessions are enabled, test
  sign-in callback and existing session across scale-down and replica change.
- Verify logs/metrics, alarms, backup/audit behavior, and egress rules.
- Inspect actual cost/usage and revise the estimate; alerting is not a hard cap.

**Exit gate:** signed-off test evidence and cost/security review. Destroy the
disposable deployment and verify expected resources are removed, retained
data/logs are understood, and a fresh apply can recreate the environment.

### Phase 5 — Production readiness and controlled promotion

**Work**

- Reassess residency, private networking, DNS, egress, access restrictions,
  threat model, backup/restore, retention, support, capacity, and availability.
- Choose Neon only after plan limits, TLS, pooled/direct connection behavior,
  egress, region, and recovery objectives are accepted. Otherwise implement
  and separately price the Azure PostgreSQL network/database design.
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

## Terraform deployment boundary

Terraform is the intended repeatable mechanism to provision Azure after the
application and container contracts have been verified locally. Terraform
cannot prove the four containers work together, validate a real Entra callback,
or guarantee Neon compatibility; those are application/local integration and
disposable Azure acceptance tests above. A successful Terraform plan is
necessary but not sufficient for production deployment.
