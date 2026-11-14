# Azure custom API and MCP wizard walkthrough

This walkthrough is for a working Agent Gateway deployment with the managed
upstream feature enabled. It tests a harmless public API through the Console;
it does not create Azure resources. The supervised Azure trial referenced in
this repository has been torn down.

The Azure wizard stores generic API/MCP upstream URLs; it does not deploy
those services. A wizard-managed Emotion service is a separate Azure-specific
flow that provisions a private Container App.

## REST API smoke test

1. Sign in to the Console as an allowlisted administrator and open the API
   wizard. Choose **REST / HTTP API** and use a unique slug such as
   `catalog-demo`.
2. Select **Remote Upstream URL** and enter
   `https://jsonplaceholder.typicode.com`.
3. Configure the permitted resource pattern as
   `/api-catalog-demo/posts/*` and allow only read operations.
4. Create a test delegation with a descriptive agent ID, for example
   `wizard-test-catalog`. Review the route and scope before registering the
   upstream and delegation together.
5. In the Console tester, select that delegation and send `GET` to
   `/api-catalog-demo/posts/1`. It should return the sample post with ID `1`;
   the upstream path is `/posts/1`.
6. With the same token, try `/api-catalog-demo/users/1`. It is outside the
   allowed scope and should be denied, normally with HTTP 403. Clear the
   token and retry the allowed path; an unauthenticated request should be
   rejected, normally with HTTP 401.

The route slug, delegation scope, and request path must match exactly. Treat
generated cURL commands as secrets because they can contain a live token; do
not paste them into tickets or public logs.

## Generic MCP smoke test

For an existing MCP service, choose **MCP Server**, provide a unique slug and
an HTTP(S) base URL reachable from the Gateway, and discover or manually
specify the tools to allow. Create the upstream and delegation, then test
`tools/list` and one harmless allowed tool through the Console's governed
`/mcp-<slug>` route. Do not send agents directly to the upstream when
validating policy enforcement.

Tool discovery may not support authenticated upstreams. Use manual tool
configuration for discovery if necessary, and use only a test credential for
requests.

## Emotion is different

To test the built-in Emotion service, use the dedicated Azure Emotion wizard
action, not the generic remote-URL flow. It provisions a private Container
App, waits for the service warmup, and registers the governed route only
after readiness. Delete it through the Console's **Delete MCP** action so
the route and managed app are removed together.

For a deployment-specific cleanup, consult the
[Azure teardown guidance](teardown.md). This repository does not include the
Azure installer, Terraform, or guarded destroy wrapper.
