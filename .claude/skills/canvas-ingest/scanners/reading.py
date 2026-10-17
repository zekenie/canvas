"""What every scanner shares: a doc's first sentence, and a folder's README."""
import os, re

ABBREVIATIONS = ('e.g.', 'i.e.', 'cf.', 'vs.')     # a period in them ends no sentence

def first_sentence(text, limit=230):
    text = re.sub(r'\s+', ' ', text).strip()
    # a sentence ends at ". " not inside backticks or parens
    depth, tick = 0, False
    for i, ch in enumerate(text):
        if ch == '`': tick = not tick
        elif not tick and ch == '(': depth += 1
        elif not tick and ch == ')': depth = max(0, depth - 1)
        elif not tick and depth == 0 and ch == '.' and (i + 1 == len(text) or text[i+1] == ' ') \
                and not any(text[:i + 1].endswith(a) for a in ABBREVIATIONS):
            s = text[:i+1]
            break
    else:
        s = text
    if len(s) > limit:
        cut = s[:limit].rsplit(' ', 1)[0].rstrip(',;:(')
        s = cut + '…'
    return s

def readme(folder):
    """The first sentence of a folder's README: of its first paragraph that's prose, not a heading, a badge, HTML or
    code. None when there's no README."""
    for name in ('README.md', 'README', 'readme.md'):
        p = os.path.join(folder, name)
        if not os.path.exists(p):
            continue
        for para in open(p, encoding='utf-8', errors='replace').read().split('\n\n'):
            lines = para.strip().split('\n')
            if lines and lines[0].startswith('```'):
                continue
            # drop headings: "# Title", and a setext title over its "====" or "----"
            lines = [l for i, l in enumerate(lines) if not l.lstrip().startswith('#')
                     and not re.fullmatch(r'\s*(=+|-+)\s*', l)
                     and not (i + 1 < len(lines) and re.fullmatch(r'\s*(=+|-+)\s*', lines[i + 1]))]
            text = ' '.join(l.strip() for l in lines if l.strip())
            if text and not text.startswith(('!', '<', '[!', '[![', '|', '>')):
                return first_sentence(text)
        return None
    return None
