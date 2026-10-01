#!/usr/bin/env python3
"""
TeamMouse -- extras/check_upvalues.py

Warns when a function is close to Forged Alliance's Lua 5.0 upvalue limit.

    python3 extras/check_upvalues.py                 # checks modules/*.lua
    python3 extras/check_upvalues.py modules/teammouse.lua

Why this exists
---------------
Lua 5.0 allows at most 32 upvalues per function. A function pays for every
module-level local that it OR ANYTHING NESTED INSIDE IT refers to, because the
value has to be threaded through the enclosing function. Going over the limit
is a load-time error -- "too many upvalues (limit=32)" -- and the whole module
fails to import, which takes the mod down with it. Lua 5.1 allows 60, so the
test suite (which runs on 5.1) will not notice.

This is an approximation: it counts the module-level locals whose names appear
inside each top-level function, and it does not model shadowing. It matched the
real compiler exactly when it was written (33 for the function that failed).
The authoritative check is loading the file with an actual Lua 5.0:

    lua50 -e "assert(loadfile('modules/teammouse.lua'))"

Exit status is 1 if any function is at or over WARN_AT.
"""

import glob
import os
import re
import sys

LIMIT = 32
WARN_AT = 29     # leave a little headroom; the next edit will add one


def module_locals(lines):
    names = set()
    for line in lines:
        m = re.match(r'^local\s+function\s+(\w+)', line)
        if m:
            names.add(m.group(1))
            continue
        m = re.match(r'^local\s+([\w\s,]+?)\s*(=|$)', line)
        if m:
            for name in m.group(1).split(','):
                name = name.strip()
                if name:
                    names.add(name)
    return names


def top_level_functions(lines):
    for i, line in enumerate(lines):
        if re.match(r'^(local\s+)?function\s+\w+', line) or re.match(r'^\w+\s*=\s*function', line):
            yield i


def check(path):
    with open(path, encoding='utf-8') as handle:
        lines = handle.read().split('\n')

    names = module_locals(lines)
    results = []

    for start in top_level_functions(lines):
        end = next((j for j in range(start + 1, len(lines)) if lines[j].startswith('end')),
                   len(lines) - 1)
        body = re.sub(r'--[^\n]*', '', '\n'.join(lines[start:end + 1]))
        own = re.match(r'^(?:local\s+)?(?:function\s+)?(\w+)', lines[start]).group(1)
        used = set(i for i in re.findall(r'(?<![\.\w])([A-Za-z_]\w*)', body)
                   if i in names and i != own)
        results.append((len(used), own, start + 1))

    return sorted(results, reverse=True)


def main(argv):
    paths = argv[1:] or sorted(glob.glob(os.path.join('modules', '*.lua')))
    worst = 0

    for path in paths:
        results = check(path)
        if not results:
            continue
        top = results[0][0]
        worst = max(worst, top)
        flag = ''
        if top >= LIMIT:
            flag = '   OVER THE LIMIT'
        elif top >= WARN_AT:
            flag = '   close to the limit'
        print('%-28s worst: %2d / %d%s' % (path, top, LIMIT, flag))
        for count, name, line in results:
            if count >= WARN_AT:
                print('    %2d  %s (line %d)' % (count, name, line))

    return 1 if worst >= WARN_AT else 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
