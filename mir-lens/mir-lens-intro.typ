// mir-lens-intro.typ — a self-contained introduction to the MIR lens.
// Compile: typst compile mir-lens-intro.typ

#set document(
  title: "The MIR Lens: seeing the calculation your abstractions hide",
  author: "Mossa (with Claude Code)",
)
#set page(margin: (x: 2.4cm, y: 2.6cm), numbering: "1")
#set text(size: 10.5pt)
#set heading(numbering: "1.1")
#set par(justify: true)
#show raw.where(block: true): it => block(
  fill: luma(248),
  stroke: luma(215) + 0.5pt,
  inset: 8pt,
  radius: 3pt,
  width: 100%,
  it,
)
#show link: set text(fill: rgb("#1a5fb4"))

#align(center)[
  #text(size: 17pt, weight: "bold")[The MIR Lens]
  #v(2pt)
  #text(size: 12pt)[Seeing the calculation your abstractions hide]
  #v(4pt)
  #text(size: 9pt, fill: luma(90))[
    A motivating introduction, with worked examples. 2026-08-07. \
    Toolchain: `rust-mir-lens` (rustc branch `inline-mir-depth-limit-flags`);
    printer: `mir_lens.py`.
  ]
]

#v(8pt)

= The problem: good code disperses arithmetic

Numerical code in Rust is written the way all good Rust is written: small
functions, meaningful types, constructors that precompute what methods will
need, generics that let one algorithm serve `f32`, `f64`, and user scalars.
Every one of these habits improves the *software*. Every one of them also
disperses the *floating-point computation* across function boundaries, struct
fields, and trait indirections — and floating-point correctness is a property
of the _composed_ computation, not of any single function.

That matters because floating-point arithmetic is not the arithmetic of the
mathematics being implemented. Each operation rounds. Addition is not
associative. `x / s * s` is not `x`. `a*a - b*b` and `(a-b)*(a+b)` differ
precisely when `a` and `b` are close — which, in a convergence loop, is
exactly when the answer is nearly ready. The hazards a numerical reviewer
must find are *compositional*:

- a subtraction of near-equal quantities, where the two operands were
  produced three calls apart;
- a division whose result is later multiplied by the same factor, the divide
  living in a constructor and the multiply in a method;
- a value recomputed from a rounded intermediate instead of propagated;
- a stopping criterion whose tolerance and scale terms come from different
  abstraction layers.

None of these is visible in a per-function code review, because each
participating function is — locally — beyond reproach. The reviewer needs to
see what the machine is actually asked to compute, in one place, *after* the
abstractions have done their work. That view is what the MIR lens produces.

= What the lens is

The lens is a way of running the Rust compiler so that it hands back the
*composed* computation of a chosen function:

+ Compile in release mode and stop at *MIR* — rustc's mid-level intermediate
  representation — after optimizations, using `--emit=mir`.
+ Force the *MIR inliner* to be total: every call that can be inlined, is,
  across crate boundaries, to any depth. What remains as calls are only true
  leaves: hardware intrinsics (`sqrt`, `ctpop`, saturating arithmetic) and
  panic paths.
+ Keep *debug names and inlining provenance*, so every flattened statement
  still knows which source function it came from and what the programmer
  called each variable.
+ Pretty-print the result: fold MIR's three-address code
  (`_5 = Div(_2, _3); _4 = Add(_1, _5)`) back into infix expressions
  (`x + delta / scale`), drop non-float plumbing, and annotate each line
  with its provenance.

Why MIR, and not source, LLVM IR, or assembly? MIR after monomorphization is
the *earliest* representation where the numbers are real — `T` has become
`f64`, `T::default_epsilon()` has become `2.2204460492503131E-16` — and the
*latest* representation where the program is still structured: loops are
loops (a CFG with a back-edge, not an unrolled or vectorized blur), names
survive, and every operation corresponds to exactly one rounding as the
language defines it. It is the program *as specified to the machine*, before
codegen's own transformations. That is the right altitude for accuracy
review.

== The missing compiler knob (and the small patch that adds it)

