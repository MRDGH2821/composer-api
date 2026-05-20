import { HttpError } from "./http";
import { parseSse } from "./sse";
import type { CursorCompletion, CursorMe, CursorPrompt, Deps, Env } from "./types";

interface CursorModelResponse {
  items?: Array<{ id: string; displayName?: string; aliases?: string[] }>;
}

interface CursorAccessTokenResponse {
  accessToken?: string;
}

interface ProtobufField {
  no: number;
  wt: number;
  value: number | Uint8Array;
}

export async function verifyCursorApiKey(env: Env, deps: Deps, apiKey: string): Promise<CursorMe> {
  return cursorPublicJson<CursorMe>(env, deps, apiKey, "/v1/me");
}

export async function listCursorModels(env: Env, deps: Deps, apiKey: string): Promise<CursorModelResponse> {
  return cursorPublicJson<CursorModelResponse>(env, deps, apiKey, "/v1/models");
}

export function resolveCursorModel(model: unknown): { id: string } | undefined {
  if (typeof model !== "string" || !model.trim()) return { id: "composer-2.5" };
  const normalized = model.trim().toLowerCase();
  if (normalized === "composer-2.5" || normalized === "composer-2-5" || normalized === "composer-latest") {
    return { id: "composer-2.5" };
  }
  if (normalized === "composer-2.5-fast" || normalized === "composer-2-5-fast") {
    return { id: "composer-2.5-fast" };
  }
  if (normalized === "auto" || normalized === "default") return { id: "default" };
  return { id: model.trim() };
}

export async function createCursorCompletion(
  env: Env,
  deps: Deps,
  apiKey: string,
  input: { prompt: CursorPrompt; model?: { id: string } }
): Promise<CursorCompletion> {
  if (input.prompt.images?.length) {
    throw new HttpError("Image input is not supported by the Cursor Cursor adapter adapter yet.", 400, "unsupported_parameter", "image");
  }
  const accessToken = await exchangeCursorApiKey(env, deps, apiKey);
  const requestId = deps.randomUUID();
  const conversationId = deps.randomUUID();
  const requestBody = encodeConnectFrame(
    encodeCursorChatChatRequest({
      prompt: input.prompt,
      model: input.model?.id || "composer-2.5",
      requestId,
      conversationId,
      messageId: deps.randomUUID()
    })
  );
  const response = await cursorInternalRaw(env, deps, accessToken, "/private-cursor-chat-endpoint", {
    method: "POST",
    headers: await cursorInternalHeaders(env, accessToken, apiKey, requestId),
    body: requestBody.buffer as ArrayBuffer
  });
  return { requestId, conversationId, stream: response };
}

export interface CursorTextEvent {
  type: "text" | "done";
  text?: string;
  finalText?: string;
}

export async function* streamCursorText(response: Response): AsyncGenerator<CursorTextEvent> {
  const contentType = response.headers.get("content-type") || "";
  if (!contentType.includes("application/connect+proto")) {
    yield* streamLegacyAgentText(response);
    return;
  }

  let text = "";
  const thinking = new ThinkingTextExtractor();
  for await (const frame of parseConnectProtoFrames(response.body)) {
    const event = decodeCursorChatFrame(frame);
    if (event.type === "error") throw new HttpError(event.message, 502, "cursor_stream_error");
    if (event.type === "tool_call") {
      throw new HttpError("Cursor requested a tool call, but this OpenAI-compatible proxy runs with tools disabled.", 502, "cursor_tool_call");
    }
    if (event.type === "text" && event.text) {
      text += event.text;
      yield { type: "text", text: event.text };
    }
    if (event.type === "thinking" && event.text) {
      for (const delta of thinking.push(event.text)) {
        text += delta;
        yield { type: "text", text: delta };
      }
    }
  }
  const flushed = thinking.flush();
  if (flushed) {
    text += flushed;
    yield { type: "text", text: flushed };
  }
  yield { type: "done", finalText: text };
}

