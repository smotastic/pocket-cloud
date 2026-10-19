# Backlog

## Gitea follow-ups

- [x] Verify Gitea is reachable from other devices on the LAN (Colima port forwarding)
- [x] Push this repo to Gitea and set up a push mirror back to GitHub
- [ ] Mirror the other repos (`setup`, `pocket-factory`) into Gitea
- [ ] Gitea Actions runner (CI for own apps)
- [ ] Use Gitea's container registry for images of own apps

## Platform

- [ ] Reverse proxy (Caddy) with readable hostnames, e.g. `git.home.lan`
- [ ] Local DNS for those hostnames (router or a small DNS service)
- [ ] Remote access from outside the LAN (Tailscale)
- [ ] Backup script for `DATA_ROOT`, plus an off-machine copy, and a tested restore
- [x] Start the Colima VM at login (`scripts/install-autostart.sh`); containers restart via `restart: unless-stopped`
- [ ] Decide on FileVault vs. unattended recovery after power loss
- [ ] Monitoring and uptime checks

## Services

- [ ] Jellyfin: media server. Run natively (Homebrew cask) for hardware transcoding; media on external disk
- [ ] Wiki: BookStack or Docmost (decide)
- [ ] PiGallery2: image gallery

## Own apps

- [ ] Home automation: own repo, image built by Gitea Actions, deployed from `stacks/homeautomation`.
      Check device discovery (mDNS/multicast) works through the Colima VM early.
