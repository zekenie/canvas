export const meta = {
  name: 'history-review',
  description: 'Review commit messages against their sessions (Sonnet), rewrite the ones that need it (Opus), verify (Sonnet), revise (Opus)',
  whenToUse: "The history skill's weekly review, with the args `review.py args` prints",
  phases: [
    { title: 'Review', detail: 'Sonnet: one agent per session group, verdicts and missing intent', model: 'sonnet' },
    { title: 'Write', detail: 'Opus: final messages for commits that need work, and squash runs', model: 'opus' },
    { title: 'Verify', detail: 'Sonnet: try to refute every new or changed sentence', model: 'sonnet' },
    { title: 'Revise', detail: 'Opus: apply the objections that hold', model: 'opus' },
  ],
}

// args, from `review.py args <run>`: {repo, memory, routes: {review, write, verify, revise: {model,
// effort}}, groups: [{id, commits: [{n, sha, subject}], sessions, raw, note, mustWrite}]}.
const R = args.routes
const REPO = args.repo
const MEM = args.memory

const AUDIENCE = `Who reads these messages: agents (and people) who will later change this code and need to know why it is the way it is, from \`git log\` and blame alone. A message serves them when it says: why the change exists (the problem, in the owner's own framing, and what prompted it); where the idea came from (data-canvas, tldraw, Keynote, another session's finding); the decisions that shaped it and whose they were (the owner's answers to questions and mid-session corrections, said as the owner's; calls the session made on its own, said as such); alternatives considered and turned down, with the reason; constraints and invariants the change sets up or relies on that a later change must respect; findings that shaped it (measured numbers, platform behavior); and what was left out on purpose or deferred. Not wanted: process noise (worktrees, reviews run, rebases, test counts, the session's own slips fixed before landing), implementation detail the diff already shows plainly, anything changed or reverted before the commit landed, and anything that belongs to another commit.`

const VOICE = `Voice, matching the repo's messages (read a few with \`git -C ${REPO} log -5 --format=%B\`): plain declarative English; dense sentences joined with colons, semicolons and commas; identifiers bare or in backticks; paragraphs, not bullets; no "we" or "I"; never "the user": the person whose project it is is "the owner", with no gendered pronouns for anyone. Quote the owner exactly, typos and all, and only what the transcript shows them saying. Keep the subject line unless it is wrong. Keep the message's own line style (older messages wrap near 100 columns, newer ones are unwrapped paragraphs). Keep the other trailer lines exactly (a Co-Authored-By line names the model that wrote the code), and leave Session: trailers out: a later step sets them. Length is what the intent needs: a small change keeps a short message.`

const SQUASH = `Squashing: only consecutive commits on main, never reordered, so the end state is unchanged. Commits are one piece of work when they are the same request, or a fix or follow-up that only finishes the commit just before it with nothing else between. Separate asks stay separate commits, even from one session; the owner has asked for some follow-ups to land as their own commits.`

// Nested double quotes have broken a structured answer before.
const QUOTES = `In your answer's strings, quote with single quotes, never double.`

