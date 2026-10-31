#!/usr/bin/env python3
"""Ports GRDB 7.11.1's own test suite onto SQLiteOrbitGRDB and measures API coverage.

Subcommands:

  sync                Regenerate Tests/SQLiteOrbitGRDBUpstreamTests/GRDBTests from the manifest.
  typecheck [REGEX]   Type-check every upstream test file (verbatim, with the port's harness)
                      against the built overlay and summarize which files and tests compile.
  autoexclude FILE.. | all | ported [--only REGEX]
                      Port FILE, removing the tests (and helper declarations) that do not
                      compile against the overlay. Recomputed from scratch on every run.
  run [--record] [--only REGEX]
                      Run the built upstream tests in isolated processes (one per class, then
                      one per test for classes that crash or hang) and summarize; with
                      --record, make the area's runtime skips exactly the failing tests.
                      Runs ignore skips (GRDB_UPSTREAM_RUN_SKIPPED), so fixed tests show up.
  skips LOG           Record failing tests from a `swift test` log as runtime skips.
  api                 Compare GRDB's and the overlay's public symbol graphs by name.
  report              Summarize the manifest: ported files, removed tests, skipped tests.

The manifest (upstream-manifest/*.txt) lists ported upstream files relative to Tests/GRDBTests.
Indented entries under a file adjust it:

  - NAME: reason   removes declarations named NAME (tests or helpers) before compilation
  ~ NAME: reason   compiles the test but skips it at runtime (XCTSkip)

Lines starting with `x PATH: reason` record upstream files deliberately not ported.

The upstream checkout is the one SwiftPM resolves for the reference package
(Tests/GRDBReference/.build/checkouts/GRDB.swift); run `swift package resolve` there first.
Run with `python3 -I`.
"""

import collections
import glob
import json
import os
import re
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))
CHECKOUT = os.path.join(HERE, ".build", "checkouts", "GRDB.swift")
UPSTREAM_TESTS = os.path.join(CHECKOUT, "Tests", "GRDBTests")
MANIFEST_DIR = os.path.join(HERE, "upstream-manifest")
QUERY_AREAS = {"QueryInterface", "FTS", "JSON"}
QUERY_PREFIXES = ("Record/PersistableRecord/", "Record/TableRecord/")
MANIFEST_HEADER = (
    "# Upstream GRDB 7.11.1 test files ported to SQLiteOrbitGRDB. See grdb_upstream.py for the\n"
    "# format. QueryInterface, FTS, JSON, and Record/PersistableRecord and Record/TableRecord\n"
    "# live in query.txt; everything else in core.txt.\n"
)
TARGET = os.path.join(REPO, "Tests", "SQLiteOrbitGRDBUpstreamTests")
GENERATED = os.path.join(TARGET, "GRDBTests")
SUPPORT = os.path.join(TARGET, "Support")
SKIPS = os.path.join(SUPPORT, "UpstreamSkips.swift")

# Upstream support files. Ported tests use the port's adaptations in Support/, while the
# reference package uses these originals.
SUPPORT_FILES = [
    "GRDBTestCase.swift",
    "Mutex.swift",
    "AsyncSemaphore.swift",
    "Core/Row/RowTestCase.swift",
    "ValueObservation/ValueObservationRecorder.swift",
    "Core/BackupTestCase.swift",
    "FailureTestCase.swift",
]
NEVER_PORTED_DIRS = ["GRDBCombineTests/CombineExpectations/", "GRDBCipher/"]


# MARK: - Manifest


class Entry:
    def __init__(self, path):
        self.path = path
        self.removed = collections.OrderedDict()
        self.skipped = collections.OrderedDict()


def manifest_file(path):
    """Each upstream area belongs to one manifest file, so concurrent edits of different areas
    never write the same file."""
    query = path.split("/")[0] in QUERY_AREAS or path.startswith(QUERY_PREFIXES)
    return os.path.join(MANIFEST_DIR, "query.txt" if query else "core.txt")


def read_manifest():
    entries = collections.OrderedDict()
    declined = collections.OrderedDict()
    read_manifest.originals = {}
    for manifest in sorted(glob.glob(os.path.join(MANIFEST_DIR, "*.txt"))):
        text = open(manifest).read()
        read_manifest.originals[manifest] = text
        current = None
        for line in text.split("\n"):
            if not line.strip() or line.startswith("#"):
                continue
            if line.startswith("x "):
                path, _, reason = line[2:].partition(": ")
                declined[path.strip()] = reason.strip()
                current = None
                continue
            if line.startswith((" ", "\t")):
                item = line.strip()
                kind, rest = item[0], item[1:].strip()
                name, _, reason = rest.partition(": ")
                if current is None or kind not in "-~":
                    sys.exit(f"{manifest}: unexpected line {line!r}")
                (current.removed if kind == "-" else current.skipped)[name.strip()] = reason.strip()
                continue
            current = Entry(line.strip())
            entries[current.path] = current
    return None, entries, declined