Almost all of this is stock rustc: the MIR inliner exists, its *cost*
thresholds are tunable (`-Zinline-mir-threshold`,
`-Zinline-mir-hint-threshold`), and `-Zinline-mir-preserve-debug` keeps the
names. What breaks on real crates is a pair of *hard-coded depth limits* in
`rustc_mir_transform/src/inline.rs`: `HISTORY_DEPTH_LIMIT = 20` and
`TOP_DOWN_DEPTH_LIMIT = 5`. Past those, the inliner refuses to look at
unmarked callees and accepts `#[inline]`-marked ones only if their body is a
single basic block. Inlining one big library entry point exhausts the budget
instantly, so everything *below* it stays a call — and the deeper (= more
composed = more numerically interesting) a helper is, the more certainly it
is hidden. On nalgebra, the functions left opaque were precisely
`SymmetricEigen::delimit_subproblem` — the convergence criterion — and on
interpn, `interp_weights` and `dot4`, despite being marked `#[inline]`.

The fix is a \~14-line rustc patch (branch `inline-mir-depth-limit-flags`,
commit `472f72b6297`) adding two flags that mirror the existing threshold
family, defaults unchanged:

- `-Zinline-mir-history-depth-limit` — depth of nested inlining before the
  inliner stops considering new callees. *This is the recursion guard*:
  64 is the sweet spot. (At 10 000, generic-heavy crates hit
  polymorphic-recursion unrolling and compile times go pathological —
  nalgebra took >5 min; at 64 the same crate flattens in 2.5 s.)
- `-Zinline-mir-top-down-depth-limit` — grown-callsite budget per top-level
  call; safe to set huge (100 000).

== The recipe

With the patched toolchain linked as `rust-mir-lens` (a snapshot build;
see @availability), from the crate to be lensed:

```bash
RUSTFLAGS="-Zcross-crate-inline-threshold=always" \
  cargo +rust-mir-lens rustc --release -- \
  -Zmir-opt-level=2 -Zinline-mir=yes \
  -Zinline-mir-threshold=100000 -Zinline-mir-hint-threshold=100000 \
  -Zinline-mir-history-depth-limit=64 -Zinline-mir-top-down-depth-limit=100000 \
  -Zinline-mir-preserve-debug=yes \
  --emit=mir
```

`RUSTFLAGS` applies to *dependencies* (they must encode their MIR for
cross-crate inlining); the flags after `--` apply to the leaf crate. The
`.mir` file lands in the cargo target directory, and the pretty-printer
turns it into the views shown below:

```bash
python3 mir_lens.py out.mir --fn <substring>              # one function, full
python3 mir_lens.py out.mir --fn <substring> --fp-core    # float dataflow only
python3 mir_lens.py out.mir --fn <substring> --scope <callee>  # provenance slice
```

`--fp-core` drops non-float statements and panic/formatting machinery — on
real crates roughly a 100:1 noise reduction. What follows is real output
from these commands.

= Example 1: cancellation assembled from innocent helpers

Three statistics helpers, each of which passes any per-function review:

```rust
/// Sample standard deviation, via the "computational formula"
/// Var(x) = E[x²] − E[x]².
pub fn std_dev(xs: &[f64]) -> f64 {
    let m = mean(xs);
    (mean_of_squares(xs) - m * m).sqrt()
}

fn mean(xs: &[f64]) -> f64 {
    total(xs) / xs.len() as f64
}

fn mean_of_squares(xs: &[f64]) -> f64 {
    let mut acc = 0.0;
    for &x in xs { acc += x * x; }
    acc / xs.len() as f64
}

fn total(xs: &[f64]) -> f64 {
    let mut acc = 0.0;
    for &x in xs { acc += x; }
    acc
}
```

`std_dev` is textbook mathematics. `mean` is a division. The two loops are
plain accumulations. Nothing here looks wrong, and nothing here *is* wrong —
locally. The lens (`--fn std_dev --fp-core`) flattens the four functions
into the one computation the machine performs:

```
fn std_dev(xs: &[f64]) -> f64
    acc~4 = acc~4 + x~6              ← total (via mean)   [loop body]
    m = acc~4 / _7                   ← mean
    acc = acc + (x * x)              ← mean_of_squares    [loop body]
    self~73 = (acc / _7) - (m * m)
    RET = sqrtf64(self~73)
```

Read the last two lines as one expression:

$ "RET" = sqrt((sum x^2) / n - ((sum x) / n)^2) $

That is a subtraction of two *near-equal, large* quantities whenever the
data has a large mean and a small spread — the classic catastrophic
cancellation of the "computational formula" for variance. The defect exists
only in the composition; the lens is what puts the composition on one
screen, with provenance arrows saying which abstraction contributed each
piece.

