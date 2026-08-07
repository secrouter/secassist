# Per-user governance

The point of routing SecAssist through SecRouter is that **every message is governed and
audited as the person who sent it** — not as one shared "chat UI" account. This is how that
works end to end.

## The flow

1. A user signs in to SecAssist with their own SecSSO identity (OIDC, MFA at the IdP).
2. On every model call, LibreChat forwards that identity to its endpoint as a header:
   `x-sec-acting-user: <email>` (configured in `librechat.yaml`).
3. The endpoint is the **auth proxy** (`proxy/`, compose service `secrouter-proxy`), not
   SecRouter directly. The proxy:
   - holds a **short-lived** `svc-secassist` token, obtained from SecSSO with the
     client-credentials grant and refreshed before it expires;
   - sets `Authorization: Bearer <that token>` and passes `x-sec-acting-user` through;
   - streams the response back unchanged.
4. SecRouter authenticates the `svc-secassist` service token, sees that its `sub` is in
   `security.oidc.delegatingSubjects`, reads `x-sec-acting-user`, and **replaces the
   principal with that end-user**. Policy, budgets, quotas, and the usage ledger all
   evaluate against the real person; the `auth.success` audit records
   `delegatedBy: svc-secassist` (RFC 8693 `act`) so the actor→subject chain is explicit.

Why the proxy exists: LibreChat can forward the *user* per request but can only send a
*static* bearer to a custom endpoint, while SecRouter needs a *fresh* (expiring) service
JWT. The proxy bridges that — short-lived tokens, and no secret in the browser.

## What you configure in SecRouter

Add the service subject to **both** OIDC lists in `freerouter.config.json`:

```jsonc
"security": { "oidc": {
  "serviceSubjects":   [ "svc-secassist" ],   // its machine token skips requireMfa
  "delegatingSubjects":[ "svc-secassist" ]     // it may forward x-sec-acting-user
}}
```

Then govern chat users like any other principal — per user or by group:

```jsonc
"security": { "policy": {
  "users": {
    "alice@example.mil": { "allowedModels": ["gpt-oss-120b"], "budgets": [{ "window": "day", "maxCostUsd": 5 }] }
  }
}}
```

Users without a specific entry get `policy.default`. In the SecRouter admin console's
**Audit** tab, their events read *`alice@example.mil · via svc-secassist`*.

## Trust model

- The forwarded `x-sec-acting-user` header is honored **only** because the caller is
  `svc-secassist` — a listed delegator. Any other token that sets the header is ignored, so
  there is no way for one user to impersonate another. The trust anchor is the
  `svc-secassist` credential itself: scope it to SecAssist alone, keep it in `.env` (never
  in the browser), and rotate it at SecSSO like any secret.
- The end-user's MFA is enforced at SecAssist's own OIDC login (SecSSO), not re-attested from
  the service token. The audit's `delegatedBy` makes that chain auditable.
- A forwarded identity is shape-checked (length, control characters) before use.

## Known limitation: groups

LibreChat forwards the user's **email/id**, not their SecSSO **groups**, to the endpoint. So
per-*user* policy (`policy.users[<email>]`) and the default apply to SecAssist traffic today,
but per-*group* policy does not key automatically off SecAssist requests. Options: assign the
relevant users explicit `policy.users` entries, or front the group with a per-user budget.
Forwarding groups is a follow-on once LibreChat exposes a group header template (or via a
SecRouter-side email→group lookup).