async function* streamLegacyAgentText(response: Response): AsyncGenerator<CursorTextEvent> {
  let text = "";
  let mode: "unknown" | "assistant" | "delta" = "unknown";
  for await (const event of parseSse(response.body)) {
    if (event.event === "done") break;
    if (!event.data) continue;
    let payload: unknown;
    try {
      payload = JSON.parse(event.data);
    } catch {
      continue;
    }

    if (event.event === "interaction_update" && isRecord(payload)) {
      const type = payload.type;
      if (type === "text-delta" && typeof payload.text === "string" && mode !== "assistant") {
        mode = "delta";
        text += payload.text;
        yield { type: "text", text: payload.text };
      } else if (type === "summary" && typeof payload.summary === "string" && !text && mode === "unknown") {
        text = payload.summary;
      }
      continue;
    }

    if (event.event === "assistant" && isRecord(payload) && typeof payload.text === "string" && mode !== "delta") {
      mode = "assistant";
      text += payload.text;
      yield { type: "text", text: payload.text };
      continue;
    }

    if (event.event === "result" && isRecord(payload)) {
      const result = typeof payload.result === "string" ? payload.result : typeof payload.text === "string" ? payload.text : "";
      if (!text && result) text = result;
      yield { type: "done", finalText: text };
      return;
    }

    if (event.event === "error" && isRecord(payload)) {
      const message = typeof payload.message === "string" ? payload.message : "Cursor stream failed";
      throw new HttpError(message, 502, "cursor_stream_error");
    }
  }
  yield { type: "done", finalText: text };
}

export async function collectCursorText(response: Response): Promise<string> {
  let finalText = "";
  for await (const event of streamCursorText(response)) {
    if (event.type === "text" && event.text) finalText += event.text;
    if (event.type === "done" && event.finalText !== undefined) finalText = event.finalText;
  }
  return finalText;
}

async function exchangeCursorApiKey(env: Env, deps: Deps, apiKey: string): Promise<string> {
  const response = await cursorInternalRaw(env, deps, apiKey, "/auth/exchange_user_api_key", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: "{}"
  });
  const payload = (await response.json()) as CursorAccessTokenResponse;
  if (!payload.accessToken) throw new HttpError("Cursor did not return an internal access token", 502, "cursor_bad_response");
  return payload.accessToken;
}

async function cursorPublicJson<T>(
  env: Env,
  deps: Deps,
  apiKey: string,
  path: string,
  init: { method?: string; body?: unknown; idempotencyKey?: string } = {}
): Promise<T> {
  const headers: Record<string, string> = {
    "Content-Type": "application/json",
    ...(init.idempotencyKey ? { "Idempotency-Key": init.idempotencyKey } : {})
  };
  const response = await cursorPublicRaw(env, deps, apiKey, path, {
    method: init.method || "GET",
    headers,
    body: init.body === undefined ? undefined : JSON.stringify(init.body)
  });
  return response.json() as Promise<T>;
}

async function cursorPublicRaw(
  env: Env,
  deps: Deps,
  apiKey: string,
  path: string,
  init: RequestInit = {}
): Promise<Response> {
  const base = env.CURSOR_API_BASE || "https://api.cursor.com";
  const url = `${base.replace(/\/$/, "")}${path}`;
  const headers = new Headers(init.headers);
  headers.set("Authorization", `Bearer ${apiKey}`);
  headers.set("x-cursor-client-type", "sdk");
  headers.set("x-cursor-client-version", "composer-api-0.1.0");
  headers.set("x-ghost-mode", "true");
  const response = await deps.fetch(url, { ...init, headers });
  if (!response.ok) {
    const text = await response.text().catch(() => "");
    const message =
      response.status === 401
        ? "Invalid Cursor API key"
        : parseCursorError(text) || `Cursor API request failed with status ${response.status}`;
    const status = response.status === 401 ? 401 : response.status === 429 ? 429 : response.status >= 500 ? 502 : 400;
    throw new HttpError(message, status, response.status === 401 ? "cursor_unauthorized" : "cursor_api_error");
  }
  return response;
}

async function cursorInternalRaw(
  env: Env,
  deps: Deps,
  token: string,
  path: string,
  init: RequestInit = {}
): Promise<Response> {
  const base = env.CURSOR_BACKEND_BASE_URL || "private-cursor-backend-origin";
  const url = `${base.replace(/\/$/, "")}${path}`;
  const headers = new Headers(init.headers);
  headers.set("Authorization", `Bearer ${token}`);
  const response = await deps.fetch(url, { ...init, headers });
  if (!response.ok) {
    const text = await response.text().catch(() => "");
    const message =
      response.status === 401
        ? "Invalid Cursor API key"
        : parseCursorError(text) || `Cursor internal API request failed with status ${response.status}`;
    const status = response.status === 401 ? 401 : response.status === 429 ? 429 : response.status >= 500 ? 502 : 400;
    throw new HttpError(message, status, response.status === 401 ? "cursor_unauthorized" : "cursor_api_error");
  }
  return response;
}