It is not hypothetical. For three sensor readings around $10^8$ —
`[1.0e8, 1.0e8 + 1.0, 1.0e8 + 2.0]`, true standard deviation
$sqrt(2\/3) approx 0.8165$:

```
composed formula: 1.4142135623730951     ← the code above (√2: pure rounding noise)
two-pass formula: 0.816496580927726      ← the true value
```

A 73% error, silently — no NaN, no panic, a plausible-looking number. (With
slightly different data the computed variance goes *negative* and `sqrt`
returns NaN.) The two sums agree to 17 significant digits; their difference
is made entirely of the rounding errors. Per-function review cannot see
this; the composed view makes it a one-line observation.

= Example 2: the struct-field dance

The harder case, and the more idiomatic one: a struct whose *constructor*
performs calculations into fields, and whose *methods* consume and further
transform those fields. The dataflow now passes through named state, which
disconnects it visually — the reviewer of the method sees only innocent
field reads; the reviewer of the constructor sees only innocent
precomputation. Concretely:

```rust
pub struct Rescaler {
    lo: f64,
    inv_span: f64, // 1.0 / (hi - lo), precomputed "for speed"
    gain: f64,     // (hi - lo) * k — silently carries the span back in
}

impl Rescaler {
    pub fn new(lo: f64, hi: f64, k: f64) -> Self {
        let span = hi - lo;
        Rescaler { lo, inv_span: 1.0 / span, gain: span * k }
    }

    /// Normalize x into [0,1], then apply the gain.
    pub fn apply(&self, x: f64) -> f64 {
        let t = (x - self.lo) * self.inv_span;
        t * self.gain
    }
}
```

`apply` multiplies two fields together — what could be cleaner? The lens, on
a wrapper that constructs and uses the struct
(`let r = Rescaler::new(lo, hi, k); r.apply(x)`):

```
fn pipeline(lo: f64, hi: f64, k: f64, x: f64) -> f64
    span = hi - lo            ← Rescaler::new
    _8 = 1 / span             ← Rescaler::new
    _9 = span * k             ← Rescaler::new
    r = Rescaler { lo: lo, inv_span: _8, gain: _9 }
    t = (x - lo) * _8         ← Rescaler::apply
    RET = t * _9
```

*The struct evaporates.* MIR inlining plus value propagation reconnects the
constructor's stores to the method's loads, so the field indirection that
obfuscated the dataflow is gone. Six adjacent lines now read as

$ "RET" = ((x - "lo") dot 1/("hi" - "lo")) dot (("hi" - "lo") dot k) $

and two things previously spread across `new` and `apply` become visible at
once: the *reciprocal-multiply* (`* (1/span)` where the mathematics says
`/ span` — one extra rounding), and the *span round-trip* — the span is
divided out through one field and multiplied back through another.
Mathematically it cancels to $(x - "lo") dot k$; numerically it is that with
three extra roundings.

How bad is it? Honestly: small, and input-dependent — which is itself worth
knowing precisely. A sweep of $10^6$ random `(lo, hi, k, x)` tuples against
the direct form:

```
1000000 random inputs: 405025 differ (40.5%), max 3 ulps
```

Forty percent of inputs land on a different float, up to 3 ulps away. As a
one-shot transformation this is harmless. The reason it belongs in review is
*location*: place this round-trip inside an iterated update and the wobble
compounds per iteration; place it inside a convergence criterion and a
3-ulp disturbance sits at exactly the $2 dot 10^(-16)$ scale the loop is
comparing against. The lens's job is not to declare the pattern guilty — it
is to make the pattern *visible* so a human can judge whether its location
is dangerous.

Two practical notes. The wrapper must contain *both halves of the dance* —
construction and use — for the fields to resolve; that is the standard
scratch-crate pattern (one thin `pub fn` per computation under review). If
the struct arrives opaque (a method on `&self` built elsewhere), the lens
still flattens the method and shows symbolic field loads: you see what the
calculation does *to* the fields, but not how they were made. And mutating
state works the same way: loops keep their shape (next example), so a struct
whose fields are updated each iteration shows its per-iteration field
arithmetic in the loop body, provenance-tagged.

= Example 3: loops keep their shape — criteria appear in loop headers

