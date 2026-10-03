// Dev-only self-check for the chat Markdown renderer
// (npm run dev → /markdown-check.html; the page title becomes PASS or FAIL: …).

import { loadKatex, renderMarkdown } from "../views/markdown";

const SAMPLE = `# Title
## Sub
#### Deep
line one
line two with **bold**, *italic*, \`code\`, ~~gone~~ and H<sub>2</sub>O, x<sup>2</sup>, <kbd>Ctrl</kbd>+<kbd>C</kbd><br>after br

| Left | Centre | Right |
|:-----|:------:|------:|
| a | **b** | 1 |
| c | d | 22 |

- [x] done
- [ ] todo
- parent
  - child
    - grandchild

1. one
2. two

> quoted
> more

> [!WARNING]
> careful here

---

Visit www.example.com or https://example.org/path and [site](https://example.com).
Bad: [js](javascript:alert(1)) [data](data:text/html,<script>alert(1)</script>) [mail](mailto:a@b.c)

Inline $E = mc^2$ and $\`\\sqrt{2}\`$, money $5 and $10, \\(a^2+b^2\\).

$$
\\int_0^\\infty e^{-x^2}\\,dx = \\frac{\\sqrt{\\pi}}{2}
$$

\`\`\`math
\\begin{pmatrix} a & b \\\\ c & d \\end{pmatrix}
\`\`\`

\`\`\`ts
let x = 1 < 2;
\`\`\`

A note[^1].

[^1]: The footnote.

<details><summary>More</summary>

Hidden **text**

</details>

<img src=x onerror="alert(1)">
<script>alert(2)</script>
<a href="JaVaScRiPt:alert(3)" onclick="alert(4)">evil</a>
<div style="background:url(https://evil.example/x)" class="island" id="foo">styled</div>
<svg onload="alert(5)"><circle r="5"/></svg>
<iframe src="https://evil.example"></iframe>
<form action="https://evil.example"><input type="text" name="q"><button>go</button></form>
<math><mi>x</mi></math>
<img src="https://example.com/cat.png" alt="cat">

![dog](https://example.com/dog.png)
`;

async function run(): Promise<string[]> {
  // ?shot: the app's styles on a dark card, for a screenshot.
  if (location.search.includes("shot")) {
    await import("../style.css");
    document.body.style.cssText = "background:#0b0c0e;width:620px;padding:12px;overflow:auto;height:auto";
  }
  const root = document.createElement("div");
  root.className = "reply md";
  root.append(renderMarkdown(SAMPLE));
  document.body.append(root);
  await loadKatex();
  await new Promise((r) => setTimeout(r, 50));

  const $ = (s: string) => root.querySelector(s);
  const $$ = (s: string) => [...root.querySelectorAll<HTMLElement>(s)];
  const text = root.textContent ?? "";
  const checks: [string, boolean][] = [
    ["heading h1", $(".md-h.md-h1")?.textContent === "Title"],
    ["heading h4 -> md-h3", $$(".md-h.md-h3").some((e) => e.textContent === "Deep")],
    ["soft line break", !!$("p br")],
    ["bold/italic/code/strike", !!$("p strong") && !!$("p em") && !!$("p > code") && $("del")?.textContent === "gone"],
    ["sub/sup/kbd/br", $("sub")?.textContent === "2" && $("sup")?.textContent === "2" && $$("kbd").length === 2],
    ["table wrapped", !!$(".md-table > table")],
    ["table alignment", $("th:nth-child(2)")?.getAttribute("align") === "center" && $("td:nth-child(3)")?.getAttribute("align") === "right"],
    ["task list", $$("input[type=checkbox][disabled]").length === 2 && $$("input:checked").length === 1],
    ["nested list", !!$("ul li ul li ul li")],
    ["ordered list", $$("ol > li").length >= 2],
    ["blockquote", !!$("blockquote")?.textContent?.includes("quoted")],
    ["hr", !!$("hr")],
    ["autolink www", $$("a").some((a) => a.title === "http://www.example.com")],
    ["autolink https", $$("a").some((a) => a.title === "https://example.org/path")],
    ["markdown link", $$("a").some((a) => a.title === "https://example.com" && a.textContent === "site")],
    ["no href anywhere", $$("[href]").length === 0],
    ["javascript:/data:/mailto: not links", !$$("a").some((a) => /^(js|data|mail|evil)$/.test(a.textContent ?? "")) && text.includes("js") && text.includes("evil")],
    ["inline math", $$("span.md-math .katex").length >= 3],
    ["display math", $$(".md-math .katex-display").length >= 2],
    ["money is not math", text.includes("$5 and $10")],
    ["fenced code block", $(".code-block .code-lang")?.textContent === "ts" && !!$(".code-block code")?.textContent?.includes("1 < 2")],
    ["footnote ref + list", !!$("sup a") && !!$("section.md-footnotes li[id^=user-content-]")],
    ["details/summary", $("details summary")?.textContent === "More" && !!$("details strong")],
    ["remote images become links", $$("a.md-img").map((a) => a.textContent).join("|") === "Image: cat|Image: dog"],
    ["no img element", $$("img").length === 0],
    ["no script/svg/iframe/form/button/math", $$("script, svg:not(.katex svg, .code-copy svg), iframe, form, button:not(.code-copy), math:not(.katex math)").length === 0],
    ["no text input", $$("input:not([type=checkbox])").length === 0],
    ["no on* attributes", $$("*").every((e) => ![...e.attributes].some((a) => a.name.startsWith("on")))],
    ["no style outside KaTeX", $$("[style]").every((e) => !!e.closest(".katex"))],
    ["model classes dropped", !$(".island")],
    ["ids prefixed", !$("#foo") && !!$("#user-content-foo")],
    ["github alert", $(".md-alert-warning .md-alert-title")?.textContent === "Warning" && !text.includes("[!WARNING]")],
    ["footnote back arrow is text", $$("a[data-footnote-backref]").every((a) => a.textContent === "↩︎")],
  ];
  return checks.filter(([, ok]) => !ok).map(([name]) => name).concat(`__count ${checks.length}`);
}

void run().then((res) => {
  const count = res.pop()!.split(" ")[1];
  document.title = res.length ? `FAIL: ${res.join(", ")}` : `PASS (${count} checks)`;
  const out = document.createElement("pre");
  out.id = "result";
  out.textContent = document.title;
  document.body.prepend(out);
}, (err) => {
  document.title = `FAIL: ${err}`;
});