function parseCursorError(text: string): string | undefined {
  try {
    const payload = JSON.parse(text) as unknown;
    if (isRecord(payload)) {
      const error = isRecord(payload.error) ? payload.error : payload;
      if (typeof error.message === "string") return error.message;
    }
  } catch {
    // Ignore JSON parse failures.
  }
  return text || undefined;
}

async function cursorInternalHeaders(env: Env, accessToken: string, cursorApiKey: string, requestId: string): Promise<Record<string, string>> {
  return {
    "Content-Type": "application/connect+proto",
    "Connect-Protocol-Version": "1",
    "User-Agent": "connect-es/1.6.1",
    "x-amzn-trace-id": `Root=${requestId}`,
    "x-client-key": await sha256Hex(accessToken),
    "x-cursor-checksum": await cursorChecksum(cursorApiKey),
    "x-cursor-client-version": env.CURSOR_CLIENT_VERSION || "2.6.22",
    "x-cursor-client-type": "ide",
    "x-cursor-client-os": "linux",
    "x-cursor-client-arch": "x64",
    "x-cursor-client-os-version": "unknown",
    "x-cursor-client-device-type": "desktop",
    "x-cursor-config-version": crypto.randomUUID(),
    "x-cursor-timezone": "UTC",
    "x-ghost-mode": "false",
    "x-new-onboarding-completed": "false",
    "x-request-id": requestId,
    "x-session-id": await sessionId(accessToken)
  };
}

function encodeCursorChatChatRequest(input: {
  prompt: CursorPrompt;
  model: string;
  requestId: string;
  conversationId: string;
  messageId: string;
}): Uint8Array {
  const messageId = input.messageId;
  const userMessage = protoMessage([
    protoField(1, 2, input.prompt.text),
    protoField(2, 0, 1),
    protoField(13, 2, messageId),
    protoField(47, 0, 1)
  ]);
  const model = protoMessage([protoField(1, 2, input.model), protoField(4, 2, new Uint8Array(0))]);
  const cursorSetting = protoMessage([
    protoField(1, 2, "cursor\\aisettings"),
    protoField(3, 2, new Uint8Array(0)),
    protoField(6, 2, protoMessage([protoField(1, 2, new Uint8Array(0)), protoField(2, 2, new Uint8Array(0))])),
    protoField(8, 0, 1),
    protoField(9, 0, 1)
  ]);
  const metadata = protoMessage([
    protoField(1, 2, "linux"),
    protoField(2, 2, "x64"),
    protoField(3, 2, "unknown"),
    protoField(4, 2, "composer-api"),
    protoField(5, 2, new Date().toISOString())
  ]);
  const messageIdRecord = protoMessage([protoField(1, 2, messageId), protoField(3, 0, 1)]);
  const request = protoMessage([
    protoField(1, 2, userMessage),
    protoField(2, 0, 1),
    protoField(3, 2, new Uint8Array(0)),
    protoField(4, 0, 1),
    protoField(5, 2, model),
    protoField(8, 2, ""),
    protoField(13, 0, 1),
    protoField(15, 2, cursorSetting),
    protoField(19, 0, 1),
    protoField(23, 2, input.conversationId),
    protoField(26, 2, metadata),
    protoField(27, 0, 0),
    protoField(30, 2, messageIdRecord),
    protoField(35, 0, 0),
    protoField(38, 0, 0),
    protoField(46, 0, 1),
    protoField(47, 2, ""),
    protoField(48, 0, 0),
    protoField(49, 0, 0),
    protoField(51, 0, 0),
    protoField(53, 0, 1),
    protoField(54, 2, "Ask")
  ]);
  return protoMessage([protoField(1, 2, request)]);
}

function encodeConnectFrame(payload: Uint8Array): Uint8Array {
  const frame = new Uint8Array(5 + payload.length);
  frame[0] = 0;
  new DataView(frame.buffer).setUint32(1, payload.length, false);
  frame.set(payload, 5);
  return frame;
}

