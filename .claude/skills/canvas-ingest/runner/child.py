"""One run of a lens, in a process of its own (runner/run.py starts it, twice, in an isolated environment).

    child.py RUN SCAN REPO COMMIT LENS OUT

RUN is 1 or 2: the two runs see different hash seeds (the environment's) and a clock that reads a different instant in each.
LENS is a lens file (`.canvas/lens.py`), or "-" for the default lens. The digest is written to OUT as JSON (indented by one
space, in the lens's own order), the warnings the lens gathered to OUT.warnings. A lens that raises shows its traceback."""
import json, os, sys, time

RUN, SCAN, REPO, COMMIT, LENS, OUT = sys.argv[1:7]
RUN = int(RUN)


def make_clock_differ(run):
    """The clock reads another instant in each run: time.time and time.time_ns, localtime, gmtime, ctime, asctime and strftime
    without a time given, clock_gettime on the wall clock, datetime's now, utcnow and today, and date.today (a run's instant
    still moves on, as the clock does). A lens that reads it gives two digests.

    `datetime.date` and `datetime.datetime` become subclasses that know `today` and `now`; what asks `isinstance(x, datetime.date)`
    or `isinstance(x, datetime.datetime)` of a value still gets the answer it would from the real classes."""
    import datetime
    base = {1: 1_000_000_000.0, 2: 1_600_000_000.0}[run]
    real_time, started = time.time, time.time()
    def now():
        return base + (real_time() - started)
    time.time = now
    time.time_ns = lambda: int(now() * 1_000_000_000)
    for name in ('localtime', 'gmtime', 'ctime'):
        def wrapped(seconds=None, _original=getattr(time, name)):
            return _original(now() if seconds is None else seconds)
        setattr(time, name, wrapped)
    real_asctime, real_strftime = time.asctime, time.strftime
    time.asctime = lambda when=None: real_asctime(time.localtime(now()) if when is None else when)
    time.strftime = lambda format, when=None: real_strftime(format, time.localtime(now()) if when is None else when)
    real_clock_gettime, real_clock_gettime_ns = time.clock_gettime, time.clock_gettime_ns
    time.clock_gettime = lambda clock: now() if clock == time.CLOCK_REALTIME else real_clock_gettime(clock)
    time.clock_gettime_ns = lambda clock: int(now() * 1_000_000_000) if clock == time.CLOCK_REALTIME else real_clock_gettime_ns(clock)
    plain_date, plain_datetime = datetime.date, datetime.datetime

    class DateKind(type):
        def __instancecheck__(cls, value):
            return isinstance(value, plain_date)

        def __subclasscheck__(cls, sub):
            return issubclass(sub, plain_date)

    class DatetimeKind(type):
        def __instancecheck__(cls, value):
            return isinstance(value, plain_datetime)

        def __subclasscheck__(cls, sub):
            return issubclass(sub, plain_datetime)

    class date(plain_date, metaclass=DateKind):
        @classmethod
        def today(cls):
            return cls.fromtimestamp(now())

    class datetime_(plain_datetime, metaclass=DatetimeKind):
        @classmethod
        def now(cls, tz=None):
            return cls.fromtimestamp(now(), tz)

        @classmethod
        def utcnow(cls):
            return cls.utcfromtimestamp(now())

        @classmethod
        def today(cls):
            return cls.fromtimestamp(now())

    datetime_.__name__ = datetime_.__qualname__ = 'datetime'
    date.__name__ = date.__qualname__ = 'date'
    datetime_.__module__ = date.__module__ = 'datetime'
    datetime.date, datetime.datetime = date, datetime_


def fail(message):
    print(f"lens: {message}", file=sys.stderr)
    sys.exit(1)


make_clock_differ(RUN)
SKILL = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
# What a lens can import: lenskit (the one package it needs, loaded from the skill's folder without putting that folder on the path,
# where the skill's own settings.py, ingest and runner would be importable by their bare names) and what sits beside the lens itself,
# in the folder first on the path. Python puts the script's own folder (runner/) first: out of it.
import importlib.util                        # noqa: E402
sys.path[:] = [p for p in sys.path if os.path.abspath(p or '.') != os.path.dirname(os.path.abspath(__file__))]
if LENS != '-':
    sys.path.insert(0, os.path.dirname(os.path.abspath(LENS)))       # a lens may keep helpers beside itself
_lenskit = importlib.util.spec_from_file_location('lenskit', os.path.join(SKILL, 'lenskit', '__init__.py'),
                                                  submodule_search_locations=[os.path.join(SKILL, 'lenskit')])
sys.modules['lenskit'] = importlib.util.module_from_spec(_lenskit)
_lenskit.loader.exec_module(sys.modules['lenskit'])
from lenskit import Repo, Scan, default      # noqa: E402

scan, repo = Scan.load(SCAN), Repo(REPO, COMMIT)
if LENS == '-':
    result = default.digest(scan, repo)
else:
    spec = importlib.util.spec_from_file_location('canvas_lens', LENS)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    if not callable(getattr(module, 'digest', None)):
        fail(f"{LENS} has no function digest(scan, repo)")
    result = module.digest(scan, repo)
repo.close()

# the digest's basic shape: a title, and lists of nodes and edges
if not isinstance(result, dict):
    fail(f"digest(scan, repo) returned {type(result).__name__}, not a dict (the digest: {{\"title\": ..., \"nodes\": [...], \"edges\": [...]}})")
digest = dict(result)
warnings = digest.pop('warnings', [])
if not isinstance(digest.get('title'), str) or not digest['title'].strip():
    fail("the digest has no \"title\": a string, what it is of")
for key in ('nodes', 'edges'):
    if not isinstance(digest.get(key), list):
        fail(f"the digest's \"{key}\" is not a list")
if not isinstance(warnings, list) or not all(isinstance(w, str) for w in warnings):
    fail("the digest's \"warnings\" is not a list of strings")
try:
    text = json.dumps(digest, indent=1) + '\n'
except TypeError as e:
    fail(f"the digest can't be written as JSON ({e}); a set becomes a sorted list")
with open(OUT, 'w', encoding='utf-8') as f:
    f.write(text)
with open(OUT + '.warnings', 'w', encoding='utf-8') as f:
    json.dump(warnings, f)
