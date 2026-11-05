# pocket-lens

[pocket-lens](https://github.com/smotastic/pocket-lens) is the photo library: originals from the
camera, filed by capture day, tagged by a local image model and shown in a gallery on the tailnet
at `https://lens.<tailnet>.ts.net`.

It has two halves:

| Here, in the VM | On the host ([`native/pocket-lens`](../../native/pocket-lens/README.md)) |
| --- | --- |
| `pocket-lens-postgres`, `-migrate`, `-server`, `-web`, and `tailscale-lens` | the model worker `lens-embedder serve` (a socket-activated launchd agent) and the `pocket-lens import` command for the card reader |

- **Library:** `${DATA_ROOT}/pocket-lens/library`, mounted read-write into the server, which is
  its only writer: each import (nightly at 03:00, Import now, phone uploads, `pocket-lens import`)
  files the inbox with exiftool and vips in the image and asks the worker on the host for the
  vectors. Phone uploads arrive in `inbox/.uploads/` and move into `inbox/` once verified. Its
  `cache/` is not backed up.
- **Ports:** the web app publishes none; only `tailscale-lens` reaches it, so the
  `Tailscale-User-Login` header the server trusts can't be forged from the LAN. The server publishes
  `127.0.0.1:${POCKET_LENS_API_PORT}` for `pocket-lens import` on the host, which authenticates with
  `POCKET_LENS_INGEST_TOKEN`.
- **Model:** the server calls the worker on the host's loopback through `host.lima.internal`.
  While the worker is down, search answers 503 and an import fails with "the image model on the
  Mac is not reachable", leaving the inbox as it is; the rest of the gallery works.
- **Memory:** server and Postgres stay around 130 MB; an import adds up to a few hundred MB while it
  makes previews, one photo at a time. The model runs on the host only during an import or a
  search.

## Deploy

1. Images `photos-server` and `photos-web` tagged `X.Y.Z` in the registry (pocket-lens's
   `release-lens.yml` on the tag `lens-vX.Y.Z`).
2. In `.env`: `POCKET_LENS_VERSION=X.Y.Z`, `POCKET_LENS_REPO`, `POCKET_LENS_DB_PASSWORD`,
   `POCKET_LENS_INGEST_TOKEN` and `POCKET_LENS_ALLOWED_LOGIN`.
3. `docker compose up -d pocket-lens-server pocket-lens-web tailscale-lens`
4. `scripts/install-lens.sh` for the host half.