def atomic_write(path, text):
    tmp = path + f".tmp{os.getpid()}"
    with open(tmp, "w") as out:
        out.write(text)
    os.replace(tmp, path)


def write_manifest(header, entries, declined):
    """Writes only the manifest files whose rendering differs from what was read."""
    os.makedirs(MANIFEST_DIR, exist_ok=True)
    files = collections.defaultdict(list)
    for path in sorted(entries):
        entry = entries[path]
        lines = [path]
        lines += [f"  - {n}: {r}" for n, r in entry.removed.items()]
        lines += [f"  ~ {n}: {r}" for n, r in entry.skipped.items()]
        files[manifest_file(path)].append("\n".join(lines))
    declined_lines = collections.defaultdict(list)
    for path in sorted(declined):
        declined_lines[manifest_file(path)].append(f"x {path}: {declined[path]}")
    originals = getattr(read_manifest, "originals", {})
    for manifest in set(files) | set(declined_lines) | set(originals):
        body = MANIFEST_HEADER + "\n" + "\n".join(files[manifest]) + "\n"
        if declined_lines[manifest]:
            body += "\n" + "\n".join(declined_lines[manifest]) + "\n"
        rendered_from_read = originals.get(manifest)
        if body != rendered_from_read:
            atomic_write(manifest, body)


# MARK: - Swift source surgery


def code_mask(text):
    """Returns text with comments and string literal contents blanked, preserving offsets."""
    out = list(text)
    n = len(text)
    i = 0

    def blank(a, b):
        for k in range(a, b):
            if out[k] != "\n":
                out[k] = " "

    def skip_string(i):
        # i points at the first character of a string literal, possibly `#`s for raw strings.
        start = i
        hashes = 0
        while i < n and text[i] == "#":
            hashes += 1
            i += 1
        if text.startswith('"""', i):
            quote = '"""'
        else:
            quote = '"'
        i += len(quote)
        close = quote + "#" * hashes
        escape = "\\" + "#" * hashes
        while i < n:
            if text.startswith(escape, i):
                j = i + len(escape)
                if j < n and text[j] == "(":
                    i = skip_interpolation(j + 1)
                    continue
                i = j + 1
                continue
            if text.startswith(close, i):
                return i + len(close)
            if quote == '"' and text[i] == "\n":
                return i
            i += 1
        return i

    def skip_interpolation(i):
        depth = 1
        while i < n and depth:
            c = text[i]
            if c == '"' or (c == "#" and re.match(r'#+"', text[i:])):
                i = skip_string(i)
                continue
            if text.startswith("//", i):
                while i < n and text[i] != "\n":
                    i += 1
                continue
            if c == "(":
                depth += 1
            elif c == ")":
                depth -= 1
            i += 1
        return i

    while i < n:
        c = text[i]
        if text.startswith("//", i):
            j = text.find("\n", i)
            j = n if j < 0 else j
            blank(i, j)
            i = j
        elif text.startswith("/*", i):
            depth, j = 1, i + 2
            while j < n and depth:
                if text.startswith("/*", j):
                    depth, j = depth + 1, j + 2
                elif text.startswith("*/", j):
                    depth, j = depth - 1, j + 2
                else:
                    j += 1
            blank(i, j)
            i = j
        elif c == '"' or (c == "#" and re.match(r'#+"', text[i:])):
            j = skip_string(i)
            blank(i, j)
            i = j
        else:
            i += 1
    return "".join(out)


DECL = r"(?:func|class|struct|enum|extension|actor|protocol|var|let|typealias|init)"


def declaration_spans(text, name):
    """Spans (start, end) of declarations named `name`, including attached attributes/comments."""
    mask = code_mask(text)
    spans = []
    if name == "init":
        pattern = re.compile(r"^[ \t]*(?:[@\w() ,.:*]+\s)?init\s*[(<]", re.M)
    else:
        pattern = re.compile(
            r"^[ \t]*(?:(?:@\w+(?:\([^)\n]*\))?|private|fileprivate|internal|public|open|final|"
            r"static|class|override|mutating|nonisolated|required|convenience|lazy|weak|"
            r"indirect|dynamic)\s+)*" + DECL + r"\s+" + re.escape(name) + r"\b",
            re.M,
        )
    for m in pattern.finditer(mask):
        start = m.start()
        # Include immediately preceding attribute lines and line comments.
        while True:
            prev_end = start - 1
            if prev_end < 0:
                break
            prev_start = mask.rfind("\n", 0, prev_end) + 1
            prev = text[prev_start:prev_end].strip()
            if prev.startswith("@") or prev.startswith("//"):
                start = prev_start
            else:
                break
        # Find the end: the brace matching the first `{` after the declaration, unless the
        # declaration ends first (a stored property or typealias without a body).
        i = m.end()
        depth = 0
        paren = 0
        end = None
        while i < len(mask):
            c = mask[i]
            if c in "([":
                paren += 1
            elif c in ")]":
                paren -= 1
            elif c == "{":
                depth += 1
            elif c == "}":
                depth -= 1
                if depth == 0:
                    end = i + 1
                    break
                if depth < 0:
                    end = i
                    break
            elif c == "\n" and depth == 0 and paren == 0:
                rest = mask[i + 1:].lstrip(" \t")
                prev_line = mask[mask.rfind("\n", 0, i) + 1:i].rstrip()
                if not rest.startswith(("{", "where", ".", "->", "throws", "async", "rethrows")) \
                        and not prev_line.endswith((",", "(", "=", "->", ":", "&")):
                    end = i
                    break
            i += 1
        if end is None:
            end = len(mask)
        line_end = text.find("\n", end)
        if line_end >= 0 and not text[end:line_end].strip():
            end = line_end
        spans.append((start, end))
    return spans


