#!/usr/bin/env python3
"""mir-lens: tier-1 pretty-printer for the numerical-accuracy lens.

Parses `rustc --emit=mir` text output (post -Zinline-mir flattening) and
reconstructs readable infix expressions per function:

- copy-propagates MIR temporaries and folds single-use defs into their use
- names locals from `debug x => _1;` entries
- tags each expression with the inlined-callee scope it came from
- keeps loops as loops (CFG blocks, back-edges marked)
- `--fp-core` elides everything not on the float dataflow (incl. panic/fmt
  machinery), which is where the 100:1 noise lives

Prototype quality: regex parsing of an unstable text format, on purpose —
see numerical-accuracy-lens.md §6 tier 1.
"""

import argparse
import re
import sys
from collections import defaultdict

# ---------------------------------------------------------------- parsing

FN_RE = re.compile(r"^(?:pub )?fn (?P<name>.+?)\((?P<args>.*)\) -> (?P<ret>.+?) \{$")
BLOCK_RE = re.compile(r"^\s+(?P<name>bb\d+)(?: \(cleanup\))?: \{$")
DEBUG_RE = re.compile(r"^\s*debug (?P<name>\w+) => (?P<place>.+?);$")
DECL_RE = re.compile(r"^\s*let (?:mut )?(?P<local>_\d+): (?P<ty>.+?);$")
SCOPE_RE = re.compile(
    r"^\s*scope (?P<num>\d+)(?: \(inlined (?P<inlined>.+?)\))? \{$")
ASSIGN_RE = re.compile(r"^\s+(?P<place>.+?) = (?P<rvalue>.+?);$")
CALL_RE = re.compile(
    r"^\s+(?P<place>.+?) = (?P<callee>.+?)\((?P<args>.*)\)"
    r" -> \[?(?:return: )?(?P<ret>bb\d+|unwind .*?)[,\]].*?;$")
TERM_GOTO_RE = re.compile(r"^\s+goto -> (?P<target>bb\d+);$")
TERM_SWITCH_RE = re.compile(
    r"^\s+switchInt\((?P<disc>.+?)\) -> \[(?P<arms>.+)\];$")
SKIP_STMT_RE = re.compile(
    r"^\s+(StorageLive|StorageDead|Retag|PlaceMention|assume|nop|Deinit|"
    r"ConstEvalCounter|FakeRead|// DBG:)")

BINOPS = {
    "Add": "+", "Sub": "-", "Mul": "*", "Div": "/", "Rem": "%",
    "AddUnchecked": "+", "SubUnchecked": "-", "MulUnchecked": "*",
    "BitXor": "^", "BitAnd": "&", "BitOr": "|", "Shl": "<<", "Shr": ">>",
    "Eq": "==", "Ne": "!=", "Lt": "<", "Le": "<=", "Gt": ">", "Ge": ">=",
    "Offset": ".offset",
}
UNOPS = {"Neg": "-", "Not": "!"}
CHECKED_BINOPS = {"AddWithOverflow": "+", "SubWithOverflow": "-",
                  "MulWithOverflow": "*"}

PANIC_CALLEES = re.compile(
    r"panic|unwrap_failed|expect_failed|slice_index_len_fail|"
    r"len_mismatch_fail|assert_failed|core::fmt|Arguments::")


def split_functions(text):
    """Yield (header_line, body_lines) per `fn ... {` item at column 0."""
    lines = text.splitlines()
    i = 0
    while i < len(lines):
        m = FN_RE.match(lines[i])
        if not m:
            i += 1
            continue
        body = []
        i += 1
        while i < len(lines) and lines[i] != "}":
            body.append(lines[i])
            i += 1
        yield m, body


class Scope:
    def __init__(self, num, inlined, parent):
        self.num, self.inlined, self.parent = num, inlined, parent

    def provenance(self):
        s = self
        while s is not None:
            if s.inlined:
                # strip generic clutter for the tag
                return re.sub(r"::<.*?>", "", s.inlined)
            s = s.parent
        return None


