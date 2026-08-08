#!/usr/bin/env bash
# SecAssist — LibreChat lifecycle + the SSO/gateway wiring readout.
set -euo pipefail
cd "$(dirname "$0")/.."   # repo root (compose.yaml + .env live here)

compose() {
  if docker compose version >/dev/null 2>&1; then docker compose "$@"
  elif command -v docker-compose >/dev/null 2>&1; then docker-compose "$@"
  else echo "docker compose (plugin or standalone) not found" >&2; exit 1; fi
}

require_env() {
  [ -f .env ] || { echo "no .env — run: cp .env.example .env && \$EDITOR .env" >&2; exit 1; }
}

# env_val KEY — read KEY from .env (last match wins, quotes stripped).
env_val() { grep -E "^${1}=" .env 2>/dev/null | tail -n1 | cut -d= -f2- | tr -d '"'; }

wiring() {
  local site issuer login_cb svc_id svc_sub
  site="$(env_val DOMAIN_CLIENT)"; issuer="$(env_val OPENID_ISSUER)"
  login_cb="${site%/}/oauth/callback/openid"
  svc_id="$(env_val SECASSIST_SVC_CLIENT_ID)"; svc_id="${svc_id:-secassist-svc}"
  svc_sub="svc-${svc_id#secassist-}"   # svc-secassist by convention
  cat <<EOF

SecAssist is wired to two things you provision elsewhere:

1) SecSSO — the login client + the service account (see secsso/blueprints/secassist.yaml):
     login client_id:   $(env_val OPENID_CLIENT_ID)   (confidential; PKCE not required)
       redirect URI:    ${login_cb}
       issuer:          ${issuer}
       scopes:          $(env_val OPENID_SCOPE)
     service account:   ${svc_id}   (OAuth2 client_credentials → the proxy)
       token URL:       $(env_val SECSSO_TOKEN_URL)
       scope:           $(env_val SECROUTER_SCOPE)    (the "secrouter" scope sets the audience)
       token "sub":     ${svc_sub}

2) SecRouter — trust that service account to act on behalf of end-users. In
   freerouter.config.json add its sub to BOTH lists:
     "security": { "oidc": {
       "serviceSubjects":   [ ..., "${svc_sub}" ],   // skip MFA for the machine token
       "delegatingSubjects":[ ..., "${svc_sub}" ]    // may forward x-sec-acting-user
     } }
   Now every chat is governed + audited as the real signed-in user (docs/governance.md).

   UI: ${site}
EOF
}

case "${1:-help}" in
  up)
    require_env
    compose up -d --build
    echo "waiting for LibreChat to answer…"
    port="$(env_val SECASSIST_HTTP_PORT)"; port="${port:-3080}"
    for _ in $(seq 1 60); do
      if curl -sf "http://localhost:${port}/health" >/dev/null 2>&1 \
         || curl -sf "http://localhost:${port}/" >/dev/null 2>&1; then echo "  ✓ up"; break; fi
      sleep 3
    done
    wiring
    ;;
  status) require_env; compose ps ;;
  wiring) require_env; wiring ;;
  backup)
    # State SecDeploy's encrypted-backup flow collects for this stack. Stack must be UP.
    require_env; shift
    dir="${1:?usage: $0 backup <dir>}"; mkdir -p "$dir"
    echo "→ mongodump LibreChat → $dir/librechat.archive"
    compose exec -T mongodb mongodump --uri "mongodb://localhost:27017/LibreChat" --archive > "$dir/librechat.archive"
    echo "→ archiving LibreChat images + uploads"
    compose exec -T librechat sh -c 'tar czf - -C /app client/public/images uploads' > "$dir/librechat-files.tar.gz"
    cp .env "$dir/.env"   # CREDS_KEY/CREDS_IV decrypt secrets INSIDE the Mongo dump — mandatory
    echo "  ✓ secassist backup → $dir (librechat.archive, librechat-files.tar.gz, .env)"
    ;;
  restore)
    # Reinitialize this stack from a backup dir. The dumped .env's CREDS_KEY/CREDS_IV is what
    # decrypts the secrets stored inside the Mongo dump, so it MUST travel with it. REPLACES state.
    require_env; shift
    dir="${1:?usage: $0 restore <dir>}"
    [ -f "$dir/librechat.archive" ] || { echo "no librechat.archive in $dir" >&2; exit 1; }
    [ -f "$dir/.env" ] && { cp "$dir/.env" .env; echo "→ restored .env (CREDS_KEY/CREDS_IV to match the dump)"; }
    echo "→ reinitializing Mongo from a clean volume"
    compose down -v 2>/dev/null || true
    compose up -d mongodb
    for _ in $(seq 1 30); do compose exec -T mongodb mongosh --quiet --eval 'db.runCommand({ping:1}).ok' >/dev/null 2>&1 && break; sleep 2; done
    echo "→ mongorestore --drop"
    compose exec -T mongodb mongorestore --uri "mongodb://localhost:27017/LibreChat" --archive --drop < "$dir/librechat.archive"
    if [ -f "$dir/librechat-files.tar.gz" ]; then
      echo "→ starting LibreChat + restoring images/uploads"
      compose up -d --build
      for _ in $(seq 1 30); do compose exec -T librechat true >/dev/null 2>&1 && break; sleep 2; done
      compose exec -T librechat sh -c 'tar xzf - -C /app' < "$dir/librechat-files.tar.gz"
    fi
    echo "  ✓ secassist restore complete (run '$0 up' to bring everything up)"
    ;;
  logs) require_env; shift; compose logs -f "$@" ;;
  down) require_env; shift; compose down "$@" ;;
  *)
    cat <<'EOF'
SecAssist — governed AI chat UI (LibreChat) control helper
  ./bootstrap/secassist.sh up             build + start, wait, print the SSO/gateway wiring
  ./bootstrap/secassist.sh status         compose ps
  ./bootstrap/secassist.sh wiring         reprint the SecSSO + SecRouter wiring readout
  ./bootstrap/secassist.sh logs [svc]     follow logs (librechat | secrouter-proxy | …)
  ./bootstrap/secassist.sh down [-v]      stop (-v also wipes volumes/state)
EOF
    ;;
esac
