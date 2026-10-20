# tailscale

Remote access over [Tailscale](https://tailscale.com), split in two:

- **The Mac** runs Tailscale (Homebrew) for SSH. It serves nothing itself.
- **Each exposed service** gets its own Tailscale node: a sidecar container in this stack
  that joins the tailnet under its own name and serves that one service over HTTPS,
  e.g. `https://galaxy.<tailnet>.ts.net`. The certificate comes from Tailscale.

Only the services listed in [`compose.yaml`](compose.yaml) get a tailnet name and HTTPS.
With Tailscale's default policy, though, tailnet devices also reach everything the Mac
publishes on its LAN ports, over the Mac's tailnet address (see [Hardening](#hardening)).
No Funnel: nothing is reachable from the internet.

| Node | Service | Serve config | Data |
|---|---|---|---|
| `galaxy` | `pocket-galaxy-web:8080` | [`serve/galaxy.json`](serve/galaxy.json) | `${DATA_ROOT}/tailscale/galaxy` |
| `docmost` | `docmost:3000` | [`serve/docmost.json`](serve/docmost.json) | `${DATA_ROOT}/tailscale/docmost` |

## How a sidecar works

- `TS_AUTHKEY` (from `.env`) logs the node in once; its identity then lives in
  `TS_STATE_DIR`, a bind mount under `${DATA_ROOT}/tailscale/<node>/`. `TS_AUTH_ONCE` keeps
  later restarts from logging in again, so the key can expire without breaking anything.
- `TS_SERVE_CONFIG` is the committed `serve/<node>.json`: HTTPS on 443, proxied to the
  service's container by its compose name. `${TS_CERT_DOMAIN}` is filled in by the
  container with the node's own name, so no tailnet name is committed.
- **Userspace networking** (`TS_USERSPACE=true`). The pocket-cloud VM has `/dev/net/tun`,
  so kernel mode would work too, but it needs `NET_ADMIN` and the device mapped into the
  container. Serve doesn't need it: tailscaled terminates TLS and opens the connection to
  the service itself, over the compose network. Userspace keeps the containers
  unprivileged.
- The sidecars live in this stack, not next to each service: what gets a tailnet name
  is one file to review, the shared settings are written once (`x-tailscale`), and the
  service stacks run without Tailscale. All stacks are included into one compose project,
  so a sidecar reaches any service by name.

## Admin console setup (once)

In the [admin console](https://login.tailscale.com/admin):

1. **DNS**: enable **MagicDNS** and, below it, **HTTPS Certificates**.
2. **Access controls**: keep Tailscale's default policy (every device reaches every other
   one, plus its default `ssh` rule) and, in the JSON editor, add only the tag owner:

   ```jsonc
   "tagOwners": {
     "tag:pocket-cloud": ["autogroup:admin"]
   },
   ```

   This is required: an auth key can only carry a tag that has an owner, and tagged nodes
   have key expiry disabled, so the sidecars stay logged in.
3. **Settings > Keys**: generate an auth key: **reusable**, **tags: `tag:pocket-cloud`**,
   not ephemeral (an ephemeral node disappears when its container stops). Put it into
   `.env` as `TS_AUTHKEY`.

With the default policy, every tailnet device reaches the sidecars and also the Mac's
tailnet address, and with it every port the Mac publishes on the LAN: Prometheus (no
auth, also the OTLP receiver), Grafana, Gitea, Docmost, Mosquitto, Pocket Galaxy over plain
HTTP. That is no worse than the LAN as long as only your own devices are in the tailnet.
The default `ssh` rule lets you SSH into your own devices (the Mac included) in `check`
mode, which asks for a browser login every 12 hours.

### Hardening

Once other people join the tailnet, or to keep the LAN ports off it, replace the default
`grants` (or `acls`) and `ssh` sections with:

```jsonc
{
  "tagOwners": {
    "tag:pocket-cloud": ["autogroup:admin"]
  },
  "grants": [
    // Every member reaches the pocket-cloud services, HTTPS only.
    { "src": ["autogroup:member"], "dst": ["tag:pocket-cloud"], "ip": ["tcp:443"] },
    // SSH to the owner's own devices, which includes the Mac.
    { "src": ["autogroup:owner"], "dst": ["autogroup:self"], "ip": ["tcp:22"] }
  ],
  "ssh": [
    {
      // "check" instead asks for a browser login every 12 hours.
      "action": "accept",
      "src": ["autogroup:owner"],
      "dst": ["autogroup:self"],
      "users": ["autogroup:nonroot"]
    }
  ]
}
```

`autogroup:self` is the owner's own devices, which includes the Mac as long as it is
logged in with the owner's account (not tagged). The tailnet then reaches only the
services listed here, the Mac's LAN ports only from the LAN. Tagged nodes have no SSH
rule, so nobody can SSH into a sidecar, and the sidecars reach nothing in the tailnet.

## The Mac (SSH)

Set up by hand, outside this repo. Prerequisite, once: the `tailscale` Homebrew formula
(the open-source tailscaled, which runs without a desktop session and supports Tailscale
SSH; the App Store app does not).

```sh
sudo brew services start tailscale # starts at boot, before any login
sudo tailscale up --ssh            # log in with your account; enables Tailscale SSH
```

Then, in the admin console, **Disable key expiry** for the Mac (machine menu), otherwise
it drops off the tailnet after 180 days and SSH stops working. Don't run `tailscale serve`
on the Mac: services go through the sidecars.

## First start

```sh
source .env && mkdir -p "$DATA_ROOT"/tailscale/galaxy
docker compose up -d tailscale-galaxy
docker compose logs -f tailscale-galaxy   # wait for the login, then Ctrl-C
```

The node appears in the admin console as `galaxy` with the tag `tag:pocket-cloud`. The
first HTTPS request fetches the certificate and can take a few seconds.

## Adding a service

Example: Grafana as `grafana`.

1. Copy [`serve/galaxy.json`](serve/galaxy.json) to `serve/grafana.json` and set `Proxy` to
   the container and its **internal** port: `http://grafana:3000`.
2. Add a service block to [`compose.yaml`](compose.yaml):

   ```yaml
     tailscale-grafana:
       <<: *tailscale
       container_name: tailscale-grafana
       environment:
         <<: *tailscale-env
         TS_HOSTNAME: grafana
       volumes:
         - ${DATA_ROOT}/tailscale/grafana:/var/lib/tailscale
         - ./serve/grafana.json:/config/serve.json:ro
       depends_on:
         - grafana
   ```

3. Add the row to the table above, `mkdir -p "$DATA_ROOT"/tailscale/grafana`, then
   `docker compose up -d tailscale-grafana`.
4. Check the app itself: apps that build absolute links need the new address, e.g.
   Grafana's `GF_SERVER_ROOT_URL` or Docmost's `DOCMOST_APP_URL`. Add a section on the
   access to the service's README.

The same auth key logs in every node. If it has expired, create a new one first.

## Backup and restore

`scripts/backup.sh` snapshots all of `DATA_ROOT`, so `${DATA_ROOT}/tailscale/` is in
every backup and a restored node comes back with its identity and name. The state changes
rarely, so the sidecars keep running during the snapshot. If a node was deleted in the
admin console in the meantime, delete its state folder and start the sidecar again; it
logs in with `TS_AUTHKEY` as a new node.

## Debugging

```sh
docker compose exec tailscale-galaxy tailscale status
docker compose exec tailscale-galaxy tailscale serve status
docker compose logs tailscale-galaxy
```

A node named `galaxy-1` means an old `galaxy` still exists in the admin console; delete
the old one and rename the new one there.