class Fn:
    def __init__(self, name, args, ret):
        self.name, self.ret = name, ret
        self.arg_locals = []       # [(local, ty)]
        self.debug = {}            # local -> source name (first wins = outermost)
        self.decl_ty = {}          # local -> type
        self.decl_scope = {}       # local -> Scope
        self.blocks = {}           # bb name -> list of (kind, payload)
        self.block_order = []
        for a in filter(None, (s.strip() for s in split_args(args))):
            if ":" in a:
                loc, ty = a.split(":", 1)
                self.arg_locals.append((loc.strip(), ty.strip()))
                self.decl_ty[loc.strip()] = ty.strip()


def parse_fn(m, body):
    fn = Fn(m["name"], m["args"], m["ret"])
    scope = Scope(-1, None, None)
    i = 0
    # --- declaration / scope section (until first block)
    while i < len(body):
        line = body[i]
        if BLOCK_RE.match(line):
            break
        sm = SCOPE_RE.match(line)
        if sm:
            scope = Scope(int(sm["num"]), sm["inlined"], scope)
        elif line.strip() == "}" and scope.parent is not None:
            scope = scope.parent
        else:
            dm = DEBUG_RE.match(line)
            if dm and dm["place"].startswith("_") and LOCAL_RE.fullmatch(dm["place"]):
                place, name = dm["place"], dm["name"]
                if place not in fn.debug:
                    if name in fn.debug.values():
                        name = f"{name}~{scope.num}"
                    fn.debug[place] = name
            cm = DECL_RE.match(line)
            if cm:
                fn.decl_ty[cm["local"]] = cm["ty"]
                fn.decl_scope[cm["local"]] = scope
        i += 1
    # --- basic blocks
    cur = None
    while i < len(body):
        line = body[i]
        bm = BLOCK_RE.match(line)
        if bm:
            cur = bm["name"]
            fn.blocks[cur] = []
            fn.block_order.append(cur)
            i += 1
            continue
        if cur is None or line.strip() == "}" or SKIP_STMT_RE.match(line):
            i += 1
            continue
        s = line.strip()
        cm = CALL_RE.match(line)
        tm_goto = TERM_GOTO_RE.match(line)
        tm_switch = TERM_SWITCH_RE.match(line)
        if tm_goto:
            fn.blocks[cur].append(("goto", tm_goto["target"]))
        elif tm_switch:
            arms = [a.strip() for a in tm_switch["arms"].split(",")]
            fn.blocks[cur].append(("switch", (tm_switch["disc"], arms)))
        elif cm:
            fn.blocks[cur].append(
                ("call", (cm["place"], cm["callee"], cm["args"], cm["ret"])))
        elif s == "return;":
            fn.blocks[cur].append(("return", None))
        elif s == "unreachable;":
            fn.blocks[cur].append(("unreachable", None))
        elif s.startswith(("drop(", "resume", "abort", "assert(")):
            fn.blocks[cur].append(("other_term", s))
        else:
            am = ASSIGN_RE.match(line)
            if am:
                fn.blocks[cur].append(("assign", (am["place"], am["rvalue"])))
            else:
                fn.blocks[cur].append(("raw", s))
        i += 1
    return fn


# ------------------------------------------------------- expression build

LOCAL_RE = re.compile(r"_\d+")
OPERAND_RE = re.compile(r"^(copy|move) (?P<place>.+)$")


class Expr:
    """Rendered expression + the set of leaf locals it reads."""

    def __init__(self, text, leaves, atomic=False):
        self.text, self.leaves, self.atomic = text, leaves, atomic

    def paren(self):
        return self.text if self.atomic else f"({self.text})"


def is_float_ty(ty):
    return ty in ("f32", "f64") or ty.startswith(("f32", "f64"))


