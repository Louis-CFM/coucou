// @ts-nocheck — kept as its authors wrote it, in plain JavaScript, so it can be
// compared with and updated from the original.
//
// From dotpals (dotpals contributors), MIT (https://github.com/Rikinshah787/dotpals),
// bridge/ui/testout.js at 6f3cf5d, itself adapted from claude-referee by Ismail
// Dasci, MIT (https://github.com/ismaildasci/claude-referee). Their notices are in
// windows/THIRD_PARTY_NOTICES.md.
//
// What a test run's output says: how many tests passed, failed, errored or were
// skipped, and which ones failed. Read only from the structured lines each test
// runner prints (summaries, FAIL markers, failing test ids); prose in the log is
// ignored. The worst case wins: a failure marker anywhere beats a passing summary,
// and output cut off before its summary never counts as a pass.
//
// Adapted from claude-referee by Ismail Dasci, MIT:
//   https://github.com/ismaildasci/claude-referee/blob/main/src/engine/runners/js.ts
//   https://github.com/ismaildasci/claude-referee/blob/main/src/engine/runners/python.ts
//   https://github.com/ismaildasci/claude-referee/blob/main/src/engine/runners/compiled.ts
//   https://github.com/ismaildasci/claude-referee/blob/main/src/engine/runners/php-ruby.ts
//   https://github.com/ismaildasci/claude-referee/blob/main/src/engine/runners/index.ts
// Ported to plain JavaScript, with a few additions for dotpals: TAP and a node:test
// summary without its "tests" line, python's unittest, Maven, Gradle, Deno and Bun,
// and a last-resort "5 passed / 1 failed" reader (marked below).
//
// Pure: no Node APIs, so it runs in the pal and the dashboard too.

const ANSI = /\u001b(?:\[[0-?]*[ -/]*[@-~]|\][^\u0007\u001b]*(?:\u0007|\u001b\\)?)/g;
const MAX_FAILING = 10;
const MAX_NAME = 120;

const toLines = (text) => String(text ?? '').replace(ANSI, '').split(/\r\n|\r|\n/);
const names = (ids) => {
  const out = [];
  for (const raw of ids) {
    const id = String(raw).trim().slice(0, MAX_NAME);
    if (id && !out.includes(id)) out.push(id);
    if (out.length === MAX_FAILING) break;
  }
  return out;
};
const facts = (runner, { passed = 0, failed = 0, errors = 0, skipped = 0, failing = [], lint = false }) => ({ runner, passed, failed, errors, skipped, failing: names(failing), lint });

// -- JavaScript: jest, vitest, mocha, node:test, eslint, tsc --------------------------

/** "1 failed, 5 passed, 2 skipped, 8 total" → counts. */
function countsOf(body) {
  const c = { passed: 0, failed: 0, skipped: 0 };
  for (const m of String(body).matchAll(/(\d+)\s+(failed|passed|skipped|todo|pending|total)\b/g)) {
    const n = Number(m[1]);
    if (m[2] === 'failed') c.failed += n;
    else if (m[2] === 'passed') c.passed += n;
    else if (m[2] !== 'total') c.skipped += n;
  }
  return c;
}

/** The last line matching `re` (its counts) and the most failures any such line reported. */
function tally(lines, re) {
  const t = { line: null, last: { passed: 0, failed: 0, skipped: 0 }, failedMax: 0 };
  for (const l of lines) {
    const m = re.exec(l);
    if (!m) continue;
    t.line = l;
    t.last = countsOf(m[1] ?? '');
    t.failedMax = Math.max(t.failedMax, t.last.failed);
  }
  return t;
}

function jest(text) {
  const lines = toLines(text);
  const tests = tally(lines, /^\s*Tests:\s+(\d.*)$/);
  const suites = tally(lines, /^\s*Test Suites:\s+(\d.*)$/);
  const noTests = lines.some((l) => /^\s*No tests found\b/.test(l));
  const ids = new Set();
  const files = new Set();
  let runErrors = 0;
  for (const l of lines) {
    const h = /^\s*● (.+?)\s*$/.exec(l);
    if (h) {
      if (/^Test suite failed to run\b/.test(h[1])) runErrors++;
      else if (!/^(?:Console|Validation Warning|Deprecation Warning)\b/.test(h[1])) ids.add(h[1]);
      continue;
    }
    const f = /^\s*FAIL\s+(\S*[./]\S*)(?:\s+\(.*\))?\s*$/.exec(l);
    if (f) files.add(f[1]);
  }
  if (tests.line === null && suites.line === null && !noTests && !ids.size && !files.size && !runErrors) return null;
  const failed = Math.max(tests.failedMax, ids.size, !ids.size && !runErrors ? files.size : 0);
  const errors = Math.max(runErrors, failed === 0 ? suites.failedMax : 0);
  return facts('jest', { passed: tests.last.passed, failed, errors, skipped: tests.last.skipped, failing: ids.size ? ids : files });
}

