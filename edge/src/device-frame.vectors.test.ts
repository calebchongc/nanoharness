import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";
import { decodeDeviceFrame, encodeDeviceFrame, NUDGE_KIND, type DeviceFrameHeader } from "./device-room";

/** The relay's half of the device-room frame vectors
 * (`protocol/device-frame-vectors.json`, also run by the Zig engine). The
 * relay treats a frame header as opaque JSON, so `typedOnly` rejects (headers
 * a typed decoder refuses) pass through it; URL and bearer rules are dialer
 * rules and are not checked here. */

interface Vectors {
  kinds: Record<string, string>;
  relayErrors: string[];
  encode: { name: string; header: DeviceFrameHeader; payloadHex: string; bytesHex: string }[];
  decodeRejects: { name: string; bytesHex: string; typedOnly?: boolean }[];
  decodeAccepts: { name: string; bytesHex: string; header: DeviceFrameHeader; payloadHex: string }[];
}

const vectors: Vectors = JSON.parse(
  readFileSync(fileURLToPath(new URL("../../protocol/device-frame-vectors.json", import.meta.url).href), "utf8")
);

const hex = (s: string): Uint8Array => Uint8Array.from(s.match(/../g) ?? [], (b) => parseInt(b, 16));

/** The routing-relevant header fields; the relay keeps any others verbatim. */
const routing = (h: DeviceFrameHeader) => ({ s: h.s, k: h.k, to: h.to, from: h.from });

describe("device frame conformance vectors", () => {
  it("uses the same frame kinds", () => {
    expect(NUDGE_KIND).toBe(vectors.kinds.nudge);
    // RELAY_KIND is module-private; its bytes are pinned by the relay control
    // frames in `encode` below.
    expect(vectors.kinds.relay).toBe(" relay");
  });

  for (const c of vectors.encode) {
    it(`encodes exact bytes: ${c.name}`, () => {
      const bytes = encodeDeviceFrame(c.header, hex(c.payloadHex));
      expect([...bytes]).toEqual([...hex(c.bytesHex)]);
      const frame = decodeDeviceFrame(bytes);
      expect(routing(frame.header)).toEqual(routing(c.header));
      expect([...frame.payload]).toEqual([...hex(c.payloadHex)]);
    });
  }

  for (const c of vectors.decodeRejects) {
    it(`${c.typedOnly ? "passes through (typed decoders reject)" : "rejects"}: ${c.name}`, () => {
      if (c.typedOnly) {
        expect(() => decodeDeviceFrame(hex(c.bytesHex))).not.toThrow();
        return;
      }
      expect(() => decodeDeviceFrame(hex(c.bytesHex))).toThrow();
    });
  }

  for (const c of vectors.decodeAccepts) {
    it(`accepts: ${c.name}`, () => {
      const frame = decodeDeviceFrame(hex(c.bytesHex));
      expect(routing(frame.header)).toEqual(routing(c.header));
      expect([...frame.payload]).toEqual([...hex(c.payloadHex)]);
    });
  }

  it("relay control payloads are {error: code} for every code", () => {
    for (const code of vectors.relayErrors) {
      const payload = new TextEncoder().encode(JSON.stringify({ error: code }));
      expect(new TextDecoder().decode(payload)).toBe(`{"error":"${code}"}`);
    }
  });
});
