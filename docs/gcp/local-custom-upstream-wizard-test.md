# GCP custom API and MCP wizard walkthrough

This walkthrough uses a public sample API to verify that the
wizard registers an upstream, creates a scoped delegation, and routes requests
through the public Console and Gateway. It does not create Google Cloud
resources.

## What the wizard does

For GCP, the wizard registers the URL of an existing HTTP(S) API or MCP server;
it does not deploy that service. The route and upstream URL are stored in the
deployment's Firestore-backed catalog. For example, an upstream registered as
`catalog-demo` is exposed at `/api-catalog-demo`; a request to
`/api-catalog-demo/posts/1` is forwarded to `/posts/1` on the configured
upstream.

Agents must call the **public Console URL** on the governed route. Do not give
them the private Gateway URL or let them call the upstream directly if you
expect the Gateway to enforce the delegation. This is route-level API/MCP
protection, not a general-purpose egress proxy for the agent's other traffic.

The Gateway access token authenticates the agent to Agent Gateway. It is not
sent to the upstream. If an upstream needs authentication, the caller must
supply a separate credential on each request; Agent Gateway does not store it.

## REST API walkthrough

### 1. Register a harmless test API

1. Sign in to the Console with an allowlisted administrator account.
2. Open **API Wizard** and choose **REST / HTTP API**.
3. Use a new, non-reserved slug such as `catalog-demo`.
4. Choose **Remote Upstream URL** and enter this upstream base URL:

   ```text
   https://jsonplaceholder.typicode.com
   ```

   This public sample API supports the read-only test requests below. Do not use a
   production API or real credentials for this walkthrough.
5. Continue to **Tools / Endpoints**. Set **Permitted Resource Path Patterns**
   to:

   ```text
   /api-catalog-demo/posts/*
   ```

   Select only **read** for this walkthrough. This scope permits GET/HEAD
   requests under the sample API's `/posts/` path, not its other routes.
6. Continue to the delegation step. Choose a short test lifetime if offered
   and use a descriptive agent ID such as `wizard-test-catalog`.
7. Leave approval rules and spend limits unset for this read-only test, unless
   you specifically want to exercise those controls.
8. Review the route and scope. Select **Register Upstream & Create
   Delegation** (or the equivalent GCP button text shown in your build). Do not
   choose **Create Delegation Only** for this registration test.

The wizard should report that the upstream and delegation were created. The
governed base route is:

```text
/api-catalog-demo
```

The route slug must match the name you entered in the wizard exactly. This
walkthrough uses `catalog-demo`, so its governed route is `/api-catalog-demo`.
Use the same spelling in the delegation scope, the Target Service selection,
and every request path.

If the Protected Upstreams inventory already shows a different route, for
example `/api-catalogue-demo`, use that exact route in requests and ensure the
delegation scope matches it. The route and delegation scope must agree; a
delegation for `/api-catalog-demo/*` does not cover `/api-catalogue-demo/*`.
Alternatively, register the upstream again using the slug from the delegation.

### 2. Test an in-scope request

1. In the **Delegations** list, find the row for the agent you created.
   Verify that the scope shown beneath its ID is `/api-catalog-demo/posts/*`,
   then click **Test** on that row.
2. Ensure the tester has a short-lived access token for that delegation. If
   needed, enter the delegation's agent secret and mint a fresh token.
3. Set the request method to **GET** and the path to:

   ```text
   /api-catalog-demo/posts/1
   ```

   Clear any query parameters left over from a previous test. The governed
   base route is not itself the sample API path.
4. Send the request. A successful response should contain the sample post with
   ID `1`. The upstream receives `/posts/1`, while the agent calls the governed
   `/api-catalog-demo/posts/1` route through the Console.

If the Gateway returns `resource not allowed`, check that the delegation scope,
request path and registered route use the same slug, and that the tester's
token belongs to that delegation. The generated cURL command can contain a
live token without guaranteeing that its delegation allows the chosen path.
Do not share the token when reporting an error.

For GET requests, the tester hides the JSON request-body editor. Parameters go
in the path or query field; the returned JSON appears in the response.

### 3. Check that authorization is enforced

To check an out-of-scope request with the **same token**, copy the generated
cURL command for the successful request into a private terminal and change
only its path to:

```text
/api-catalog-demo/users/1
```

This is outside the configured `/posts/*` scope and should be denied by the
Gateway (normally HTTP 403). Editing the path in the tester can select another
matching delegation or clear the token, which would not test the original
delegation's scope. Treat the generated cURL command as a secret because it
contains the live token; do not share it.

Then clear the access token in the tester and retry the in-scope
`/api-catalog-demo/posts/1` route; an unauthenticated request should be
rejected (normally HTTP 401). If either request succeeds unexpectedly, stop
testing and record the sanitized response before using the feature further.

## Supplying an upstream credential

The sample API above needs no credential. To test credential forwarding, use a
separate test upstream for which you control a non-production test credential:

- Enter `X-API-Key: TEST_VALUE` in **Custom HTTP Headers** for the Endpoint
  Tester, or send that header from your client; or
- Enter `X-Upstream-Authorization: Bearer TEST_VALUE` when the upstream
  expects an `Authorization` header.

The Gateway first validates the Agent Gateway `Authorization: Bearer <agent
token>` header. It then removes that Gateway credential and maps
`X-Upstream-Authorization` to the upstream `Authorization` header. The
`X-Upstream-Authorization` header itself is not forwarded. `X-API-Key` is
forwarded as a separate header.

Use only a dummy or revocable test credential. Do not paste production secrets
into screenshots, shared terminals, prompts, source control, or logs. These
headers are supplied per request and are not saved with the upstream
registration. For clients outside the tester, keep both tokens in the client's
secret store and call the public Console URL.

## MCP server walkthrough

The registration flow is similar, but choose **MCP Server**, set a unique slug,
and enter the server's reachable HTTP(S) base URL. In the tools step:

1. Use **Discover Tools from Upstream** for an MCP server that allows discovery
   without authentication, or add the tool names manually if discovery is not
   available.
2. Select only the tools the test agent needs. The wizard also includes the
   MCP initialization/list actions needed for protocol setup.
3. Create the upstream and delegation. The governed route is
   `/mcp-<your-slug>`.
4. Test MCP `tools/list`, followed by an allowed `tools/call`, through the
   public Console route.

Tool discovery probes the upstream separately and does not
use the per-request caller credential headers. Therefore, authenticated MCP
servers may need their tools entered manually; the actual governed MCP call
can still carry caller-supplied `X-API-Key` or `X-Upstream-Authorization`
headers.

## Reachability and cleanup

- The upstream must be reachable from the Gateway's Cloud Run service, not
  merely from your browser or workstation. `localhost` refers to the Cloud
  Run container; it is not your computer. Private services require suitable
  GCP network connectivity and configuration.
- Registration stores the upstream base URL; it does not deploy the upstream
  or add an API's own authentication policy.
- Deleting the registered upstream removes its route from the catalog, but
  existing delegations remain. Delete the test upstream from the Console's
  protected-upstreams inventory, then revoke the test delegation separately.
- The built-in demo entries are deployment-configured and do not have the
  customer-registered upstream Delete action.
- Confirm subsequent calls to the deleted route fail, and do not leave
  temporary test credentials active.

## Report test results

For useful feedback, record the test image version, upstream type, whether
registration succeeded, the governed path, HTTP status for the in-scope and
out-of-scope requests, and any sanitized error text. Do not include access
tokens, agent secrets, upstream credentials, or personal data.