function vitest(text) {
  const lines = toLines(text);
  const tests = tally(lines, /^\s*Tests\s+(\d.*)$/);
  const files = tally(lines, /^\s*Test Files\s+(\d.*)$/);
  const noFiles = lines.some((l) => /^\s*No test files found\b/.test(l));
  const ids = new Set();
  const loadFails = new Set();
  const marked = new Set();
  let unhandled = 0;
  for (const l of lines) {
    const f = /^\s*FAIL\s+(\S.*?)\s*$/.exec(l);
    if (f) {
      if (f[1].includes(' > ')) ids.add(f[1]);
      else if (/\[.*\]$/.test(f[1])) loadFails.add(f[1]);
      continue;
    }
    const m = /^\s*❯ (\S+) \(\d+ tests?(?: \| (\d+) failed)?/.exec(l);
    if (m && Number(m[2] ?? 0) > 0) { marked.add(m[1]); continue; }
    const e = /^\s*Errors\s+(\d+) errors?\b/.exec(l);
    if (e) unhandled = Math.max(unhandled, Number(e[1]));
  }
  if (tests.line === null && files.line === null && !noFiles && !(ids.size + loadFails.size + marked.size) && !unhandled) return null;
  const failed = Math.max(tests.failedMax, ids.size, !ids.size && marked.size ? marked.size : 0);
  const errors = Math.max(loadFails.size, unhandled, failed === 0 ? files.failedMax : 0);
  return facts('vitest', { passed: tests.last.passed, failed, errors, skipped: tests.last.skipped, failing: ids.size + loadFails.size ? [...ids, ...loadFails] : marked });
}

function mocha(text) {
  const lines = toLines(text);
  let passIdx = -1;
  let pendIdx = -1;
  let failIdx = -1;
  let passed = 0;
  let skipped = 0;
  let failedMax = 0;
  let ticks = false;
  lines.forEach((l, i) => {
    const m = /^\s*(\d+) (passing|failing|pending)\b/.exec(l);
    if (m) {
      const n = Number(m[1]);
      if (m[2] === 'passing') [passIdx, passed] = [i, n];
      else if (m[2] === 'pending') [pendIdx, skipped] = [i, n];
      else [failIdx, failedMax] = [i, Math.max(failedMax, n)];
    } else if (/^\s*[✔✓]\s/.test(l)) ticks = true;
  });
  if (pendIdx < passIdx) skipped = 0;
  const summary = passIdx >= 0 || failIdx >= 0 || pendIdx >= 0;
  const ids = new Map();
  if (summary || ticks) {
    lines.forEach((l, i) => {
      const m = /^\s{2,}(\d+)\) (\S.*?)\s*$/.exec(l);
      if (!m) return;
      let name = m[2];
      const next = i > failIdx && failIdx >= 0 ? /^\s{5,}(\S.*):\s*$/.exec(lines[i + 1] ?? '') : null;
      if (next) name = `${name} > ${next[1]}`;
      ids.set(Number(m[1]), name);
    });
  }
  if (!summary && !ids.size) return null;
  return facts('mocha', { passed, failed: Math.max(failedMax, ids.size), skipped, failing: ids.values() });
}

/**
 * node --test: "ℹ tests 5 / ℹ pass 5 / ℹ fail 0". dotpals addition: the TAP reporter's
 * "# pass 5" lines too, and a summary without its "tests" line ("… | Select-String pass").
 */
function nodeTest(text) {
  const lines = toLines(text);
  const num = (key) => {
    const re = new RegExp(`^\\s*(?:ℹ|#) ${key} (\\d+)\\s*$`);
    for (let i = lines.length - 1; i >= 0; i--) { const m = re.exec(lines[i]); if (m) return Number(m[1]); }
    return null;
  };
  const pass = num('pass');
  const fail = num('fail');
  const ids = new Set();
  let inFailing = false;
  for (const l of lines) {
    if (/^✖ failing tests:\s*$/.test(l)) inFailing = true;
    const m = /^✖ (.+?) \(\d+(?:\.\d+)?ms\)\s*$/.exec(l);
    if (m && !inFailing) ids.add(m[1]);
    const tap = /^not ok \d+ - (.+?)\s*(?:#.*)?$/.exec(l);
    if (tap) ids.add(tap[1]);
  }
  const failed = Math.max(fail ?? 0, ids.size);
  if (pass === null && fail === null && failed === 0) return null;
  return facts('node:test', { passed: pass ?? 0, failed, skipped: (num('skipped') ?? 0) + (num('todo') ?? 0), failing: ids });
}

function eslint(text) {
  const lines = toLines(text);
  let summary = false;
  let errorsMax = 0;
  let file = '';
  const entries = new Set();
  for (const l of lines) {
    const s = /^\s*✖\s+(\d+) problems?\s+\((\d+) errors?,\s*(\d+) warnings?\)/.exec(l);
    if (s) { summary = true; errorsMax = Math.max(errorsMax, Number(s[2])); continue; }
    const d = /^\s+(\d+):(\d+)\s+(error|warning)\s+(.*?)(?:\s{2,}([@\w/.-]+))?\s*$/.exec(l);
    if (d) {
      if (d[3] === 'error') entries.add(`${file ? `${file}:` : ''}${d[1]}:${d[2]} ${d[5] ?? 'error'}`);
      summary = true;
      continue;
    }
    if (/^\S*[./\\]\S*$/.test(l)) file = l;
  }
  if (!summary) return null;
  return facts('eslint', { errors: Math.max(errorsMax, entries.size), failing: entries, lint: true });
}

function tsc(text) {
  const lines = toLines(text);
  let summary = false;
  let errorsMax = 0;
  const entries = new Set();
  for (const l of lines) {
    const s = /^\s*(?:\[[^\]]*\]\s*)?Found (\d+) errors?\b/.exec(l);
    if (s) { summary = true; errorsMax = Math.max(errorsMax, Number(s[1])); continue; }
    const a = /^\s*(\S+?)\((\d+),(\d+)\):\s+error\s+(TS\d+):/.exec(l) ?? /^\s*(\S+?):(\d+):(\d+)\s+-\s+error\s+(TS\d+):/.exec(l);
    if (a) { entries.add(`${a[1]}:${a[2]}:${a[3]} ${a[4]}`); continue; }
    const g = /^\s*error\s+(TS\d+):/.exec(l);
    if (g) entries.add(g[1]);
  }
  if (!summary && !entries.size) return null;
  return facts('tsc', { errors: Math.max(errorsMax, entries.size), failing: entries, lint: true });
}

