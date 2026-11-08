# pocket-comms

[pocket-comms](https://github.com/smotastic/pocket-comms) is the phone web app that reads and drives
the Herdr coding agents. Unlike every other service here it is **not a container**: it runs
natively on the Mac under the launchd agent `dev.pocket-cloud.comms`, installed by
[`scripts/install-comms.sh`](../../scripts/install-comms.sh), and the Mac's own Tailscale node
serves it over HTTPS.

## Why native

pocket-comms needs things that exist only on the host, in the user's login session:

- **Herdr's Unix socket**, `~/.config/herdr/herdr.sock`. A socket doesn't work across the Colima
  virtiofs mount: the VM sees the file but can't connect to the host process.
- **The Claude and Pi session files** under the home folder, read live, at the paths the host's
  agents write them.

### Why not a sidecar in `stacks/tailscale`

The obvious alternative, a `tailscale-comms` sidecar like the other services', was rejected:

1. pocket-comms listens on `127.0.0.1` only (hard-coded). From inside the Colima VM, `127.0.0.1`
   is the VM, so a sidecar can't reach the server.
2. Making the server listen wider so the VM can reach it would be unsafe. Its only authentication is
   the `Tailscale-User-Login` header, which can be trusted only when `tailscale serve` sets it.
   Anyone on the LAN (and, with the default tailnet policy, the tailnet) could then call the server
   directly with a forged header and type into every coding agent.

Loopback only, with `tailscale serve` on the same machine, is the one setup where the header can't be
forged.

## Setup

In `.env`:

| Variable | Meaning |
|---|---|
| `POCKET_COMMS_VERSION` | Tag (`comms-vX.Y.Z`) or full commit SHA to run. Branch names and short SHAs are refused. |
| `POCKET_COMMS_REPO` | Clone URL, e.g. Gitea over SSH or the GitHub mirror |
| `COMMS_PORT` | The server's port on `127.0.0.1`, default `4410` |
| `COMMS_ALLOWED_LOGIN` | The Tailscale login that may use the app: `<user>@<provider>`, or `<user>@` for any provider |
| `COMMS_GITEA_TOKEN` | Optional. Gitea token with `write:issue` and `read:repository`: the issue lists, closing issues and the issues created from the brainstorm chat; the plist is mode `600` |
| `COMMS_GITEA_URL` | Optional. The Gitea to read, default `http://localhost:3000` |
| `COMMS_GITEA_HOSTS` | Optional. Further host names of that Gitea in git remotes (SSH aliases), comma-separated, default `gitea` |
| `COMMS_BRAINSTORM_PROVIDER`, `COMMS_BRAINSTORM_MODEL` | Optional. The brainstorm chat's model, such as `openai` and `gpt-6-luna`; without both the chat says it is not set up |
| `COMMS_BRAINSTORM_API_KEY` | Optional. An API key for that provider; without it the server uses the Mac user's Pi login (`pi`, then `/login`) |
| `COMMS_BRAINSTORM_THINKING` | Optional. `off` (default) to `max` |
| `COMMS_STATE_DIR` | Optional. Where the brainstorm chat is kept, default `~/.pocket-comms` |
| `COMMS_BRAINSTORM_PI_AUTH_FILE` | Optional. Pi's credential file, default `~/.pi/agent/auth.json` |
| `COMMS_SPEECH_URL`, `COMMS_SPEECH_MODEL` | Optional. The speech-to-text service for voice messages in the brainstorm chat, such as `http://localhost:4430/v1` and `Systran/faster-whisper-small` ([stacks/whisper](../../stacks/whisper/README.md)); without both there is no Record voice |

Requires Node.js 26+ and pnpm 11+ (Homebrew). Then:

```sh
scripts/install-comms.sh            # clone, build, start at login; probes 127.0.0.1 for 403
scripts/install-comms.sh status     # agent, version, probe, tailscale serve, log tail
```

The values are written into the agent's plist, so after changing `.env` run `install` again.

### Expose it on the tailnet (once, by hand)

The script never changes Tailscale's configuration. Once:

```sh
sudo tailscale serve --bg 4410      # https://<mac>.<tailnet>.ts.net/ -> http://127.0.0.1:4410
tailscale serve status
```

`--bg` keeps the config in tailscaled's state across reboots; while the server is down it answers
502. The Mac's tailscaled runs as root, so `serve` needs `sudo` (or once
`sudo tailscale set --operator=$USER`). **Never use Funnel** for this: it would put the agents on the
internet.

Under the [hardened tailnet policy](../../stacks/tailscale/README.md#hardening), the Mac takes only
SSH; pocket-comms needs `tcp:443` there too, for the owner only. On the iPhone, open the address in
Safari, then **Share > Add to Home Screen**.

## Layout

```text
${DATA_ROOT}/pocket-comms/
  repo/              the clone; fetched, never built in
  releases/<sha>/    one git worktree per installed version, with node_modules and the builds
  current -> releases/<sha>    what the agent runs
```

The agent runs `node apps/comms-server/dist/main.js` of `current` with `COMMS_WEB_DIST` pointing at
the built web app; `pnpm start` would rebuild on every restart. The three newest releases are kept.
The folder holds no state (the app keeps "seen" in memory), so it is excluded from the backups.
The brainstorm chat is the one stored state, in `COMMS_STATE_DIR` (`~/.pocket-comms/brainstorm.json`);
losing it loses only the conversation, not the issues created from it.
Logs go to `~/Library/Logs/pocket-cloud/comms.log`.

## Update and rollback

```sh
# set POCKET_COMMS_VERSION in .env to the new tag (or back to the previous one), then
scripts/install-comms.sh update     # fetch tags, build into releases/<sha>, switch, restart, probe
```

Only tag versions whose CI is green in pocket-comms. A failed build leaves the running version
alone. If the new version doesn't answer `403` on loopback after the switch, the script switches
back to the previous release and exits with an error. Rolling back to a release still on disk
needs no build.

## Debugging

```sh
scripts/install-comms.sh status
scripts/install-comms.sh restart
tail -f ~/Library/Logs/pocket-cloud/comms.log
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:4410/   # 403 = up, guard on
```

The server starts without Herdr and shows the agents once Herdr's socket is there. If the server
exits, launchd starts it again after at most 30 seconds. `scripts/install-comms.sh uninstall` removes the agent but keeps the releases and the serve
config; `sudo tailscale serve reset` stops serving.
