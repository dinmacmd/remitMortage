#!/usr/bin/env python3
"""
SRI checker — fails if a third-party <script> or <link rel=stylesheet> loaded via https://
does not carry an integrity + crossorigin attribute.

Mirrors fix.md #500 requirement: "Add a CI check that fails if a new external script is added without an integrity hash."

Scope: only script/style tags that actually load code. Plain <a href="https://...">, fetch("https://..."),
img src, etc are NOT checked — they are not executable.

Pass criteria for each candidate tag:
  1. tag contains integrity="sha256|384|512-..."  AND  crossorigin="anonymous" (or "anonymous" / "use-credentials")
  OR
  2. tag uses sriProps() / SRI_MANIFEST from frontend/src/lib/sri.ts (centralized helper) — considered compliant
     when the file imports from "@/lib/sri" or "src/lib/sri" and the tag spreads {...sriProps(url)} or contains sriProps.

Usage:
  python scripts/check-sri.py
  python scripts/check-sri.py --frontend frontend
  python scripts/check-sri.py --strict  # (default) fail on violations
  python scripts/check-sri.py --json    # machine readable

Exit codes:
  0 = all external scripts/styles have SRI or no candidates found (clean)
  1 = violations found (CI fails)
  2 = internal error (bad args, missing dir)
"""

import argparse
import json
import re
import sys
from pathlib import Path

# Files to scan
DEFAULT_FRONTEND = Path("frontend")
SCAN_EXTS = {".tsx", ".ts", ".jsx", ".js", ".html", ".htm"}

# Regexes — multiline-aware, case-insensitive for HTML
# Matches <script ... src="https://..." ...>  (captures full tag) — also covers <Script> via IGNORECASE
SCRIPT_SRC_RE = re.compile(
    r'<script\b[^>]*\bsrc\s*=\s*(?P<q>["\'])(?P<url>https://[^"\']+)(?P=q)[^>]*>',
    re.IGNORECASE | re.DOTALL,
)
# Matches Next.js <Script src="https://..."> (capital S) — kept for explicitness but deduped; case-sensitive to avoid double count with IGNORECASE script
NEXT_SCRIPT_RE = re.compile(
    r'<Script\b[^>]*\bsrc\s*=\s*(?P<q>["\'])(?P<url>https://[^"\']+)(?P=q)[^>]*>',
    re.DOTALL,
)
# Matches <link ... href="https://..." ...> but only when rel=stylesheet (or as=script)
LINK_HREF_RE = re.compile(
    r'<link\b[^>]*\bhref\s*=\s*(?P<q>["\'])(?P<url>https://[^"\']+)(?P=q)[^>]*>',
    re.IGNORECASE | re.DOTALL,
)
# For link, require rel=stylesheet to be considered executable style
LINK_REL_STYLESHEET_RE = re.compile(r'rel\s*=\s*["\']stylesheet["\']', re.IGNORECASE)
LINK_AS_SCRIPT_RE = re.compile(r'as\s*=\s*["\']script["\']', re.IGNORECASE)

INTEGRITY_RE = re.compile(r'integrity\s*=\s*["\']sha(256|384|512)-[A-Za-z0-9+/]+=*["\']', re.IGNORECASE)
CROSSORIGIN_RE = re.compile(r'crossorigin\s*=\s*["\'](?:anonymous|use-credentials)["\']', re.IGNORECASE)
# Also match JSX spread: {...sriProps(url)} or sriProps( or SRI_MANIFEST
SRIPROPS_RE = re.compile(r'sriProps\s*\(|SRI_MANIFEST|integrity.*crossOrigin|crossOrigin.*integrity', re.IGNORECASE)
# Import from sri helper
SRI_IMPORT_RE = re.compile(r'from\s+["\']@/lib/sri["\']|from\s+["\']\.\.?/.*sri["\']|import.*sri', re.IGNORECASE)