// -- Python: pytest, ruff (and unittest, a dotpals addition) ---------------------------

const TIME = String.raw`in \d+(?:\.\d+)?s(?: \(\d+:\d{2}:\d{2}\))?`;
const PYTEST_SUMMARY = new RegExp(String.raw`^(?:\d+ (?:failed|passed|skipped|deselected|xfailed|xpassed|warnings?|errors?|rerun)(?:, )?)+ ${TIME}$`);
const PYTEST_NO_TESTS = new RegExp(String.raw`^no tests ran ${TIME}$`);
const PYTEST_EMPTY = /^(?:=+\s*|collecting \.\.\. )?collected 0 items\b.*$/;
const PYTEST_TEST_ID = /^[\w./\\-]+\.py(?:::\S.*)?$/;

function pytestCounts(line) {
  const out = { failed: 0, passed: 0, skipped: 0, errors: 0 };
  for (const m of line.matchAll(/(\d+) (failed|passed|skipped|errors?)\b/g)) {
    const key = m[2].startsWith('error') ? 'errors' : m[2];
    out[key] = Math.max(out[key], Number(m[1]));
  }
  return out;
}

function pytest(text) {
  const failedIds = new Set();
  const errorIds = new Set();
  const summaries = [];
  let empty = false;
  let failuresBlock = false;
  let errorsBlock = false;
  for (const raw of toLines(text)) {
    const line = raw.trim();
    const bare = line.replace(/^=+\s*|\s*=+$/g, '');
    if (PYTEST_SUMMARY.test(bare) || PYTEST_NO_TESTS.test(bare)) { summaries.push(line); continue; }
    if (PYTEST_EMPTY.test(line)) { empty = true; continue; }
    if (/^=+ FAILURES =+$/.test(line)) failuresBlock = true;
    else if (/^=+ ERRORS =+$/.test(line)) errorsBlock = true;
    const collect = /^_+ ERROR collecting (\S+\.py) _+$/.exec(line);
    if (collect) { errorIds.add(collect[1]); continue; }
    const short = /^(?:\[gw\d+\]\s+)?(?:\[\s*\d+%\]\s+)?(FAILED|ERROR)\s+(.+)$/.exec(line);
    if (short) {
      const id = short[2].split(' - ')[0].trim();
      if (PYTEST_TEST_ID.test(id)) (short[1] === 'FAILED' ? failedIds : errorIds).add(id);
      continue;
    }
    const verbose = /^([\w./\\-]+\.py::\S.*?)\s+(FAILED|ERROR)\b/.exec(line);
    if (verbose) (verbose[2] === 'FAILED' ? failedIds : errorIds).add(verbose[1]);
  }
  const markers = failedIds.size + errorIds.size > 0 || failuresBlock || errorsBlock;
  if (!summaries.length && !empty && !markers) return null;
  let failed = Math.max(failedIds.size, failuresBlock ? 1 : 0);
  let errors = Math.max(errorIds.size, errorsBlock ? 1 : 0);
  for (const s of summaries) {
    const c = pytestCounts(s);
    failed = Math.max(failed, c.failed);
    errors = Math.max(errors, c.errors);
  }
  const tail = pytestCounts(summaries.at(-1) ?? '');
  return facts('pytest', { passed: tail.passed, failed, errors, skipped: tail.skipped, failing: [...failedIds, ...errorIds] });
}