const sources = (g) => `Sources:
- The session record${g.sessions.length > 1 ? 's' : ''}: ${g.sessions.join(', ')}. Read ${g.sessions.length > 1 ? 'them' : 'it'} in full before judging, in chunks (Read with offset/limit). A record made at landing (the one a commit's Session: trailer names) covers its session up to that landing; a line "===== commit written: <subject> =====", in a record the review made, marks where a commit's message was written, and the work before it belongs to that commit, though intent from earlier in the session may too. Times are UTC; git dates may be -0500.
${g.raw.length ? `- The raw transcript, for a detail the record dropped or what came after a landing (large JSONL: grep it, don't read it whole): ${g.raw.join(', ')}` : '- There is no raw transcript for this group.'}
- The current message and the change: \`git -C ${REPO} log -1 --format=%B <sha>\`, \`git -C ${REPO} show --stat <sha>\`, \`git -C ${REPO} show <sha> -- <path>\`, and \`git -C ${REPO} show <sha>:<path>\` for a file as of that commit.
- The owner's durable preferences and the decisions behind features, as memory files: ${MEM}/*.md (MEMORY.md indexes them).
${g.note ? `\nAbout this group: ${g.note}` : ''}`

const commitList = (g) => g.commits.map(c => `${c.sha.slice(0, 8)} (#${c.n} of the commits under review) ${c.subject}`).join('\n')

const REVIEW_SCHEMA = {
  type: 'object',
  properties: {
    commits: { type: 'array', items: { type: 'object', properties: {
      sha: { type: 'string' },
      verdict: { type: 'string', enum: ['keep', 'touch-up', 'rewrite'] },
      intent_summary: { type: 'string', description: 'Why this commit exists, per the sources, in 2-4 plain sentences' },
      missing: { type: 'array', items: { type: 'object', properties: {
        point: { type: 'string' },
        category: { type: 'string', enum: ['motivation', 'origin', 'decision', 'owner-correction', 'rejected-alternative', 'constraint', 'finding', 'deferred', 'other'] },
        importance: { type: 'string', enum: ['high', 'medium', 'low'] },
        evidence: { type: 'string', description: 'Timestamp and an exact short quote from the record' },
      }, required: ['point', 'category', 'importance', 'evidence'] } },
      inaccuracies: { type: 'array', items: { type: 'object', properties: {
        claim: { type: 'string' }, problem: { type: 'string' }, evidence: { type: 'string' },
      }, required: ['claim', 'problem', 'evidence'] } },
    }, required: ['sha', 'verdict', 'intent_summary', 'missing', 'inaccuracies'] } },
    squash_runs: { type: 'array', items: { type: 'object', properties: {
      shas: { type: 'array', items: { type: 'string' } }, reason: { type: 'string' },
    }, required: ['shas', 'reason'] } },
  },
  required: ['commits', 'squash_runs'],
}

const MESSAGES_SCHEMA = {
  type: 'object',
  properties: {
    messages: { type: 'array', items: { type: 'object', properties: {
      shas: { type: 'array', items: { type: 'string' }, description: 'One commit, or a consecutive run squashed into one' },
      message: { type: 'string', description: 'The full message: subject, blank line, body, trailer lines' },
      notes: { type: 'string', description: 'What changed from the current message and why, in two or three sentences' },
    }, required: ['shas', 'message', 'notes'] } },
    declined: { type: 'array', items: { type: 'object', properties: {
      what: { type: 'string' }, reason: { type: 'string' },
    }, required: ['what', 'reason'] } },
  },
  required: ['messages', 'declined'],
}

const VERIFY_SCHEMA = {
  type: 'object',
  properties: {
    messages: { type: 'array', items: { type: 'object', properties: {
      shas: { type: 'array', items: { type: 'string' } },
      problems: { type: 'array', items: { type: 'object', properties: {
        quote: { type: 'string', description: 'The sentence or phrase at fault, or "missing" for a lost fact' },
        problem: { type: 'string' },
        evidence: { type: 'string' },
        fix: { type: 'string' },
      }, required: ['quote', 'problem', 'evidence', 'fix'] } },
    }, required: ['shas', 'problems'] } },
  },
  required: ['messages'],
}

const reviewPrompt = (g) => `Review git commit messages in ${REPO} against the record of the session that produced them. Read-only: do not modify the repo, build, or commit.

${AUDIENCE}

Commits in this group:
${commitList(g)}

${sources(g)}

For each commit, give a verdict. "keep" when the message already tells that reader why the change exists and what shaped it; many recent messages already do, so say keep when it is true and don't pad. "touch-up" when a few points are missing. "rewrite" only when the message is misleading or badly incomplete. List each missing point with its evidence (timestamp and an exact short quote) and how much it matters to that reader, and each claim in the current message that is wrong against the record or against the code at that commit. Attribute intent to the right commit: a point belongs to the commit whose diff embodies it.

${SQUASH}
List any run of this group's commits that should be squashed, with the reason; an empty list is a fine answer. Do not write messages. ${QUOTES}`

const writePrompt = (g, review) => `Write the final commit messages for commits in ${REPO} that a reviewer found wanting. Read-only: do not modify the repo, build, or commit; return the messages.

${AUDIENCE}

${VOICE}

Commits in this group:
${commitList(g)}

${sources(g)}

The reviewer's findings (Sonnet) are below. Treat them as leads, not facts: confirm each point in the record (find the quote) and against the code at that commit before you use it, and drop what you can't confirm. Keep every accurate fact in the current message that the reader above would want; you may tighten wording, and drop process noise and trivia. Lead with why. Write a message only for a commit whose verdict is touch-up or rewrite, or for a squash run you agree with; leave keeps out. ${SQUASH} For a squash, write one message for the run as it lands: what it adds up to, with bugs made and fixed inside the run left out, since they never existed on main. List in "declined" any finding or squash you didn't take, and why. ${QUOTES}

Reviewer's findings:
${JSON.stringify(review, null, 1)}`

const verifyPrompt = (g, written) => `Check rewritten commit messages for ${REPO} by trying to refute them. Read-only: do not modify the repo, build, or commit.

Commits in this group:
${commitList(g)}

${sources(g)}

For each message below, compare it with the commit's current message (\`git log -1 --format=%B <sha>\`). For every sentence that is new or changed: find its support in the session record (the owner's words for anything attributed to the owner) and in the code at that commit. Flag a claim you cannot support, one that overclaims (a decision credited to the owner that the session made, "rejected" for "not chosen"), one about work that changed before the commit landed or belongs to another commit, and an accurate, useful fact of the current message that was lost. Flag breaches of these rules too: ${VOICE}
Default to flagging when unsure. Report problems only, with a concrete fix for each; an empty list means the message stands. Do not rewrite messages. ${QUOTES}

Messages:
${JSON.stringify(written.messages, null, 1)}`

const revisePrompt = (g, written, verdicts) => `A verifier checked the commit messages below for ${REPO} and raised problems. Read-only: do not modify the repo, build, or commit.

${VOICE}

${sources(g)}

Check each problem against the sources; apply the ones that hold, and leave a message as it is where a problem doesn't hold (say so in its notes). Return every message, revised or not, in the same form. ${QUOTES}

Messages:
${JSON.stringify(written.messages, null, 1)}

Problems:
${JSON.stringify(verdicts.messages.filter(m => m.problems.length), null, 1)}`

const results = await pipeline(
  args.groups,
  (g) => agent(reviewPrompt(g), { label: `review:${g.id}`, phase: 'Review', schema: REVIEW_SCHEMA, model: R.review.model, effort: R.review.effort }),
  (review, g) => {
    if (!review) return null
    const needs = g.mustWrite || review.commits.some(c => c.verdict !== 'keep') || review.squash_runs.length > 0
    if (!needs) return { g, review, written: null }
    return agent(writePrompt(g, review), { label: `write:${g.id}`, phase: 'Write', schema: MESSAGES_SCHEMA, model: R.write.model, effort: R.write.effort })
      // A writer that died keeps its review, and the group is marked to run again.
      .then(written => written ? { g, review, written } : { g, review, written: null, writeFailed: true })
  },
  (r) => {
    if (!r || !r.written || !r.written.messages.length) return r
    return agent(verifyPrompt(r.g, r.written), { label: `verify:${r.g.id}`, phase: 'Verify', schema: VERIFY_SCHEMA, model: R.verify.model, effort: R.verify.effort })
      .then(verdicts => ({ ...r, verdicts }))
  },
  (r) => {
    if (!r || !r.written) return r ? { ...r, final: null } : null
    // A verifier that died on an API error leaves its messages as written, marked so.
    if (r.written.messages.length && !r.verdicts) return { ...r, final: r.written, unverified: true }
    if (!r.verdicts || !r.verdicts.messages.some(m => m.problems.length)) return { ...r, final: r.written }
    return agent(revisePrompt(r.g, r.written, r.verdicts), { label: `revise:${r.g.id}`, phase: 'Revise', schema: MESSAGES_SCHEMA, model: R.revise.model, effort: R.revise.effort })
      // A reviser that died, or returned fewer messages than it was given, leaves the drafts.
      .then(final => final && final.messages.length >= r.written.messages.length ? { ...r, final } : { ...r, final: r.written, unverified: true })
  },
)

const done = results.filter(Boolean)
const lost = args.groups.filter((g, i) => !results[i]).map(g => g.id)
log(`${done.length}/${args.groups.length} groups through every stage${lost.length ? `; no result for ${lost.join(', ')}` : ''}`)
return done.map(r => ({ id: r.g.id, review: r.review, written: r.written, verdicts: r.verdicts || null, final: r.final || null, unverified: !!r.unverified, writeFailed: !!r.writeFailed }))