def remove_declarations(text, names):
    spans = []
    for name in names:
        bare = name.split(".")[-1]
        found = declaration_spans(text, bare)
        if not found:
            raise LookupError(name)
        spans.extend(found)
    # Nested declarations can share a name (a test and a local helper); keep outermost spans.
    merged = []
    for start, end in sorted(set(spans)):
        if merged and start < merged[-1][1]:
            merged[-1] = (merged[-1][0], max(end, merged[-1][1]))
        else:
            merged.append((start, end))
    for start, end in reversed(merged):
        text = text[:start] + text[end:]
    return text


def convert_imports(text):
    text = re.sub(r"^(\s*)@testable import GRDB\b.*$", r"\1import SQLiteOrbitGRDB", text, flags=re.M)
    text = re.sub(r"^(\s*)import GRDB$", r"\1import SQLiteOrbitGRDB", text, flags=re.M)
    text = re.sub(r"^(\s*)import (?:GRDBSQLite|SQLite3)$", r"\1import CSQLite3", text, flags=re.M)
    return text


def ported_source(path, entry):
    text = open(os.path.join(UPSTREAM_TESTS, path)).read()
    text = convert_imports(text)
    if entry is not None and entry.removed:
        text = remove_declarations(text, list(entry.removed))
    banner = (
        f"// Generated from GRDB 7.11.1 Tests/GRDBTests/{path} by Tests/GRDBReference/grdb_upstream.py.\n"
        "// Do not edit: change Tests/GRDBReference/upstream-manifest.txt and run `sync`.\n"
    )
    return banner + text


def test_spans(text):
    mask = code_mask(text)
    spans = []
    for m in re.finditer(r"^[ \t]*(?:@\w+\s+)*func (test\w*)\s*\(\s*\)", mask, re.M):
        i = mask.find("{", m.end())
        depth = 0
        j = i
        while j < len(mask):
            if mask[j] == "{":
                depth += 1
            elif mask[j] == "}":
                depth -= 1
                if depth == 0:
                    break
            j += 1
        spans.append((m.group(1), text.count("\n", 0, m.start()) + 1, text.count("\n", 0, j) + 1))
    return spans


# MARK: - Commands


def check_checkout():
    if not os.path.isdir(UPSTREAM_TESTS):
        sys.exit(f"missing {UPSTREAM_TESTS}; run `swift package resolve --package-path {HERE}`")


def cmd_sync(args):
    check_checkout()
    header, entries, declined = read_manifest()
    wanted = {}
    for path, entry in entries.items():
        try:
            wanted[os.path.join(GENERATED, path)] = ported_source(path, entry)
        except LookupError as error:
            sys.exit(f"{path}: no declaration named {error}")
    for old in glob.glob(os.path.join(GENERATED, "**", "*.swift"), recursive=True):
        if old not in wanted:
            os.remove(old)
    for dest, source in wanted.items():
        os.makedirs(os.path.dirname(dest), exist_ok=True)
        if not os.path.exists(dest) or open(dest).read() != source:
            atomic_write(dest, source)
    for root, dirs, files in os.walk(GENERATED, topdown=False):
        if not os.listdir(root):
            os.rmdir(root)
    lines = []
    for path, entry in entries.items():
        for name, reason in entry.skipped.items():
            klass = os.path.splitext(os.path.basename(path))[0]
            key = name if "." in name else f"{klass}.{name}"
            lines.append(f"  {swift_string(key)}: {swift_string(reason)},")
    skips = (
        "// Generated by Tests/GRDBReference/grdb_upstream.py from upstream-manifest/.\n"
        "// Upstream tests that compile against SQLiteOrbitGRDB but are skipped at runtime.\n"
        "let upstreamSkips: [String: String] = [\n"
        + ("\n".join(sorted(lines)) + "\n" if lines else ":\n")
        + "]\n"
    )
    if not os.path.exists(SKIPS) or open(SKIPS).read() != skips:
        atomic_write(SKIPS, skips)
    print(f"generated {len(entries)} files")


