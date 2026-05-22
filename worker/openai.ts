import { HttpError } from "./http";
import { encodeSse } from "./sse";
import type { CursorImage, CursorPrompt, CursorToolCall } from "./types";

export type ApiKind = "chat" | "responses";

export interface PreparedRequest {
  model: string;
  cursorModel?: { id: string };
  prompt: CursorPrompt;
  stream: boolean;
  promptChars: number;
  responseMetadata: Record<string, unknown>;
  tools: OpenAiToolSpec[];
}

export interface OpenAiToolSpec {
  name: string;
  description?: string;
  parameters?: unknown;
}

export interface OpenAiToolCall {
  id: string;
  type: "function";
  function: {
    name: string;
    arguments: string;
  };
}

const SYSTEM_DIRECTIVE = [
  "You are serving an OpenAI-compatible API request through Cursor Composer.",
  "Answer the user directly in chat style.",
  "Do not modify files, run terminal commands, open pull requests, or use coding-agent workflow unless the user explicitly asks for code as text.",
  "Return only the final answer content."
].join("\n");

const TOOL_SYSTEM_DIRECTIVE = [
  "You are serving an OpenAI-compatible API request through Cursor Composer.",
  "Answer directly when no tool is needed.",
  "When a provided tool is needed, call it using Cursor Composer's tool-call marker protocol and do not describe the marker as prose."
].join("\n");

export function prepareChatRequest(body: unknown, cursorModel: { id: string } | undefined): PreparedRequest {
  const record = expectRecord(body, "body");
  const messages = expectArray(record.messages, "messages");
  validateCommonUnsupported(record);
  if (record.functions !== undefined) {
    throw new HttpError("Legacy function calling is not supported by this adapter.", 400, "unsupported_parameter", "functions");
  }

  const tools = record.tool_choice === "none" ? [] : parseChatTools(record.tools);
  const model = typeof record.model === "string" && record.model.trim() ? record.model.trim() : "composer-2.5";
  const transcript: string[] = [tools.length ? TOOL_SYSTEM_DIRECTIVE : SYSTEM_DIRECTIVE];
  appendChatTools(transcript, tools, record.tool_choice);
  transcript.push("", "Conversation:");
  const images: CursorImage[] = [];
  for (const message of messages) {
    const item = expectRecord(message, "messages[]");
    const role = typeof item.role === "string" ? item.role : "user";
    const { text, images: messageImages } = contentToTextAndImages(item.content, role);
    images.push(...messageImages);
    if (role === "tool") {
      const toolCallId = typeof item.tool_call_id === "string" ? item.tool_call_id : "";
      const toolName = typeof item.name === "string" ? item.name : "";
      const label = [toolName ? `name=${toolName}` : "", toolCallId ? `tool_call_id=${toolCallId}` : ""].filter(Boolean).join(" ");
      transcript.push(`TOOL RESULT${label ? ` (${label})` : ""}: ${text || "[empty]"}`);
    } else {
      transcript.push(`${role.toUpperCase()}: ${text || "[empty]"}`);
    }
    if (Array.isArray(item.tool_calls)) {
      transcript.push(`${role.toUpperCase()} TOOL_CALLS: ${JSON.stringify(item.tool_calls)}`);
    }
  }
  appendChatOptions(transcript, record);
  const text = transcript.join("\n");
  return {
    model,
    cursorModel,
    prompt: { text, ...(images.length ? { images } : {}) },
    stream: record.stream === true,
    promptChars: text.length,
    responseMetadata: {
      temperature: numberOrNull(record.temperature),
      top_p: numberOrNull(record.top_p)
    },
    tools
  };
}

