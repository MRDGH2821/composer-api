#!/usr/bin/env node
import { Agent } from "@cursor/sdk";
import crypto from "node:crypto";
import { existsSync, readFileSync } from "node:fs";
import http from "node:http";
import path from "node:path";
import { fileURLToPath } from "node:url";

const scriptDir = path.dirname(fileURLToPath(import.meta.url));
const repoRoot = path.resolve(scriptDir, "..");

loadEnvFile(path.join(repoRoot, ".env"));
loadEnvFile(path.join(process.cwd(), ".env"));

const host = process.env.CURSOR_SDK_BRIDGE_HOST || "127.0.0.1";
const port = parseInteger(process.env.CURSOR_SDK_BRIDGE_PORT, 8792);
const bridgeToken = process.env.CURSOR_SDK_BRIDGE_TOKEN || "";
const maxJsonBytes = parseInteger(process.env.CURSOR_SDK_BRIDGE_MAX_JSON_BYTES, 1024 * 1024);
const maxAgents = parseInteger(process.env.CURSOR_SDK_BRIDGE_MAX_AGENTS, 128);
const defaultCwd = process.env.CURSOR_SDK_WORKING_DIRECTORY || process.cwd();

const agentCache = new Map();

const server = http.createServer((request, response) => {
  handleRequest(request, response).catch((error) => {
    writeJson(response, openAiError(error), statusFromError(error));
  });
});

server.listen(port, host, () => {
  console.log(`Cursor SDK local-agent bridge listening on http://${host}:${port}/sdk`);
});

process.on("SIGINT", () => closeAndExit(0));
process.on("SIGTERM", () => closeAndExit(0));

async function handleRequest(request, response) {
  const url = new URL(request.url || "/", `http://${request.headers.host || `${host}:${port}`}`);

  if (request.method === "GET" && url.pathname === "/health") {
    writeJson(response, { ok: true, agents: agentCache.size });
    return;
  }

  if (request.method !== "POST" || url.pathname !== "/sdk") {
    writeJson(response, openAiError(new HttpError("Not found", 404, "not_found")), 404);
    return;
  }

  if (bridgeToken && bearerToken(request) !== bridgeToken) {
    writeJson(response, openAiError(new HttpError("Invalid bridge token", 401, "unauthorized")), 401);
    return;
  }

  const body = await readJsonBody(request);
  const apiKey = requiredString(body.apiKey, "apiKey");
  const prompt = requiredString(body.prompt, "prompt");
  const model = normalizeModel(typeof body.model === "string" ? body.model : "");
  const sessionKey = typeof body.sessionKey === "string" && body.sessionKey ? body.sessionKey : crypto.randomUUID();
  const workingDirectory = sdkWorkingDirectory(body.workingDirectory);
  const requestId = typeof body.requestId === "string" && body.requestId ? body.requestId : crypto.randomUUID();

  const output = await runLocalAgent({
    apiKey,
    model,
    prompt: bridgePrompt(prompt),
    sessionKey,
    workingDirectory,
    requestId
  });
  writeJson(response, output);
}

async function runLocalAgent(input) {
  const agent = await getAgent(input);
  let run;
  let capturedToolCall = null;
  let cancelRequested = false;
  let text = "";

  const captureToolCall = async (toolCall) => {
    if (capturedToolCall || !toolCall) return;
    const normalized = normalizeSDKToolCall(toolCall);
    if (!normalized || !isForwardableSDKToolCall(normalized)) return;
    capturedToolCall = normalized;
    cancelRequested = true;
    if (run) {
      try {
        await run.cancel();
      } catch {
        // The SDK may already be finishing the local run. The captured model
        // tool call is still the response we need to return to the client.
      }
    }
  };

  run = await agent.send(input.prompt, {
    model: { id: input.model },
    local: { force: true },
    idempotencyKey: input.requestId,
    onDelta: async ({ update }) => {
      const toolCall = toolCallFromDelta(update);
      if (toolCall) await captureToolCall(toolCall);
    }
  });

  if (cancelRequested) {
    try {
      await run.cancel();
    } catch {}
  }

  for await (const event of run.stream()) {
    if (event.type === "assistant") {
      for (const block of event.message?.content ?? []) {
        if (block?.type === "text" && typeof block.text === "string") text += block.text;
      }
      continue;
    }
    if (event.type === "tool_call") {
      await captureToolCall({ type: event.name, args: event.args });
      if (capturedToolCall) break;
    }
  }

  if (capturedToolCall) {
    return {
      text: "",
      toolCalls: [capturedToolCall],
      agentID: agent.agentId,
      runID: run.id,
      status: "tool_call"
    };
  }

  const result = await run.wait();
  if (result.status === "error") {
    throw new HttpError("Cursor SDK run failed", 502, "cursor_sdk_error");
  }
  if (!text && typeof result.result === "string") text = result.result;
  return {
    text: stripFinalMarker(text),
    toolCalls: [],
    agentID: agent.agentId,
    runID: run.id,
    status: result.status
  };
}