/** dotpals addition: python -m unittest ("Ran 5 tests in 0.01s", then "OK" or "FAILED (failures=1)"). */
function unittest(text) {
  const lines = toLines(text);
  let ran = null;
  let result = null;
  const ids = new Set();
  for (const raw of lines) {
    const line = raw.trim();
    const r = /^Ran (\d+) tests? in \d/.exec(line);
    if (r) { ran = Number(r[1]); continue; }
    const o = /^(OK|FAILED)(?: \((.*)\))?$/.exec(line);
    if (o && ran !== null) { result = { ok: o[1] === 'OK', counts: o[2] ?? '' }; continue; }
    const f = /^(?:FAIL|ERROR): (\S+) \((\S+)\)/.exec(line);
    if (f) ids.add(`${f[2]}.${f[1]}`);
  }
  if (ran === null) return null;
  const count = (key) => Number(new RegExp(`\\b${key}=(\\d+)`).exec(result?.counts ?? '')?.[1] ?? 0);
  const failed = Math.max(count('failures'), result && !result.ok && !count('errors') ? 1 : 0);
  const errors = count('errors');
  const skipped = count('skipped') + count('expected failures');
  // No OK/FAILED line yet: cut off before the result, so nothing passed for sure.
  const passed = result ? Math.max(0, ran - failed - errors - skipped) : 0;
  return facts('unittest', { passed, failed, errors, skipped, failing: ids });
}

function ruff(text) {
  const violations = new Set();
  let found = 0;
  let fixable = 0;
  let clean = false;
  let header = null;
  for (const raw of toLines(text)) {
    const line = raw.trim();
    const f = /^Found (\d+) errors?\.$/.exec(line);
    if (f) { found = Math.max(found, Number(f[1])); continue; }
    if (/^All checks passed!$/.test(line)) { clean = true; continue; }
    const fix = /^\[\*\] (\d+) fixable with the .{0,4}--fix.{0,4} option/.exec(line);
    if (fix) { fixable = Math.max(fixable, Number(fix[1])); continue; }
    const concise = /^(\S+?):(\d+):(\d+): ([A-Z]{1,4}\d{2,4})(?: |$)/.exec(raw.trimStart());
    if (concise) { violations.add(`${concise[1]}:${concise[2]}:${concise[3]} ${concise[4]}`); continue; }
    const head = /^([A-Z]{1,4}\d{2,4}) (?:\[\*\] )?\S/.exec(line);
    if (head) { header = head[1]; continue; }
    const arrow = /^\s*--> (\S+?):(\d+):(\d+)$/.exec(raw);
    if (arrow && header) { violations.add(`${arrow[1]}:${arrow[2]}:${arrow[3]} ${header}`); header = null; }
  }
  if (!clean && !found && !fixable && !violations.size) return null;
  return facts('ruff', { errors: Math.max(found, violations.size, fixable), failing: violations, lint: true });
}

// -- compiled: go test, cargo test, dotnet test (and Maven, Gradle: dotpals additions) ---

// Subtests (`TestX/sub`) are reported next to their parent, so only top-level ids count.
const topLevel = (ids) => { const top = [...ids].filter((n) => !n.includes('/')).length; return top > 0 ? top : ids.size; };

function goTest(text) {
  const lines = toLines(text);
  let summaries = 0;
  const failedIds = new Set();
  const passedIds = new Set();
  const skippedIds = new Set();
  const startedIds = new Set();
  let okPackages = 0;
  let failedPackages = 0;
  let buildFailed = 0;
  let other = false;
  let panic = false;
  let goroutine = false;
  let bareFail = false;
  for (const line of lines) {
    const ok = /^ok\s+\S+\s+(?:[\d.]+s\b|\(cached\))(.*)$/.exec(line);
    if (ok) { summaries++; if (!/\[no tests to run\]/.test(ok[1] ?? '')) okPackages++; continue; }
    if (/^FAIL\s+\S+\s+(?:[\d.]+s\b|\[(?:build|setup) failed\])/.test(line)) {
      summaries++;
      if (/\[(?:build|setup) failed\]/.test(line)) buildFailed++;
      else failedPackages++;
      continue;
    }
    if (/^\?\s+\S+\s+\[no test files\]/.test(line)) { summaries++; continue; }
    const t = /^\s*--- (FAIL|PASS|SKIP): (\S+)/.exec(line);
    if (t) {
      other = true;
      (t[1] === 'FAIL' ? failedIds : t[1] === 'PASS' ? passedIds : skippedIds).add(t[2]);
      continue;
    }
    const started = /^\s*=== RUN\s+(\S+)/.exec(line);
    if (started) startedIds.add(started[1]);
    if (/^\s*=== (?:RUN|PAUSE|CONT)\s/.test(line)) other = true;
    else if (/^panic: /.test(line)) panic = true;
    else if (/^goroutine \d+ \[/.test(line)) goroutine = true;
    else if (/^FAIL\s*$/.test(line)) bareFail = true;
  }
  if (!summaries && !other && !(panic && goroutine)) return null;
  const unfinished = [...startedIds].some((id) => !failedIds.has(id) && !passedIds.has(id) && !skippedIds.has(id)) ? 1 : 0;
  const errors = buildFailed + unfinished + (panic && (goroutine || other || summaries) ? 1 : 0);
  const failed = Math.max(failedPackages, topLevel(failedIds), bareFail && !errors ? 1 : 0);
  if (!summaries && !failed && !errors) return null;
  return facts('go test', { passed: Math.max(okPackages, topLevel(passedIds)), failed, errors, skipped: topLevel(skippedIds), failing: failedIds });
}

function cargoTest(text) {
  const lines = toLines(text);
  let results = 0;
  const failedIds = new Set();
  const compile = new Set();
  let passed = 0;
  let failedSum = 0;
  let ignored = 0;
  let okLines = 0;
  let failedStatus = false;
  let couldNotCompile = false;
  let testFailedLine = false;
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i];
    // "ignored" is optional here: dotpals sees clipped and filtered output too.
    const r = /^test result: (ok|FAILED)\.\s*(\d+) passed;\s*(\d+) failed;(?:\s*(\d+) ignored;)?/.exec(line);
    if (r) {
      results++;
      passed += Number(r[2]);
      failedSum += Number(r[3]);
      ignored += Number(r[4] ?? 0);
      if (r[1] === 'FAILED') failedStatus = true;
      continue;
    }
    const t = /^test (.+?) \.\.\. (ok|FAILED|ignored)\b/.exec(line);
    if (t) { if (t[2] === 'FAILED') failedIds.add(t[1]); else if (t[2] === 'ok') okLines++; continue; }
    const s = /^---- (.+?) stdout ----$/.exec(line);
    if (s) { failedIds.add(s[1]); continue; }
    if (/^failures:\s*$/.test(line)) {
      for (let j = i + 1; j < lines.length; j++) {
        const item = /^ {4}([\w:]+|\S+ - .+ \(line \d+\))$/.exec(lines[j]);
        if (!item) break;
        failedIds.add(item[1]);
      }
      continue;
    }
    if (/^error\[E\d+\]/.test(line)) compile.add(line);
    else if (/^error: could not compile /.test(line)) couldNotCompile = true;
    else if (/^error: test failed, to rerun pass/.test(line)) testFailedLine = true;
  }
  const errors = compile.size || (couldNotCompile ? 1 : 0);
  const failed = Math.max(failedSum, failedIds.size, failedStatus || testFailedLine ? 1 : 0);
  if (!results && !failed && !errors) return null;
  return facts('cargo test', { passed: results ? passed : okLines, failed, errors, skipped: ignored, failing: failedIds });
}

