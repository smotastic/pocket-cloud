# pocket-lens on the host

The VM half is [`stacks/pocket-lens`](../../stacks/pocket-lens/README.md): its server runs every
import (nightly at 03:00, **Import now**, phone uploads) and is the library's only writer. Two
parts of pocket-lens run natively, installed by [`scripts/install-lens.sh`](../../scripts/install-lens.sh)
from the release `lens-v$POCKET_LENS_VERSION` under `$DATA_ROOT/pocket-lens/host`:

- **`dev.pocket-cloud.lens-embedder`**: `lens-embedder serve`, socket-activated on
  `127.0.0.1:$POCKET_LENS_EMBEDDER_PORT`. launchd starts it on the server's first request (the
  vectors of new photos during an import, or a search); it exits after 15 idle minutes.
- **`pocket-lens import <path>`**: copies a card into the library's `inbox/` and asks the server
  to import it.

Lens 0.4 and earlier also ran `dev.pocket-cloud.lens-run` and `dev.pocket-cloud.lens-watch` here;
`install-lens.sh` unloads and removes them, and moves anything left in the old
`$DATA_ROOT/pocket-lens/uploads` folder into the inbox.

## Why native

The model (MobileCLIP2-B, about 1.5 GB while it runs) uses the Apple GPU through PyTorch MPS.
Docker on macOS has no access to the GPU, and holding the model in the VM would cost its memory all
day. The camera's Wireless Transmitter Utility writes into the library's `inbox/` on the host.

## Use

```sh
scripts/install-lens.sh            # install or switch to POCKET_LENS_VERSION
scripts/install-lens.sh status
scripts/install-lens.sh run        # ask the server to import the inbox now (as Import now does)
pocket-lens import "/Volumes/NIKON Z6II"   # a card: copy into the inbox and import
```

Needs `node`, `pnpm`, `uv` (Homebrew) and a desktop session. The first request downloads the model
weights (about 400 MB) into the Hugging Face cache.

Deploy the VM half first, then run `install-lens.sh`: the new server no longer writes the old
uploads folder, so nothing lands there after the script has emptied it.
