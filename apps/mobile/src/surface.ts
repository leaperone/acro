export function mapContainedPoint(
  point: { x: number; y: number },
  container: { w: number; h: number },
  content: { w: number; h: number },
): { x: number; y: number } | null {
  if (
    ![point.x, point.y, container.w, container.h, content.w, content.h].every(Number.isFinite) ||
    container.w <= 0 ||
    container.h <= 0 ||
    content.w <= 0 ||
    content.h <= 0
  ) {
    return null;
  }
  const scale = Math.min(container.w / content.w, container.h / content.h);
  const renderedWidth = content.w * scale;
  const renderedHeight = content.h * scale;
  const offsetX = (container.w - renderedWidth) / 2;
  const offsetY = (container.h - renderedHeight) / 2;
  if (
    point.x < offsetX ||
    point.x >= offsetX + renderedWidth ||
    point.y < offsetY ||
    point.y >= offsetY + renderedHeight
  ) {
    return null;
  }
  return { x: (point.x - offsetX) / scale, y: (point.y - offsetY) / scale };
}