function dotnetTest(text) {
  const lines = toLines(text);
  let summaries = 0;
  const failedIds = new Set();
  const buildErrors = new Set();
  let passed = 0;
  let failedSum = 0;
  let skipped = 0;
  let passedLines = 0;
  let failedStatus = false;
  let noTests = false;
  let runFailed = false;
  let buildFailed = false;
  for (const line of lines) {
    const s = /^\s*(Passed|Failed)!\s+-\s+Failed:\s*(\d+),\s*Passed:\s*(\d+),\s*Skipped:\s*(\d+),\s*Total:\s*(\d+)/.exec(line);
    if (s) {
      summaries++;
      failedSum += Number(s[2]);
      passed += Number(s[3]);
      skipped += Number(s[4]);
      if (s[1] === 'Failed') failedStatus = true;
      continue;
    }
    const f = /^\s+Failed (.+?) \[[^\]]*\]\s*$/.exec(line);
    if (f) { failedIds.add(f[1]); continue; }
    if (/^\s+Passed (.+?) \[[^\]]*\]\s*$/.test(line)) { passedLines++; continue; }
    // MSBuild and compiler codes (CS0103, MSB3073, NETSDK1045), not TypeScript's (TS2322).
    if (/\berror (?!TS\d)[A-Z]{2,6}\d{3,5}:/.test(line)) { buildErrors.add((/^(.*?)\s*(?:\[[^\]]*\.\w*proj\])?\s*$/.exec(line)?.[1] ?? line).trim()); continue; }
    if (/^\s*No test is available\b/.test(line)) noTests = true;
    else if (/^\s*Test Run Failed\.?\s*$/.test(line)) runFailed = true;
    else if (/^\s*Build FAILED\.?\s*$/.test(line)) buildFailed = true;
  }
  const errors = buildErrors.size || (buildFailed ? 1 : 0);
  const failed = Math.max(failedSum, failedIds.size, failedStatus || runFailed ? 1 : 0);
  if (!summaries && !noTests && !failed && !errors) return null;
  return facts('dotnet test', { passed: summaries ? passed : passedLines, failed, errors, skipped, failing: failedIds });
}