def swift_string(text):
    text = re.sub(r"[\x00-\x1f]", " ", text)
    return '"' + text.replace("\\", "\\\\").replace('"', '\\"') + '"'


def swiftc_command(sources, modules):
    return [
        "swiftc", "-typecheck", "-swift-version", "5",
        "-enable-upcoming-feature", "InferSendableFromCaptures",
        "-enable-upcoming-feature", "GlobalActorIsolatedTypesUsability",
        "-D", "SWIFT_PACKAGE",
        "-I", modules,
        "-Xcc", f"-fmodule-map-file={REPO}/Sources/CSQLite3/module.modulemap",
        "-Xcc", f"-fmodule-map-file={REPO}/Sources/CLinuxEvents/module.modulemap",
        "-module-cache-path", os.path.join(tempfile.gettempdir(), "grdb-upstream-modcache"),
    ] + sources


def harness_sources():
    return sorted(glob.glob(os.path.join(SUPPORT, "*.swift")))



def typecheck_file(path, text, modules, workdir):
    safe = path.replace("/", "_")
    src = os.path.join(workdir, safe)
    with open(src, "w") as out:
        out.write(text)
    # SwiftPM generates `Bundle.module` for the target's resources.
    bundle = os.path.join(workdir, "BundleModule.swift")
    if not os.path.exists(bundle):
        with open(bundle, "w") as out:
            out.write("import Foundation\nextension Bundle { static let module = Bundle.main }\n")
    sources = harness_sources() + [bundle] + [src]
    result = subprocess.run(swiftc_command(sources, modules), capture_output=True, text=True)
    errors = []
    harness_errors = []
    for line in (result.stdout + result.stderr).splitlines():
        m = re.match(r"(.*?):(\d+):\d+: error: (.*)", line)
        if not m:
            continue
        if os.path.basename(m.group(1)) == safe:
            errors.append((int(m.group(2)), m.group(3)))
        else:
            harness_errors.append(line)
    return errors, harness_errors, result.returncode


def modules_dir(args):
    scratch = os.environ.get("ORBIT_SCRATCH", os.path.join(REPO, ".build"))
    return os.path.join(scratch, "debug", "Modules")


def all_upstream_files():
    files = []
    for f in glob.glob(os.path.join(UPSTREAM_TESTS, "**", "*.swift"), recursive=True):
        rel = os.path.relpath(f, UPSTREAM_TESTS)
        if rel in SUPPORT_FILES or any(rel.startswith(d) for d in NEVER_PORTED_DIRS):
            continue
        files.append(rel)
    return sorted(files)


def cmd_typecheck(args):
    """Verbatim upstream files, each type-checked alone with the port's harness."""
    check_checkout()
    pattern = re.compile(args[0]) if args else None
    files = [f for f in all_upstream_files() if not pattern or pattern.search(f)]
    modules = modules_dir(args)
    workdir = tempfile.mkdtemp(prefix="grdb-typecheck-")
    from concurrent.futures import ThreadPoolExecutor

    def run(path):
        text = convert_imports(open(os.path.join(UPSTREAM_TESTS, path)).read())
        errors, harness, _ = typecheck_file(path, text, modules, workdir)
        tests = test_spans(text)
        lines = {line for line, _ in errors}
        inside = set()
        clean = []
        for name, a, b in tests:
            hit = {l for l in lines if a <= l <= b}
            inside |= hit
            clean.append((name, not hit))
        outside = lines - inside
        return path, errors, harness, tests, clean, outside

    with ThreadPoolExecutor(max_workers=os.cpu_count() or 4) as pool:
        results = list(pool.map(run, files))
    totals = collections.Counter()
    by_area = collections.defaultdict(collections.Counter)
    report = []
    for path, errors, harness, tests, clean, outside in results:
        area = path.split("/")[0] if "/" in path else "(root)"
        ok_file = not errors and not harness
        totals["files"] += 1
        totals["files_ok"] += ok_file
        for name, body_ok in clean:
            ok = body_ok and not outside and not harness
            totals["tests"] += 1
            totals["tests_ok"] += ok
            by_area[area]["tests"] += 1
            by_area[area]["tests_ok"] += ok
            report.append(f"{'OK ' if ok else 'ERR'}\t{path}\t{name}")
    print(f"upstream files type-checking verbatim: {totals['files_ok']}/{totals['files']}")
    print(f"upstream tests type-checking: {totals['tests_ok']}/{totals['tests']} "
          f"({100 * totals['tests_ok'] / max(totals['tests'], 1):.1f}%)")
    for area, c in sorted(by_area.items(), key=lambda kv: -kv[1]["tests"]):
        print(f"  {area:18s} {c['tests_ok']:5d}/{c['tests']:5d} ({100 * c['tests_ok'] / c['tests']:5.1f}%)")
    out = os.environ.get("GRDB_TYPECHECK_REPORT")
    if out:
        with open(out, "w") as f:
            f.write("\n".join(report) + "\n")
        errs = collections.Counter()
        files_by = collections.defaultdict(set)
        for path, errors, *_ in results:
            for _, message in errors:
                key = summarize_error(message)
                errs[key] += 1
                files_by[key].add(path)
        with open(out + ".errors", "w") as f:
            for key in sorted(errs, key=lambda k: (-len(files_by[k]), -errs[k])):
                f.write(f"{len(files_by[key]):4d} files {errs[key]:5d}x  {key}\n")