async function* parseConnectProtoFrames(stream: ReadableStream<Uint8Array> | null): AsyncGenerator<Uint8Array> {
  if (!stream) return;
  const reader = stream.getReader();
  let buffer = new Uint8Array(0);
  try {
    for (;;) {
      const { value, done } = await reader.read();
      if (done) break;
      if (value) buffer = concatBytes(buffer, value);
      for (;;) {
        if (buffer.length < 5) break;
        const flags = buffer[0];
        const length = new DataView(buffer.buffer, buffer.byteOffset + 1, 4).getUint32(0, false);
        if (buffer.length < 5 + length) break;
        const payload = buffer.slice(5, 5 + length);
        buffer = buffer.slice(5 + length);
        if ((flags & 1) === 1) {
          throw new HttpError("Cursor returned a compressed Connect frame that this Worker cannot decode.", 502, "cursor_stream_error");
        }
        if ((flags & 2) === 2) {
          handleEndStreamFrame(payload);
          continue;
        }
        yield payload;
      }
    }
  } finally {
    reader.releaseLock();
  }
}

function handleEndStreamFrame(payload: Uint8Array) {
  if (!payload.length) return;
  const text = decodeUtf8(payload).trim();
  if (!text || text === "{}") return;
  try {
    const parsed = JSON.parse(text) as unknown;
    if (isRecord(parsed) && isRecord(parsed.error)) {
      const message = cursorStreamErrorMessage(parsed.error) || "Cursor stream failed";
      throw new HttpError(message, 502, "cursor_stream_error");
    }
  } catch (error) {
    if (error instanceof HttpError) throw error;
  }
}

function decodeCursorChatFrame(payload: Uint8Array):
  | { type: "text"; text: string }
  | { type: "thinking"; text: string }
  | { type: "tool_call" }
  | { type: "ignore" }
  | { type: "error"; message: string } {
  try {
    for (const field of decodeProtobufFields(payload)) {
      if (field.no === 1) return { type: "tool_call" };
      if (field.no !== 2 || field.wt !== 2 || !(field.value instanceof Uint8Array)) continue;
      let text = "";
      let thinking = "";
      for (const inner of decodeProtobufFields(field.value)) {
        if (inner.no === 1 && inner.wt === 2 && inner.value instanceof Uint8Array) text += decodeUtf8(inner.value);
        if (inner.no === 25 && inner.wt === 2 && inner.value instanceof Uint8Array) {
          for (const thinkingField of decodeProtobufFields(inner.value)) {
            if (thinkingField.no === 1 && thinkingField.wt === 2 && thinkingField.value instanceof Uint8Array) {
              thinking += decodeUtf8(thinkingField.value);
            }
          }
        }
      }
      if (text) return { type: "text", text };
      if (thinking) return { type: "thinking", text: thinking };
    }
    return { type: "ignore" };
  } catch (error) {
    return { type: "error", message: error instanceof Error ? error.message : "Failed to decode Cursor stream" };
  }
}

class ThinkingTextExtractor {
  private static finalMarkers = ["</think>", "<|final|>", "<｜final｜>"];
  private buffer = "";
  private open = true;

  push(delta: string): string[] {
    if (!this.open) return [delta];
    this.buffer += delta;
    const marker = this.findFinalMarker();
    if (!marker) return [];
    this.open = false;
    const after = this.buffer.slice(marker.index + marker.marker.length).replace(/^\s+/, "");
    this.buffer = "";
    return after ? [after] : [];
  }

  flush(): string {
    if (!this.open) return "";
    const marker = this.findFinalMarker();
    if (marker) {
      const after = this.buffer.slice(marker.index + marker.marker.length).replace(/^\s+/, "");
      this.buffer = "";
      return after;
    }
    this.buffer = "";
    return "";
  }

  private findFinalMarker(): { marker: string; index: number } | null {
    let found: { marker: string; index: number } | null = null;
    for (const marker of ThinkingTextExtractor.finalMarkers) {
      const index = this.buffer.lastIndexOf(marker);
      if (index !== -1 && (!found || index > found.index)) found = { marker, index };
    }
    return found;
  }
}

function protoMessage(parts: Uint8Array[]): Uint8Array {
  return concatBytes(...parts);
}

function protoField(fieldNumber: number, wireType: 0 | 2, value: string | number | Uint8Array): Uint8Array {
  const tag = encodeVarint((fieldNumber << 3) | wireType);
  if (wireType === 0) return concatBytes(tag, encodeVarint(value as number));
  const bytes = typeof value === "string" ? new TextEncoder().encode(value) : value instanceof Uint8Array ? value : encodeVarint(value);
  return concatBytes(tag, encodeVarint(bytes.length), bytes);
}

