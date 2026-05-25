# CursorAPI

CursorAPI is a native macOS app that exposes a local OpenAI-compatible API for Cursor Composer models.

After a Cursor API key is saved, the app listens on loopback only at `http://127.0.0.1:8787/v1` by default and provides:

- `GET /v1/models`
- `POST /v1/chat/completions`
- `POST /v1/responses`
- `GET /health`

`GET /health` includes the local base URL and `sdkConfigured`, which is `true` when the app has bundled or locally supplied bridge routing.

The local API listener does not start until a Cursor API key is saved and the app build has bridge routing. The key is stored in the macOS Keychain; generated agent configs use a `cursor-local` placeholder instead of writing the real key to disk.

Streaming Chat Completions and Responses requests are sent as live chunked SSE. The app includes its own SDK-compatible HTTP/2 bridge layer internally and does not call the hosted Cloudflare API.

The connection pane includes a Check Composer action that performs a small request through the same key exchange and HTTP/2 bridge used by normal API requests.

Both Chat Completions `tool_calls` and Responses `function_call` outputs are supported for local coding-agent tool loops. Responses streams emit `response.function_call_arguments.delta` and `response.function_call_arguments.done` events when the SDK harness asks the client to run a local function tool.

Responses API state is kept in the app process. A request with `previous_response_id`
continues on the same SDK agent session as the earlier response. Independent
projects can run concurrently by sending one of these per-project hints:

- `X-CursorAPI-Session`
- `X-CursorAPI-Project`
- `X-Project-Path`
- `X-Workspace-Path`
- `X-Working-Directory`
- `metadata.project_path`
- `metadata.workspace_path`
- `metadata.working_directory`

Without a session or project hint, a new Responses request gets a fresh SDK agent
session and can still be continued later with `previous_response_id`.

The one-click setup panel can install local Composer 2.5 and Composer 2.5 Fast provider entries for:

- OpenCode
- Codex
- VS Code
- Cline
- Kilo Code
- pi

The app reads each config before writing it. If a CursorAPI provider already exists but points at a different local port, the setup panel shows it as ready to install again so the config can be updated.

When the app changes an existing config, it first writes a sibling `*.cursorapi-backup.*` file. Kilo's `.jsonc` config is parsed with comment support before the CursorAPI provider is merged in.

Where a client requires an API key field, the generated local config uses `cursor-local` as a placeholder. CursorAPI replaces that with the Cursor API key stored in the app, so the generated OpenCode, Codex, pi, Kilo, and Cline configs do not need to contain a real Cursor key.

Private Cursor backend origins and SDK endpoint paths are intentionally not checked into this repository. Development builds can read them from the app settings or ignored local environment files:

- `CURSOR_API_KEY`
- `CURSOR_API_BASE`
- `CURSOR_BACKEND_BASE_URL`
- `CURSOR_LOCAL_AGENT_ENDPOINT`
- `CURSOR_SDK_CLIENT_VERSION`
- `CURSOR_API_PORT`

When packaging a distributable local app, the package script embeds bridge
defaults from ignored local env files or the packager's environment into the
generated `.app` bundle. This keeps private transport values out of source
control while allowing users to launch the app by double-clicking and only enter
their Cursor API key:

```sh
CURSOR_BACKEND_BASE_URL="..." \
CURSOR_API_BASE="..." \
CURSOR_LOCAL_AGENT_ENDPOINT="..." \
CURSOR_SDK_CLIENT_VERSION="sdk-1.0.13" \
macos/CursorAPI/Scripts/package-app.sh
```

If any required bridge value is missing at package time, the app still builds
but shows a bridge-missing notice until Settings > Advanced Bridge Overrides is filled in. Set `CURSOR_API_REQUIRE_BUNDLED_TRANSPORT=1` when making release builds to fail packaging instead.

Build and run:

```sh
swift test --package-path macos/CursorAPI
macos/CursorAPI/Scripts/package-app.sh
open macos/CursorAPI/dist/CursorAPI.app
```

The package script builds a release app with an app icon, ad-hoc signs it for local launch, and writes `macos/CursorAPI/dist/CursorAPI.zip`.
