# whisper

Speech-to-text for [pocket-comms](../../native/pocket-comms/README.md): the voice messages of the
brainstorm chat. [speaches](https://github.com/speaches-ai/speaches) runs
[faster-whisper](https://github.com/SYSTRAN/faster-whisper) on the VM's CPU behind an
OpenAI-compatible API.

| | |
|---|---|
| API | `http://localhost:4430/v1` (`WHISPER_PORT`), loopback only |
| Transcribe | `POST /v1/audio/transcriptions`, multipart `file` and `model` |
| Model | `Systran/faster-whisper-small` (`WHISPER_MODEL`), multilingual, int8 on CPU |
| Data | `${DATA_ROOT}/whisper/models` (the Hugging Face cache, ~470 MB for `small`) |

- **Ports:** published on `127.0.0.1` only. pocket-comms runs on the host and reaches it the way it
  reaches Gitea; the service has no authentication, so it must never be on the LAN or the tailnet.
- **Model:** downloaded on start if missing (`PRELOAD_MODELS`); the server exits if the download
  fails. The language is detected per clip unless a request sets `language`.
- **Memory:** about 230 MB idle after a start, about 950 MB while the model is loaded, limited to
  2 GiB. `WHISPER_MODEL_TTL` seconds (default 300) after the last clip the model is unloaded; the
  process then stays at about 600 MB, because Python keeps most of the freed memory.
- **Speed:** a 17-second clip takes about 4 to 7 seconds on the VM's 4 CPUs, longer while the Mac
  is busy, and a second more when the model has to load first.

## Deploy

```sh
source .env && mkdir -p "$DATA_ROOT"/whisper/models
docker compose up -d whisper
curl -s localhost:4430/v1/audio/transcriptions -F file=@clip.m4a -F model=Systran/faster-whisper-small
```

A larger model (`Systran/faster-whisper-medium`, or a converted `large-v3-turbo`) transcribes
German better at about twice the memory and time: set `WHISPER_MODEL` and run `up -d` again.