export function prepareResponsesRequest(body: unknown, cursorModel: { id: string } | undefined): PreparedRequest {
  const record = expectRecord(body, "body");
  validateCommonUnsupported(record);
  if (Array.isArray(record.tools) && record.tools.length > 0) {
    throw new HttpError("OpenAI Responses tools are not supported by this Cursor adapter.", 400, "unsupported_parameter", "tools");
  }
  if (record.background === true) {
    throw new HttpError("background responses are not supported.", 400, "unsupported_parameter", "background");
  }

  const model = typeof record.model === "string" && record.model.trim() ? record.model.trim() : "composer-2.5";
  const transcript: string[] = [SYSTEM_DIRECTIVE];
  const instructions = typeof record.instructions === "string" ? record.instructions.trim() : "";
  if (instructions) transcript.push("", `INSTRUCTIONS:\n${instructions}`);
  transcript.push("", "INPUT:");
  const { text, images } = responseInputToTextAndImages(record.input);
  transcript.push(text || "[empty]");
  appendResponseOptions(transcript, record);
  const prompt = transcript.join("\n");
  return {
    model,
    cursorModel,
    prompt: { text: prompt, ...(images.length ? { images } : {}) },
    stream: record.stream === true,
    promptChars: prompt.length,
    responseMetadata: {
      instructions: instructions || null,
      max_output_tokens: integerOrNull(record.max_output_tokens),
      temperature: numberOrNull(record.temperature),
      top_p: numberOrNull(record.top_p),
      text: isRecord(record.text) ? record.text : { format: { type: "text" } }
    },
    tools: []
  };
}

export function chatCompletionResponse(input: {
  id: string;
  created: number;
  model: string;
  text: string;
  toolCalls?: OpenAiToolCall[];
  promptChars: number;
  metadata?: Record<string, unknown>;
}): Record<string, unknown> {
  const toolCalls = input.toolCalls ?? [];
  const completionChars = input.text.length + serializedToolCallLength(toolCalls);
  return {
    id: input.id,
    object: "chat.completion",
    created: input.created,
    model: input.model,
    choices: [
      {
        index: 0,
        message: {
          role: "assistant",
          content: toolCalls.length && !input.text ? null : input.text,
          ...(toolCalls.length ? { tool_calls: toolCalls } : {}),
          refusal: null,
          annotations: []
        },
        logprobs: null,
        finish_reason: toolCalls.length ? "tool_calls" : "stop"
      }
    ],
    usage: usageFromChars(input.promptChars, completionChars),
    service_tier: "default",
    system_fingerprint: null,
    ...input.metadata
  };
}

export function responseObject(input: {
  id: string;
  created: number;
  model: string;
  text: string;
  toolCalls?: OpenAiToolCall[];
  promptChars: number;
  metadata?: Record<string, unknown>;
}): Record<string, unknown> {
  const messageId = `msg_${input.id.slice(5)}`;
  const output: Record<string, unknown>[] = [];
  if (input.text || !input.toolCalls?.length) {
    output.push({
      id: messageId,
      type: "message",
      status: "completed",
      role: "assistant",
      content: [
        {
          type: "output_text",
          text: input.text,
          annotations: []
        }
      ]
    });
  }
  for (const [index, toolCall] of (input.toolCalls ?? []).entries()) {
    output.push({
      id: `fc_${input.id.slice(5)}_${index}`,
      type: "function_call",
      status: "completed",
      call_id: toolCall.id,
      name: toolCall.function.name,
      arguments: toolCall.function.arguments
    });
  }
  const outputChars = input.text.length + serializedToolCallLength(input.toolCalls ?? []);
  return {
    id: input.id,
    object: "response",
    created_at: input.created,
    status: "completed",
    completed_at: Math.max(input.created, Math.floor(Date.now() / 1000)),
    error: null,
    incomplete_details: null,
    model: input.model,
    output,
    parallel_tool_calls: true,
    previous_response_id: null,
    reasoning: { effort: null, summary: null },
    store: false,
    tool_choice: "auto",
    tools: [],
    truncation: "disabled",
    usage: responseUsageFromChars(input.promptChars, outputChars),
    user: null,
    metadata: {},
    ...input.metadata
  };
}

