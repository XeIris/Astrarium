#!/usr/bin/env python3
"""Fail if a change touched anything but comments.

    tools/commentcheck.py [REV] [PATH...]

Strips comments and whitespace from each changed file at REV (default HEAD) and in
the working tree, and compares what is left. Handles GDScript/Python/shell
(`#`, with strings), gdshader/GLSL/JS (`//`, `/* */`, strings); Python
docstrings count as comments. Exit status 1 lists every file whose code changed.
"""
import re
import subprocess
import sys

HASH = {'.gd', '.py', '.sh'}
SLASH = {'.gdshader', '.gdshaderinc', '.glsl', '.js', '.mjs', '.c', '.h'}


def strip(src, ext):
    out, i, n = [], 0, len(src)
    while i < n:
        c = src[i]
        if ext in HASH and c == '#':
            while i < n and src[i] != '\n':
                i += 1
            continue
        if ext in SLASH and src.startswith('//', i):
            while i < n and src[i] != '\n':
                i += 1
            continue
        if ext in SLASH and src.startswith('/*', i):
            j = src.find('*/', i + 2)
            i = n if j < 0 else j + 2
            continue
        if ext == '.py' and src.startswith(('"""', "'''"), i):
            q = src[i:i + 3]
            j = src.find(q, i + 3)
            # A docstring stands alone on its line; anything else is a value.
            line_start = src.rfind('\n', 0, i) + 1
            if src[line_start:i].strip() == '':
                i = n if j < 0 else j + 3
                continue
            end = n if j < 0 else j + 3
            out.append(src[i:end])
            i = end
            continue
        if ext == '.gd' and src.startswith(('"""', "'''"), i):
            j = src.find(src[i:i + 3], i + 3)
            end = n if j < 0 else j + 3
            out.append(strip(src[i:end], '.gdshader'))
            i = end
            continue
        if c in '"\'' or (c == '`' and ext in {'.js', '.mjs'}):
            j = i + 1
            while j < n and src[j] != c:
                if src[j] == '\\':
                    j += 1
                elif src[j] == '\n' and c != '`' and ext not in HASH:
                    break
                j += 1
            lit = src[i:j + 1]
            if ext == '.gd' and '\n' in lit:
                # A multi-line string in GDScript is embedded shader source.
                lit = strip(lit, '.gdshader')
            out.append(lit)
            i = j + 1
            continue
        out.append(c)
        i += 1
    return re.sub(r'\s+', '', ''.join(out))


def ext_of(path):
    m = re.search(r'(\.[A-Za-z0-9]+)$', path)
    return m.group(1) if m else ''


def main():
    args = sys.argv[1:]
    rev = 'HEAD'
    if args and not args[0].startswith(('-', '.')) and '/' not in args[0] and '.' not in args[0]:
        rev = args.pop(0)
    changed = subprocess.check_output(
        ['git', 'diff', '--name-only', '--diff-filter=M', rev, '--', *args]).decode().split()
    bad, checked = [], 0
    for path in changed:
        ext = ext_of(path)
        if ext not in HASH | SLASH:
            continue
        old = subprocess.run(['git', 'show', f'{rev}:{path}'], capture_output=True).stdout.decode('utf-8', 'replace')
        new = open(path, encoding='utf-8', errors='replace').read()
        checked += 1
        if strip(old, ext) != strip(new, ext):
            bad.append(path)
    for p in bad:
        print('CODE CHANGED', p)
    print(f'{checked} files checked, {len(bad)} with code changes')
    return 1 if bad else 0


if __name__ == '__main__':
    sys.exit(main())
