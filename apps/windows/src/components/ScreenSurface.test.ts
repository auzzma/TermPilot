import { describe, it, expect } from "vitest";
import { decodeScreenFrame, keySym } from "./ScreenSurface";
describe("native VNC adapter", () => {
  it("decodes binary BGRX without base64 and preserves opaque alpha", () => {
    const header = new TextEncoder().encode(
      JSON.stringify({ width: 1, height: 1, pixelFormat: "bgrx" }),
    );
    const bytes = new Uint8Array(4 + header.length + 4);
    new DataView(bytes.buffer).setUint32(0, header.length);
    bytes.set(header, 4);
    bytes.set([3, 2, 1, 0], 4 + header.length);
    expect(Array.from(decodeScreenFrame(bytes.buffer)!.rgba)).toEqual([
      1, 2, 3, 255,
    ]);
  });
  it("rejects truncated and oversized frames", () => {
    const bytes = new Uint8Array(8);
    new DataView(bytes.buffer).setUint32(0, 65537);
    expect(() => decodeScreenFrame(bytes.buffer)).toThrow();
  });
  it("maps modifiers, function keys and unicode", () => {
    expect(keySym("Control")).toBe(0xffe3);
    expect(keySym("F1")).toBe(0xffbe);
    expect(keySym("中")).toBe(0x1004e2d);
    expect(keySym("Unidentified")).toBe(0);
  });
});
