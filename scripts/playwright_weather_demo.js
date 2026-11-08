#!/usr/bin/env node
/**
 * End-to-end Playwright automation for the AWS Open-Meteo Weather Demo.
 *
 * 1. Opens the deployed ConsoleURL in Chrome (persistent profile so you only
 *    sign in once per Cognito session).
 * 2. If not signed in yet, navigates to /oidc/login, pre-fills your operator
 *    email, and waits for you to complete Cognito sign-in in the browser window.
 * 3. Creates the scoped weather delegation (demo/weather-delegation.json)
 *    via the signed-in console session.
 * 4. Runs Phase 1 (`bash demo/public-weather-tutorial.sh access`) and captures
 *    the held Approval ID.
 * 5. Clicks the real "Approve" button in the Console UI for that Approval ID.
 * 6. Runs Phase 2 (`bash demo/public-weather-tutorial.sh approved`).
 * 7. Clicks the real "Revoke" button in the Console UI for that Delegation ID.
 * 8. Runs Phase 3 (`bash demo/public-weather-tutorial.sh revoked`).
 */

const fs = require('fs');
const path = require('path');
const { spawnSync } = require('child_process');
const { chromium } = require('playwright');

const runtimeRoot = path.resolve(__dirname, '..');
const consoleUrl = (process.env.CONSOLE_URL || '').replace(/\/+$/, '');
const gatewayUrl = (process.env.GATEWAY_URL || '').replace(/\/+$/, '');
const operatorEmail = process.env.OPERATOR_EMAIL || 'stevef1uk@gmail.com';
const cognitoPassword = process.env.COGNITO_PASSWORD || '';
const profileDir = process.env.PLAYWRIGHT_PROFILE_DIR || '/tmp/agw-weather-playwright-profile';

if (!consoleUrl || !gatewayUrl) {
  console.error('Error: CONSOLE_URL and GATEWAY_URL must be set.');
  process.exit(2);
}

function banner(msg) {
  console.log(`\n==> ${msg}`);
}

