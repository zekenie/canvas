#!/usr/bin/python3
"""The files of a commit that `prepare` installs from, for the stamp that says whether it must run again.

    git ls-tree -r -z SHA | lockfiles.py

Reads `ls-tree -r -z`'s records (NUL-ended, so no path is quoted or cut at a newline) on standard input and prints a line, `<blob id>
<path>`, for each file at any depth with the name of a lockfile or of the manifest it is made from: npm's, Yarn's, pnpm's and
Bun's, Cargo's, Go's sums, Composer's, Pipenv's, Poetry's, uv's, Bundler's, Gradle's, Swift's, and pip's `requirements*.txt`."""
import re, sys

NAMES = re.compile(rb'(package\.json|package-lock\.json|npm-shrinkwrap\.json|yarn\.lock|pnpm-lock\.yaml|bun\.lockb?|Package\.resolved|'
                   rb'Gemfile\.lock|poetry\.lock|uv\.lock|Pipfile\.lock|Cargo\.lock|go\.sum|composer\.lock|gradle\.lockfile|requirements.*\.txt)')

for record in sys.stdin.buffer.read().split(b'\0'):
    head, _, path = record.partition(b'\t')
    if path and NAMES.fullmatch(path.rpartition(b'/')[2]):
        sys.stdout.buffer.write(head.split(b' ')[-1] + b' ' + path + b'\n')
