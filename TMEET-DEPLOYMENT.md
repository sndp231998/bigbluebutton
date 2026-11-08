# T-Meet Deployment Guide

How the T-Meet server (`https://tmeet.tsaedu.com`) is built, and how to update or rebuild it.

Last setup: 2 November 2026.

## Quick deploy: `/root/run.sh`

After pushing changes to GitHub, run on the server:

| Command | What it does |
| --- | --- |
| `/root/run.sh` | Pull both repos, rebuild Greenlight image and replace the container, rebuild the HTML5 client only if `bigbluebutton-html5/` changed, copy favicon and default slide, health check |
| `/root/run.sh greenlight` | Only Greenlight (pull, build, replace) |
| `/root/run.sh bbb` | Only HTML5 client (forced rebuild) and assets |
| `/root/run.sh translate` | Rebuild and restart the caption translator (`tmeet-translate`) and its nginx config |
| `/root/run.sh rollback` | Put the previous Greenlight image back |

`/root/run.sh` is a symlink to `tmeet-run.sh` in this repo, so it updates itself on pull. Setup on a new server: `ln -sfn /root/bigbluebutton/tmeet-run.sh /root/run.sh`.

## What runs where

| Part | Source | Location on server |
| --- | --- | --- |
| BigBlueButton 3.0.40 backend (all services) | Official packages via `bbb-install.sh` | system packages |
| T-Meet HTML5 client (meeting UI) | this repo, branch `production-3.0.40` | `/root/bigbluebutton` → deployed to `/usr/share/bigbluebutton/html5-client/` |
| T-Meet Greenlight (landing page, rooms, login) | `sndp231998/greenlight`, branch `production` | `/root/greenlight` → Docker image `greenlight-custom:production` |
| Greenlight runtime (compose, `.env`, database) | created by `bbb-install.sh -g` | `/root/greenlight-v3` |
| Favicon (browser tab icon) | `bigbluebutton-config/assets/favicon.ico` | `/var/www/bigbluebutton-default/assets/favicon.ico` |

Only the HTML5 client is customized in this repo (title `T-Meet`, `clientTitle`), so the rest of BigBlueButton comes from official packages.

### Branches

- `production`: the original T-Meet changes on top of BBB 3.0.35.
- `production-3.0.40`: the same T-Meet commits cherry-picked onto upstream tag `v3.0.40`. **This is what the server runs.** The HTML5 client must match the installed BBB version.

## Fresh server setup

Requirements: Ubuntu **22.04**, 4+ CPU, 8+ GB RAM, DNS `A` record for `tmeet.tsaedu.com` pointing to the server, ports TCP 80/443 and UDP 16384-32768 open.

1. Do **not** install `docker.io` from Ubuntu. `bbb-install.sh` installs `docker-ce`, and the two conflict (Docker fails to start).
2. Install BBB and Greenlight:
   ```bash
   hostnamectl set-hostname tmeet.tsaedu.com
   wget -qO /root/bbb-install.sh https://raw.githubusercontent.com/bigbluebutton/bbb-install/v3.0.x-release/bbb-install.sh
   nohup bash /root/bbb-install.sh -v jammy-300 -s tmeet.tsaedu.com -e sandipchapagain797@gmail.com -g -w > /root/bbb-install.log 2>&1 < /dev/null &
   tail -f /root/bbb-install.log
   ```
3. Check: `bbb-conf --check` and `bbb-conf --status`.
4. Clone the repos:
   ```bash
   cd /root
   git clone -b production-3.0.40 https://github.com/sndp231998/bigbluebutton.git
   git clone -b production https://github.com/sndp231998/greenlight.git
   ```
5. Deploy the HTML5 client, favicon and Greenlight (next sections).
6. Create the admin user (password needs 8+ chars with upper, lower, digit and symbol):
   ```bash
   docker exec greenlight-v3 bundle exec rake "admin:create[Name,email@example.com,Strong@Pass1]"
   ```

## Deploy the HTML5 client (meeting UI)

```bash
cd /root/bigbluebutton && git pull
cd bigbluebutton-html5 && ./deploy.sh
```