# Allowlist for https URLs that are NOT considered "CDN script/style" even if they appear in src/href.
# These are typically fetched via JS or are non-executable, but we still flag them if they are in script/link tags.
# The checker is intentionally strict: any <script src="https://..."> MUST have SRI, no domain allowlist.
# If a legitimate non-CDN script src is needed (e.g. self-hosted analytics on same https domain), add exception here.
ALLOWLIST_SCRIPT_SRC_PREFIXES = set()  # empty — no allowlist for script/style CDN

def is_stylesheet_link(tag: str) -> bool:
    return bool(LINK_REL_STYLESHEET_RE.search(tag) or LINK_AS_SCRIPT_RE.search(tag))

def tag_has_sri(tag: str, file_content: str) -> bool:
    # Direct integrity + crossorigin on the tag
    if INTEGRITY_RE.search(tag) and CROSSORIGIN_RE.search(tag):
        return True
    # Centralized helper usage: file imports sri and tag spreads sriProps
    # Heuristic: if file imports from lib/sri and tag contains sriProps or the whole file contains sriProps
    # we consider it compliant. This avoids false positives for pattern:
    #   import { sriProps } from "@/lib/sri"; <script src={url} {...sriProps(url)} />
    if SRIPROPS_RE.search(tag):
        return True
    if SRI_IMPORT_RE.search(file_content) and SRIPROPS_RE.search(file_content):
        # If the file uses sriProps anywhere and this tag is a script/link with https, assume it is wired correctly.
        # This is lenient but prevents blocking the intended centralized pattern.
        # For stricter checking, require the tag itself to contain sriProps.
        # We check both: if tag has sriProps -> already returned True, else if file has sri import and tag is https script,
        # we still require tag-level integrity OR explicit sriProps in tag. So we do NOT auto-pass here.
        # Keep this branch as False to force explicit per-tag integrity.
        pass
    return False

def strip_comments(text: str) -> str:
    """Replace comments with spaces (keeping newlines) so line numbers stay aligned."""
    # Order matters: longest delimiters first
    # Note: // line comments must not strip // inside URLs (https://) or strings, so use negative lookbehind for :
    patterns = [
        re.compile(r'/\*.*?\*/', re.DOTALL),  # /* block */
        re.compile(r'<!--.*?-->', re.DOTALL),  # HTML comment
        re.compile(r'\{/\*.*?\*/\}', re.DOTALL),  # JSX {/* block */}
        re.compile(r'(?<!:)//.*?$', re.MULTILINE),  # // line comment, but not :// inside URLs
        re.compile(r'^\s*#.*?$', re.MULTILINE),  # # shell comment (rare in TS but safe)
    ]
    stripped = text
    for pat in patterns:
        stripped = pat.sub(lambda m: re.sub(r'[^\n]', ' ', m.group(0)), stripped)
    return stripped