Accuracy review cares most about *stopping criteria*, so a lens that
unrolled or vectorized loops would be useless. This example (from the
original proof of concept) splits a Newton iteration across `#[inline]`
helpers so that no single function shows the loop's real test:

```rust
#[inline]
fn newton_step(x: f64, c: f64) -> f64 { 0.5 * (x + c / x) }

#[inline]
fn residual(x: f64, c: f64) -> f64 { x * x - c } // cancels exactly at convergence

pub fn sqrt_newton(c: f64) -> f64 {
    let mut x = c;
    while residual(x, c).abs() > 1e-12 * c {
        x = newton_step(x, c);
    }
    x
}
```

The lens output keeps the control-flow graph — a loop header, a body, a
back-edge — with the criterion fully composed *in the header*:

```
bb1:                                    // loop header = the criterion
    _7 = Mul(copy _5, copy _5)          // x * x            ← residual()
    _4 = Sub(move _7, copy _1)          //   … − c          ← the cancellation
    _3 = fabs(move _4)
bb4:
    _6 = Mul(const 9.9999999999999998E-13, copy _1)   // "1e-12" * c
    _2 = Gt(move _3, move _6)
bb2:                                    // Newton step, inlined
    _9 = Div(copy _1, copy _0)
    _8 = Add(copy _0, move _9)
    _0 = Mul(const 0.5, move _8)
    goto bb1
```

Three reveals in one screen. The criterion computes `x*x − c` — a
subtraction that cancels catastrophically *exactly when the iteration is
nearly converged*, i.e. exactly when the test's result matters; the honest
residual near convergence is dominated by rounding, so the loop's
termination is partly noise-driven. The tolerance is *absolute in `c`*
(`1e-12 * c` has the wrong scale for `x`; a relative criterion on `x` would
be `eps * x * x`-shaped). And the constant advertises its true self: the
source's `1e-12` is really `9.9999999999999998E-13` — post-monomorphization
MIR shows actual representable values, not source syntax.

= The real thing: nalgebra's eigenvalue convergence criterion <nalgebra>

Everything above is a distilled demo. The motivating target was shipping
library code: `nalgebra`'s symmetric eigenvalue decomposition
(`SymmetricEigen`), whose QR algorithm decides *deflation* — "is this
off-diagonal element effectively zero, so the problem splits?" — inside a
helper called `delimit_subproblem`. That decision *is* the accuracy of the
computed eigenvalues: deflate too eagerly and eigenvalues are wrong;
too conservatively and the iteration spins against rounding noise. It is
precisely the line a numerical reviewer must audit.

In the source, that line is unreadable *as arithmetic*. It lives behind
roughly six layers of abstraction — the public `symmetric_eigen` entry,
`do_decompose`, the tridiagonalization, `delimit_subproblem` itself, generic
scalar traits (`T: RealField`), and `T::default_epsilon()` — spread over
multiple modules of a heavily generic crate. And with stock rustc, the lens
recipe *could not reach it*: the hard-coded depth limits of @availability's
patch were exhausted by `do_decompose` long before the criterion, so
`delimit_subproblem` stayed an opaque call. (That failure is what motivated
the rustc patch: the depth limits hide exactly the deep, composed,
numerically interesting code.)

With the patched toolchain, a two-line wrapper —

```rust
pub fn eigenvalues3(m: [[f64; 3]; 3]) -> [f64; 3] {
    let m = nalgebra::Matrix3::from(m);
    m.symmetric_eigen().eigenvalues.into()
}
```

— flattens to 149,270 lines of MIR in seconds (history depth 64), and in
the loop-header blocks, with provenance intact, the deflation criterion is
finally visible as the machine sees it:

```
fabs(off_diag[m])   >   2.2204460492503131E-16 * (fabs(diag[m]) + fabs(diag[m+1]))
```

That single recovered line answers, at a glance, questions the source keeps
abstract:

- *What is the tolerance, actually?* Not `T::default_epsilon()` — the
  literal `2.2204460492503131E-16`, i.e. machine epsilon for `f64`, visible
  as a monomorphized constant.
- *What scale is the comparison against?* The sum of the two neighboring
  diagonal magnitudes, $|d_m| + |d_(m+1)|$ — a LAPACK-style relative
  criterion. A reviewer can now reason about when that scale is
  appropriate: for graded matrices (diagonal entries of wildly different
  magnitude), sum-of-neighbors versus other scalings is a real, documented
  trade-off in the eigenvalue literature — and now it is *auditable* in the
  Rust ecosystem's linear-algebra workhorse, without reading six layers of
  generic code.