`deploy.sh` runs `npm ci`, builds (about 5 minutes), copies `dist/` to `/usr/share/bigbluebutton/html5-client/` and restarts nginx.

## Deploy the favicon

```bash
cp /root/bigbluebutton/bigbluebutton-config/assets/favicon.ico /var/www/bigbluebutton-default/assets/favicon.ico
cp /root/greenlight/public/apple-touch-icon.png /var/www/bigbluebutton-default/assets/apple-touch-icon.png
cp /root/greenlight/public/apple-touch-icon-precomposed.png /var/www/bigbluebutton-default/assets/apple-touch-icon-precomposed.png
```

nginx serves `/favicon.ico` from this folder for both Greenlight and the meeting page.

## Deploy Greenlight

```bash
cd /root/greenlight && git pull
docker build -t greenlight-custom:production .
cd /root/greenlight-v3 && docker compose up -d
docker logs --tail 20 greenlight-v3
```

`/root/greenlight-v3/docker-compose.yml` must use `image: greenlight-custom:production` (the official file is kept as `docker-compose.yml.official`). Google login keys go in `/root/greenlight-v3/.env` (`GOOGLE_CLIENT_ID`, `GOOGLE_CLIENT_SECRET`).

## Client settings override

`/etc/bigbluebutton/bbb-html5.yml` holds server-specific client settings (survives upgrades). Current content:

```yaml
public:
  app:
    clientTitle: T-Meet
    copyright: ©2026 T-Meet
    helpLink: https://tmeet.tsaedu.com/
    displayBbbServerVersion: false
    bbbTabletApp:
      enabled: false
    audioCaptions:          # translated live captions, see below
      enabled: true
      provider: webspeech
      language:
        available:
          - ne-NP
          - hi-IN
          - en-US
        defaultSelectLocale: true
        locale: ne-NP     # speakers transcribe in Nepali unless they pick another language
  kurento:
    wsUrl: wss://tmeet.tsaedu.com/bbb-webrtc-sfu
    screenshare:
      bitrate: 800          # default 1500; lowered so presenters' audio does not break during screen share
      constraints:
        video:
          frameRate:
            ideal: 5
            max: 10
          width:
            max: 1920       # default 2560
          height:
            max: 1080       # default 1600
        audio: true
  pads:
    url: https://tmeet.tsaedu.com/pad
```

The meeting welcome message is set in `/etc/bigbluebutton/bbb-web.properties` (`defaultWelcomeMessage`, `defaultWelcomeMessageFooter`, no BigBlueButton links). The default slide is `bigbluebutton-config/assets/default.pdf` (page 1: T-Meet welcome slide, pages 2 to 4: blank white pages for the whiteboard, 960x540), copied by `run.sh` to `/var/www/bigbluebutton-default/assets/default.pdf`.

After editing either file, run `systemctl restart bbb-apps-akka bbb-web` (this ends running meetings, so check `getMeetings` first). The previous version is saved as `bbb-html5.yml.bak-2026-11-02`.

## Translated live captions (English, Hindi, Nepali)

Free and self-hosted, no paid API:

- **Speech to text:** the speaker's own browser (Web Speech API, works best in Chrome). Enabled in `/etc/bigbluebutton/bbb-html5.yml` under `public.app.audioCaptions` with languages `ne-NP`, `hi-IN`, `en-US`.
- **Translation:** the `tmeet-translate` container (folder `tmeet-translate/` in this repo) runs the IndicTrans2 distilled models from AI4Bharat (MIT license) on CPU with int8 weights. It listens on `127.0.0.1:8095`. nginx exposes it as `/tmeet-translate/` only to users with a valid meeting session (`bigbluebutton-config/tmeet/tmeet-translate.nginx`, installed into `/etc/bigbluebutton/nginx/`).
- **Client:** the speaker picks the language they speak in the audio modal. Each viewer picks the caption language in the CC button menu. Captions in other languages are translated on the fly (debounced while the sentence grows, cached).

Measured on this server: about 0.6 to 1 second per sentence once warm. The container uses about 1.5 GB RAM and 1.9 GB of model files in `/root/tmeet-translate-models`.

