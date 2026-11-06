// The loop's two moves on a node, and the state they change. A node is popular either way round: many arrows point at it, or it
// points at many. Promoting a node that many point at makes it a pill target, and each of its users reaches it through a pill beside the
// user (D17). Fanning out a node that points at many is the mirror: each of its uses becomes a pill beside it, standing for the shape
// it uses. Either way the arrows it had are gone, and the board says the same thing.

/**
 * The search's state: the promoted nodes (and the order they came in), the fanned-out ones (and theirs), the hosts and splits of shared
 * pills, and the edges set apart (`from` + NUL + `to`): each a pill of its own beside its start, because its arrow ran too long.
 */
export const ext = (state, over) => Object.assign({
  promoted: state.promoted, order: state.order, fanned: state.fanned || new Set(), fans: state.fans || [], hosts: state.hosts, splits: state.splits,
  apart: state.apart || new Set(),
}, over);

/** Whether an edge may be set apart as a pill of its own: any edge but one the digest says is never a pill, or to a shape no pill stands for. */
export function mayBeApart(model, e) {
  return !e.direct && !model.node(e.to).never;
}

/** The state with a candidate's move made: `mode` 'in' promotes the node, 'out' fans it out. */
export function withMove(state, c) {
  return c.mode === 'out'
    ? ext(state, { fanned: new Set(state.fanned || []).add(c.node), fans: (state.fans || []).concat([c.node]) })
    : ext(state, { promoted: new Set(state.promoted).add(c.node), order: state.order.concat([c.node]) });
}

/** The state with a node's move taken back. */
export function withoutMove(state, node, mode) {
  return mode === 'out'
    ? ext(state, { fanned: new Set([...(state.fanned || [])].filter((t) => t !== node)), fans: (state.fans || []).filter((t) => t !== node) })
    : ext(state, { promoted: new Set([...state.promoted].filter((t) => t !== node)), order: state.order.filter((t) => t !== node) });
}

/** The keys of the pill groups a move makes: those for the promoted node, or those of the fanned-out node's own edges. */
export function moveGroups(layouter, trial, c) {
  return new Set(layouter.pillPlan(trial).groups
    .filter((g) => (c.mode === 'out' ? g.edges.some((e) => e.from === c.node) : g.target === c.node)).map((g) => g.key));
}

/** Whether fanning out `from` turns its edge `e` into a pill: an edge on its board that may be a pill, to a shape a pill may stand for. */
export function fansOut(model, e) {
  return !e.cross && !e.via && !e.direct && !model.node(e.to).never;
}

/** The shapes a fanned-out node's pills stand for on its board: what fanning it out makes pill targets. */
export function fanTargets(model, v) {
  return (model.out.get(v) || []).filter((e) => fansOut(model, e)).map((e) => e.to);
}