export function chatChunk(input: {
  id: string;
  created: number;
  model: string;
  delta?: string;
  role?: "assistant";
  toolCall?: { index: number; value: OpenAiToolCall };
  finish?: boolean;
  finishReason?: "stop" | "tool_calls";
}): Uint8Array {
  const delta = input.finish
    ? {}
    : {
        ...(input.role ? { role: input.role } : {}),
        ...(input.delta ? { content: input.delta } : {}),
        ...(input.toolCall
          ? {
              tool_calls: [
                {
                  index: input.toolCall.index,
                  id: input.toolCall.value.id,
                  type: input.toolCall.value.type,
                  function: input.toolCall.value.function
                }
              ]
            }
          : {})
      };
  const chunk = {
    id: input.id,
    object: "chat.completion.chunk",
    created: input.created,
    model: input.model,
    system_fingerprint: null,
    choices: [
      {
        index: 0,
        delta,
        logprobs: null,
        finish_reason: input.finish ? input.finishReason || "stop" : null
      }
    ]
  };
  return encodeSse(chunk);
}

export function doneChunk(): Uint8Array {
  return encodeSse("[DONE]");
}

export function responseCreatedEvents(input: { id: string; created: number; model: string; metadata?: Record<string, unknown> }): Uint8Array[] {
  const base = {
    id: input.id,
    object: "response",
    created_at: input.created,
    status: "in_progress",
    error: null,
    incomplete_details: null,
    model: input.model,
    output: [],
    parallel_tool_calls: true,
    previous_response_id: null,
    reasoning: { effort: null, summary: null },
    store: false,
    tool_choice: "auto",
    tools: [],
    truncation: "disabled",
    usage: null,
    user: null,
    metadata: {},
    ...input.metadata
  };
  const item = {
    id: `msg_${input.id.slice(5)}`,
    type: "message",
    status: "in_progress",
    role: "assistant",
    content: []
  };
  return [
    encodeSse({ type: "response.created", response: base }, "response.created"),
    encodeSse({ type: "response.in_progress", response: base }, "response.in_progress"),
    encodeSse({ type: "response.output_item.added", output_index: 0, item }, "response.output_item.added"),
    encodeSse(
      {
        type: "response.content_part.added",
        item_id: item.id,
        output_index: 0,
        content_index: 0,
        part: { type: "output_text", text: "", annotations: [] }
      },
      "response.content_part.added"
    )
  ];
}

export function responseDeltaEvent(input: { id: string; delta: string }): Uint8Array {
  return encodeSse(
    {
      type: "response.output_text.delta",
      item_id: `msg_${input.id.slice(5)}`,
      output_index: 0,
      content_index: 0,
      delta: input.delta
    },
    "response.output_text.delta"
  );
}

export function responseDoneEvents(input: {
  id: string;
  created: number;
  model: string;
  text: string;
  toolCalls?: OpenAiToolCall[];
  promptChars: number;
  metadata?: Record<string, unknown>;
}): Uint8Array[] {
  const itemId = `msg_${input.id.slice(5)}`;
  const part = { type: "output_text", text: input.text, annotations: [] };
  const item = { id: itemId, type: "message", status: "completed", role: "assistant", content: [part] };
  return [
    encodeSse(
      { type: "response.output_text.done", item_id: itemId, output_index: 0, content_index: 0, text: input.text },
      "response.output_text.done"
    ),
    encodeSse(
      { type: "response.content_part.done", item_id: itemId, output_index: 0, content_index: 0, part },
      "response.content_part.done"
    ),
    encodeSse({ type: "response.output_item.done", output_index: 0, item }, "response.output_item.done"),
    encodeSse(
      { type: "response.completed", response: responseObject(input) },
      "response.completed"
    )
  ];
}

