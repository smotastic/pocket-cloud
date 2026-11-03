# pocket-lens on the host

The VM half is [`stacks/pocket-lens`](../../stacks/pocket-lens/README.md). Two parts of
pocket-lens run natively, installed by [`scripts/install-lens.sh`](../../scripts/install-lens.sh)
from the release `lens-v$POCKET_LENS_VERSION` under `$DATA_ROOT/pocket-lens/host`:

- **`dev.pocket-cloud.lens-run`**: `pocket-lens run` every night at 03:00. It files the inbox,
  writes previews with `exiftool` and `sips`, embeds them with the model worker, registers the
  photos through the server's ingest API and purges the trash. Log:
  `~/Library/Logs/pocket-cloud/lens-run.log`.
- **`dev.pocket-cloud.lens-embedder`**: `lens-embedder serve`, socket-activated on
  `127.0.0.1:$POCKET_LENS_EMBEDDER_PORT`. launchd starts it on the gallery's first search; it exits
  after 15 idle minutes.

## Why native

The model (MobileCLIP2-B, about 1.5 GB while it runs) uses the Apple GPU through PyTorch MPS.
Docker on macOS has no access to the GPU, and holding the model in the VM would cost its memory all
day. The files are host files too: the camera's Wireless Transmitter Utility writes into the
library's `inbox/`.

## Use

```sh
scripts/install-lens.sh            # install or switch to POCKET_LENS_VERSION
scripts/install-lens.sh status
scripts/install-lens.sh run        # the nightly run, now
pocket-lens import "/Volumes/NIKON Z6II"   # a card: copy into the inbox and run
```

Needs `node`, `pnpm`, `uv`, `exiftool` (Homebrew) and a desktop session. The first run downloads
the model weights (about 400 MB) into the Hugging Face cache.
