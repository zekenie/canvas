"""The scan a lens reads: what a scanner wrote (reference/scan.md has its format), with the lookups a lens makes of it.

    scan = Scan.load("scan.json")           # a lens is handed one, by `ingest`
    scan.modules["Core"]                    # a module by name (test modules too)
    scan.production                         # the names of the modules that are drawn, in the scan's order
    scan.files[("Core", "Store.swift")]     # a file by (module, its path in the module): production modules' only
    scan.uses                               # [(from, to, names)]: which file uses which, once a pair, with the names it uses

Nothing here is read from the environment or kept at module level: a Scan is a value made of the data it is given."""
import json


class Scan:
    def __init__(self, data):
        self.data = data                                        # the scan as the scanner wrote it
        self.language = data.get('language')                    # "swift", "typescript", ...: the words a note uses (lenskit.text)
        self.name = data.get('name')                            # what the code calls itself, or None
        self.modules = {m['name']: dict(m) for m in data['modules']}
        self.production = [m['name'] for m in data['modules'] if not m['test']]
        drawn = set(self.production)
        for name in self.production:
            # a module's imports, among the modules drawn (not a package from elsewhere, not itself)
            self.modules[name]['deps'] = [d for d in self.modules[name]['deps'] if d in drawn and d != name]
        self.files = {(f['module'], f['rel']): f for f in data['files'] if f['module'] in drawn}
        pairs = {}
        for u in data['uses']:
            pair = (tuple(u['from']), tuple(u['to']))
            names = pairs.setdefault(pair, [])
            names.extend([n for n in u['names'] if n not in names])
        self.uses = [(a, b, names) for (a, b), names in pairs.items()]

    @classmethod
    def load(cls, path):
        with open(path, encoding='utf-8') as f:
            return cls(json.load(f))

    def module(self, name):
        return self.modules[name]

    def file(self, module, path):
        return self.files[(module, path)]
