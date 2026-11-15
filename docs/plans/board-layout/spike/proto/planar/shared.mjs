// A direction with shared pills: its module's layoutBoard, then sharePills. node: import { withShared } from './shared.mjs'; withShared(mod)
import { sharePills } from './share.mjs';
export function withShared(mod, opts) {
  return { async layoutBoard(m, board) { const r = await mod.layoutBoard(m, board); const s = sharePills(m, board, r.layout, opts); return { layout: s.layout, info: Object.assign({}, r.info, { shared: s.merged, closed: s.closed }) }; } };
}
