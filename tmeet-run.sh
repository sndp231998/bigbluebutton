#!/usr/bin/env bash
# T-Meet deploy script. Pulls both repos and redeploys what changed.
#
#   /root/run.sh               # everything: greenlight + bbb (html5 only if it changed) + assets
#   /root/run.sh greenlight    # only Greenlight image + container
#   /root/run.sh bbb           # only HTML5 client (forced rebuild) + assets
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
  }

  case "${1:-all}" in
    all)
      deploy_greenlight
      pull "$BBB_REPO"
      deploy_html5
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
    rollback) rollback_greenlight ;;
    *) sed -n '2,8p' "$0"; exit 2 ;;
  esac

  log "Done"
}

main "$@"
