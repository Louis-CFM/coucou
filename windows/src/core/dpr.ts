/** Calls `onChange` whenever the page's pixel density changes (the window moved to another display). Returns a stop function. */
export function watchDpr(onChange: () => void): () => void {
  if (typeof window.matchMedia !== "function") return () => {};
  let stop = () => {};
  const arm = () => {
    const list = window.matchMedia(`(resolution: ${window.devicePixelRatio}dppx)`);
    const fire = () => { list.removeEventListener("change", fire); onChange(); arm(); };
    list.addEventListener("change", fire);
    stop = () => list.removeEventListener("change", fire);
  };
  arm();
  return () => stop();
}