ERROR_PATTERNS = [
    (r"cannot find type '([^']+)' in scope", "missing type {0}"),
    (r"cannot find '([^']+)' in scope", "missing {0}"),
    (r"value of type '([^']+)' has no member '([^']+)'", "missing {0}.{1}"),
    (r"type '([^']+)' has no member '([^']+)'", "missing {0}.{1}"),
    (r"no such module '([^']+)'", "missing module {0}"),
    (r"'([^']+)' is inaccessible due to '(?:internal|private|fileprivate)'", "internal API {0}"),
    (r"incorrect argument labels? in call \(have '([^']+)', expected '([^']+)'\)", "labels ({0}) instead of ({1})"),
    (r"extra argument '([^']+)' in call", "missing parameter {0}:"),
    (r"extra arguments? at positions? ", "extra arguments"),
]


def summarize_error(message):
    for pattern, fmt in ERROR_PATTERNS:
        m = re.search(pattern, message)
        if m:
            groups = [re.sub(r"<.*>", "", g) for g in m.groups()]
            return fmt.format(*groups)
    return re.sub(r"\s*\[#\w+\]$", "", message)


def take_only(args):
    """Extracts `--only REGEX`, which restricts a command to matching upstream paths."""
    if "--only" in args:
        i = args.index("--only")
        pattern = re.compile(args[i + 1])
        del args[i:i + 2]
        return pattern
    return None


def cmd_autoexclude(args):
    """Recomputes the removed tests of each file from scratch; runtime skips are kept."""
    check_checkout()
    only = take_only(args)
    header, entries, declined = read_manifest()
    if args == ["all"]:
        args = all_upstream_files()
    elif args == ["ported"]:
        args = list(entries)
    if only:
        args = [a for a in args if only.search(a)]
    modules = modules_dir(args)
    workdir = tempfile.mkdtemp(prefix="grdb-autoexclude-")
    from concurrent.futures import ThreadPoolExecutor

    def run(path):
        entry = Entry(path)
        if path in entries:
            entry.skipped = entries[path].skipped
        log = []
        for _ in range(16):
            try:
                text = ported_source(path, entry)
            except LookupError as error:
                return path, None, f"cannot remove declaration {error}"
            errors, harness, _ = typecheck_file(path, text, modules, workdir)
            if harness:
                return path, None, "harness errors: " + harness[0]
            if not errors:
                break
            tests = test_spans(text)
            mask = code_mask(text)
            progressed = False
            for line, message in errors:
                owner = None
                for name, a, b in tests:
                    if a <= line <= b:
                        owner = name
                if owner is None:
                    owner = enclosing_helper(mask, line)
                if owner is None or owner in entry.removed:
                    continue
                if not declaration_spans(text, owner):
                    continue
                entry.removed[owner] = summarize_error(message)
                progressed = True
            if not progressed:
                reasons = collections.Counter(summarize_error(m) for _, m in errors)
                return path, None, ", ".join(r for r, _ in reasons.most_common(3))
        else:
            return path, None, "too many removal rounds"
        names = {name for name, _, _ in test_spans(text)}
        entry.skipped = collections.OrderedDict(
            (k, v) for k, v in entry.skipped.items() if k.split(".")[-1] in names)
        return path, entry, None

    with ThreadPoolExecutor(max_workers=os.cpu_count() or 4) as pool:
        results = list(pool.map(run, args))
    for path, entry, reason in results:
        total = len(test_spans(convert_imports(open(os.path.join(UPSTREAM_TESTS, path)).read())))
        if entry is None:
            print(f"{path}: not ported ({reason})")
            entries.pop(path, None)
            declined[path] = reason
            continue
        declined.pop(path, None)
        kept = len(test_spans(ported_source(path, entry)))
        if kept == 0 and total > 0:
            print(f"{path}: no test compiles")
            entries.pop(path, None)
            declined[path] = "no test compiles: " + ", ".join(list(entry.removed.values())[:3])
            continue
        print(f"{path}: {kept}/{total} tests compile")
        entries[path] = entry
    write_manifest(header, entries, declined)


