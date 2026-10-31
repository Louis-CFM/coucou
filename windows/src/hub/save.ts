import { h } from "../views/dom";

/** One write at a time; keep the form intact until the native store confirms it. */
export function pageSave(page: HTMLElement) {
  const error = h("div", { class: "hub-warn", role: "alert" });
  error.hidden = true;
  page.append(error);
  let pending = false;
  return async (write: () => Promise<void>): Promise<"saved" | "failed" | "pending"> => {
    if (pending) return "pending";
    pending = true;
    error.textContent = "";
    error.hidden = true;
    const controls = [...page.querySelectorAll<HTMLInputElement | HTMLSelectElement | HTMLTextAreaElement | HTMLButtonElement>("input, select, textarea, button")]
      .map(el => ({ el, disabled: el.disabled }));
    for (const { el } of controls) el.disabled = true;
    try {
      await write();
      return "saved";
    } catch (cause) {
      error.textContent = cause instanceof Error ? cause.message : String(cause);
      error.hidden = false;
      return "failed";
    } finally {
      for (const { el, disabled } of controls) el.disabled = disabled;
      pending = false;
    }
  };
}
