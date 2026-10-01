# Testing & Verification Workflow

Follow this before treating any change to TeamMouse as finished. Each step has
caught a real bug that an earlier step missed -- they are not redundant with
each other.

## 1. Get the project extracted and a Lua 5.1 interpreter ready

The person will usually upload a zip of the whole project. Extract it to a
working copy, and keep an untouched copy of the exact uploaded zip on the side
(you'll diff against it later):

```bash
mkdir -p /tmp/pristine && cd /tmp/pristine && unzip -q /mnt/user-data/uploads/TeamMouse*.zip
cp -r /tmp/pristine/TeamMouse /home/claude/TeamMouse   # working copy, edit this one
```

`lua5.1`/`luac5.1` are commonly already installed; if not, `apt-get install -y
lua5.1` works in this environment. Lua 5.1 is what the mock test suite runs on
-- it is **not** the same runtime as the real game (see the next section for
why that matters and isn't just a formality).

One known one-time fixup on older exports of this project: `legacyprotocol.lua`
may still import `/mods/Mouse/modules/cursordata.lua` (a stale path from before
a rename). If so, change it to `import(_G.TeamMousePath ..
'/modules/cursordata.lua')`, matching every other cross-module import in the
project, before doing anything else.

## 2. Build and use a real Lua 5.0 interpreter -- do not skip this

**The mock suite alone is not sufficient.** Lua 5.1 allows 60 upvalues per
function; the real game's Lua 5.0 allows 32. A change that passes every mock
test can still fail to load in the actual game with `too many upvalues
(limit=32)`, and this has happened in practice more than once. Build a real Lua
5.0 once per session and keep it around:

```bash
cd /tmp && mkdir lua50 && cd lua50
curl -sSL -o lua.tar.gz -L https://codeload.github.com/lua/lua/tar.gz/refs/tags/v5.0
tar xzf lua.tar.gz --strip-components=1 -C . 2>/dev/null || (mkdir src && tar xzf lua.tar.gz -C src --strip-components=1)
cd src
# linit.c in this tag is a merge-conflict-marked placeholder; drop it and ltests.c
gcc -O1 -w -std=gnu89 -DLUA_USE_POSIX -o lua50 $(ls *.c | grep -v '^ltests.c$\|^linit.c$') -lm -ldl
```

Then, before delivering any change, confirm every module and hook file still
loads (this is a load/compile check only -- it does not run anything):

```bash
cat > /tmp/lua50/check.lua <<'EOF'
local bad = 0
for i = 1, table.getn(arg) do
    local f, err = loadfile(arg[i])
    if f then print('ok    ' .. arg[i]) else bad = bad + 1; print('FAIL  ' .. tostring(err)) end
end
if bad > 0 then os.exit(1) end
EOF
/tmp/lua50/src/lua50 /tmp/lua50/check.lua modules/*.lua hook/lua/ui/game/*.lua mod_info.lua
```

Every line must read `ok`. A `FAIL` here means the mod will not start in the
real game, regardless of what the mock suite says.

### A float build of Lua 5.0 -- the game's number type

FA's Lua numbers are 32-bit floats; stock Lua uses doubles. Build a second
interpreter with floats and run everything on it too (the compact wire
format's exactness depends on it, and float rounding can hide elsewhere):

```bash
cd /tmp/lua50/src
gcc -O1 -w -std=gnu89 -DLUA_USE_POSIX '-DLUA_NUMBER=float' '-DLUA_NUMBER_SCAN="%f"' \
    '-DLUA_NUMBER_FMT="%.7g"' -o lua50f $(ls *.c | grep -v '^ltests.c$\|^linit.c$') -lm -ldl
```

`print(16777217)` printing `1.677722e+07` confirms it. Note `wire_size.lua` /
`bandwidth_report.lua` give slightly different numbers here: an unrounded
value needs fewer digits as a float.

### The upvalue guard is a heuristic, not the authority

`extras/check_upvalues.py` estimates each function's upvalue count by counting
which module-level locals its source text refers to. It does not model
shadowing and is not the real compiler, but it caught the one real regression
that occurred at the value it predicted (33, against the limit of 32). Run it
as a fast pre-check:

```bash
python3 extras/check_upvalues.py
```

Treat any function it flags as needing the real Lua 5.0 load check above to
confirm either way, not as a pass/fail verdict on its own.

## 3. Run the full mock suite

```bash
cd /home/claude/TeamMouse
luac5.1 -p modules/*.lua extras/*.lua && echo OK   # syntax check, fast
for t in test_integration test_visibility test_replaycodec; do
    printf "%-18s " $t; lua5.1 extras/$t.lua 2>&1 | tail -1
done
lua5.1 extras/test_fuzz.lua 2>&1 | tail -8
```

There is a single known, pre-existing, cosmetic failure unrelated to most work
in this project: `HUD dot stays inside the panel at 1,1`, a geometric
positioning edge case in `hudghost.lua`. If the suite reports exactly this one
failure and nothing else, that's the expected clean baseline, not a regression
you introduced.

### What the mock can and can't tell you

`extras/mock_fa.lua` is a from-scratch simulation of just enough of the
engine's UI primitives (`Group`, `Bitmap`, `LazyVar`, a fake `WorldView`, a fake
root frame) for these tests to run standalone. It is **not** a real hit-test
engine:

- It has **no real spatial hit-testing**. A test can't "click at pixel (400,
  300) and see which control receives it" -- it can only call
  `control:HandleEvent(event)` directly on whatever control the test already
  has a reference to. Anything about *which* control the real engine's hit-test
  system would route an event to has to be verified by the person in the actual
  game, not by the mock.
- `ForkThread` and `WaitSeconds` are **deliberately no-ops** (`ForkThread`
  stores the function but never calls it; `WaitSeconds` returns immediately).
  Other code in this project relies on that -- e.g. the replay-playback loop's
  `while true do ... WaitSeconds(...) end` would spin forever if `WaitSeconds`
  ever actually waited zero real time inside a real loop. Don't change either
  to actually execute/wait without checking every existing caller first.
- `DisableHitTest` was originally a total no-op; it was upgraded to actually
  track a `_hitTestDisabled` flag specifically to let a test verify the
  cell-toggling mechanism. Nothing in the mock's own dispatch logic reads that
  flag to gate anything (there's no real hit-test tree to consult) -- it only
  lets a test assert "was this specific control asked to disable/enable."
- `Destroy()` marks a control destroyed (`_destroyed = true`) but does **not**
  remove it from its parent's own `children` list. Any test helper that walks
  `parent.children` looking for a named control (`Mock.FindDriver`,
  `Mock.FindCursors`, `Mock.FindDragOverlays`) must filter `not
  child._destroyed`, or a destroy-then-recreate cycle will look like duplicates
  existing simultaneously.
- `IsKeyDown` reads a small shared button-state tracker, updated by the
  default `HandleEvent` on `WorldView` and the root frame reacting to
  `ButtonPress`/`ButtonRelease`. It resets at the start of each
  `CreateEnvironment` call (each test session), which is enough for this
  suite's sequential, single-session-at-a-time tests but would not isolate
  correctly if a test ever ran two sessions concurrently.

When you need to verify something the mock genuinely cannot model (real
spatial hit-test routing, real engine timing, real `DisableHitTest`/`Hide`
behaviour on revisit), say so plainly rather than presenting a mock-passing
test as proof, and ask the person to confirm in the live game. Several of this
project's real bugs were only found that way.

### Run the suites on Lua 5.0 too -- it is the game's version

    for L in /tmp/lua50/src/lua50 /tmp/lua50/src/lua50f lua5.1; do
      for t in test_integration test_visibility test_replaycodec test_fuzz; do
        $L extras/$t.lua | tail -1
      done
    done

The suites run unchanged on both. 5.0 catches what 5.1 hides, and it has
bitten in game: a closure made inside a `for` loop captures the loop
variable itself in 5.0, which is nil once the loop is over (panel.lua's
checkboxes all found `record == nil`). 5.1 gives each iteration a fresh
variable, so the same test passes there. Also run:

    python3 extras/check_loop_closures.py   # closures capturing a loop variable

The mock adds FAF's own `string.match` (lua/system/utils.lua) when the
interpreter lacks it, as stock 5.0 does. Test code must use 5.0 varargs
(`arg`, `unpack(arg)`), not `...` in a function body, and must not call
`table.setn` (5.1 rejects it).


## 4. Write a regression test that proves the bug, not just a patch

For every real bug fixed, add a test and **prove it actually catches the bug**
by running it against a copy of the code from before the fix -- either the
original uploaded zip, or the file with just that one fix reverted -- and
confirming the new test fails there and passes after. A test that only ever
runs against the fixed code proves nothing about whether it would have caught
the regression. This project's test suite has several examples of exactly this
pattern (search for "Regression test for:" comments in `test_integration.lua`).

## 5. Package and deliver

Diff against the *exact* zip the person uploaded this round (not an earlier
one -- they may have made their own edits in between), so the patch applies
cleanly on top of what they're actually running:

```bash
diff -ruN --exclude='*.png' --exclude='*.lnk' --exclude='.git' \
    /tmp/pristine/TeamMouse /home/claude/TeamMouse \
    | sed 's#/tmp/pristine/TeamMouse#a#; s#/home/claude/TeamMouse#b#' \
    > /mnt/user-data/outputs/teammouse-changes.patch

# Verify it actually applies before delivering it
rm -rf /tmp/applytest && cp -r /tmp/pristine/TeamMouse /tmp/applytest
cd /tmp/applytest && patch -p1 --dry-run < /mnt/user-data/outputs/teammouse-changes.patch

# A zip of just the changed files, at their original paths, alongside the patch
cd /home/claude && zip -q /mnt/user-data/outputs/TeamMouse_changed_files.zip \
    TeamMouse/modules/<changed files> TeamMouse/extras/<changed test files>
```

Deliver both the patch and the changed-files zip via `present_files`. Report
the exact verification results (load check, upvalue count, pass/fail counts per
test file, fuzz result) rather than a general "everything works" -- the person
has been shown specific numbers throughout this project's history and will
notice if that stops.