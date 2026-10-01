#!/usr/bin/env python3
"""Flag closures that capture a for-loop variable.

In Lua 5.0 (the game's version) a function created inside a `for` loop that
refers to the loop's own variable sees the variable itself, not its value at
that iteration -- and once the loop has finished that is nil. Lua 5.1, which
the test suite also runs on, gives each iteration a fresh variable, so the bug
does not show there. Copy the variable into a local inside the loop body.

    python3 extras/check_loop_closures.py [files...]
"""
import re, sys, glob

KEYWORDS_OPEN = {'function', 'if', 'for', 'while', 'repeat', 'do'}

def tokens(src):
    # strip comments and strings
    src = re.sub(r'--\[(=*)\[.*?\]\1\]', ' ', src, flags=re.S)
    src = re.sub(r'--[^\n]*', ' ', src)
    src = re.sub(r'\[(=*)\[.*?\]\1\]', '""', src, flags=re.S)
    src = re.sub(r'"(\\.|[^"\\])*"', '""', src)
    src = re.sub(r"'(\\.|[^'\\])*'", '""', src)
    for m in re.finditer(r'[A-Za-z_][A-Za-z0-9_]*|\.\.\.|\.\.|[^\sA-Za-z0-9_]', src):
        line = src.count('\n', 0, m.start()) + 1
        yield m.group(0), line

def check(path):
    toks = list(tokens(open(path).read()))
    problems = []
    # stack of ('for', vars) / ('function',) / ('block',)
    stack = []
    i = 0
    n = len(toks)
    pending_do_for = None
    while i < n:
        t, line = toks[i]
        prev = toks[i - 1][0] if i > 0 else ''
        if t == 'for':
            # collect names up to 'in' or '='
            names = []
            j = i + 1
            while j < n and toks[j][0] not in ('in', '='):
                if re.match(r'[A-Za-z_]', toks[j][0]):
                    names.append(toks[j][0])
                j += 1
            pending_do_for = names
            i = j
            continue
        if t == 'do':
            if pending_do_for is not None:
                stack.append(('for', pending_do_for))
                pending_do_for = None
            else:
                stack.append(('block',))
        elif t == 'while':
            pending_do_for = None
            # its 'do' opens a plain block
            stack.append(('while',))
        elif t == 'function':
            stack.append(('function', line))
        elif t in ('if',):
            stack.append(('block',))
        elif t == 'repeat':
            stack.append(('block',))
        elif t == 'until':
            if stack: stack.pop()
        elif t == 'end':
            if stack:
                top = stack.pop()
                if top[0] == 'while':
                    pass
        elif re.match(r'[A-Za-z_]', t) and prev not in ('.', ':'):
            # is it a loop variable of a for that encloses the innermost function?
            fn_depth = None
            for k in range(len(stack) - 1, -1, -1):
                if stack[k][0] == 'function':
                    fn_depth = k
                    break
            if fn_depth is not None:
                for k in range(fn_depth - 1, -1, -1):
                    if stack[k][0] == 'function':
                        break
                    if stack[k][0] == 'for' and t in stack[k][1]:
                        problems.append((line, t, stack[fn_depth][1]))
                        break
        # a 'while' consumes the next 'do' as its own
        if t == 'do' and len(stack) >= 2 and stack[-2][0] == 'while' and stack[-1][0] == 'block':
            stack.pop()
        i += 1
    return problems

def main(argv):
    files = argv[1:] or sorted(glob.glob('modules/*.lua') + glob.glob('hook/lua/ui/game/*.lua'))
    bad = 0
    for f in files:
        for line, name, fline in check(f):
            bad += 1
            print('%s:%d: closure (line %d) captures loop variable %r' % (f, line, fline, name))
    print('%d closure(s) capturing a loop variable' % bad)
    return 1 if bad else 0

if __name__ == '__main__':
    sys.exit(main(sys.argv))