export function modelList(): Record<string, unknown> {
  return {
    object: "list",
    data: [
      modelItem("default", "Auto"),
      modelItem("composer-2.5", "Cursor Composer 2.5"),
      modelItem("composer-2.5-fast", "Cursor Composer 2.5 Fast"),
      modelItem("composer-2", "Cursor Composer 2"),
      modelItem("composer-latest", "Cursor Composer latest alias"),
      modelItem("gpt-5.3-codex", "Codex 5.3"),
      modelItem("gpt-5.2-codex", "Codex 5.2"),
      modelItem("gpt-5.1-codex-max", "Codex 5.1 Max"),
      modelItem("gpt-5.1-codex-mini", "Codex 5.1 Mini"),
      modelItem("gpt-5.2", "GPT-5.2"),
      modelItem("gpt-5.1", "GPT-5.1"),
      modelItem("gpt-5-mini", "GPT-5 Mini"),
      modelItem("gemini-3.1-pro", "Gemini 3.1 Pro"),
      modelItem("gemini-3.5-flash", "Gemini 3.5 Flash"),
      modelItem("gemini-3-flash", "Gemini 3 Flash"),
      modelItem("gemini-2.5-flash", "Gemini 2.5 Flash"),
      modelItem("grok-build-0.1", "Grok Build 0.1"),
      modelItem("grok-4.3", "Grok 4.3"),
      modelItem("kimi-k2.5", "Kimi K2.5")
    ]
  };
}

export function toOpenAiToolCalls(input: {
  toolCalls: CursorToolCall[];
  tools?: OpenAiToolSpec[];
  responseId: string;
  startIndex?: number;
}): OpenAiToolCall[] {
  return input.toolCalls.map((toolCall, offset) => {
    const index = (input.startIndex ?? 0) + offset;
    const name = resolveToolName(toolCall.name, input.tools ?? []);
    return {
      id: `call_${input.responseId.replace(/[^A-Za-z0-9]/g, "").slice(-18)}_${index}`,
      type: "function",
      function: {
        name,
        arguments: JSON.stringify(toolCall.arguments ?? {})
      }
    };
  });
}

function modelItem(id: string, name: string) {
  return {
    id,
    object: "model",
    created: 1779148800,
    owned_by: "cursor",
    name
  };
}

function parseChatTools(value: unknown): OpenAiToolSpec[] {
  if (value === undefined) return [];
  if (!Array.isArray(value)) throw new HttpError("tools must be an array.", 400, "invalid_request_error", "tools");
  return value.map((tool, index) => {
    const record = expectRecord(tool, `tools[${index}]`);
    if (record.type !== "function") {
      throw new HttpError("Only function tools are supported.", 400, "unsupported_parameter", `tools[${index}].type`);
    }
    const fn = expectRecord(record.function, `tools[${index}].function`);
    if (typeof fn.name !== "string" || !fn.name.trim()) {
      throw new HttpError("Tool function name is required.", 400, "invalid_request_error", `tools[${index}].function.name`);
    }
    return {
      name: fn.name.trim(),
      ...(typeof fn.description === "string" ? { description: fn.description } : {}),
      ...(fn.parameters !== undefined ? { parameters: fn.parameters } : {})
    };
  });
}

function appendChatTools(transcript: string[], tools: OpenAiToolSpec[], toolChoice: unknown) {
  if (!tools.length) return;
  transcript.push(
    "",
    "TOOLS:",
    "The client can execute these tools. If a tool is needed, emit a Cursor Composer tool-call block instead of prose."
  );
  for (const tool of tools) {
    transcript.push(`- ${tool.name}${tool.description ? `: ${tool.description}` : ""}`);
    if (tool.parameters !== undefined) transcript.push(`  parameters: ${JSON.stringify(tool.parameters)}`);
  }
  if (isRecord(toolChoice) && toolChoice.type === "function" && isRecord(toolChoice.function) && typeof toolChoice.function.name === "string") {
    transcript.push(`Use the ${toolChoice.function.name} tool if you call a tool.`);
  } else if (toolChoice === "required") {
    transcript.push("You must call at least one tool.");
  }
}