async function getAgent(input) {
  const cacheKey = agentCacheKey(input);
  const cached = agentCache.get(cacheKey);
  if (cached) {
    cached.touchedAt = Date.now();
    return cached.agent;
  }

  const agent = await Agent.create({
    apiKey: input.apiKey,
    model: { id: input.model },
    name: "API for Cursor local bridge",
    local: {
      cwd: input.workingDirectory,
      sandboxOptions: { enabled: false },
      settingSources: []
    }
  });
  agentCache.set(cacheKey, { agent, touchedAt: Date.now() });
  evictAgents();
  return agent;
}

function bridgePrompt(prompt) {
  return [
    "You are running through the real Cursor SDK local runtime behind an OpenAI-compatible client.",
    "The outer client owns local tool execution. When local work is needed, emit exactly one SDK tool call, then stop.",
    "For file creation, file edits, deletes, package installs, tests, builds, and project scaffolds, use SDK shell with a complete command. Do not use SDK edit/write for mutations because hidden edit patches cannot be forwarded to the outer client.",
    "When using SDK shell for file writes, include mkdir -p for parent directories and quoted heredocs or a small script with the full intended content.",
    "When creating Vite 8 React projects, use @vitejs/plugin-react ^5 with vite ^8, or omit the plugin if it is not needed. Do not pair Vite 8 with @vitejs/plugin-react 4.",
    "For inspection-only work, SDK read, grep, glob, and ls are acceptable. Do not claim local work is done until a tool result is present in the transcript.",
    "",
    prompt
  ].join("\n");
}

function toolCallFromDelta(update) {
  if (!update || typeof update !== "object") return null;
  if (update.type !== "partial-tool-call" && update.type !== "tool-call-started") return null;
  const toolCall = update.toolCall;
  if (!toolCall || typeof toolCall !== "object") return null;
  return toolCall;
}

function normalizeSDKToolCall(toolCall) {
  const name = typeof toolCall.type === "string" ? toolCall.type : typeof toolCall.name === "string" ? toolCall.name : "";
  if (!name) return null;
  const args = toolCall.args && typeof toolCall.args === "object" && !Array.isArray(toolCall.args) ? toolCall.args : {};
  return {
    name,
    arguments: normalizeArguments(args)
  };
}

function isForwardableSDKToolCall(toolCall) {
  const args = toolCall.arguments || {};
  switch (canonicalToolName(toolCall.name)) {
    case "shell":
      return hasString(args, "command");
    case "write":
      return hasString(args, "path", "filePath", "targetFile")
        && hasStringAllowEmpty(args, "fileText", "content", "contents", "text", "data");
    case "edit":
      return hasString(args, "path", "filePath", "targetFile")
        && (
          hasStringAllowEmpty(args, "patchContent", "patch_content", "streamContent", "stream_content")
          || (hasStringAllowEmpty(args, "oldText", "oldString", "old_str") && hasStringAllowEmpty(args, "newText", "newString", "replacement"))
        );
    case "delete":
    case "read":
      return hasString(args, "path", "filePath", "targetFile");
    case "glob":
      return hasString(args, "globPattern", "glob_pattern", "pattern", "targetDirectory", "target_directory");
    case "grep":
      return hasString(args, "pattern", "query");
    case "ls":
      return true;
    case "mcp":
      return hasString(args, "providerIdentifier", "provider", "server")
        && hasString(args, "toolName", "tool", "name");
    case "readlints":
    case "semsearch":
    case "todowrite":
      return Object.keys(args).length > 0;
    default:
      return Object.keys(args).length > 0;
  }
}

function canonicalToolName(name) {
  return String(name || "").replace(/[^A-Za-z0-9]/g, "").toLowerCase();
}

function hasString(args, ...keys) {
  return keys.some((key) => typeof args[key] === "string" && args[key].trim().length > 0);
}

function hasStringAllowEmpty(args, ...keys) {
  return keys.some((key) => typeof args[key] === "string");
}

function normalizeArguments(args) {
  const output = {};
  for (const [key, value] of Object.entries(args)) {
    if (value === undefined || typeof value === "function" || typeof value === "symbol") continue;
    output[key] = normalizeJsonValue(value);
  }
  return output;
}