function runTutorialPhase(phase, agentToken) {
  banner(`Running tutorial phase: '${phase}'`);
  const res = spawnSync('bash', ['demo/public-weather-tutorial.sh', phase], {
    cwd: runtimeRoot,
    env: {
      ...process.env,
      GATEWAY_URL: gatewayUrl,
      AGENT_TOKEN: agentToken,
    },
    encoding: 'utf8',
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  if (res.stdout) process.stdout.write(res.stdout);
  if (res.stderr) process.stderr.write(res.stderr);
  if (res.status !== 0) {
    throw new Error(`Phase '${phase}' exited with status ${res.status}`);
  }
  return res.stdout || '';
}

(async () => {
  fs.mkdirSync(profileDir, { recursive: true, mode: 0o700 });

  banner(`Launching Chrome via Playwright (Console: ${consoleUrl})`);
  const context = await chromium.launchPersistentContext(profileDir, {
    channel: 'chrome',
    headless: false,
    viewport: { width: 1280, height: 900 },
  });

  try {
    const page = context.pages()[0] || (await context.newPage());

    await page.goto(consoleUrl, { waitUntil: 'domcontentloaded' });

    const checkWhoami = async () => {
      return await page.evaluate(async () => {
        try {
          const r = await fetch('/api/whoami?_=' + Date.now(), { credentials: 'same-origin' });
          if (!r.ok) return { signed_in: false };
          return await r.json();
        } catch {
          return { signed_in: false };
        }
      });
    };

    let whoami = await checkWhoami();
    if (!whoami.signed_in) {
      banner('Not signed in yet — redirecting to Cognito Hosted UI (/oidc/login)...');
      await page.goto(`${consoleUrl}/oidc/login`, { waitUntil: 'domcontentloaded' });

      const userField = page.locator('#signInFormUsername:visible, input[name="username"]:visible').first();
      const passField = page.locator('#signInFormPassword:visible, input[name="password"]:visible').first();

      try {
        await userField.waitFor({ state: 'visible', timeout: 8000 });
        await userField.fill(operatorEmail);
        if (cognitoPassword) {
          await passField.fill(cognitoPassword);
          const submitBtn = page.locator('input[name="signInSubmitButton"]:visible, button[type="submit"]:visible').first();
          await submitBtn.click();
        } else {
          await passField.focus();
          console.log('================================================================================');
          console.log(`Please enter the Cognito password for ${operatorEmail} in the opened Chrome window`);
          console.log('and click "Sign in". Playwright will continue automatically once signed in!');
          console.log('================================================================================');
        }
      } catch {
        // Already redirecting or custom IdP page
      }

      await page.waitForURL(
        (url) => url.origin === new URL(consoleUrl).origin && !url.pathname.startsWith('/oidc/'),
        { timeout: 300000 }
      );
      await page.waitForLoadState('domcontentloaded');
      whoami = await checkWhoami();
      if (!whoami.signed_in) {
        throw new Error('Browser returned to ConsoleURL, but /api/whoami still reports signed_in=false.');
      }
    }

    banner(`Signed in to Console as ${whoami.email || whoami.subject || 'operator'}`);

    // Step 1: Create the scoped weather delegation
    const delegationSpec = JSON.parse(
      fs.readFileSync(path.join(runtimeRoot, 'demo/weather-delegation.json'), 'utf8')
    );

    banner('Step 1: Creating scoped weather delegation via /api/delegations');
    const created = await page.evaluate(async (spec) => {
      const r = await fetch('/api/delegations', {
        method: 'POST',
        credentials: 'same-origin',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(spec),
      });
      const text = await r.text();
      if (!r.ok) {
        throw new Error(`POST /api/delegations failed (${r.status}): ${text}`);
      }
      const data = JSON.parse(text);
      if (typeof window.loadDelegations === 'function') {
        await window.loadDelegations();
      }
      return {
        delegationId: data.delegation && data.delegation.id,
        agentId: data.delegation && data.delegation.agent_id,
        token: data.token,
      };
    }, delegationSpec);

    if (!created.delegationId || !created.token) {
      throw new Error('Delegation response did not include delegation.id and token.');
    }
    console.log(`Created delegation_id=${created.delegationId} (agent_id=${created.agentId})`);

    // Step 2: Run Phase 1 ('access')
    const accessOutput = runTutorialPhase('access', created.token);
    const match = accessOutput.match(/Approval ID:\s*(\S+)/);
    if (!match) {
      throw new Error('Could not find "Approval ID: <id>" in access phase output.');
    }
    const approvalId = match[1].trim();
    console.log(`Captured held Approval ID: ${approvalId}`);

    // Step 3: Approve the pending elevation request in the Console UI
    banner(`Step 3: Approving pending elevation request (${approvalId}) in Console UI`);
    await page.evaluate(async () => {
      if (typeof window.loadApprovals === 'function') {
        await window.loadApprovals();
      }
    });

    const approveBtn = page.locator(
      `button[data-act="decide"][data-accept="1"][data-id="${approvalId}"]`
    );
    await approveBtn.waitFor({ state: 'visible', timeout: 15000 });
    await approveBtn.scrollIntoViewIfNeeded();
    const [approveResp] = await Promise.all([
      page.waitForResponse(
        (r) =>
          r.url().includes(`/api/approvals/${encodeURIComponent(approvalId)}/decision`) &&
          r.request().method() === 'POST'
      ),
      approveBtn.click(),
    ]);
    if (!approveResp.ok()) {
      throw new Error(`Approve button request failed with HTTP ${approveResp.status()}`);
    }
    console.log(`Approved ${approvalId} in Console UI (HTTP ${approveResp.status()})`);

    // Step 4: Run Phase 2 ('approved')
    runTutorialPhase('approved', created.token);

    // Step 5: Revoke the delegation in the Console UI
    banner(`Step 5: Revoking delegation (${created.delegationId}) in Console UI`);
    await page.evaluate(async () => {
      if (typeof window.loadDelegations === 'function') {
        await window.loadDelegations();
      }
    });

    const revokeBtn = page.locator(
      `button[data-act="revoke"][data-id="${created.delegationId}"]`
    );
    await revokeBtn.waitFor({ state: 'visible', timeout: 15000 });
    await revokeBtn.scrollIntoViewIfNeeded();
    const [revokeResp] = await Promise.all([
      page.waitForResponse(
        (r) =>
          r.url().includes(`/api/delegations/${encodeURIComponent(created.delegationId)}/revoke`) &&
          r.request().method() === 'POST'
      ),
      revokeBtn.click(),
    ]);
    if (!revokeResp.ok()) {
      throw new Error(`Revoke button request failed with HTTP ${revokeResp.status()}`);
    }
    console.log(`Revoked ${created.delegationId} in Console UI (HTTP ${revokeResp.status()})`);

    // Step 6: Run Phase 3 ('revoked')
    runTutorialPhase('revoked', created.token);

    banner('All 3 phases (access -> approved -> revoked) PASSED via Playwright!');
    await page.waitForTimeout(2000);
  } finally {
    await context.close();
  }
})().catch((err) => {
  console.error(`\nERROR: ${err.message}`);
  process.exit(1);
});
