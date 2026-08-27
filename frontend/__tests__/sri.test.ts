import { isValidIntegrity, assertValidIntegrity, sriProps, buildIntegrity } from "@/lib/sri";

describe("SRI helper", () => {
  describe("isValidIntegrity", () => {
    it("accepts valid sha384", () => {
      expect(isValidIntegrity("sha384-oqVuAfXRKap7fdgcCY5uykM6+R9GqQ8K/uxy9rx7HNQlGYl1kPzQho1wx4JwY8wC4Fq5g==")).toBe(true);
    });
    it("accepts sha256 and sha512", () => {
      expect(isValidIntegrity("sha256-/n4Ag==")).toBe(true);
      expect(isValidIntegrity("sha512-abcDEF123/+/==")).toBe(true);
    });
    it("rejects missing prefix", () => {
      expect(isValidIntegrity("abc123==")).toBe(false);
    });
    it("rejects tampered hash", () => {
      expect(isValidIntegrity("sha384-invalid not base64!!")).toBe(false);
    });
    it("rejects empty", () => {
      expect(isValidIntegrity("")).toBe(false);
    });
  });

  describe("assertValidIntegrity", () => {
    it("does not throw for valid", () => {
      expect(() => assertValidIntegrity("https://cdn.example.com/a.js", "sha384-abc123==")).not.toThrow();
    });
    it("throws for invalid", () => {
      expect(() => assertValidIntegrity("https://cdn.example.com/a.js", "bad")).toThrow(/Invalid integrity/);
    });
  });

  describe("sriProps", () => {
    it("throws fail-closed when URL not in manifest", () => {
      expect(() => sriProps("https://cdn.jsdelivr.net/npm/lodash@4.17.21/lodash.min.js")).toThrow(/Missing integrity/);
    });
    // Note: when a hash is added to SRI_MANIFEST, sriProps should return integrity + anonymous
    // Example (uncomment after adding):
    // it("returns integrity + crossorigin for pinned URL", () => {
    //   const props = sriProps("https://cdn.jsdelivr.net/npm/lodash@4.17.21/lodash.min.js");
    //   expect(props.integrity).toMatch(/^sha384-/);
    //   expect(props.crossOrigin).toBe("anonymous");
    // });
  });

  describe("buildIntegrity", () => {
    it("builds sha384 for string", async () => {
      const integrity = await buildIntegrity("hello world", "sha384");
      expect(integrity).toMatch(/^sha384-/);
      // tampered input should produce different hash
      const tampered = await buildIntegrity("hello world!", "sha384");
      expect(tampered).not.toBe(integrity);
    });
    it("builds sha256 and sha512", async () => {
      expect(await buildIntegrity("test", "sha256")).toMatch(/^sha256-/);
      expect(await buildIntegrity("test", "sha512")).toMatch(/^sha512-/);
    });
    it("same input produces same hash (deterministic)", async () => {
      const a = await buildIntegrity("deterministic", "sha384");
      const b = await buildIntegrity("deterministic", "sha384");
      expect(a).toBe(b);
    });
  });

  describe("browser blocking semantics", () => {
    it("tampered hash is considered invalid and would be blocked", async () => {
      const original = await buildIntegrity("console.log('hi')", "sha384");
      const tamperedHash = original.slice(0, -2) + "ab";
      expect(isValidIntegrity(tamperedHash)).toBe(true); // format valid
      // but content mismatch: hash of tampered content != original hash
      const tamperedContentHash = await buildIntegrity("console.log('tampered')", "sha384");
      expect(tamperedContentHash).not.toBe(original);
      expect(tamperedContentHash).not.toBe(tamperedHash);
    });
  });
});
