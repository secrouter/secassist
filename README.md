# SecAssist — a governed AI chat UI for the SecRouter suite

**A ChatGPT-style assistant your whole team can use — every message governed.** SecAssist
packages [LibreChat](https://github.com/danny-avila/LibreChat) as the suite's end-user chat
interface: people **sign in with SSO** (SecSSO / OIDC) and every model call is routed through
**SecRouter**, so policy, budgets, egress, and a tamper-evident audit apply **per person** —
not to one shared service account.

[![License: Apache 2.0](https://img.shields.io/badge/License-Apache_2.0-blue.svg)](LICENSE)

Part of the **SecRouter** suite: SecAssist is the human-facing chat front door; SecLLM's
`/admin` console (model ops) and SecRouter's `/admin` console (governance) sit behind it.

## What you get

- **LibreChat** (chat UI + conversation history + search) via Compose, with **MongoDB** and
  **Meilisearch**. Pinned images; nothing built except a tiny local proxy.
- **SSO-only login.** Local registration and password login are off; users authenticate
  through SecSSO via OpenID Connect (`OPENID_*`). One click, MFA enforced at the IdP.
- **Per-user governance.** A small zero-dependency [auth proxy](proxy/) authenticates to
  SecRouter as the `svc-secassist` service account and **forwards each signed-in user**, so
  the gateway attributes policy, budget, quota, and audit to the real person. See
  [docs/governance.md](docs/governance.md).
- **Only in-boundary models.** The one endpoint is SecRouter; SecAssist never holds a
  commercial provider key. SecRouter decides which models each user may reach.

## Architecture

```
  Browser ──login (OIDC)──▶ SecSSO
     │
     ▼  chat
  LibreChat ──/v1 + x-sec-acting-user──▶ secrouter-proxy ──Bearer svc-secassist──▶ SecRouter ─▶ SecLLM / GovCloud
     │                                     (mints + refreshes the service token)      (governs + audits
     └─ MongoDB (history) · Meilisearch (search)                                        as the end-user)
```

LibreChat logs each person in and, on every model call, forwards their identity in
`x-sec-acting-user`. It can only send a *static* bearer to a custom endpoint, so the proxy
supplies the *fresh* `svc-secassist` client-credentials token SecRouter needs and passes the
user header through. SecRouter's `delegatingSubjects` then replaces the principal with that
end-user. No user secret ever reaches the browser; service tokens stay short-lived.

## Quickstart

```bash
cp .env.example .env
# generate the secrets it asks for (see the comments in .env):
#   openssl rand -hex 32   → CREDS_KEY, JWT_SECRET, JWT_REFRESH_SECRET, OPENID_SESSION_SECRET
#   openssl rand -hex 16   → CREDS_IV, MEILI_MASTER_KEY
$EDITOR .env               # set the SecSSO + SecRouter refs too

./bootstrap/secassist.sh up      # builds the proxy, starts the stack, prints the wiring
```

`up` finishes by printing exactly what to provision in **SecSSO** (the login client + the
`secassist-svc` service account) and **SecRouter** (add `svc-secassist` to `serviceSubjects`
+ `delegatingSubjects`). In the suite, **SecDeploy wires all of this for you**
(`--with-assist`); the readout is for standalone / manual installs.

- **SSO** setup and claims: [docs/sso.md](docs/sso.md)
- **Per-user governance** (how delegation works, the audit trail): [docs/governance.md](docs/governance.md)

## Notes

- **Container-based.** LibreChat is a Node app with MongoDB + Meilisearch; SecAssist runs it
  in containers (Colima on macOS, Podman on Fedora), like SecSSO and SecChat.
- **Third-party.** LibreChat, MongoDB, and Meilisearch are not vendored — their images are
  pulled at deploy under their own licenses (see [NOTICE](NOTICE)). Only `proxy/` is original.
- Run behind SecProxy (TLS) in production; set `DOMAIN_CLIENT`/`DOMAIN_SERVER` to the
  `https://` address so OIDC redirect URIs match.

## License

[Apache 2.0](LICENSE) — Copyright 2026 Austin Probe.
