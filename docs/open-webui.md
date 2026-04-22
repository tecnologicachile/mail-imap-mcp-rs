# Open WebUI

Open WebUI expects an HTTP/OpenAPI tool server. `mail-mcp` speaks MCP over
stdio, so the supported way to use it from Open WebUI is to wrap it with the
[`mcpo`](https://github.com/open-webui/mcpo) MCP-to-OpenAPI adapter.

## 1. Build `mail-mcp`

```bash
cargo build --release
```

## 2. Install an adapter launcher

Use whichever option you prefer:

```bash
pip install mcpo
```

or

```bash
uv tool install mcpo
```

## 3. Start the adapter

Set your normal `MAIL_*` account variables, then launch the wrapper:

```bash
MAIL_IMAP_DEFAULT_HOST=imap.gmail.com \
MAIL_IMAP_DEFAULT_USER=you@gmail.com \
MAIL_IMAP_DEFAULT_PASS=your-app-password \
MAIL_SMTP_DEFAULT_HOST=smtp.gmail.com \
MAIL_SMTP_DEFAULT_USER=you@gmail.com \
MAIL_SMTP_DEFAULT_PASS=your-app-password \
MAIL_SMTP_DEFAULT_SECURE=starttls \
MAIL_IMAP_WRITE_ENABLED=true \
MAIL_SMTP_WRITE_ENABLED=true \
MCPO_PORT=8000 \
MCPO_API_KEY=change-me \
./scripts/run-open-webui-adapter.sh
```

The wrapper looks for:

1. `MAIL_MCP_BIN` if you set it
2. `target/release/mail-mcp`
3. `target/debug/mail-mcp`
4. `mail-mcp` on `PATH`

Useful wrapper variables:

| Variable | Default | Description |
|----------|---------|-------------|
| `MAIL_MCP_BIN` | auto-detect | `mail-mcp` binary to expose |
| `MCPO_COMMAND` | auto-detect | Override how `mcpo` is launched |
| `MCPO_HOST` | `0.0.0.0` | HTTP bind address |
| `MCPO_PORT` | `8000` | HTTP bind port |
| `MCPO_API_KEY` | unset | Optional API key |
| `MCPO_ROOT_PATH` | unset | Optional URL prefix |
| `MCPO_LOG_LEVEL` | `INFO` | Adapter log level |

Once started, the generated OpenAPI endpoints are available at:

- `http://localhost:8000/openapi.json`
- `http://localhost:8000/docs`

## 4. Add the server in Open WebUI

In Open WebUI, add a new OpenAPI tool server that points at the adapter URL:

- Base URL: `http://<host>:8000`
- API key: the same value as `MCPO_API_KEY` if you set one

Open WebUI will read the generated schema and expose the `mail-mcp` tools.

## Smoke test

This repository includes a smoke test for the adapter:

```bash
./scripts/test-open-webui-adapter.sh
```

It starts GreenMail, launches `mail-mcp` behind `mcpo`, verifies the generated
OpenAPI schema, and exercises real tool calls through the adapter.