function encodeVarint(value: number): Uint8Array {
  const bytes: number[] = [];
  let current = value >>> 0;
  while (current >= 0x80) {
    bytes.push((current & 0x7f) | 0x80);
    current >>>= 7;
  }
  bytes.push(current);
  return new Uint8Array(bytes);
}

function decodeProtobufFields(bytes: Uint8Array): ProtobufField[] {
  const fields: ProtobufField[] = [];
  let offset = 0;
  while (offset < bytes.length) {
    const tag = readVarint(bytes, offset);
    offset = tag.offset;
    const no = tag.value >> 3;
    const wt = tag.value & 7;
    if (wt === 0) {
      const value = readVarint(bytes, offset);
      offset = value.offset;
      fields.push({ no, wt, value: value.value });
    } else if (wt === 2) {
      const length = readVarint(bytes, offset);
      offset = length.offset;
      fields.push({ no, wt, value: bytes.slice(offset, offset + length.value) });
      offset += length.value;
    } else if (wt === 1) {
      offset += 8;
    } else if (wt === 5) {
      offset += 4;
    } else {
      throw new Error(`Unsupported protobuf wire type ${wt}`);
    }
  }
  return fields;
}

function readVarint(bytes: Uint8Array, offset: number): { value: number; offset: number } {
  let value = 0;
  let shift = 0;
  while (offset < bytes.length) {
    const byte = bytes[offset++];
    value += (byte & 0x7f) * 2 ** shift;
    if ((byte & 0x80) === 0) return { value, offset };
    shift += 7;
  }
  throw new Error("Unexpected end of protobuf varint");
}

function concatBytes(...parts: Uint8Array<ArrayBufferLike>[]): Uint8Array<ArrayBuffer> {
  const total = parts.reduce((sum, part) => sum + part.length, 0);
  const output = new Uint8Array(total);
  let offset = 0;
  for (const part of parts) {
    output.set(part, offset);
    offset += part.length;
  }
  return output;
}

async function sha256Hex(value: string): Promise<string> {
  const bytes = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(value));
  return [...new Uint8Array(bytes)].map((byte) => byte.toString(16).padStart(2, "0")).join("");
}

async function cursorChecksum(cursorApiKey: string): Promise<string> {
  const machineId = await sha256Hex(`composer-api:${cursorApiKey}`);
  const timestamp = BigInt(Math.floor(Date.now() / 1_000_000));
  const bytes = new Uint8Array([
    Number((timestamp >> 40n) & 255n),
    Number((timestamp >> 32n) & 255n),
    Number((timestamp >> 24n) & 255n),
    Number((timestamp >> 16n) & 255n),
    Number((timestamp >> 8n) & 255n),
    Number(timestamp & 255n)
  ]);
  let t = 165;
  for (let i = 0; i < bytes.length; i += 1) {
    bytes[i] = ((bytes[i] ^ t) + (i % 256)) & 255;
    t = bytes[i];
  }
  return `${base64Url(bytes)}${machineId}`;
}

async function sessionId(token: string): Promise<string> {
  const hash = (await sha256Hex(token)).slice(0, 32);
  return `${hash.slice(0, 8)}-${hash.slice(8, 12)}-${hash.slice(12, 16)}-${hash.slice(16, 20)}-${hash.slice(20)}`;
}

function base64Url(bytes: Uint8Array): string {
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary).replaceAll("+", "-").replaceAll("/", "_").replaceAll("=", "");
}

function decodeUtf8(bytes: Uint8Array): string {
  return new TextDecoder().decode(bytes);
}

function cursorStreamErrorMessage(error: unknown): string | undefined {
  if (!isRecord(error)) return undefined;
  const titleAndDetail = detailFromCursorError(error);
  if (titleAndDetail) return titleAndDetail;
  return typeof error.message === "string" ? error.message : undefined;
}

function detailFromCursorError(error: Record<string, unknown>): string | undefined {
  const details = Array.isArray(error.details) ? error.details : [];
  for (const detail of details) {
    if (!isRecord(detail) || !isRecord(detail.debug)) continue;
    const debugDetails = isRecord(detail.debug.details) ? detail.debug.details : undefined;
    const title = typeof debugDetails?.title === "string" ? debugDetails.title : "";
    const body = typeof debugDetails?.detail === "string" ? debugDetails.detail : "";
    const message = [title, body].filter(Boolean).join(" ");
    if (message) return message;
  }
  return undefined;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null;
}
