#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_PATH="$ROOT_DIR/dist/API for Cursor.app"
TIMEOUT_SECONDS=45
RUN_OPENCODE=1
KEEP_RUNNING=0
TEMP_DIRS=()
TEMP_FILES=()

usage() {
  cat <<USAGE
Usage: CURSOR_API_TEST_KEY=crsr_... $0 [--app PATH] [--timeout SECONDS] [--skip-opencode] [--keep-running]

Launch the packaged macOS app and verify the live Composer routing path using
an environment-provided Cursor API key. This checks direct chat completions,
streaming chat completions, Responses API output, SDK bridge process reuse, and
an OpenCode interactive round trip when opencode and tmux are installed.

  --app PATH        App bundle to launch. Defaults to dist/API for Cursor.app.
  --timeout N       Seconds to wait for app and live requests. Default: 45.
  --skip-opencode   Skip the interactive OpenCode check.
  --keep-running    Leave the launched app running after the smoke check.
USAGE
}

fail() {
  echo "Live routing smoke check failed: $*" >&2
  exit 1
}

absolute_path() {
  local path="$1"
  local dir
  local base
  dir="$(cd "$(dirname "$path")" && pwd)"
  base="$(basename "$path")"
  printf '%s/%s\n' "$dir" "$base"
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --app)
      APP_PATH="${2:-}"
      [ -n "$APP_PATH" ] || { echo "--app requires a path" >&2; exit 64; }
      shift
      ;;
    --timeout)
      TIMEOUT_SECONDS="${2:-}"
      [ -n "$TIMEOUT_SECONDS" ] || { echo "--timeout requires seconds" >&2; exit 64; }
      shift
      ;;
    --skip-opencode)
      RUN_OPENCODE=0
      ;;
    --keep-running)
      KEEP_RUNNING=1
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 64
      ;;
  esac
  shift
done

[ -n "${CURSOR_API_TEST_KEY:-}" ] || fail "set CURSOR_API_TEST_KEY to a Cursor API key before running this live smoke check"
[ -d "$APP_PATH" ] || fail "app bundle is missing at $APP_PATH"
APP_PATH="$(absolute_path "$APP_PATH")"

NODE_BINARY="$APP_PATH/Contents/Resources/node"
if [ ! -x "$NODE_BINARY" ]; then
  NODE_BINARY="$(command -v node || true)"
fi
[ -x "$NODE_BINARY" ] || fail "Node is required for JSON assertions; package the app or install Node"

