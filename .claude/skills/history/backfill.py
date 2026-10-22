"""Give every record in history/sessions/ its directory, and the plans of every session whose
transcript is still on this machine (SKILL.md, Backfill). A record kept as one file, <name>.md,
becomes <name>/transcript.md; a session's plans, found as condense.py finds them at landing, go in
<name>/plans/. A transcript already recorded stays as it was committed (the weekly review read
it), not condensed again. Running it again writes only plans that are new or changed; one that
can no longer be found stays as it was recorded.

    python3 backfill.py [--dry-run] [--dir history/sessions]
"""
import argparse, glob, os, re, sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import condense


def current_plans(record):
    root = os.path.join(record, "plans")
    return {os.path.relpath(os.path.join(d, n), root): open(os.path.join(d, n), errors="replace").read()
            for d, _, names in os.walk(root) for n in names}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dir", default="history/sessions")
    ap.add_argument("--dry-run", action="store_true")
    a = ap.parse_args()
    moved = [f.removesuffix(".md") for f in sorted(glob.glob(f"{a.dir}/*.md"))]
    both = [r for r in moved if os.path.exists(r)]
    if both:
        sys.exit(f"kept both as one file and as a directory: {', '.join(both)}")
    for record in moved:
        if not a.dry_run:
            os.makedirs(record)
            os.rename(f"{record}.md", f"{record}/transcript.md")
    records = sorted(set(moved) | {d for d in glob.glob(f"{a.dir}/*") if os.path.isdir(d)})
    gone, changed = [], []
    for record in records:
        name = os.path.basename(record)
        m = re.search(r"-([0-9a-f]{8})$", name)
        if not m or re.match(r"\d{4}-\d\d-\d\d-pr-\d+-", name):
            continue  # a cloud session's record is its pull request; its transcript was never here
        sids = sorted({os.path.basename(f)[:-6] for f in glob.glob(f"{condense.PROJECTS}*/{m.group(1)}*.jsonl")})
        if not sids:
            gone.append(name)
            continue
        if len(sids) > 1:
            print(f"{name}: sessions {', '.join(sids)} share its id's first 8 characters; left alone", file=sys.stderr)
            continue
        now = current_plans(record)
        found = {k: v for k, v in condense.plans(sids[0]).items() if now.get(k) != v}
        if found:
            changed.append((name, sorted(found)))
            if not a.dry_run:
                condense.write_plans(record, found)
    verb = "would " if a.dry_run else ""
    print(f"{verb}move {len(moved)} records into directories")
    print(f"{verb}write plans for {len(changed)} records:")
    for name, plans in changed:
        print(f"  {name}: {', '.join(plans)}")
    print(f"{len(gone)} records' transcripts are no longer on this machine")


if __name__ == "__main__":
    main()
