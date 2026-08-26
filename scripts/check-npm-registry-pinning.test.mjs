import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { validateRepo } from "./check-npm-registry-pinning.mjs";

function writeJson(filePath, value) {
  fs.mkdirSync(path.dirname(filePath), { recursive: true });
  fs.writeFileSync(filePath, JSON.stringify(value, null, 2));
}

function makeRepo() {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "registry-pinning-"));
  fs.writeFileSync(path.join(dir, ".npmrc"), "@remitmortgage:registry=https://npm.pkg.github.com\n");
  writeJson(path.join(dir, "backend", "package.json"), {
    name: "@remitmortgage/backend",
    private: true,
    version: "0.1.0",
    dependencies: { "@remitmortgage/shared": "^1.0.0" },
  });
  writeJson(path.join(dir, "backend", "package-lock.json"), {
    name: "@remitmortgage/backend",
    lockfileVersion: 3,
    packages: {
      "": { name: "@remitmortgage/backend", version: "0.1.0" },
      "node_modules/@remitmortgage/shared": {
        version: "1.0.0",
        resolved: "https://npm.pkg.github.com/@remitmortgage/shared/-/shared-1.0.0.tgz",
      },
    },
  });
  return dir;
}

test("accepts scoped private package names and pinned internal registry", () => {
  const repo = makeRepo();
  assert.deepEqual(validateRepo(repo), []);
});

test("rejects a manipulated lockfile resolving internal scope from public npm", () => {
  const repo = makeRepo();
  const lockPath = path.join(repo, "backend", "package-lock.json");
  const lock = JSON.parse(fs.readFileSync(lockPath, "utf8"));
  lock.packages["node_modules/@remitmortgage/shared"].resolved =
    "https://registry.npmjs.org/@remitmortgage/shared/-/shared-1.0.0.tgz";
  writeJson(lockPath, lock);

  const errors = validateRepo(repo);
  assert.equal(errors.length, 1);
  assert.match(errors[0], /unexpected registry/);
});

test("rejects unscoped private package names", () => {
  const repo = makeRepo();
  writeJson(path.join(repo, "frontend", "package.json"), {
    name: "frontend",
    private: true,
    version: "0.1.0",
  });

  const errors = validateRepo(repo);
  assert(errors.some((error) => error.includes("not scoped")));
});
