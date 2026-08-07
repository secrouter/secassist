# SecAssist SSO (OpenID Connect via SecSSO)

SecAssist uses LibreChat's built-in OpenID Connect login, pointed at SecSSO. Local
registration and email/password login are disabled — everyone signs in through the IdP,
where MFA is enforced.

## The login client

Provision a **confidential** OIDC application in SecSSO for SecAssist. The suite ships it as
`secsso/blueprints/secassist.yaml` (auto-applied); manually it is:

- `client_id`: `secassist`
- `client_type`: confidential (client secret; Authorization Code flow)
- redirect URI: `${DOMAIN_CLIENT}/oauth/callback/openid`
- scopes: `openid profile email groups`

## `.env` settings

| Variable | Meaning |
|---|---|
| `OPENID_ISSUER` | SecSSO issuer for this app, e.g. `https://secsso.sec.internal/application/o/secassist/` |
| `OPENID_CLIENT_ID` | `secassist` |
| `OPENID_CLIENT_SECRET` | the client secret from SecSSO |
| `OPENID_SESSION_SECRET` | random 32-byte hex (`openssl rand -hex 32`) |
| `OPENID_SCOPE` | `openid profile email groups` |
| `OPENID_CALLBACK_URL` | `/oauth/callback/openid` |
| `OPENID_EMAIL_CLAIM` / `OPENID_NAME_CLAIM` / `OPENID_USERNAME_CLAIM` | claim mapping (`email` / `name` / `preferred_username`) |
| `OPENID_BUTTON_LABEL` | login button text (`Sign in with SecSSO`) |
| `OPENID_AUTO_REDIRECT` | `true` → skip LibreChat's landing page, go straight to SecSSO |
| `ALLOW_REGISTRATION` / `ALLOW_EMAIL_LOGIN` | both `false` — SSO only |
| `ALLOW_SOCIAL_LOGIN` / `ALLOW_SOCIAL_REGISTRATION` | both `true` — allow OIDC users to log in / be created on first login |

## Restricting who can log in

To gate access to a group, set `OPENID_REQUIRED_ROLE` (with the matching role/group
variables LibreChat documents) so only members of, say, `secassist-users` are admitted.
Otherwise any SecSSO user with a valid token can sign in and is created on first login.

## Note on groups

LibreChat reads the `groups` scope for its own authorization, but it does **not** currently
expose the user's IdP groups as a request-header template for the downstream model endpoint.
That affects *gateway* policy, not login — see [governance.md](governance.md) for how
SecRouter keys per-user policy on the forwarded email in the meantime.