def scan_file(path: Path):
    violations = []
    try:
        text = path.read_text(encoding="utf-8", errors="ignore")
    except Exception as e:
        return [{"file": str(path), "line": 0, "url": "", "tag": "", "error": f"read error: {e}"}]

    # Quick skip: no https script/link at all
    if "https://" not in text:
        return []

    # Strip comments for scanning, but keep original text for line counting and snippet extraction
    stripped = strip_comments(text)
    scan_text = stripped
    has_sri_import = bool(SRI_IMPORT_RE.search(text))

    seen = set()  # dedupe (file, line, url) across script/next-script/link loops
    # Find script tags
    for m in SCRIPT_SRC_RE.finditer(scan_text):
        tag = m.group(0)
        url = m.group("url")
        if ALLOWLIST_SCRIPT_SRC_PREFIXES and any(url.startswith(p) for p in ALLOWLIST_SCRIPT_SRC_PREFIXES):
            continue
        # Check SRI
        has_integrity = bool(INTEGRITY_RE.search(tag))
        has_crossorigin = bool(CROSSORIGIN_RE.search(tag))
        has_sriprops_in_tag = bool(SRIPROPS_RE.search(tag))
        # Also consider file-level sriProps if tag uses expression src={...} (not matched by this regex)
        # For static src="https://", require inline integrity
        if has_sriprops_in_tag and has_sri_import:
            continue
        if has_integrity and has_crossorigin:
            continue
        # Violation
        line = scan_text.count("\n", 0, m.start()) + 1
        key = (str(path), line, url)
        if key in seen:
            continue
        seen.add(key)
        violations.append({
            "file": str(path),
            "line": line,
            "url": url,
            "tag": tag.strip()[:300],
            "reason": "missing integrity" if not has_integrity else "missing crossorigin" if not has_crossorigin else "missing SRI",
        })

    for m in NEXT_SCRIPT_RE.finditer(scan_text):
        tag = m.group(0)
        url = m.group("url")
        has_integrity = bool(INTEGRITY_RE.search(tag))
        has_crossorigin = bool(CROSSORIGIN_RE.search(tag))
        has_sriprops_in_tag = bool(SRIPROPS_RE.search(tag))
        if has_sriprops_in_tag and has_sri_import:
            continue
        if has_integrity and has_crossorigin:
            continue
        line = scan_text.count("\n", 0, m.start()) + 1
        key = (str(path), line, url)
        if key in seen:
            continue
        seen.add(key)
        violations.append({
            "file": str(path),
            "line": line,
            "url": url,
            "tag": tag.strip()[:300],
            "reason": "missing integrity" if not has_integrity else "missing crossorigin",
        })

    for m in LINK_HREF_RE.finditer(scan_text):
        tag = m.group(0)
        if not is_stylesheet_link(tag):
            continue
        url = m.group("url")
        has_integrity = bool(INTEGRITY_RE.search(tag))
        has_crossorigin = bool(CROSSORIGIN_RE.search(tag))
        has_sriprops_in_tag = bool(SRIPROPS_RE.search(tag))
        if has_sriprops_in_tag and has_sri_import:
            continue
        if has_integrity and has_crossorigin:
            continue
        line = scan_text.count("\n", 0, m.start()) + 1
        key = (str(path), line, url)
        if key in seen:
            continue
        seen.add(key)
        violations.append({
            "file": str(path),
            "line": line,
            "url": url,
            "tag": tag.strip()[:300],
            "reason": "missing integrity" if not has_integrity else "missing crossorigin",
        })

    # Also check for dynamic script injection: document.createElement('script') with .src = "https://"
    # This is more complex; we flag any assignment to .src with https:// that is not followed by .integrity
    # Simple heuristic: if file contains 'createElement' and 'https://' and not '.integrity'
    if "createElement" in scan_text and "https://" in scan_text:
        # Find .src = "https://..."
        dyn_re = re.compile(r'\.src\s*=\s*["\'](https://[^"\']+)["\']')
        for m in dyn_re.finditer(scan_text):
            url = m.group(1)
            # Check if nearby (within 500 chars) there is .integrity assignment
            snippet = scan_text[max(0, m.start()-500): m.end()+500]
            if "integrity" not in snippet.lower() or "crossorigin" not in snippet.lower():
                # Only flag if this looks like script creation (near createElement)
                if "script" in snippet.lower():
                    line = scan_text.count("\n", 0, m.start()) + 1
                    violations.append({
                        "file": str(path),
                        "line": line,
                        "url": url,
                        "tag": snippet.strip()[:300],
                        "reason": "dynamic script src without integrity (createElement)",
                    })

    # Check for JSX expression src={url} where url is https:// literal assigned elsewhere
    # e.g. const url = "https://cdn.example.com/..."; <script src={url} />
    # We catch const url = "https://..." and then later <script src={...}> without sriProps
    # Heuristic: find const ... = "https://..." and then <script src={ or <Script src={
    jsx_script_expr_re = re.compile(r'<(?:script|Script)\b[^>]*\bsrc\s*=\s*\{[^}]*\}[^>]*>', re.IGNORECASE | re.DOTALL)
    for m in jsx_script_expr_re.finditer(scan_text):
        tag = m.group(0)
        # If this JSX tag already has integrity or sriProps, skip
        if INTEGRITY_RE.search(tag) and CROSSORIGIN_RE.search(tag):
            continue
        if SRIPROPS_RE.search(tag) and has_sri_import:
            continue
        # Check if file defines a https url literal anywhere
        https_literal_re = re.compile(r'["\'](https://[^"\']+)["\']')
        # Only flag if there is at least one https literal in file that looks CDN-ish
        cdn_like = any(
            "cdn" in u.lower() or "jsdelivr" in u.lower() or "unpkg" in u.lower() or "cdnjs" in u.lower() or "cloudflare" in u.lower() or "googleapis" in u.lower()
            for u in https_literal_re.findall(scan_text)
        )
        # If the file has a CDN-like https literal and a dynamic script src without SRI, flag
        if cdn_like:
            line = scan_text.count("\n", 0, m.start()) + 1
            violations.append({
                "file": str(path),
                "line": line,
                "url": "<dynamic>",
                "tag": tag.strip()[:300],
                "reason": "dynamic script src without integrity (JSX expression, use sriProps)",
            })

    return violations