function validateCommonUnsupported(record: Record<string, unknown>) {
  if (typeof record.n === "number" && record.n !== 1) {
    throw new HttpError("Only n=1 is supported.", 400, "unsupported_parameter", "n");
  }
  if (record.logprobs === true || record.top_logprobs !== undefined) {
    throw new HttpError("logprobs are not available through Cursor's API.", 400, "unsupported_parameter", "logprobs");
  }
  if (Array.isArray(record.modalities) && record.modalities.some((value) => value !== "text")) {
    throw new HttpError("Only text output is supported.", 400, "unsupported_parameter", "modalities");
  }
  if (record.audio !== undefined) {
    throw new HttpError("Audio output is not supported.", 400, "unsupported_parameter", "audio");
  }
}

function appendChatOptions(transcript: string[], record: Record<string, unknown>) {
  const constraints: string[] = [];
  const maxTokens = integerOrNull(record.max_completion_tokens ?? record.max_tokens);
  if (maxTokens) constraints.push(`Keep the answer within about ${maxTokens} output tokens.`);
  appendStopConstraint(constraints, record.stop);
  appendJsonConstraint(constraints, record.response_format);
  if (constraints.length) transcript.push("", "OUTPUT CONSTRAINTS:", ...constraints.map((item) => `- ${item}`));
}

function appendResponseOptions(transcript: string[], record: Record<string, unknown>) {
  const constraints: string[] = [];
  const maxTokens = integerOrNull(record.max_output_tokens);
  if (maxTokens) constraints.push(`Keep the answer within about ${maxTokens} output tokens.`);
  appendStopConstraint(constraints, record.stop);
  const text = isRecord(record.text) ? record.text : undefined;
  appendJsonConstraint(constraints, text?.format);
  if (constraints.length) transcript.push("", "OUTPUT CONSTRAINTS:", ...constraints.map((item) => `- ${item}`));
}

function appendStopConstraint(constraints: string[], stop: unknown) {
  if (typeof stop === "string") constraints.push(`Do not include text after this stop sequence: ${stop}`);
  else if (Array.isArray(stop) && stop.length) constraints.push(`Stop before any of these sequences: ${stop.join(", ")}`);
}

function appendJsonConstraint(constraints: string[], format: unknown) {
  if (!isRecord(format)) return;
  if (format.type === "json_object") constraints.push("Return a single valid JSON object and no surrounding prose.");
  if (format.type === "json_schema") {
    const schema = isRecord(format.json_schema) ? format.json_schema.schema : format.schema;
    constraints.push(`Return JSON that matches this schema: ${JSON.stringify(schema ?? format)}`);
  }
}

function responseInputToTextAndImages(input: unknown): { text: string; images: CursorImage[] } {
  if (typeof input === "string") return { text: input, images: [] };
  if (!Array.isArray(input)) return { text: input === undefined ? "" : JSON.stringify(input), images: [] };
  const lines: string[] = [];
  const images: CursorImage[] = [];
  for (const item of input) {
    if (typeof item === "string") {
      lines.push(item);
      continue;
    }
    const record = expectRecord(item, "input[]");
    if (record.type === "message" || typeof record.role === "string") {
      const role = typeof record.role === "string" ? record.role : "user";
      const content = contentToTextAndImages(record.content, role);
      lines.push(`${role.toUpperCase()}: ${content.text || "[empty]"}`);
      images.push(...content.images);
    } else if (record.type === "function_call" || record.type === "function_call_output") {
      lines.push(`${String(record.type).toUpperCase()}: ${JSON.stringify(record)}`);
    } else {
      lines.push(JSON.stringify(record));
    }
  }
  return { text: lines.join("\n"), images };
}

