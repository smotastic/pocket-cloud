# Backlog

## Gitea follow-ups

- [x] Verify Gitea is reachable from other devices on the LAN (Colima port forwarding)
- [x] Push this repo to Gitea and set up a push mirror back to GitHub
- [x] Move `pocket-factory` into Gitea (push mirror to GitHub, GitHub Actions off, `master` protected in Gitea). `setup` stays on GitHub.
- [x] Move `pocket-galaxy` into Gitea (all branches copied, push mirror to GitHub, GitHub Actions off)
- [ ] Protect `master` of `pocket-galaxy` in Gitea
- [x] Gitea Actions runner (`stacks/gitea-runner`)
- [ ] pocket-factory CI green on Gitea (branch `docs/gitea-workflow`, in progress)
- [ ] Use Gitea's container registry for images of own apps

## Platform

- [ ] Reverse proxy (Caddy) with readable hostnames, e.g. `git.home.lan`
- [ ] Local DNS for those hostnames (router or a small DNS service)
- [ ] Remote access from outside the LAN (Tailscale)
- [ ] Backups: script + daily launchd job done (`scripts/backup.sh`, restic); pending: external disk, `init`, `install-backup.sh`, password in password manager
- [x] Start the Colima VM at login (`scripts/install-autostart.sh`); containers restart via `restart: unless-stopped`
- [ ] Decide on FileVault vs. unattended recovery after power loss
- [ ] Monitoring and uptime checks

## Services

- [ ] Jellyfin: media server. Run natively (Homebrew cask) for hardware transcoding; media on external disk
- [ ] Wiki: BookStack or Docmost (decide)
- [ ] PiGallery2: image gallery

## Own apps

- [ ] Deploy the pocket-factory bookmarks blueprint from `stacks/bookmarks`, as proof that own
      apps can be deployed from this repo (Gitea issue #2)
- [ ] Home automation: own repo, image built by Gitea Actions, deployed from `stacks/homeautomation`.
      Check device discovery (mDNS/multicast) works through the Colima VM early.