/** dotpals addition: Maven Surefire ("Tests run: 5, Failures: 1, Errors: 0, Skipped: 0"). The last one is the total. */
function maven(text) {
  const lines = toLines(text);
  let last = null;
  let failedMax = 0;
  let errorsMax = 0;
  const ids = new Set();
  for (const l of lines) {
    const m = /^(?:\[\w+\]\s+)?Tests run:\s*(\d+),\s*Failures:\s*(\d+),\s*Errors:\s*(\d+),\s*Skipped:\s*(\d+)/.exec(l);
    if (m) {
      last = m.slice(1).map(Number);
      failedMax = Math.max(failedMax, last[1]);
      errorsMax = Math.max(errorsMax, last[2]);
      continue;
    }
    const f = /^(?:\[ERROR\]\s+)(\S+?[.#]\S+?)(?::\d+)?\s+(?:»|<<<)\s/.exec(l);
    if (f) ids.add(f[1]);
  }
  if (!last) return null;
  const [run, failed, errors, skipped] = last;
  return facts('maven', { passed: Math.max(0, run - failed - errors - skipped), failed: Math.max(failed, failedMax), errors: Math.max(errors, errorsMax), skipped, failing: ids });
}

/** dotpals addition: Gradle ("5 tests completed, 1 failed, 1 skipped" and "> Task :test FAILED"). */
function gradle(text) {
  const lines = toLines(text);
  let summary = null;
  let taskFailed = false;
  const ids = new Set();
  for (const l of lines) {
    const m = /^\s*(\d+) tests? completed(?:, (\d+) failed)?(?:, (\d+) skipped)?/.exec(l);
    if (m) { summary = m.slice(1).map((x) => Number(x ?? 0)); continue; }
    if (/^> Task :\S*test\S* FAILED$/i.test(l.trim())) taskFailed = true;
    const f = /^(\S+) > (.+?) FAILED$/.exec(l.trim());
    if (f) ids.add(`${f[1]} > ${f[2]}`);
  }
  if (!summary && !ids.size) return null;
  const [done = 0, failed = 0, skipped = 0] = summary ?? [];
  return facts('gradle', { passed: Math.max(0, done - failed - skipped), failed: Math.max(failed, ids.size, taskFailed && !summary ? 1 : 0), skipped, failing: ids });
}

/** dotpals addition: Deno ("ok | 5 passed | 0 failed") and Bun (" 5 pass", " 0 fail"). */
function denoBun(text) {
  const lines = toLines(text);
  let deno = null;
  let pass = null;
  let fail = null;
  let skip = 0;
  for (const l of lines) {
    const d = /^(ok|FAILED) \| (\d+) passed(?: \((\d+) steps?\))? \| (\d+) failed(?: \((\d+) steps?\))?(?: \| (\d+) ignored)?/.exec(l.trim());
    if (d) { deno = [Number(d[2]), Number(d[4]), Number(d[6] ?? 0)]; continue; }
    const b = /^\s*(\d+) (pass|fail|skip|todo)\s*$/.exec(l);
    if (b) {
      if (b[2] === 'pass') pass = Number(b[1]);
      else if (b[2] === 'fail') fail = Number(b[1]);
      else skip += Number(b[1]);
    }
  }
  if (deno) return facts('deno', { passed: deno[0], failed: deno[1], skipped: deno[2] });
  if (pass !== null && fail !== null) return facts('bun', { passed: pass, failed: fail, skipped: skip });
  return null;
}

// -- PHP and Ruby: PHPUnit, RSpec -------------------------------------------------------

function phpunit(text) {
  const all = toLines(text).map((l) => l.replace(/\s+$/, ''));
  const candidates = [];
  const failureIds = new Map();
  const errorIds = new Map();
  let section = null;
  let summaryFailures = 0;
  let summaryErrors = 0;
  let headerFailures = 0;
  let headerErrors = 0;
  let failFloor = 0;
  let errFloor = 0;
  let progressFail = false;
  const counts = (rest) => {
    const out = {};
    for (const m of rest.matchAll(/([A-Za-z][A-Za-z ]*?):\s*(\d+)/g)) out[m[1].toLowerCase()] = Math.max(out[m[1].toLowerCase()] ?? 0, Number(m[2]));
    return out;
  };
  for (const line of all) {
    let m;
    if ((m = /^OK \((\d+) tests?, (\d+) assertions?\)/.exec(line))) { candidates.push({ passed: Number(m[1]), skipped: 0 }); section = null; }
    else if (/^OK, but .*!$/.test(line)) { candidates.push({ passed: 0, skipped: 0 }); section = null; }
    else if ((m = /^Tests:\s*(\d+)\s*(?:,(.*?))?\.?$/.exec(line))) {
      const c = counts(m[2] ?? '');
      const failures = c.failures ?? 0;
      const errors = c.errors ?? 0;
      const skipped = c.skipped ?? 0;
      summaryFailures = Math.max(summaryFailures, failures);
      summaryErrors = Math.max(summaryErrors, errors);
      candidates.push({ passed: Math.max(0, Number(m[1]) - failures - errors - skipped), skipped });
      section = null;
    } else if (/^No tests executed!/.test(line)) { candidates.push({ passed: 0, skipped: 0 }); section = null; }
    else if (/^FAILURES!$/.test(line)) { failFloor = 1; section = null; }
    else if (/^ERRORS!$/.test(line)) { errFloor = 1; section = null; }
    else if ((m = /^There (?:was|were) (\d+) ([a-z ]+?)s?:$/i.exec(line))) {
      const n = Number(m[1]);
      const kind = m[2].toLowerCase();
      if (kind === 'failure') { section = 'failure'; headerFailures = Math.max(headerFailures, n); }
      else if (kind === 'error') { section = 'error'; headerErrors = Math.max(headerErrors, n); }
      else section = 'other';
    } else if (section === 'failure' || section === 'error') {
      if ((m = /^(\d+)\) ([\w\\]+::\S.*)$/.exec(line))) (section === 'failure' ? failureIds : errorIds).set(`${m[1]}) ${m[2]}`, m[2]);
    } else if (/^[.FEWSIRDN]+\s+\d+ \/ \d+ \(\s*\d+%\)$/.test(line.trim())) {
      if (/[FE]/.test(line.trim().split(/\s+/)[0])) progressFail = true;
    }
  }
  const last = candidates.at(-1);
  let failed = Math.max(summaryFailures, failureIds.size, headerFailures, failFloor);
  const errors = Math.max(summaryErrors, errorIds.size, headerErrors, errFloor);
  if (!failed && !errors && progressFail) failed = 1;
  if (!last && !failed && errors) failed = errors;
  if (!last && !failed && !errors) return null;
  return facts('phpunit', { passed: last?.passed ?? 0, failed, errors, skipped: last?.skipped ?? 0, failing: [...failureIds.values(), ...errorIds.values()] });
}

function rspec(text) {
  const all = toLines(text).map((l) => l.replace(/\s+$/, ''));
  const summaries = [];
  const numbered = new Map();
  const located = new Map();
  const loadErrors = new Set();
  let section = null;
  let summaryFailures = 0;
  let summaryErrors = 0;
  let failuresHeader = false;
  for (const line of all) {
    let m;
    if ((m = /^\s*(\d+) examples?, (\d+) failures?(?:, (\d+) pending)?(?:, (\d+) errors? occurred outside of examples)?\s*$/.exec(line))) {
      const failures = Number(m[2]);
      const pending = Number(m[3] ?? 0);
      summaryFailures = Math.max(summaryFailures, failures);
      summaryErrors = Math.max(summaryErrors, Number(m[4] ?? 0));
      summaries.push({ passed: Math.max(0, Number(m[1]) - failures - pending), skipped: pending });
      section = null;
    } else if (/^Failures:$/.test(line)) { section = 'failures'; failuresHeader = true; }
    else if (/^Failed examples:$/.test(line)) section = 'failed';
    else if (/^Pending:$/.test(line)) section = 'pending';
    else if (/^Finished in /.test(line)) section = null;
    else if ((m = /^rspec (\.?\/?\S+?:\d+(?:\[[\d:]+\])?|\.?\/\S+)\s*(?:#\s*(.*))?$/.exec(line))) located.set(m[1], `${m[1]}${m[2] ? ` # ${m[2]}` : ''}`);
    else if ((m = /^An error occurred while loading (\S+?)\.?$/.exec(line))) loadErrors.add(m[1]);
    else if (section === 'failures' && (m = /^\s*(\d+)\) (.+)$/.exec(line))) {
      const lm = /^An error occurred while loading (\S+?)\.?$/.exec(m[2]);
      if (lm) loadErrors.add(lm[1]);
      numbered.set(`${m[1]}) ${m[2]}`, m[2]);
    }
  }
  const last = summaries.at(-1);
  const failureIds = [...numbered.values()].filter((n) => !/^An error occurred while loading /.test(n));
  const failed = Math.max(summaryFailures, failureIds.length, located.size, failuresHeader && !loadErrors.size ? 1 : 0);
  const errors = Math.max(summaryErrors, loadErrors.size);
  if (!last && !failed && !errors) return null;
  return facts('rspec', { passed: last?.passed ?? 0, failed, errors, skipped: last?.skipped ?? 0, failing: located.size ? [...located.values()] : [...numbered.values()] });
}

/**
 * dotpals addition, used only when no runner above recognised the output: lines that
 * start with a count ("  4 passed (3.0s)", "1 failed", "12 passing"), as Playwright,
 * Cypress and many others print. dotpals read test results this way before.
 */
function counted(text) {
  const c = { passed: 0, failed: 0, skipped: 0 };
  let any = false;
  for (const l of toLines(text)) {
    for (const m of l.matchAll(/(?:^|[\s,|:(])(\d+)\s+(passed|passing|failed|failing|skipped|pending)\b/g)) {
      any = true;
      const n = Number(m[1]);
      if (/^pass/.test(m[2])) c.passed = Math.max(c.passed, n);
      else if (/^fail/.test(m[2])) c.failed = Math.max(c.failed, n);
      else c.skipped = Math.max(c.skipped, n);
    }
  }
  return any ? facts('tests', c) : null;
}

const RUNNERS = [pytest, unittest, ruff, jest, vitest, mocha, eslint, tsc, nodeTest, goTest, cargoTest, dotnetTest, maven, gradle, denoBun, phpunit, rspec];

/**
 * Facts from a test command's output:
 *   { runner, passed, failed, errors, skipped, total, failing: [names], parsed }
 * `parsed` is false when no runner's summary or failure markers were found; then
 * the counts are all 0 and the caller has only the exit status to go on.
 * When several runners show up ("tsc && jest"), the one that counted the most tests
 * speaks, and any failures or errors the others found are added (worst case wins).
 * Linters and type checkers (eslint, tsc, ruff) only ever add errors.
 */
export function parseTestOutput(output) {
  const text = String(output ?? '');
  const found = RUNNERS.map((parse) => parse(text)).filter(Boolean);
  if (!found.some((f) => !f.lint)) {
    const fallback = counted(text);
    if (fallback) found.push(fallback);
  }
  if (!found.length) return { runner: null, passed: 0, failed: 0, errors: 0, skipped: 0, total: 0, failing: [], parsed: false };
  const tests = found.filter((f) => !f.lint).sort((a, b) => (b.passed + b.failed + b.errors + b.skipped) - (a.passed + a.failed + a.errors + a.skipped));
  const lints = found.filter((f) => f.lint).sort((a, b) => b.errors - a.errors || b.failing.length - a.failing.length);
  const main = tests[0] ?? { ...lints[0], errors: 0, failing: [] };
  const out = { runner: main.runner, passed: main.passed, failed: main.failed, errors: main.errors, skipped: main.skipped, failing: [...main.failing] };
  const add = (f) => {
    out.failing = names([...out.failing, ...f.failing]);
    if (!out.runner.includes(f.runner)) out.runner = `${out.runner} + ${f.runner}`;
  };
  for (const f of tests.slice(1)) {
    if (f.failed + f.errors === 0) continue;
    out.failed = Math.max(out.failed, f.failed);
    out.errors = Math.max(out.errors, f.errors);
    add(f);
  }
  // Linters read the same lines in different ways ("Found 1 error." is tsc's and ruff's): count the most any one found.
  if (lints[0]?.errors) { out.errors += lints[0].errors; add(lints[0]); }
  out.total = out.passed + out.failed + out.errors + out.skipped;
  out.parsed = true;
  return out;
}

// -- why a test failed --------------------------------------------------------------------

const WHY_MAX = 140;
// A source file and line, as stack traces and failure headers show them ("test/math.test.js:5:10").
const WHERE = /((?:[\w.@-]+[\\/])*[\w.@-]+\.(?:[cm]?[jt]sx?|py|go|rs|rb|php|java|kt|cs|exs?)):(\d+)/;

/**
 * Why the first failing test failed, in its runner's own words, when the output says so:
 * { why, where? } or null. Only the first: for a person and for the agent, that's where to start.
 *   why    "expected 3, got -1" (jest's Expected/Received, node's expected/actual), else the
 *          assertion or error line: pytest's "assert -1 == 3", go's "sum(1, 2) = -1; want 3",
 *          "AssertionError: expected -1 to equal 3", "Expected values to be strictly equal: -1 !== 3"
 *   where  the first test file and line in it ("test/math.test.js:5"), else the first file that
 *          isn't a dependency's or the runtime's
 */
export function failureReason(output) {
  // `grep -n` puts "160-" or "160:" before each line.
  const lines = toLines(output).map((l) => l.trim().replace(/^\d+[-:]\s*/, ''));
  const value = (re) => { for (const l of lines) { const m = re.exec(l); if (m) return m[1].replace(/,$/, ''); } return null; };
  // "Must not equal" or "must not match": expected and actual are the same thing, so its own words say it better.
  const negated = lines.some((l) => /^operator:\s*'(?:not\w+|doesNot\w+)'/.test(l) || (/Error\b/.test(l) && /\b(?:to not|not to|unequal)\b/i.test(l)));
  const expected = negated ? null : value(/^Expected(?: value)?:\s+(.+)$/) ?? value(/^expected:\s+(.+)$/);
  const actual = negated ? null : value(/^Received(?: value)?:\s+(.+)$/) ?? value(/^actual:\s+(.+)$/);
  let why = expected != null && actual != null ? `expected ${expected}, got ${actual}` : null;
  if (!why) {
    // An error line can be another command's, crashed before the tests ran: look from the first
    // failing test on. Unless that's a test file that wouldn't load ("✖ test/x.test.js"): its error comes just before.
    const at = lines.findIndex((l) => /^(?:✖|✗|×|●|not ok\b|FAIL\b|FAILED\b|--- FAIL\b|E\s+\S|\d+\) )/.test(l));
    const from = at > 0 && !/\.(?:test|spec)\.\w+\b|\btest_\w+\.py\b|_test\.\w+\b/.test(lines[at]) ? at : 0;
    const j = lines.slice(from).findIndex((l) => /^E\s+\S/.test(l) || /^[\w./\\-]+_test\.go:\d+:\s/.test(l) || /^(?:\w+\s+)?\[?\w*(?:Assertion)?Error\b[^:]*:/.test(l) || /^assertion\b.*\bfailed\b/i.test(l));
    const i = j < 0 ? -1 : from + j;
    if (i >= 0) {
      why = lines[i].replace(/^E\s+/, '').replace(/^[\w./\\-]+_test\.go:\d+:\s+/, '');
      // "Expected values to be strictly equal:" says what follows: the values.
      if (why.endsWith(':')) why = `${why} ${lines.slice(i + 1).find(Boolean) ?? ''}`.trim();
    }
  }
  if (!why) return null;
  const spots = lines.map((l) => WHERE.exec(l)).filter((m) => m && !/node_modules|node:|internal[\\/]|site-packages/.test(m[0]));
  const spot = spots.find((m) => /test|spec/i.test(m[1])) ?? spots[0];
  const where = spot ? `${spot[1].split(/[\\/]/).slice(-2).join('/')}:${spot[2]}` : null;
  return { why: why.slice(0, WHY_MAX), ...(where ? { where } : {}) };
}