def main():
    parser = argparse.ArgumentParser(description="Check SRI on external scripts/styles")
    parser.add_argument("--frontend", default=str(DEFAULT_FRONTEND), help="frontend directory to scan")
    parser.add_argument("--json", action="store_true", help="output JSON")
    parser.add_argument("--strict", action="store_true", default=True, help="strict mode (default)")
    args = parser.parse_args()

    frontend = Path(args.frontend)
    if not frontend.exists():
        print(f"Frontend dir not found: {frontend}", file=sys.stderr)
        sys.exit(2)

    all_files = []
    for ext in SCAN_EXTS:
        all_files.extend(frontend.rglob(f"*{ext}"))
    # Also scan public
    public_dir = frontend / "public"
    if public_dir.exists():
        for ext in SCAN_EXTS:
            all_files.extend(public_dir.rglob(f"*{ext}"))

    violations = []
    for f in sorted(set(all_files)):
        # Skip node_modules, .next, etc and test fixtures (they contain example CDN strings)
        if "node_modules" in str(f) or ".next" in str(f) or "dist" in str(f) or "__tests__" in str(f) or "__mocks__" in str(f) or "/e2e/" in str(f) or "\\e2e\\" in str(f):
            continue
        violations.extend(scan_file(f))

    if args.json:
        print(json.dumps({"violations": violations, "count": len(violations)}, indent=2))
    else:
        if violations:
            print("SRI violations found:", file=sys.stderr)
            for v in violations:
                print(f"::error file={v['file']},line={v['line']}::SRI missing for {v['url']} - {v['reason']}", file=sys.stderr)
                print(f"  {v['file']}:{v['line']} - {v['reason']}: {v['url']}", file=sys.stderr)
                print(f"    tag: {v['tag']}", file=sys.stderr)
            print(f"\nTotal violations: {len(violations)}", file=sys.stderr)
            print("\nFix: add integrity=\"sha384-...\" and crossorigin=\"anonymous\" to each tag.", file=sys.stderr)
            print("Generate hash: curl -s <url> | openssl dgst -sha384 -binary | openssl base64 -A", file=sys.stderr)
            print("Or: node frontend/scripts/sri-hash.mjs <url>", file=sys.stderr)
            print("Centralized: import { sriProps } from \"@/lib/sri\"; <script src={url} {...sriProps(url)} />", file=sys.stderr)
        else:
            print("No SRI violations - all external scripts/styles have integrity + crossorigin or no CDN loads found.")

    sys.exit(1 if violations else 0)

if __name__ == "__main__":
    main()
