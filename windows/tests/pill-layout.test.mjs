import { test } from "node:test";
import assert from "node:assert/strict";
import { existsSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { spawnSync } from "node:child_process";
import { pathToFileURL } from "node:url";
import { PILL_CATALOG } from "../src/core/pills.ts";

const edge = "C:\\Program Files (x86)\\Microsoft\\Edge\\Application\\msedge.exe";

test("agent pill labels clear animated mascots, badges and grid edges at Windows scales", {
  skip: !existsSync(edge),
}, (t) => {
  const temp = mkdtempSync(join(tmpdir(), "coucou-pills-"));
  try {
    const names = [...PILL_CATALOG.map((pill) => pill.name), "Claude Code", "A Very Long Agent Name"];
    const css = pathToFileURL(resolve("src/style.css")).href;
    const html = `<!doctype html><html><head><link rel="stylesheet" href="${css}"></head><body>
      <div id="root"><main class="overview" style="width:620px;height:84px;margin:42px 10px">
        <div class="left"></div><div class="right"><div class="card"><div class="pills"></div></div></div>
      </main></div><pre id="layout-result"></pre><script>
      const names = ${JSON.stringify(names)};
      const grid = document.querySelector('.pills');
      const root = document.querySelector('#root');
      const pills = ['idle', 'working', 'finished', 'error'].map((state) => {
        const pill = document.createElement('div');
        pill.className = 'pill';
        pill.dataset.state = state;
        pill.innerHTML = '<span class="mini" style="width:24px;height:24px"><canvas style="width:40px;height:40px"></canvas></span><span class="lbl"></span>';
        if (state === 'finished' || state === 'error') pill.insertAdjacentHTML('beforeend', '<span class="pill-badge"></span>');
        grid.append(pill);
        return pill;
      });
      const results = [];
      for (const theme of ['original', 'windowsDarkFrosted']) {
        root.dataset.appearance = theme;
        for (const name of [...names, 'Claude Desktop', 'Claude Desktop', 'Claude Desktop', 'Claude Desktop']) {
          const pill = pills[results.length % pills.length];
          const label = pill.querySelector('.lbl');
          label.textContent = name;
          pill.title = name;
          const box = pill.getBoundingClientRect();
          const text = label.getBoundingClientRect();
          const mascot = pill.querySelector('canvas').getBoundingClientRect();
          const badge = pill.querySelector('.pill-badge')?.getBoundingClientRect();
          results.push({ theme, name, state: pill.dataset.state, gap: text.left - mascot.right,
            center: Math.abs((text.top + text.bottom - mascot.top - mascot.bottom) / 2),
            inside: text.right <= box.right && box.right <= grid.getBoundingClientRect().right,
            badgeClear: !badge || text.right <= badge.left,
            clipped: label.scrollWidth > label.clientWidth,
            ellipsis: getComputedStyle(label).textOverflow, title: pill.title });
        }
      }
      document.querySelector('#layout-result').textContent = JSON.stringify(results);
      </script></body></html>`;
    const file = join(temp, "pills.html");
    writeFileSync(file, html);
    for (const scale of [1, 1.25, 1.5]) {
      const run = spawnSync(edge, ["--headless=new", "--disable-gpu", "--no-first-run",
        `--user-data-dir=${join(temp, `edge-${scale}`)}`, `--force-device-scale-factor=${scale}`,
        "--dump-dom", pathToFileURL(file).href], { encoding: "utf8", timeout: 20000 });
      if (run.error?.code === "EPERM") {
        t.skip("Browser process creation is blocked by this environment");
        return;
      }
      assert.equal(run.status, 0, String(run.error ?? run.stderr));
      const output = run.stdout.match(/<pre id="layout-result">([^<]+)<\/pre>/)?.[1];
      assert.ok(output, "Edge did not return layout measurements");
      const results = JSON.parse(output);
      assert.equal(results.length, (names.length + 4) * 2);
      for (const result of results) {
        assert.ok(result.gap >= 3.5, `${scale}x ${result.theme} ${result.name}: mascot overlaps label`);
        assert.ok(result.center <= 1, `${scale}x ${result.theme} ${result.name}: vertical alignment`);
        assert.ok(result.inside && result.badgeClear, `${scale}x ${result.theme} ${result.name}: label overflows pill or badge`);
        assert.equal(result.ellipsis, "ellipsis");
        assert.equal(result.title, result.name);
      }
      assert.ok(results.some((result) => result.name === "A Very Long Agent Name" && result.clipped));
    }
  } finally {
    rmSync(temp, { recursive: true, force: true });
  }
});