cleanup() {
  for file in "${TEMP_FILES[@]+"${TEMP_FILES[@]}"}"; do
    rm -f "$file"
  done
  for dir in "${TEMP_DIRS[@]+"${TEMP_DIRS[@]}"}"; do
    rm -rf "$dir"
  done
  if [ "$KEEP_RUNNING" -eq 0 ]; then
    osascript -e 'tell application id "ai.standardagents.cursorapi" to quit' >/dev/null 2>&1 || true
    pkill -f 'cursor-sdk-opencode-bridge.mjs' >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

smoke_output="$(mktemp "${TMPDIR:-/tmp}/api-for-cursor-live-app.XXXXXX")"
TEMP_FILES+=("$smoke_output")
"$ROOT_DIR/Scripts/smoke-app.sh" --app "$APP_PATH" --require-server --keep-running --timeout "$TIMEOUT_SECONDS" >"$smoke_output"
cat "$smoke_output"

port="$(sed -nE 's/.*http:\/\/127\.0\.0\.1:([0-9]+)\/health.*/\1/p' "$smoke_output" | head -1)"
[ -n "$port" ] || fail "could not determine local API port from app smoke output"
base_url="http://127.0.0.1:$port/v1"

post_json() {
  local path="$1"
  local body="$2"
  curl -fsS --max-time "$TIMEOUT_SECONDS" "$base_url$path" \
    -H "Authorization: Bearer $CURSOR_API_TEST_KEY" \
    -H "Content-Type: application/json" \
    -d "$body"
}

extract_chat_content() {
  "$NODE_BINARY" -e '
let body = "";
process.stdin.on("data", (chunk) => body += chunk);
process.stdin.on("end", () => {
  const json = JSON.parse(body);
  process.stdout.write(json.choices?.[0]?.message?.content?.trim() || "");
});
'
}

extract_response_text() {
  "$NODE_BINARY" -e '
let body = "";
process.stdin.on("data", (chunk) => body += chunk);
process.stdin.on("end", () => {
  const json = JSON.parse(body);
  let text = json.output_text || "";
  if (!text && Array.isArray(json.output)) {
    text = json.output.flatMap((item) => item.content || []).map((content) => content.text || "").join("");
  }
  process.stdout.write(text.trim());
});
'
}

extract_stream_text() {
  "$NODE_BINARY" -e '
let body = "";
process.stdin.on("data", (chunk) => body += chunk);
process.stdin.on("end", () => {
  let text = "";
  let done = false;
  for (const line of body.split(/\r?\n/)) {
    if (!line.startsWith("data:")) continue;
    const payload = line.slice(5).trim();
    if (payload === "[DONE]") {
      done = true;
      continue;
    }
    if (!payload) continue;
    const json = JSON.parse(payload);
    text += json.choices?.[0]?.delta?.content || "";
  }
  if (!done) process.exit(2);
  process.stdout.write(text.trim());
});
'
}

chat_body='{"model":"composer-2.5-fast","messages":[{"role":"user","content":"Reply exactly: hello"}],"stream":false}'
chat_content="$(post_json "/chat/completions" "$chat_body" | extract_chat_content)"
[ "$chat_content" = "hello" ] || fail "chat completions returned '$chat_content', expected hello"

stream_body='{"model":"composer-2.5-fast","messages":[{"role":"user","content":"Reply exactly: hello"}],"stream":true,"stream_options":{"include_usage":true}}'
stream_content="$(post_json "/chat/completions" "$stream_body" | extract_stream_text)"
[ "$stream_content" = "hello" ] || fail "streaming chat returned '$stream_content', expected hello"

responses_body='{"model":"composer-2.5-fast","input":"Reply exactly: hello","stream":false}'
responses_content="$(post_json "/responses" "$responses_body" | extract_response_text)"
[ "$responses_content" = "hello" ] || fail "Responses API returned '$responses_content', expected hello"

bridge_process_count() {
  ps ax -o command= \
    | grep -F "$APP_PATH/Contents/Resources/node" \
    | grep -F "cursor-sdk-opencode-bridge.mjs" \
    | grep -v grep \
    | wc -l \
    | tr -d " "
}

bridge_count="$(bridge_process_count)"
[ "$bridge_count" = "1" ] || fail "expected one shared SDK bridge process, found $bridge_count"
echo "Verified direct chat, streaming chat, Responses API, and one shared SDK bridge process."

if [ "$RUN_OPENCODE" -eq 1 ]; then
  if ! command -v opencode >/dev/null 2>&1 || ! command -v tmux >/dev/null 2>&1; then
    echo "Skipping live OpenCode check; opencode or tmux is not installed."
    exit 0
  fi

  temp_home="$(mktemp -d "${TMPDIR:-/tmp}/api-for-cursor-live-opencode-home.XXXXXX")"
  temp_config="$(mktemp -d "${TMPDIR:-/tmp}/api-for-cursor-live-opencode-config.XXXXXX")"
  temp_project="$(mktemp -d "${TMPDIR:-/tmp}/api-for-cursor-live-opencode-project.XXXXXX")"
  TEMP_DIRS+=("$temp_home" "$temp_config" "$temp_project")
  mkdir -p "$temp_config/opencode"

  config_file="$temp_config/opencode/opencode.json"
  TEMP_FILES+=("$config_file")
  sed \
    -e "s#__BASE_URL__#$base_url#g" \
    -e "s#__API_KEY__#$CURSOR_API_TEST_KEY#g" >"$config_file" <<'JSON'
{
  "provider": {
    "cursorapi": {
      "npm": "@ai-sdk/openai-compatible",
      "name": "API for Cursor",
      "options": {
        "baseURL": "__BASE_URL__",
        "apiKey": "__API_KEY__"
      },
      "models": {
        "composer-2.5-fast": {
          "name": "Composer 2.5 Fast",
          "cost": { "input": 3, "output": 15 },
          "limit": { "context": 200000, "output": 65536 }
        }
      }
    }
  }
}
JSON

  models_output="$(cd "$temp_project" && HOME="$temp_home" XDG_CONFIG_HOME="$temp_config" opencode --pure models cursorapi 2>&1)"
  printf '%s\n' "$models_output"
  grep -F "cursorapi/composer-2.5-fast" <<<"$models_output" >/dev/null || fail "OpenCode did not list composer-2.5-fast"

  session="api-for-cursor-live-opencode-$$"
  tmux new-session -d -x 160 -y 48 -s "$session" "cd \"$temp_project\" && HOME=\"$temp_home\" XDG_CONFIG_HOME=\"$temp_config\" opencode --pure --model cursorapi/composer-2.5-fast"
  sleep 4
  tmux send-keys -t "$session" "Reply exactly: pongtest" Enter

  deadline=$((SECONDS + TIMEOUT_SECONDS))
  last_capture=""
  while [ "$SECONDS" -lt "$deadline" ]; do
    last_capture="$(tmux capture-pane -t "$session" -p -J -S -200 2>/dev/null || true)"
    pong_count="$( (printf "%s\n" "$last_capture" | grep -F "pongtest" || true) | wc -l | tr -d " " )"
    if [ "${pong_count:-0}" -ge 2 ] && printf "%s\n" "$last_capture" | grep -F "API for Cursor" >/dev/null; then
      tmux kill-session -t "$session" >/dev/null 2>&1 || true
      echo "Verified live OpenCode interactive response through API for Cursor."
      bridge_count="$(bridge_process_count)"
      [ "$bridge_count" = "1" ] || fail "expected one shared SDK bridge process after OpenCode, found $bridge_count"
      exit 0
    fi
    sleep 1
  done

  printf "%s\n" "$last_capture" | tail -80
  tmux kill-session -t "$session" >/dev/null 2>&1 || true
  fail "OpenCode did not surface the live Composer response before timeout"
fi
