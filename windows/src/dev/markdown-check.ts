// Dev-only self-check for the chat Markdown renderer
// (npm run dev → /markdown-check.html; the page title becomes PASS or FAIL: …).

import { renderMarkdown } from "../views/markdown";

function html(src: string): string {
  const div = document.createElement("div");
  div.append(renderMarkdown(src));
  return div.innerHTML;
}

const cases: [string, string][] = [
  ["Use **bold** and *italic* and `code`.", "<p>Use <strong>bold</strong> and <em>italic</em> and <code>code</code>.</p>"],
  ["# Title\nline one\nline two", '<div class="md-h md-h1">Title</div><p>line one<br>line two</p>'],
  ["- a\n- **b**\n\n1. one\n2. two", "<ul><li>a</li><li><strong>b</strong></li></ul><ol><li>one</li><li>two</li></ol>"],
  ["```\nlet x = 1 < 2;\n```", "<pre><code>let x = 1 &lt; 2;</code></pre>"],
  // Markup in a reply stays text, never HTML.
  ['<img src=x onerror="alert(1)">', "<p>&lt;img src=x onerror=\"alert(1)\"&gt;</p>"],
  ["[site](https://example.com) and [bad](javascript:alert(1))", '<p><a title="https://example.com">site</a> and bad</p>'],
  ["> quoted\n\nafter", "<blockquote>quoted</blockquote><p>after</p>"],
];

const failures = cases
  .map(([src, want]) => [src, want, html(src)])
  .filter(([, want, got]) => want !== got)
  .map(([src, want, got]) => `${JSON.stringify(src)}\n  want ${want}\n  got  ${got}`);

document.title = failures.length ? `FAIL: ${failures.length}` : "PASS";
document.body.textContent = failures.length ? failures.join("\n\n") : `PASS (${cases.length} cases)`;
