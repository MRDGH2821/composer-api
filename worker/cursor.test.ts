import { describe, expect, it } from "vitest";
import { streamCursorText } from "./cursor";
import { encodeSse } from "./sse";

describe("Cursor stream adapter", () => {
  it("extracts final text from raw Cursor adapter Connect/protobuf frames", async () => {
    const response = new Response(
      new ReadableStream<Uint8Array>({
        start(controller) {
          controller.enqueue(connectFrame(chatResponseText("Hello")));
          controller.enqueue(connectFrame(chatResponseText(" from Composer")));
          controller.enqueue(connectFrame(new TextEncoder().encode("{}"), 2));
          controller.close();
        }
      }),
      { headers: { "Content-Type": "application/connect+proto" } }
    );
    const events = [];
    for await (const event of streamCursorText(response)) events.push(event);
    expect(events).toEqual([
      { type: "text", text: "Hello" },
      { type: "text", text: " from Composer" },
      { type: "done", finalText: "Hello from Composer" }
    ]);
  });

  it("strips Composer thinking before yielding final Cursor adapter text", async () => {
    const response = new Response(
      new ReadableStream<Uint8Array>({
        start(controller) {
          controller.enqueue(connectFrame(chatResponseThinking('The user asked for OK.')));
          controller.enqueue(connectFrame(chatResponseThinking("\n</think>\nOK")));
          controller.enqueue(connectFrame(new TextEncoder().encode("{}"), 2));
          controller.close();
        }
      }),
      { headers: { "Content-Type": "application/connect+proto" } }
    );
    const events = [];
    for await (const event of streamCursorText(response)) events.push(event);
    expect(events).toEqual([
      { type: "text", text: "OK" },
      { type: "done", finalText: "OK" }
    ]);
  });

  it("strips Composer final markers when there is no think closing tag", async () => {
    const response = new Response(
      new ReadableStream<Uint8Array>({
        start(controller) {
          controller.enqueue(connectFrame(chatResponseThinking("Hidden reasoning <｜final｜>Visible answer")));
          controller.enqueue(connectFrame(new TextEncoder().encode("{}"), 2));
          controller.close();
        }
      }),
      { headers: { "Content-Type": "application/connect+proto" } }
    );
    const events = [];
    for await (const event of streamCursorText(response)) events.push(event);
    expect(events).toEqual([
      { type: "text", text: "Visible answer" },
      { type: "done", finalText: "Visible answer" }
    ]);
  });

  it("strips Composer final markers from normal text frames", async () => {
    const response = new Response(
      new ReadableStream<Uint8Array>({
        start(controller) {
          controller.enqueue(connectFrame(chatResponseText("Hidden reasoning <｜final｜>\nVisible answer")));
          controller.enqueue(connectFrame(chatResponseText("< | final | >Second answer")));
          controller.enqueue(connectFrame(new TextEncoder().encode("{}"), 2));
          controller.close();
        }
      }),
      { headers: { "Content-Type": "application/connect+proto" } }
    );
    const events = [];
    for await (const event of streamCursorText(response)) events.push(event);
    expect(events).toEqual([
      { type: "text", text: "Visible answer" },
      { type: "text", text: "Second answer" },
      { type: "done", finalText: "Visible answerSecond answer" }
    ]);
  });

  it("surfaces detailed Cursor end-stream errors", async () => {
    const response = new Response(
      new ReadableStream<Uint8Array>({
        start(controller) {
          controller.enqueue(connectFrame(cursorError("Too many computers.", "Too many computers used within the last 24 hours."), 2));
          controller.close();
        }
      }),
      { headers: { "Content-Type": "application/connect+proto" } }
    );
    await expect(async () => {
      for await (const _event of streamCursorText(response)) {
        // Drain stream.
      }
    }).rejects.toThrow("Too many computers used within the last 24 hours");
  });

  it("extracts text deltas from Cursor interaction_update events", async () => {
    const response = new Response(
      new ReadableStream<Uint8Array>({
        start(controller) {
          controller.enqueue(encodeSse({ type: "text-delta", text: "Hello" }, "interaction_update"));
          controller.enqueue(encodeSse({ type: "text-delta", text: " world" }, "interaction_update"));
          controller.enqueue(encodeSse({ status: "FINISHED", result: "Hello world" }, "result"));
          controller.close();
        }
      })
    );
    const events = [];
    for await (const event of streamCursorText(response)) events.push(event);
    expect(events).toEqual([
      { type: "text", text: "Hello" },
      { type: "text", text: " world" },
      { type: "done", finalText: "Hello world" }
    ]);
  });

  it("falls back to legacy assistant events", async () => {
    const response = new Response(
      new ReadableStream<Uint8Array>({
        start(controller) {
          controller.enqueue(encodeSse({ text: "Legacy text" }, "assistant"));
          controller.enqueue(encodeSse({ status: "FINISHED" }, "result"));
          controller.close();
        }
      })
    );
    const events = [];
    for await (const event of streamCursorText(response)) events.push(event);
    expect(events.at(-1)).toEqual({ type: "done", finalText: "Legacy text" });
  });
});

function chatResponseText(text: string): Uint8Array {
  return protoMessage([protoField(2, protoMessage([protoField(1, text)]))]);
}

function chatResponseThinking(text: string): Uint8Array {
  return protoMessage([protoField(2, protoMessage([protoField(25, protoMessage([protoField(1, text)]))]))]);
}

function connectFrame(payload: Uint8Array, flags = 0): Uint8Array {
  const frame = new Uint8Array(5 + payload.length);
  frame[0] = flags;
  new DataView(frame.buffer).setUint32(1, payload.length, false);
  frame.set(payload, 5);
  return frame;
}

function cursorError(title: string, detail: string): Uint8Array {
  return new TextEncoder().encode(
    JSON.stringify({
      error: {
        code: "resource_exhausted",
        message: "Error",
        details: [{ debug: { details: { title, detail } } }]
      }
    })
  );
}

function protoMessage(parts: Uint8Array[]): Uint8Array {
  const total = parts.reduce((sum, part) => sum + part.length, 0);
  const output = new Uint8Array(total);
  let offset = 0;
  for (const part of parts) {
    output.set(part, offset);
    offset += part.length;
  }
  return output;
}

function protoField(fieldNumber: number, value: string | Uint8Array): Uint8Array {
  const data = typeof value === "string" ? new TextEncoder().encode(value) : value;
  return protoMessage([varint((fieldNumber << 3) | 2), varint(data.length), data]);
}

function varint(value: number): Uint8Array {
  const bytes: number[] = [];
  let current = value;
  while (current >= 0x80) {
    bytes.push((current & 0x7f) | 0x80);
    current >>>= 7;
  }
  bytes.push(current);
  return new Uint8Array(bytes);
}