def enclosing_helper(mask, line):
    """The innermost named declaration around `line` that is not an XCTestCase subclass."""
    offset = 0
    for _ in range(line - 1):
        offset = mask.index("\n", offset) + 1
    stack = []
    decl = re.compile(r"(?:func|class|struct|enum|extension|actor|var|let|init)\b\s*([A-Za-z_]\w*)?")
    depth = 0
    i = 0
    pending = []
    while i < offset:
        m = decl.match(mask, i)
        if m and (i == 0 or not (mask[i - 1].isalnum() or mask[i - 1] == "_")):
            pending.append((m.group(0).split()[0], m.group(1) or "init", depth))
            i = m.end()
            continue
        c = mask[i]
        if c == "{":
            if pending and pending[-1][2] == depth:
                stack.append(pending.pop())
            else:
                stack.append(("block", None, depth))
            pending = [p for p in pending if p[2] < depth]
            depth += 1
        elif c == "}":
            depth -= 1
            if stack:
                stack.pop()
        elif c == "\n":
            pending = [p for p in pending if p[0] in ("func", "init", "class", "struct", "enum", "extension", "actor")]
        i += 1
    # Prefer the outermost non-test-case declaration that is a helper, so removing it is safe.
    named = [s for s in stack if s[1] and s[0] != "block"]
    if not named:
        return None
    top = named[0]
    if top[0] == "class" and re.search(r"class\s+" + re.escape(top[1]) + r"\s*:\s*(GRDBTestCase|XCTestCase|RowTestCase|BackupTestCase|FailureTestCase)", mask):
        # A member of the test case itself: remove the member if it is not a test.
        if len(named) > 1:
            member = named[1]
            if member[1] in ("setup", "setUp", "tearDown", "setUpWithError"):
                return None
            return member[1]
        return None
    if top[0] == "extension":
        return named[1][1] if len(named) > 1 else None
    return top[1]


def xctest_binary():
    scratch = os.environ.get("ORBIT_SCRATCH", os.path.join(REPO, ".build"))
    path = os.path.join(scratch, "debug", "sqlite-orbitPackageTests.xctest")
    if not os.path.exists(path):
        sys.exit(f"missing {path}; run `swift build --build-tests` first")
    return path


def run_xctest(binary, selector, timeout):
    try:
        env = dict(os.environ, GRDB_UPSTREAM_RUN_SKIPPED="1")
        result = subprocess.run([binary, selector], capture_output=True, text=True, timeout=timeout,
                                errors="replace", env=env)
        return result.returncode, result.stdout + result.stderr
    except subprocess.TimeoutExpired as error:
        out = (error.stdout or b"") + (error.stderr or b"")
        return None, out.decode(errors="replace") if isinstance(out, bytes) else out


def parse_results(log):
    """Outcome per (class, test): passed, failed (with message), or skipped."""
    outcomes = {}
    messages = {}
    for m in re.finditer(r"^.*?: error: (\w+)\.(\w+) : (.*)$", log, re.M):
        messages.setdefault((m.group(1), m.group(2)), m.group(3).strip())
    for m in re.finditer(r"Test Case '(?:-\[)?(?:\w+\.)?(\w+)[. ](\w+)\]?' (passed|failed|skipped)", log):
        outcomes[(m.group(1), m.group(2))] = m.group(3)
    started = re.findall(r"Test Case '(?:-\[)?(?:\w+\.)?(\w+)[. ](\w+)\]?' started", log)
    return outcomes, messages, started


def class_paths(entries):
    by_class = {}
    for path in entries:
        source = open(os.path.join(UPSTREAM_TESTS, path)).read()
        for klass in re.findall(r"class\s+(\w+)\s*:", source):
            by_class.setdefault(klass, path)
    return by_class


