// GitLab card — the words, links and alerts that differ from GitHub's. Rust
// (src-tauri/src/gitlab.rs) sends the very shapes GitHub's pulse has, so the
// types, the readers and the summaries are core/github.ts's; a merge request is
// a GitHubPR, a project's default-branch pipeline a GitHubRepoCI.

import { t } from "../i18n/i18n";
import { GH_STRINGS } from "./github";

export type { GitHubSection as GitLabSection } from "./github";

/** Every word the GitLab card shows that GitHub's does not. */
export const GL_STRINGS = {
  title: "GitLab",
  get myPRs() { return t("My MRs"); },
  get mainCI() { return t("Default branch pipelines"); },
};

/** The sections' titles: GitHub's, with GitLab's own wording for the two that differ. */
export function glSectionTitle(section: "myPRs" | "toReview" | "mainCI" | "activity"): string {
  switch (section) {
    case "myPRs": return GL_STRINGS.myPRs;
    case "mainCI": return GL_STRINGS.mainCI;
    case "toReview": return GH_STRINGS.toReview;
    case "activity": return GH_STRINGS.activity;
  }
}

/** The instance the poll talked to, as Rust sent it; gitlab.com until the first answer. */
export function readBaseUrl(data: Record<string, unknown>): string {
  return typeof data.baseUrl === "string" && data.baseUrl ? data.baseUrl : "https://gitlab.com";
}

/** Only http(s) links to the configured instance open — a link GitLab returned is never trusted blindly. */
export function safeGitLabUrl(raw: string, baseUrl: string): string | null {
  let url: URL;
  let base: URL;
  try {
    url = new URL(raw);
    base = new URL(baseUrl);
  } catch {
    return null;
  }
  if (url.protocol !== "https:" && url.protocol !== "http:") return null;
  if (url.host !== base.host) return null;
  return url.toString();
}

/** A project's pipelines page, where a red default branch is explained. */
export function pipelinesUrl(projectUrl: string): string {
  return `${projectUrl.replace(/\/$/, "")}/-/pipelines`;
}

export function gitlabProfileUrl(baseUrl: string, login: string): string {
  return `${baseUrl.replace(/\/$/, "")}/${encodeURIComponent(login)}`;
}
