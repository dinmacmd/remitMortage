#!/usr/bin/env node
import fs from "node:fs";
import path from "node:path";
import process from "node:process";

const DEFAULT_SCOPE = "@remitmortgage";
const DEFAULT_REGISTRY = "https://npm.pkg.github.com/";
const SKIP_DIRS = new Set([".git", "node_modules", "dist", "build", "coverage", ".next", "target"]);
const DEPENDENCY_FIELDS = ["dependencies", "devDependencies", "peerDependencies", "optionalDependencies"];

function normalizeRegistry(url) {
  return url.endsWith("/") ? url : `${url}/`;
}

function readJson(filePath) {
  return JSON.parse(fs.readFileSync(filePath, "utf8"));
}

function walkForFiles(rootDir, fileName) {
  const matches = [];
  const entries = fs.readdirSync(rootDir, { withFileTypes: true });

  for (const entry of entries) {
    const fullPath = path.join(rootDir, entry.name);
    if (entry.isDirectory()) {
      if (!SKIP_DIRS.has(entry.name)) {
        matches.push(...walkForFiles(fullPath, fileName));
      }
      continue;
    }
    if (entry.isFile() && entry.name === fileName) {
      matches.push(fullPath);
    }
  }

  return matches;
}

function npmrcPinsScope(repoRoot, scope, registry) {
  const npmrcPath = path.join(repoRoot, ".npmrc");
  if (!fs.existsSync(npmrcPath)) {
    return false;
  }

  const expected = `${scope}:registry=${normalizeRegistry(registry).replace(/\/$/, "")}`;
  return fs
    .readFileSync(npmrcPath, "utf8")
    .split(/\r?\n/)
    .map((line) => line.trim())
    .some((line) => line === expected || line === `${expected}/`);
}

function dependencyNames(pkg) {
  const names = [];
  for (const field of DEPENDENCY_FIELDS) {
    const deps = pkg[field] ?? {};
    names.push(...Object.keys(deps));
  }
  return names;
}

function lockPackageNameFromPath(packagePath) {
  const parts = packagePath.split("node_modules/");
  return parts.length > 1 ? parts[parts.length - 1] : null;
}

export function validateRepo(repoRoot, options = {}) {
  const scope = options.scope ?? process.env.INTERNAL_NPM_SCOPE ?? DEFAULT_SCOPE;
  const registry = normalizeRegistry(options.registry ?? process.env.INTERNAL_NPM_REGISTRY ?? DEFAULT_REGISTRY);
  const errors = [];

  if (!scope.startsWith("@") || scope.includes("/")) {
    errors.push(`Internal scope must look like @org. Received: ${scope}`);
  }

  if (!npmrcPinsScope(repoRoot, scope, registry)) {
    errors.push(`.npmrc must pin ${scope} packages to ${registry}`);
  }

  for (const packageJsonPath of walkForFiles(repoRoot, "package.json")) {
    const pkg = readJson(packageJsonPath);
    const rel = path.relative(repoRoot, packageJsonPath);

    if (pkg.private === true && typeof pkg.name === "string" && !pkg.name.startsWith(`${scope}/`)) {
      errors.push(`${rel} is private/internal but package name is not scoped as ${scope}/*: ${pkg.name}`);
    }

    for (const depName of dependencyNames(pkg)) {
      if (depName.startsWith("remitmortgage-") || depName === "frontend" || depName === "backend") {
        errors.push(`${rel} references unscoped internal-looking dependency ${depName}; use ${scope}/*`);
      }
    }
  }

  for (const lockfilePath of walkForFiles(repoRoot, "package-lock.json")) {
    const lock = readJson(lockfilePath);
    const rel = path.relative(repoRoot, lockfilePath);
    const packages = lock.packages ?? {};

    for (const [packagePath, metadata] of Object.entries(packages)) {
      const packageName = packagePath === "" ? metadata.name : lockPackageNameFromPath(packagePath);
      if (!packageName?.startsWith(`${scope}/`)) {
        continue;
      }

      if (packagePath === "") {
        continue;
      }

      const resolved = metadata.resolved;
      if (typeof resolved !== "string" || !resolved.startsWith(registry)) {
        errors.push(`${rel} resolves ${packageName} from unexpected registry: ${resolved ?? "<missing>"}`);
      }
    }
  }

  return errors;
}

if (import.meta.url === `file://${process.argv[1]}`) {
  const repoRoot = process.argv[2] ? path.resolve(process.argv[2]) : process.cwd();
  const errors = validateRepo(repoRoot);
  if (errors.length > 0) {
    console.error("Dependency confusion guard failed:");
    for (const error of errors) {
      console.error(`- ${error}`);
    }
    process.exit(1);
  }

  console.log("Dependency confusion guard passed: scoped package names and registry pins are valid.");
}