def cmd_run(args):
    only = take_only(args)
    record = "--record" in args
    binary = xctest_binary()
    listing = subprocess.run([binary, "--list-tests"], capture_output=True, text=True).stdout
    tests = re.findall(r"^SQLiteOrbitGRDBUpstreamTests\.(\w+)/(\w+)$", listing, re.M)
    if only:
        by_class = class_paths(read_manifest()[1])
        tests = [t for t in tests if t[0] in by_class and only.search(by_class[t[0]])]
    classes = sorted({c for c, _ in tests})
    from concurrent.futures import ThreadPoolExecutor
    outcomes, messages = {}, {}

    def run_class(klass):
        code, log = run_xctest(binary, f"SQLiteOrbitGRDBUpstreamTests.{klass}", 300)
        o, m, started = parse_results(log)
        finished = all(k in o for k in started) and code is not None
        return klass, o, m, finished

    workers = max(2, (os.cpu_count() or 4) // 2)
    with ThreadPoolExecutor(max_workers=workers) as pool:
        unfinished = []
        for klass, o, m, finished in pool.map(run_class, classes):
            outcomes.update(o)
            messages.update(m)
            if not finished:
                unfinished.append(klass)

        def run_test(key):
            klass, test = key
            code, log = run_xctest(binary, f"SQLiteOrbitGRDBUpstreamTests.{klass}/{test}", 120)
            o, m, _ = parse_results(log)
            if key not in o:
                return key, "crashed" if code is not None else "timeout", log
            return key, o[key], m.get(key)

        isolated = [k for k in tests if k[0] in unfinished]
        for key, outcome, detail in pool.map(run_test, isolated):
            outcomes[key] = "failed" if outcome in ("crashed", "timeout") else outcome
            if outcome == "crashed":
                tail = [l for l in (detail or "").splitlines() if "Fatal error" in l or "error:" in l]
                messages[key] = "crashes: " + (tail[-1].strip() if tail else "process exited")
            elif outcome == "timeout":
                messages[key] = "hangs (timed out)"
            elif detail:
                messages[key] = detail
    counts = collections.Counter(outcomes.get(k, "missing") for k in tests)
    print(f"upstream tests: {len(tests)} compiled; passed {counts['passed']}, "
          f"skipped {counts['skipped']}, failed {counts['failed']}, not run {counts['missing']}")
    failed = sorted(k for k in tests if outcomes.get(k) in ("failed", None))
    for klass, test in failed[:40]:
        print(f"  FAIL {klass}.{test}: {messages.get((klass, test), '')[:150]}")
    if record:
        header, entries, declined = read_manifest()
        by_class = class_paths(entries)
        # The run ignores skips, so the failures replace the skips of every class that ran.
        ran = {by_class.get(k) for k, _ in tests}
        removed = 0
        for path in ran:
            if path in entries:
                klasses = {k for k, p in by_class.items() if p == path}
                ran_tests = {t if k == os.path.splitext(os.path.basename(path))[0] else f"{k}.{t}"
                             for k, t in tests if k in klasses}
                for name in list(entries[path].skipped):
                    if name in ran_tests and (name.split(".")[0] if "." in name else os.path.splitext(os.path.basename(path))[0], name.split(".")[-1]) not in failed:
                        del entries[path].skipped[name]
                        removed += 1
        added = 0
        for klass, test in failed:
            path = by_class.get(klass)
            if path is None:
                print(f"unknown class {klass}")
                continue
            name = test if klass == os.path.splitext(os.path.basename(path))[0] else f"{klass}.{test}"
            reason = re.sub(r"\s+", " ", messages.get((klass, test), "fails"))[:110]
            if name not in entries[path].skipped:
                entries[path].skipped[name] = "runtime: " + reason
                added += 1
        write_manifest(header, entries, declined)
        print(f"recorded {added} new skips, removed {removed} passing skips; run `sync` and rebuild")
    if os.environ.get("GRDB_RUN_REPORT"):
        with open(os.environ["GRDB_RUN_REPORT"], "w") as f:
            for key in tests:
                f.write(f"{outcomes.get(key, 'missing')}\t{key[0]}.{key[1]}\n")


def cmd_skips(args):
    header, entries, declined = read_manifest()
    log = open(args[0], errors="replace").read()
    reasons = {}
    for m in re.finditer(r"^.*?: error: (\w+)\.(\w+) : (.*)$", log, re.M):
        reasons.setdefault((m.group(1), m.group(2)), m.group(3).strip()[:110])
    started = re.findall(r"Test Case '(\w+)\.(\w+)' started", log)
    finished = set(re.findall(r"Test Case '(\w+)\.(\w+)' (?:passed|failed|skipped)", log))
    for key in started:
        if key not in finished:
            reasons.setdefault(key, "crashes the test process")
    by_class = {os.path.splitext(os.path.basename(p))[0]: p for p in entries}
    added = 0
    for (klass, test), reason in sorted(reasons.items()):
        path = by_class.get(klass)
        if path is None:
            # Classes whose name differs from the file name.
            for p in entries:
                if re.search(r"class\s+" + klass + r"\b", open(os.path.join(UPSTREAM_TESTS, p)).read()):
                    path = p
                    break
        if path is None:
            print(f"unknown class {klass}")
            continue
        name = test if klass == os.path.splitext(os.path.basename(path))[0] else f"{klass}.{test}"
        if name not in entries[path].skipped:
            entries[path].skipped[name] = "runtime: " + reason
            added += 1
    write_manifest(header, entries, declined)
    print(f"added {added} skips")


def cmd_api(args):
    """Name-level comparison of public symbol graphs (paths and kinds, ignoring signatures)."""
    check_checkout()
    work = tempfile.mkdtemp(prefix="grdb-api-")
    grdb_out = os.path.join(work, "grdb")
    orbit_out = os.path.join(work, "orbit")
    os.makedirs(grdb_out)
    os.makedirs(orbit_out)
    ref_modules = os.path.join(HERE, ".build", "debug", "Modules")
    common = ["-target", subprocess.check_output(["swiftc", "-print-target-info"], text=True)
              and json.loads(subprocess.check_output(["swiftc", "-print-target-info"], text=True))["target"]["triple"],
              "-minimum-access-level", "public"]
    subprocess.run(["swift-symbolgraph-extract", "-module-name", "GRDB", "-I", ref_modules,
                    "-I", os.path.join(CHECKOUT, "Sources", "GRDBSQLite"), "-output-dir", grdb_out] + common, check=True)
    subprocess.run(["swift-symbolgraph-extract", "-module-name", "SQLiteOrbitGRDB", "-I", modules_dir(args),
                    "-I", os.path.join(REPO, "Sources", "CSQLite3"), "-I", os.path.join(REPO, "Sources", "CLinuxEvents"),
                    "-output-dir", orbit_out] + common, check=True)
    grdb = collect_symbols(grdb_out, keep_inherited=False)
    orbit = collect_symbols(orbit_out, keep_inherited=True)
    total = collections.Counter()
    covered = collections.Counter()
    missing = []
    for key, location in grdb.items():
        area = location.split("/GRDB/")[-1].split("/")[0] if "/GRDB/" in location else "?"
        total[area] += 1
        if key in orbit:
            covered[area] += 1
        else:
            missing.append((location.split("/GRDB/")[-1], key))
    all_total, all_covered = sum(total.values()), sum(covered.values())
    print(f"GRDB public declarations matched by name: {all_covered}/{all_total} "
          f"({100 * all_covered / all_total:.1f}%)")
    for area in sorted(total, key=lambda a: -total[a]):
        print(f"  {area:18s} {covered[area]:5d}/{total[area]:5d} ({100 * covered[area] / total[area]:5.1f}%)")
    out = os.environ.get("GRDB_API_REPORT")
    if out:
        with open(out, "w") as f:
            for location, (path, kind) in sorted(missing):
                f.write(f"{location}\t{kind}\t{path}\n")


def collect_symbols(directory, keep_inherited):
    kinds = {
        "class": "type", "struct": "type", "enum": "type", "protocol": "type", "typealias": "type",
        "method": "member", "property": "member", "enum.case": "member",
        "type.method": "static", "type.property": "static",
        "subscript": "subscript", "type.subscript": "subscript", "init": "init",
        "func.op": "operator", "associatedtype": "associatedtype",
        "var": "global", "func": "global", "macro": "global",
    }
    out = {}
    for path in glob.glob(os.path.join(directory, "*.symbols.json")):
        for symbol in json.load(open(path))["symbols"]:
            precise = symbol["identifier"]["precise"]
            if "::SYNTHESIZED::" in precise and not keep_inherited:
                continue
            components = symbol["pathComponents"]
            if any(c.startswith("_") for c in components):
                continue
            if any(a.get("isUnconditionallyUnavailable") or a.get("isUnconditionallyDeprecated")
                   or "deprecated" in a or "obsoleted" in a for a in symbol.get("availability", [])):
                continue
            kind = symbol["kind"]["identifier"].replace("swift.", "")
            if kind == "extension":
                continue
            key = (".".join(components), kinds.get(kind, kind))
            out.setdefault(key, symbol.get("location", {}).get("uri", ""))
    return out


def cmd_report(args):
    header, entries, declined = read_manifest()
    total = kept = skipped = 0
    by_area = collections.defaultdict(collections.Counter)
    for path, entry in entries.items():
        tests = test_spans(convert_imports(open(os.path.join(UPSTREAM_TESTS, path)).read()))
        names = {name for name, _, _ in tests}
        removed = sum(1 for n in entry.removed if n.split(".")[-1] in names)
        skip = len(entry.skipped)
        area = path.split("/")[0]
        by_area[area]["tests"] += len(tests)
        by_area[area]["passing"] += len(tests) - removed - skip
        by_area[area]["files"] += 1
        total += len(tests)
        kept += len(tests) - removed
        skipped += skip
    all_tests = sum(len(test_spans(open(os.path.join(UPSTREAM_TESTS, p)).read())) for p in all_upstream_files())
    print(f"ported files: {len(entries)}/{len(all_upstream_files())}; declined: {len(declined)}")
    print(f"tests in ported files: {total}; compiled: {kept}; skipped at runtime: {skipped}; "
          f"running: {kept - skipped}")
    print(f"running tests over the whole upstream suite: {kept - skipped}/{all_tests} "
          f"({100 * (kept - skipped) / all_tests:.1f}%)")
    for area, c in sorted(by_area.items(), key=lambda kv: -kv[1]["tests"]):
        print(f"  {area:18s} {c['passing']:5d}/{c['tests']:5d} running in {c['files']} files")


def main():
    commands = {
        "sync": cmd_sync, "typecheck": cmd_typecheck, "autoexclude": cmd_autoexclude,
        "skips": cmd_skips, "api": cmd_api, "report": cmd_report, "run": cmd_run,
    }
    if len(sys.argv) < 2 or sys.argv[1] not in commands:
        sys.exit(__doc__)
    commands[sys.argv[1]](sys.argv[2:])


if __name__ == "__main__":
    main()