function normalizeJsonValue(value) {
  if (value === null || typeof value === "string" || typeof value === "number" || typeof value === "boolean") return value;
  if (Array.isArray(value)) return value.map(normalizeJsonValue);
  if (typeof value === "object") return normalizeArguments(value);
  return String(value);
}

function agentCacheKey(input) {
  const digest = crypto
    .createHash("sha256")
    .update([input.apiKey, input.model, input.workingDirectory, input.sessionKey].join("\0"))
    .digest("hex")
    .slice(0, 32);
  return digest;
}

function evictAgents() {
  while (agentCache.size > maxAgents) {
    const oldest = [...agentCache.entries()].sort((a, b) => a[1].touchedAt - b[1].touchedAt)[0];
    if (!oldest) return;
    agentCache.delete(oldest[0]);
    try {
      oldest[1].agent.close();
    } catch {}
  }
}

function normalizeModel(model) {
  const normalized = model.trim().toLowerCase();
  if (!normalized || normalized === "default" || normalized === "auto") return "composer-2.5";
  if (normalized === "composer-2.5-sdk" || normalized === "composer-2-5-sdk") return "composer-2.5";
  if (normalized === "composer-2.5-fast" || normalized === "composer-2-5-fast") return "composer-2.5";
  return model.trim();
}

function sdkWorkingDirectory(value) {
  const trimmed = typeof value === "string" ? value.trim() : "";
  if (!trimmed || trimmed.toLowerCase() === "undefined" || trimmed.toLowerCase() === "null") return defaultCwd;
  return trimmed;
}

function stripFinalMarker(text) {
  return text.replace(/\s*<\/?(?:final_answer|answer)>\s*$/gi, "").trim();
}

function requiredString(value, key) {
  if (typeof value !== "string" || !value.trim()) {
    throw new HttpError(`Missing ${key}`, 400, "invalid_request");
  }
  return value;
}

async function readJsonBody(request) {
  let body = "";
  for await (const chunk of request) {
    body += chunk;
    if (body.length > maxJsonBytes) throw new HttpError("Request body too large", 413, "request_too_large");
  }
  if (!body.trim()) return {};
  try {
    return JSON.parse(body);
  } catch {
    throw new HttpError("Invalid JSON", 400, "invalid_json");
  }
}

function writeJson(response, body, status = 200) {
  const data = Buffer.from(JSON.stringify(body));
  response.writeHead(status, {
    "Content-Type": "application/json; charset=utf-8",
    "Content-Length": String(data.length),
    "Cache-Control": "no-cache, no-transform",
    "Access-Control-Allow-Origin": "*"
  });
  response.end(data);
}

function openAiError(error) {
  return {
    error: {
      message: error instanceof Error ? error.message : String(error),
      type: error?.type || "api_error",
      code: error?.code || null
    }
  };
}

function statusFromError(error) {
  return Number.isInteger(error?.status) ? error.status : 500;
}

class HttpError extends Error {
  constructor(message, status = 500, code = "api_error") {
    super(message);
    this.status = status;
    this.code = code;
    this.type = status >= 500 ? "api_error" : "invalid_request_error";
  }
}

function bearerToken(request) {
  const value = request.headers.authorization || "";
  const [scheme, token] = value.split(/\s+/, 2);
  return scheme?.toLowerCase() === "bearer" ? token || "" : "";
}

function parseInteger(value, fallback) {
  const parsed = Number.parseInt(String(value || ""), 10);
  return Number.isFinite(parsed) && parsed > 0 ? parsed : fallback;
}

function loadEnvFile(filePath) {
  if (!existsSync(filePath)) return;
  for (const line of readFileSync(filePath, "utf8").split(/\r?\n/)) {
    const trimmed = line.trim();
    if (!trimmed || trimmed.startsWith("#")) continue;
    const normalized = trimmed.startsWith("export ") ? trimmed.slice(7).trim() : trimmed;
    const equals = normalized.indexOf("=");
    if (equals <= 0) continue;
    const key = normalized.slice(0, equals).trim();
    let value = normalized.slice(equals + 1).trim();
    if ((value.startsWith('"') && value.endsWith('"')) || (value.startsWith("'") && value.endsWith("'"))) {
      value = value.slice(1, -1);
    }
    if (!process.env[key]) process.env[key] = value;
  }
}

async function closeAndExit(code) {
  for (const entry of agentCache.values()) {
    try {
      entry.agent.close();
    } catch {}
  }
  server.close(() => process.exit(code));
  setTimeout(() => process.exit(code), 500).unref();
}