function contentToTextAndImages(content: unknown, role: string): { text: string; images: CursorImage[] } {
  if (typeof content === "string") return { text: content, images: [] };
  if (content === null || content === undefined) return { text: "", images: [] };
  if (!Array.isArray(content)) return { text: JSON.stringify(content), images: [] };

  const parts: string[] = [];
  const images: CursorImage[] = [];
  for (const part of content) {
    if (typeof part === "string") {
      parts.push(part);
      continue;
    }
    if (!isRecord(part)) {
      parts.push(JSON.stringify(part));
      continue;
    }
    const type = part.type;
    if ((type === "text" || type === "input_text" || type === "output_text") && typeof part.text === "string") {
      parts.push(part.text);
    } else if (type === "image_url" && isRecord(part.image_url) && typeof part.image_url.url === "string") {
      images.push(imageFromUrl(part.image_url.url, part.image_url));
      parts.push("[image]");
    } else if (type === "input_image" && typeof part.image_url === "string") {
      images.push(imageFromUrl(part.image_url));
      parts.push("[image]");
    } else if (type === "input_image" && isRecord(part.image_url) && typeof part.image_url.url === "string") {
      images.push(imageFromUrl(part.image_url.url, part.image_url));
      parts.push("[image]");
    } else if (type === "tool_result" || type === "function_call_output") {
      parts.push(`${role} ${String(type)}: ${JSON.stringify(part)}`);
    } else {
      parts.push(JSON.stringify(part));
    }
  }
  return { text: parts.join("\n"), images };
}

function imageFromUrl(url: string, metadata?: Record<string, unknown>): CursorImage {
  const dimension =
    typeof metadata?.width === "number" &&
    typeof metadata.height === "number" &&
    Number.isFinite(metadata.width) &&
    Number.isFinite(metadata.height)
      ? { width: Math.round(metadata.width), height: Math.round(metadata.height) }
      : undefined;
  const dataUrl = /^data:([^;,]+);base64,(.+)$/i.exec(url);
  if (dataUrl) {
    return { mimeType: dataUrl[1], data: dataUrl[2], ...(dimension ? { dimension } : {}) };
  }
  return { url, ...(dimension ? { dimension } : {}) };
}

function usageFromChars(promptChars: number, completionChars: number) {
  const promptTokens = estimateTokens(promptChars);
  const completionTokens = estimateTokens(completionChars);
  return {
    prompt_tokens: promptTokens,
    completion_tokens: completionTokens,
    total_tokens: promptTokens + completionTokens,
    prompt_tokens_details: { cached_tokens: 0, audio_tokens: 0 },
    completion_tokens_details: {
      reasoning_tokens: 0,
      audio_tokens: 0,
      accepted_prediction_tokens: 0,
      rejected_prediction_tokens: 0
    }
  };
}

function responseUsageFromChars(inputChars: number, outputChars: number) {
  const inputTokens = estimateTokens(inputChars);
  const outputTokens = estimateTokens(outputChars);
  return {
    input_tokens: inputTokens,
    input_tokens_details: { cached_tokens: 0 },
    output_tokens: outputTokens,
    output_tokens_details: { reasoning_tokens: 0 },
    total_tokens: inputTokens + outputTokens
  };
}

function serializedToolCallLength(toolCalls: OpenAiToolCall[]): number {
  return toolCalls.reduce((sum, toolCall) => sum + toolCall.function.name.length + toolCall.function.arguments.length, 0);
}

function resolveToolName(emittedName: string, tools: OpenAiToolSpec[]): string {
  const exact = tools.find((tool) => tool.name === emittedName);
  if (exact) return exact.name;
  const normalized = normalizeToolName(emittedName);
  const match = tools.find((tool) => normalizeToolName(tool.name) === normalized);
  return match?.name ?? emittedName;
}

function normalizeToolName(value: string): string {
  return value.toLowerCase().replace(/[^a-z0-9]/g, "");
}

function estimateTokens(chars: number): number {
  return Math.max(1, Math.ceil(chars / 4));
}

function expectRecord(value: unknown, name: string): Record<string, unknown> {
  if (!isRecord(value)) throw new HttpError(`${name} must be an object`, 400, "invalid_request_error", name);
  return value;
}

function expectArray(value: unknown, name: string): unknown[] {
  if (!Array.isArray(value)) throw new HttpError(`${name} must be an array`, 400, "invalid_request_error", name);
  return value;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null;
}

function integerOrNull(value: unknown): number | null {
  return typeof value === "number" && Number.isInteger(value) ? value : null;
}

function numberOrNull(value: unknown): number | null {
  return typeof value === "number" && Number.isFinite(value) ? value : null;
}