class Renderer:
    def __init__(self, fn, fp_core=False, scope_filter=None, floor=None):
        self.fn = fn
        self.fp_core = fp_core
        self.scope_filter = scope_filter
        self.floor = floor or []
        # locals declared in a scope matching --scope (for dataflow closure)
        self.scope_locals = set()
        if scope_filter:
            for loc, sc in fn.decl_scope.items():
                prov = sc.provenance() if sc else None
                if prov and scope_filter in prov:
                    self.scope_locals.add(loc)
        self.use_count = defaultdict(int)
        self.def_count = defaultdict(int)
        for stmts in fn.blocks.values():
            for kind, payload in stmts:
                if kind == "assign":
                    place, rvalue = payload
                    self._count_defs(place)
                    for loc in LOCAL_RE.findall(rvalue):
                        self.use_count[loc] += 1
                elif kind == "call":
                    place, _, args, _ = payload
                    self._count_defs(place)
                    for loc in LOCAL_RE.findall(args):
                        self.use_count[loc] += 1
                elif kind == "switch":
                    for loc in LOCAL_RE.findall(payload[0]):
                        self.use_count[loc] += 1

    def _count_defs(self, place):
        if LOCAL_RE.fullmatch(place):
            self.def_count[place] += 1

    def local_name(self, loc):
        if loc == "_0":
            return "RET"
        return self.fn.debug.get(loc, loc)

    def is_fp(self, loc):
        return is_float_ty(self.fn.decl_ty.get(loc, ""))

    def provenance(self, loc):
        sc = self.fn.decl_scope.get(loc)
        return sc.provenance() if sc else None

    # -- operand / rvalue -> Expr
    def operand(self, s, env):
        s = s.strip()
        om = OPERAND_RE.match(s)
        if om:
            return self.place(om["place"], env)
        if s.startswith("const "):
            c = s[len("const "):]
            c = re.sub(r"_(?:[iu](?:8|16|32|64|128|size))\b", "", c)
            c = re.sub(r"(?<=\d)f(32|64)\b", "", c)
            return Expr(c, set(), atomic=True)
        return self.place(s, env)

    def place(self, s, env):
        s = s.strip()
        if LOCAL_RE.fullmatch(s):
            if s in env:
                return env[s]
            return Expr(self.local_name(s), {s}, atomic=True)
        # projections: (_1.0: f64), (*_5), ((_6 as Some).0: T), &_3
        inner = s
        leaves = set(LOCAL_RE.findall(s))
        inner = re.sub(r"\(\((_\d+) as (\w+)\)\.(\d+): .*?\)",
                       lambda m: f"{self.local_name(m[1])}.as_{m[2]}.{m[3]}", inner)
        inner = re.sub(r"\((_\d+)\.(\d+): .*?\)",
                       lambda m: f"{self.local_name(m[1])}.{m[2]}", inner)
        inner = re.sub(r"_\d+", lambda m: self._sub_env_text(m[0], env), inner)
        return Expr(inner, leaves, atomic=True)

    def _sub_env_text(self, loc, env):
        if loc in env and env[loc].atomic:
            return env[loc].text
        return self.local_name(loc)

    def rvalue(self, s, env):
        s = s.strip()
        m = re.match(r"^(\w+)\((?P<a>.+), (?P<b>.+)\)$", s)
        if m and m[1] in BINOPS:
            a, b = self.operand(m["a"], env), self.operand(m["b"], env)
            return Expr(f"{a.paren()} {BINOPS[m[1]]} {b.paren()}",
                        a.leaves | b.leaves)
        if m and m[1] in CHECKED_BINOPS:
            a, b = self.operand(m["a"], env), self.operand(m["b"], env)
            return Expr(f"{a.paren()} {CHECKED_BINOPS[m[1]]} {b.paren()} [checked]",
                        a.leaves | b.leaves)
        m = re.match(r"^(\w+)\((?P<a>.+)\)$", s)
        if m and m[1] in UNOPS:
            a = self.operand(m["a"], env)
            return Expr(f"{UNOPS[m[1]]}{a.paren()}", a.leaves)
        if m and m[1] == "discriminant":
            a = self.operand(m["a"], env)
            return Expr(f"discr({a.text})", a.leaves)
        cm = re.match(r"^(?P<op>copy|move) (?P<place>.+)$", s)
        if cm:
            return self.place(cm["place"], env)
        if s.startswith("const "):
            return self.operand(s, env)
        if s.startswith("&"):
            a = self.place(s.lstrip("&mut *"), env)
            return Expr(a.text, a.leaves, atomic=True)
        m = re.match(r"^(?P<a>.+) as (?P<ty>.+?) \((?P<kind>\w+)\)$", s)
        if m:
            a = self.operand(m["a"], env)
            return Expr(f"{a.paren()} as {m['ty']}", a.leaves)
        # aggregate / array / tuple / enum ctor: render leaves through env
        txt = re.sub(r"(copy|move) ", "", s)
        leaves = set(LOCAL_RE.findall(s))
        txt = re.sub(r"_\d+", lambda mm: self._sub_env_text(mm[0], env), txt)
        return Expr(txt, leaves, atomic=True)

    # -- statement stream -> folded lines
    def render(self, out):
        fn = self.fn
        args = ", ".join(f"{self.local_name(l)}: {t}" for l, t in fn.arg_locals)
        out.append(f"fn {fn.name}({args}) -> {fn.ret}")
        back_targets = self.back_edge_targets()
        for bb in fn.block_order:
            stmts = fn.blocks[bb]
            if self.fp_core and self.block_is_panic_path(bb):
                continue
            env = {}
            lines = []
            for kind, payload in stmts:
                if kind == "assign":
                    place, rv = payload
                    expr = self.rvalue(rv, env)
                    self.emit_or_bind(place, expr, env, lines, call=False)
                elif kind == "call":
                    place, callee, cargs, ret = payload
                    callee_short = re.sub(r"::<.*?>", "", callee)
                    callee_short = re.sub(r"<(.+?) as (.+?)>", r"\2", callee_short)
                    if PANIC_CALLEES.search(callee):
                        lines.append((None, f"!panic: {callee_short}(…)", None,
                                      False, set()))
                        continue
                    exprs = [self.operand(a, env)
                             for a in split_args(cargs) if a.strip()]
                    leaves = set().union(*(e.leaves for e in exprs)) if exprs else set()
                    text = f"{callee_short}({', '.join(e.text for e in exprs)})"
                    self.emit_or_bind(place, Expr(text, leaves, atomic=True),
                                      env, lines, call=True)
                elif kind == "switch":
                    disc, arms = payload
                    d = self.operand(disc, env)
                    fp = any(self.is_fp(l) for l in d.leaves) or \
                        bool(re.search(r"\d\.\d|sqrt|fabs|abs\(", d.text))
                    lines.append((None, f"switch {d.text} -> {', '.join(arms)}",
                                  None, fp, d.leaves))
                elif kind == "goto":
                    loop = " [loop back-edge]" if payload in back_targets and \
                        fn.block_order.index(payload) <= fn.block_order.index(bb) else ""
                    lines.append((None, f"goto {payload}{loop}", None, False, set()))
                elif kind == "return":
                    lines.append((None, "return", None, False, set()))
                elif kind == "other_term":
                    lines.append((None, payload.rstrip(";"), None, False, set()))
            lines = self.apply_floor(lines)
            if self.scope_filter:
                # dataflow closure: keep lines produced *in* the scope, and
                # lines that *consume* a value the scope produced
                lines = [l for l in lines
                         if (l[2] and self.scope_filter in l[2])
                         or (l[4] & self.scope_locals)]
            elif self.fp_core:
                # keep float-dataflow lines; for blocks that keep any, also
                # keep their control flow so loop structure stays readable,
                # and always keep a loop head's branch condition
                kept = [l for l in lines if l[3]]
                if kept:
                    lines = [l for l in lines
                             if l[3] or l[1].startswith(("switch", "goto", "return"))]
                elif bb in back_targets:
                    lines = [l for l in lines if l[1].startswith("switch")]
                else:
                    lines = []
            if not lines:
                continue
            head = f"  {bb}" + (" (loop head)" if bb in back_targets else "") + ":"
            out.append(head)
            for _, text, prov, _fp, _lv in lines:
                tag = f"   ← {prov}" if prov else ""
                out.append(f"    {text}{tag}")

    def apply_floor(self, lines):
        """Collapse runs of statements whose provenance matches a --floor
        pattern into one elision marker: the 'abstraction floor'."""
        if not self.floor:
            return lines
        out, run_prov, run_n = [], None, 0
        def flush():
            nonlocal run_prov, run_n
            if run_n:
                out.append((None, f"⟨{run_prov}: {run_n} stmts elided⟩",
                            None, True, set()))
            run_prov, run_n = None, 0
        for l in lines:
            prov = l[2]
            if prov and any(f in prov for f in self.floor):
                if run_prov not in (None, prov):
                    flush()
                run_prov, run_n = prov, run_n + 1
            else:
                flush()
                out.append(l)
        flush()
        return out

    def emit_or_bind(self, place, expr, env, lines, call):
        """Single-use pure defs fold into their use; the rest print."""
        if LOCAL_RE.fullmatch(place):
            uses = self.use_count[place]
            defs = self.def_count[place]
            named = place in self.fn.debug or place == "_0"
            if not call and uses == 1 and defs == 1 and not named:
                env[place] = expr
                return
            if call and uses == 1 and defs == 1 and not named:
                # calls are values too; fold unless result feeds many places
                env[place] = expr
                return
            name = self.local_name(place)
            env.pop(place, None)
            prov = self.provenance(place)
            fp = self.is_fp(place) or any(self.is_fp(l) for l in expr.leaves)
            lines.append((place, f"{name} = {expr.text}", prov, fp,
                          expr.leaves | {place}))
        else:
            tgt = self.place(place, {})
            fp = any(self.is_fp(l) for l in tgt.leaves | expr.leaves)
            lines.append((None, f"{tgt.text} = {expr.text}", None, fp,
                          tgt.leaves | expr.leaves))

    def block_is_panic_path(self, bb):
        stmts = self.fn.blocks[bb]
        for kind, payload in stmts:
            if kind == "call" and PANIC_CALLEES.search(payload[1]):
                return True
            if kind == "other_term" and "panic" in payload:
                return True
        return False

    def back_edge_targets(self):
        order = {b: i for i, b in enumerate(self.fn.block_order)}
        targets = set()
        for bb, stmts in self.fn.blocks.items():
            for kind, payload in stmts:
                dests = []
                if kind == "goto":
                    dests = [payload]
                elif kind == "switch":
                    dests = [a.split(": ")[1] for a in payload[1] if ": " in a]
                elif kind == "call":
                    if payload[3].startswith("bb"):
                        dests = [payload[3]]
                for d in dests:
                    if d in order and order[d] <= order.get(bb, 0):
                        targets.add(d)
        return targets


