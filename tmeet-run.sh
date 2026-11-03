#!/usr/bin/env bash
# T-Meet deploy script. Pulls both repos and redeploys what changed.
#
#   /root/run.sh               # everything: greenlight + bbb (html5 only if it changed) + assets
#   /root/run.sh greenlight    # only Greenlight image + container
#   /root/run.sh bbb           # only HTML5 client (forced rebuild) + assets
#   /root/run.sh translate     # caption translator container (tmeet-translate)
#   /root/run.sh rollback      # put the previous Greenlight image back
#
# /root/run.sh is a symlink to /root/bigbluebutton/tmeet-run.sh, so the script
# updates itself with git pull. Everything runs inside main() so a pull that
# rewrites this file mid-run cannot break the running copy.

main() {
  set -euo pipefail

  local BBB_REPO=/root/bigbluebutton
  local GL_REPO=/root/greenlight
  local GL_RUNTIME=/root/greenlight-v3
  local ASSETS=/var/www/bigbluebutton-default/assets
  local IMAGE=greenlight-custom:production
  local PREVIOUS=greenlight-custom:previous
  local HTML5_STAMP=/root/.tmeet-html5-deployed
  local TRANSLATE_STAMP=/root/.tmeet-translate-deployed
  local TRANSLATE_IMAGE=tmeet-translate:latest
  local HF_TOKEN_FILE=/root/.hf-token
  local SITE=https://tmeet.tsaedu.com

  log() { echo -e "\n\033[1;34m==> $*\033[0m"; }
  ok() { echo -e "\033[1;32m    $*\033[0m"; }
  warn() { echo -e "\033[1;33m    $*\033[0m"; }

  pull() {
    log "git pull $1"
    git -C "$1" pull --ff-only
    ok "$(git -C "$1" log --oneline -1)"
  }

  deploy_greenlight() {
    pull "$GL_REPO"
    log "Building $IMAGE"
    if docker image inspect "$IMAGE" >/dev/null 2>&1; then
      docker tag "$IMAGE" "$PREVIOUS"
      ok "old image kept as $PREVIOUS (use: run.sh rollback)"
    fi
    docker build -q -t "$IMAGE" "$GL_REPO"
    log "Replacing greenlight-v3 container"
    (cd "$GL_RUNTIME" && docker compose up -d)
    docker image prune -f >/dev/null
    wait_for_greenlight
  }

  wait_for_greenlight() {
    log "Waiting for Greenlight"
    for _ in $(seq 1 30); do
      if [ "$(curl -s -o /dev/null -w '%{http_code}' "$SITE/")" = "200" ]; then
        ok "Greenlight is up ($SITE)"
        return 0
      fi
      sleep 3
    done
    warn "Greenlight did not answer 200 in 90s; check: docker logs --tail 50 greenlight-v3"
    return 1
  }

  rollback_greenlight() {
    docker image inspect "$PREVIOUS" >/dev/null 2>&1 || { warn "no $PREVIOUS image to roll back to"; exit 1; }
    log "Rolling back Greenlight to $PREVIOUS"
    docker tag "$PREVIOUS" "$IMAGE"
    (cd "$GL_RUNTIME" && docker compose up -d --force-recreate greenlight-v3)
    wait_for_greenlight
  }

  deploy_html5() {
    local force="${1:-}"
    local head
    head=$(git -C "$BBB_REPO" rev-parse HEAD)
    if [ -z "$force" ] && [ -f "$HTML5_STAMP" ] \
      && git -C "$BBB_REPO" diff --quiet "$(cat "$HTML5_STAMP")" "$head" -- bigbluebutton-html5; then
      ok "HTML5 client unchanged since last deploy, skipping build"
      return 0
    fi
    log "Building and deploying HTML5 client (about 5 minutes)"
    (cd "$BBB_REPO/bigbluebutton-html5" && ./deploy.sh)
    echo "$head" > "$HTML5_STAMP"
  }

  deploy_translate() {
    local force="${1:-}"
    local head
    head=$(git -C "$BBB_REPO" rev-parse HEAD)
    if [ -z "$force" ] && [ -f "$TRANSLATE_STAMP" ]       && git -C "$BBB_REPO" diff --quiet "$(cat "$TRANSLATE_STAMP")" "$head" -- tmeet-translate; then
      ok "tmeet-translate unchanged since last deploy, skipping build"
      return 0
    fi
    [ -f "$HF_TOKEN_FILE" ] || { warn "no $HF_TOKEN_FILE (Hugging Face read token); skipping tmeet-translate"; return 0; }
    log "Building $TRANSLATE_IMAGE"
    docker build -q -t "$TRANSLATE_IMAGE" "$BBB_REPO/tmeet-translate"
    log "Replacing tmeet-translate container (models load in about a minute)"
    docker rm -f tmeet-translate >/dev/null 2>&1 || true
    docker run -d --name tmeet-translate --restart unless-stopped       -p 127.0.0.1:8095:8095 --memory 3g       -v /root/tmeet-translate-models:/models       -v "$HF_TOKEN_FILE":/run/secrets/hf_token:ro -e HF_TOKEN_PATH=/run/secrets/hf_token       -e PRELOAD=en-indic,indic-en,indic-indic       "$TRANSLATE_IMAGE" >/dev/null
    docker image prune -f >/dev/null
    echo "$head" > "$TRANSLATE_STAMP"
    ok "tmeet-translate started (logs: docker logs -f tmeet-translate)"
  }

  deploy_nginx() {
    local src="$BBB_REPO/bigbluebutton-config/tmeet/tmeet-translate.nginx"
    local dst=/etc/bigbluebutton/nginx/tmeet-translate.nginx
    if ! cmp -s "$src" "$dst"; then
      log "Installing nginx config for tmeet-translate"
      cp "$src" "$dst"
      nginx -t && systemctl reload nginx
      ok "nginx reloaded"
    fi
  }

  deploy_assets() {
    log "Copying favicon, touch icons and default slide"
    cp "$BBB_REPO/bigbluebutton-config/assets/favicon.ico" "$ASSETS/favicon.ico"
    cp "$BBB_REPO/bigbluebutton-config/assets/default.pdf" "$ASSETS/default.pdf"
    cp "$GL_REPO/public/apple-touch-icon.png" "$ASSETS/apple-touch-icon.png"
    cp "$GL_REPO/public/apple-touch-icon-precomposed.png" "$ASSETS/apple-touch-icon-precomposed.png"
    ok "assets updated"
  }

  health() {
    log "Health check"
    local status
    status=$(bbb-conf --status 2>&1 || true)
    ok "$(grep -c "✔" <<< "$status" || true) BBB services active"
    grep "✘" <<< "$status" || true
    curl -s "$SITE/bigbluebutton/api" | grep -q SUCCESS && ok "BBB API answers" || warn "BBB API did not answer"
    if docker ps --format '{{.Names}}' | grep -qx tmeet-translate; then
      curl -s http://127.0.0.1:8095/health | grep -q ok && ok "tmeet-translate answers" || warn "tmeet-translate not ready yet"
    fi
  }

  case "${1:-all}" in
    all)
      deploy_greenlight
      pull "$BBB_REPO"
      deploy_html5
      deploy_translate
      deploy_nginx
      deploy_assets
      health
      ;;
    greenlight) deploy_greenlight ;;
    bbb)
      pull "$BBB_REPO"
      deploy_html5 force
      deploy_assets
      health
      ;;
    translate)
      pull "$BBB_REPO"
      deploy_translate force
      deploy_nginx
      ;;
    rollback) rollback_greenlight ;;
    *) sed -n '2,9p' "$0"; exit 2 ;;
  esac

  log "Done"
}

main "$@"
