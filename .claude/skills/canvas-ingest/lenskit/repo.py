"""The code at one commit, read through git and never the working tree: an edit that is not committed is not seen.

    repo = Repo("/path/to/checkout")                # the commit HEAD points at, now
    repo.files("**/*.py")                           # the commit's paths, sorted, that match
    repo.read("pkg/app.py")                         # text: UTF-8, with U+FFFD where it isn't
    repo.read_bytes("logo.png"); repo.exists("x")
    repo.commit                                     # the commit's sha

`files` takes a glob over the whole path: `*` and `?` stay inside a folder's name, `**` crosses folders (`**/` also
matches no folder at all, so `**/*.py` takes `a.py`), `[abc]` is one of those characters. No pattern is every path. A
submodule is not a file. Git plumbing does it all: `git ls-tree -r -z` once, `git cat-file --batch` kept open."""
import os, re, subprocess


class Repo:
    def __init__(self, root, commit='HEAD'):
        self._root = os.path.abspath(root)
        self.name = os.path.basename(self._root)
        self.commit = self._git('rev-parse', '--verify', commit + '^{commit}').decode().strip()
        self._entries = None
        self._batch = None

    def _git(self, *args):
        done = subprocess.run(['git', '-C', self._root, *args], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        if done.returncode != 0:
            raise RuntimeError(f"git {' '.join(args)} in {self._root}: {done.stderr.decode(errors='replace').strip()}")
        return done.stdout

    def _tree(self):
        """{path: object id} of the commit's files, read once."""
        if self._entries is None:
            entries = {}
            for record in self._git('ls-tree', '-r', '-z', self.commit).split(b'\0'):
                if not record:
                    continue
                head, _, path = record.partition(b'\t')
                mode, kind, oid = head.split(b' ')
                if kind == b'blob':
                    entries[path.decode('utf-8', 'surrogateescape')] = oid.decode()
            self._entries = entries
        return self._entries

    def files(self, pattern=None):
        paths = sorted(self._tree())
        if pattern is None:
            return paths
        match = glob(pattern)
        return [p for p in paths if match.fullmatch(p)]

    def exists(self, path):
        return path in self._tree()

    def read_bytes(self, path):
        oid = self._tree().get(path)
        if oid is None:
            raise FileNotFoundError(f"{path} is not in commit {self.commit[:12]}")
        if self._batch is None:
            self._batch = subprocess.Popen(['git', '-C', self._root, 'cat-file', '--batch'],
                                           stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
        self._batch.stdin.write(oid.encode() + b'\n')
        self._batch.stdin.flush()
        header = self._batch.stdout.readline().split()
        if len(header) != 3 or header[1] != b'blob':
            raise RuntimeError(f"git cat-file could not read {path} ({oid}): {b' '.join(header).decode(errors='replace')}")
        size = int(header[2])
        data = self._batch.stdout.read(size)
        self._batch.stdout.read(1)          # the newline that ends an object
        return data

    def read(self, path):
        return self.read_bytes(path).decode('utf-8', errors='replace')

    def close(self):
        if self._batch is not None:
            self._batch.stdin.close()
            self._batch.wait()
            self._batch = None

    def __enter__(self):
        return self

    def __exit__(self, *_):
        self.close()


def glob(pattern):
    """A compiled regular expression for a path glob: `*` and `?` within a name, `**` across folders."""
    out, i = [], 0
    while i < len(pattern):
        c = pattern[i]
        if pattern.startswith('**/', i):
            out.append('(?:.*/)?')
            i += 3
        elif pattern.startswith('**', i):
            out.append('.*')
            i += 2
        elif c == '*':
            out.append('[^/]*')
            i += 1
        elif c == '?':
            out.append('[^/]')
            i += 1
        elif c == '[':
            end = pattern.find(']', i + 2)
            if end < 0:
                out.append(re.escape(c))
                i += 1
            else:
                body = pattern[i + 1:end]
                out.append('[' + ('^' if body.startswith('!') else '') + body.lstrip('!').replace('\\', '\\\\') + ']')
                i = end + 1
        else:
            out.append(re.escape(c))
            i += 1
    return re.compile(''.join(out), re.DOTALL)