- *Where does it sit?* In the loop header, evaluated per sweep — the lens
  shows the criterion in its control-flow position, so the reviewer sees
  not just the formula but *when* it fires.

This is the thesis demonstrated end-to-end on real code: the composed
floating-point computation of a shipping library, criterion included, on one
screen, with every line traceable to its source function.

= What to look for in a lensed function

A short reviewer's checklist, distilled from the examples:

- *Subtractions of near-equal quantities in loop-head criteria* —
  cancellation strikes exactly when the residual is smallest (Examples 1
  and 3).
- *A `Div` whose result is later multiplied by the same factor* — or a
  stored reciprocal multiplied where the mathematics divides
  (Example 2's round-trip).
- *Values recomputed from rounded intermediates instead of propagated* —
  e.g. a grid position `x0 = start + step * i` where `i` was floored from
  the same data that `loc − x0` is about to consume.
- *Constants at their true values* — `1e-12` printing as
  `9.9999999999999998E-13` is informative; a tolerance that is secretly
  machine-epsilon-scaled (@nalgebra) is a design fact worth knowing.
- *Casts down and back up across API boundaries* — precision lost at a seam
  neither side owns.

= Using it, and its limits <availability>

*Availability.* The lens needs the patched rustc (two `-Z` flags). In this
checkout it is built and linked as the rustup toolchain `rust-mir-lens`
(a frozen snapshot, so other builds cannot clobber it). The link is
machine-local — rustup can run it but not download it; another machine
builds branch `inline-mir-depth-limit-flags` and links its own snapshot.
A project can pin it with `rust-toolchain.toml`:

```toml
[toolchain]
channel = "rust-mir-lens"
```

Custom linked names are valid channels; since a stage1 toolchain ships no
cargo, rustup's shim transparently falls back to the default toolchain's
cargo, which is exactly what the recipe expects. Pinning only makes the
flags *available* — the lens remains an explicit analysis invocation, and
its `RUSTFLAGS` must never be baked into a project's `.cargo/config.toml`
(they would distort every normal build).

*Scoping.* Never lens a whole application. Make a scratch crate depending
on the library under review, with one thin `pub fn` wrapper per computation
of interest, taking and returning plain floats or arrays. Wrappers should
contain every half of any construct/use dance (Example 2). Start with small
crates; bring in generic heavyweights only for targeted questions.

*Limits, honestly stated.* The lens is a *viewer*, not a verifier: it shows
the composed computation and a human judges it — no error bounds are
computed (pairing the view with tools that do estimate error is future
work). The printer keeps loop control flow under `--fp-core`, slices with
dataflow closure under `--scope` (consuming statements included), and can
collapse chosen callees behind an *abstraction floor* (`--floor libm`
prints `⟨…: N stmts elided⟩` instead of bit-twiddling internals) — but some
`Result`/`ControlFlow` enum plumbing still shows, pending full
expression-DAG reconstruction. History depth must stay modest (64) on
generic-heavy crates or compile time degrades; lifting that properly means
teaching the inliner to detect polymorphic recursion specifically, rather
than bounding all depth — a candidate rustc follow-up. And what the lens
shows is the program *as specified* — one rounding per MIR operation. For
Rust this is close to what runs: rustc enables no fast-math reassociation,
and fused multiply-adds occur only where the source wrote `mul_add`.

*Status.* The rustc patch is a \~14-line, defaults-unchanged flag addition —
a candidate for upstreaming so the lens runs on stock nightlies. The
pretty-printer (`mir_lens.py`) is a working tier-1 prototype; design notes,
the validation log, and the roadmap (expression-DAG reconstruction, an
"abstraction floor" to keep libm symbolic, a historical-accuracy-bugs
benchmark) live alongside it.

#v(6pt)
#line(length: 100%, stroke: luma(200))
#text(size: 9pt, fill: luma(90))[
  Written with Claude Code (Claude Fable 5), 2026-08-07, from live runs in
  this checkout: the std-dev, Rescaler, and ulp-sweep outputs are verbatim
  tool output; the Newton and nalgebra excerpts are from the recorded
  proof-of-concept and scale-test logs (`numerical-accuracy-lens.md` §4,
  §10).
]