The models are gated on Hugging Face (free). A read token from account `Sandip8085` is stored in `/root/.hf-token` (mode 600, never commit it). On a new server:

```bash
read -s -p "HF token: " T && echo "$T" > /root/.hf-token && chmod 600 /root/.hf-token && unset T
/root/run.sh translate
docker logs -f tmeet-translate   # wait for "loaded ... indic-indic"
```

The account must have accepted the terms of `ai4bharat/indictrans2-en-indic-dist-200M`, `indictrans2-indic-en-dist-200M` and `indictrans2-indic-indic-dist-320M`.

## Swap

A 12 GB swap file (`/swapfile`, in `/etc/fstab`) with `vm.swappiness=10` (`/etc/sysctl.d/99-tmeet-swap.conf`) covers the 4 GB webpack build of the HTML5 client while BBB and the translator are running.

## Network tuning (fast meeting start)

Added 8 November 2026. Without these, "Start" took 10+ seconds and the blue loading screen 2 to 4 minutes for users in Nepal.

- **BBR TCP congestion control.** The route from Nepal has about 160 ms latency and some packet loss, and the default `cubic` slowed the 2.1 MB client bundle to about 10 KB/s. BBR made it 10 to 20 times faster. Files: `/etc/sysctl.d/98-tmeet-bbr.conf` (`default_qdisc=fq`, `tcp_congestion_control=bbr`, `tcp_slow_start_after_idle=0`) and `/etc/modules-load.d/tmeet-bbr.conf`. Revert: delete both files and run `sysctl -w net.ipv4.tcp_congestion_control=cubic`.
- **Own domain pinned, no DNS lookup.** The Contabo DNS servers sometimes drop queries, and Greenlight calls the BBB API through `https://tmeet.tsaedu.com`, so a dropped lookup added about 10 s to "Start". `207.180.223.240 tmeet.tsaedu.com` is in `/etc/hosts` and `/etc/cloud/templates/hosts.debian.tmpl` (cloud-init rewrites `/etc/hosts`), and `/root/greenlight-v3/docker-compose.yml` has `extra_hosts: ["tmeet.tsaedu.com:207.180.223.240"]` under `greenlight-v3`. Change these if the server IP changes.

## After `apt upgrade`

A `bbb-html5` or `bbb-config` package update overwrites the custom UI and favicon. After any upgrade:

1. Check the version: `cat /etc/bigbluebutton/bigbluebutton-release`.
2. If the BBB version changed (for example 3.0.41), move the T-Meet commits to the new tag first (next section).
3. Run "Deploy the HTML5 client" and "Deploy the favicon" again.

## Moving T-Meet to a new BBB version

Run on a machine with push access, replacing `3.0.41` with the new version:

```bash
git fetch https://github.com/bigbluebutton/bigbluebutton.git tag v3.0.41 --no-tags
git checkout -b production-3.0.41 v3.0.41
git cherry-pick v3.0.40..production-3.0.40
git push origin production-3.0.41
```

Then on the server: `git fetch origin && git checkout production-3.0.41` and deploy.

## Backups on the server

| What | Where |
| --- | --- |
| Official HTML5 client (3.0.40) | `/root/html5-client.official-3.0.40.bak` |
| Official Greenlight compose file | `/root/greenlight-v3/docker-compose.yml.official` |
| Original BBB favicon | `/var/www/bigbluebutton-default/assets/favicon.ico.bbb-original` |
| Install log | `/root/bbb-install.log` |

## API for other platforms

External platforms integrate through the standard BigBlueButton API at `https://tmeet.tsaedu.com/bigbluebutton/api/`. Integration guide: https://claude.ai/artifact/BMRcJ5UkaShvk7g9FKYG7Y

The shared secret is shown by `bbb-conf --secret` on the server. **Never commit it** and share it only through a private channel. Greenlight uses the same secret; if it is rotated (`bbb-conf --setsecret`), update `BIGBLUEBUTTON_SECRET` in `/root/greenlight-v3/.env` and run `docker compose up -d`.
