// Legacy localization-format conversion, retained for regression coverage.
export function convertFormat(text, names = []) {
  let next = 0;
  return text.replace(/%(?:(\d+)\$)?(@|lld|ld|d|lu|u|f|%)/g, (_m, pos, spec) => {
    if (spec === "%") return "%";
    const index = pos ? Number(pos) - 1 : next++;
    return `{${names[index] ?? index}}`;
  });
}
