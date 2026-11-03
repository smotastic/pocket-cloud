# pocket-lens

[pocket-lens](https://github.com/smotastic/pocket-lens) is the photo library: originals from the
camera, filed by capture day, tagged by a local image model and shown in a gallery on the tailnet
at `https://lens.<tailnet>.ts.net`.

It has two halves:

| Here, in the VM | On the host ([`native/pocket-lens`](../../native/pocket-lens/README.md)) |
| --- | --- |
| `pocket-lens-postgres`, `-migrate`, `-server`, `-web`, and `tailscale-lens` | the nightly `pocket-lens run` and the search worker `lens-embedder serve`, both launchd agents |

- **Library:** `${DATA_ROOT}/pocket-lens/library`, mounted read-only into the server. The host CLI
  is its only writer. Its `cache/` is not backed up.
- **Ports:** the web app publishes none; only `tailscale-lens` reaches it, so the
  `Tailscale-User-Login` header the server trusts can't be forged from the LAN. The server publishes
  `127.0.0.1:${POCKET_LENS_API_PORT}` for the host CLI, which authenticates with
  `POCKET_LENS_INGEST_TOKEN`.
- **Search:** the server calls the worker on the host's loopback through `host.lima.internal`.
  While the worker is down, search answers 503; the rest of the gallery works.
- **Memory:** server and Postgres stay around 120 MB; the model runs on the host only during a run
  or a search.

## Deploy

1. Images `photos-server` and `photos-web` tagged `X.Y.Z` in the registry (pocket-lens's
   `release-lens.yml` on the tag `lens-vX.Y.Z`).
2. In `.env`: `POCKET_LENS_VERSION=X.Y.Z`, `POCKET_LENS_REPO`, `POCKET_LENS_DB_PASSWORD`,
   `POCKET_LENS_INGEST_TOKEN` and `POCKET_LENS_ALLOWED_LOGIN`.
3. `docker compose up -d pocket-lens-server pocket-lens-web tailscale-lens`
4. `scripts/install-lens.sh` for the host half.