def split_args(s):
    """Split call args on top-level commas."""
    out, depth, cur = [], 0, ""
    for ch in s:
        if ch in "([<{":
            depth += 1
        elif ch in ")]>}":
            depth -= 1
        if ch == "," and depth == 0:
            out.append(cur)
            cur = ""
        else:
            cur += ch
    if cur.strip():
        out.append(cur)
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("mir_file")
    ap.add_argument("--fn", dest="only", help="substring filter on fn name")
    ap.add_argument("--fp-core", action="store_true",
                    help="elide non-float dataflow and panic machinery")
    ap.add_argument("--scope", help="statements whose inlining provenance "
                    "contains this substring, plus statements consuming "
                    "values that scope produced (dataflow closure)")
    ap.add_argument("--floor", action="append", default=None, metavar="SUBSTR",
                    help="abstraction floor: collapse statements whose "
                    "provenance matches SUBSTR into one elision marker "
                    "(repeatable; e.g. --floor libm --floor compiler_builtins)")
    args = ap.parse_args()
    text = open(args.mir_file).read()
    out = []
    for m, body in split_functions(text):
        if args.only and args.only not in m["name"]:
            continue
        fn = parse_fn(m, body)
        Renderer(fn, fp_core=args.fp_core, scope_filter=args.scope,
                 floor=args.floor).render(out)
        out.append("")
    print("\n".join(out))


if __name__ == "__main__":
    main()
