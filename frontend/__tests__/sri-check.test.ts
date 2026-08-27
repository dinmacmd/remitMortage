import { execSync } from "child_process";
import * as fs from "fs";
import * as path from "path";
import * as os from "os";

const FRONTEND_ROOT = path.resolve(__dirname, "..");
const REPO_ROOT = path.resolve(FRONTEND_ROOT, "..");
const CHECKER = path.resolve(REPO_ROOT, "scripts/check-sri.py");

function runChecker(tmpFrontend: string): { exitCode: number; output: string } {
  try {
    const out = execSync(`python "${CHECKER}" --frontend "${tmpFrontend}" 2>&1`, {
      encoding: "utf-8",
      cwd: REPO_ROOT,
    });
    return { exitCode: 0, output: out.toString() };
  } catch (e: any) {
    // Node's execSync error may have stdout/stderr as Buffer
    const stdout = (e.stdout as Buffer | string | undefined)?.toString() ?? "";
    const stderr = (e.stderr as Buffer | string | undefined)?.toString() ?? "";
    const output = stdout || stderr || (e.message as string) || "";
    const code = typeof e.status === "number" ? e.status : 1;
    return { exitCode: code, output };
  }
}

describe("SRI checker (scripts/check-sri.py)", () => {
  it("checker script exists and is executable", () => {
    expect(fs.existsSync(CHECKER)).toBe(true);
    const content = fs.readFileSync(CHECKER, "utf-8");
    expect(content).toContain("SRI violations");
  });

  it("passes on current frontend (no CDN script without SRI)", () => {
    try {
      execSync(`python "${CHECKER}" --frontend "${FRONTEND_ROOT}" 2>&1`, {
        encoding: "utf-8",
        cwd: REPO_ROOT,
      });
    } catch (e: any) {
      const out = e.stdout?.toString() || e.message;
      throw new Error(`Expected frontend to pass SRI check, but got violations:\n${out}`);
    }
  });

  it("fails when a new external script without integrity is added", () => {
    const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "sri-check-"));
    const tmpFrontend = path.join(tmp, "frontend");
    fs.mkdirSync(path.join(tmpFrontend, "src", "app"), { recursive: true });
    // Create a bad file
    fs.writeFileSync(
      path.join(tmpFrontend, "src", "app", "bad.tsx"),
      `export default function Bad(){ return <script src="https://cdn.jsdelivr.net/npm/lodash@4.17.21/lodash.min.js"></script> }`
    );
    const result = runChecker(tmpFrontend);
    expect(result.exitCode).toBe(1);
    expect(result.output).toMatch(/SRI violations|missing integrity/i);
    expect(result.output).toMatch(/cdn\.jsdelivr\.net/);
    fs.rmSync(tmp, { recursive: true, force: true });
  });

  it("passes when external script has integrity + crossorigin", () => {
    const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "sri-check-"));
    const tmpFrontend = path.join(tmp, "frontend");
    fs.mkdirSync(path.join(tmpFrontend, "src", "app"), { recursive: true });
    fs.writeFileSync(
      path.join(tmpFrontend, "src", "app", "good.tsx"),
      `export default function Good(){ return <script src="https://cdn.jsdelivr.net/npm/lodash@4.17.21/lodash.min.js" integrity="sha384-abc123==" crossorigin="anonymous"></script> }`
    );
    const result = runChecker(tmpFrontend);
    expect(result.exitCode).toBe(0);
    expect(result.output).toMatch(/No SRI violations/);
    fs.rmSync(tmp, { recursive: true, force: true });
  });

  it("passes when using sriProps helper", () => {
    const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "sri-check-"));
    const tmpFrontend = path.join(tmp, "frontend");
    fs.mkdirSync(path.join(tmpFrontend, "src", "app"), { recursive: true });
    fs.writeFileSync(
      path.join(tmpFrontend, "src", "app", "helper.tsx"),
      `import { sriProps } from "@/lib/sri"; const url="https://cdn.jsdelivr.net/npm/lodash@4.17.21/lodash.min.js"; export default function H(){ return <script src={url} {...sriProps(url)}></script> }`
    );
    const result = runChecker(tmpFrontend);
    // The helper file imports from sri and uses sriProps, so checker considers it compliant (does not flag dynamic JSX with sriProps)
    // For static string literal with sriProps spread, the tag itself contains sriProps, so it passes.
    // Our helper creates a dynamic src={url} without integrity on tag, but file contains sriProps — our checker currently
    // only passes if tag itself contains sriProps. Since <script src={url} {...sriProps(url)}> does contain sriProps in tag, it passes.
    // If it were <script src={url}> without sriProps, it would fail.
    expect(result.exitCode).toBe(0);
    fs.rmSync(tmp, { recursive: true, force: true });
  });

  it("fails for stylesheet link without integrity", () => {
    const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "sri-check-"));
    const tmpFrontend = path.join(tmp, "frontend");
    fs.mkdirSync(path.join(tmpFrontend, "src", "app"), { recursive: true });
    fs.writeFileSync(
      path.join(tmpFrontend, "src", "app", "bad-css.tsx"),
      `export default function Bad(){ return <link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/bootstrap@5.3.0/dist/css/bootstrap.min.css" /> }`
    );
    const result = runChecker(tmpFrontend);
    expect(result.exitCode).toBe(1);
    expect(result.output).toMatch(/bootstrap.*missing integrity/i);
    fs.rmSync(tmp, { recursive: true, force: true });
  });

  it("ignores non-executable external links (a href)", () => {
    const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "sri-check-"));
    const tmpFrontend = path.join(tmp, "frontend");
    fs.mkdirSync(path.join(tmpFrontend, "src", "app"), { recursive: true });
    fs.writeFileSync(
      path.join(tmpFrontend, "src", "app", "anchor.tsx"),
      `export default function A(){ return <a href="https://example.com">link</a> }`
    );
    const result = runChecker(tmpFrontend);
    expect(result.exitCode).toBe(0);
    fs.rmSync(tmp, { recursive: true, force: true });
  });

  it("ignores CDN URLs inside comments", () => {
    const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "sri-check-"));
    const tmpFrontend = path.join(tmp, "frontend");
    fs.mkdirSync(path.join(tmpFrontend, "src", "app"), { recursive: true });
    fs.writeFileSync(
      path.join(tmpFrontend, "src", "app", "comment.tsx"),
      `// <script src="https://cdn.jsdelivr.net/npm/bad@1.0/bad.js"></script>\n/* <link rel="stylesheet" href="https://cdn.example.com/a.css" /> */\nexport default function C(){ return null }`
    );
    const result = runChecker(tmpFrontend);
    expect(result.exitCode).toBe(0);
    fs.rmSync(tmp, { recursive: true, force: true });
  });
});
