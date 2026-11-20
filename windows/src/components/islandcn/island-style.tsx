export const IslandStyle = ({ id, css }: { id: string; css: string }) => (
  <style href={`islandcn-${id}`} precedence="islandcn">
    {css}
  </style>
);
