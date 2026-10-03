# Time-of-day benchmark

Compare the original `Instant.time()` decomposition with the algorithms in
[Ben Joffe's article](https://www.benjoffe.com/fast-time-of-day). Production now
uses V1; the original signed arithmetic is retained as `baseline`.

## Run

From the repository root, with Zig 0.17:

```sh
zig test -O ReleaseSafe --dep zeit -Mroot=bench/bench_time.zig \
  -O ReleaseSafe -Mzeit=src/zeit.zig
mkdir -p zig-out
zig build-exe -O ReleaseFast -fllvm --dep zeit -Mroot=bench/bench_time.zig \
  -O ReleaseFast -Mzeit=src/zeit.zig -femit-bin=zig-out/bench-time
zig-out/bench-time
```

On Linux, optionally pin the executable to an available CPU with
`taskset -c 0 zig-out/bench-time`. To inspect generated code, append
`-femit-asm=zig-out/bench-time.s` to the build command.

## Method

- `baseline`: the original signed sequential arithmetic.
- `narrow`: the same sequential arithmetic, using `u32` after signed day
  normalization. This controls for integer width/signedness separately from
  dependency restructuring.
- `v1`: independent division by 60 and 3600, followed by subtraction. The
  full-conversion benchmark calls the actual `Instant.time()` implementation.
- `v2`: 32-bit fixed-point high/low halves, with explicit wrapping arithmetic.
- `v2_64`: the article's widened V2 using `u128` products.

Each scope uses 4,096 deterministic pseudorandom inputs, a warmup, and nine
samples of 2,097,152 conversions each. Variant order rotates between samples.
Results report median/min/max wall-clock ns/op, without subtracting overhead.
Scalar calls are deliberately not inlined across the harness boundary, keeping
the benchmark scalar and requiring all output fields. This includes call,
load/store, loop, and checksum costs, so it is not a measurement of bare
instruction latency. H:M:S throughput uses four checksum accumulators; latency
feeds the previous output checksum into the next input using XOR and modulo
86,400 (also included in the timing).

Full-conversion tests use timestamps spanning 1900–2100, including negative Unix
timestamps and random fractional seconds. They exercise runtime timezone
dispatch with UTC and a parsed US Central POSIX DST rule. Calendar conversion,
timezone adjustment, and subsecond decomposition remain unchanged. These are
not TZif transition-table lookup benchmarks. Candidate full conversions mirror
`Instant.time()` in the benchmark file; keep them synchronized if it changes.

Correctness checks cover all 86,400 seconds for every variant, plus 40,000
random full conversions and explicit epoch/day, fractional-second, offset, and
DST boundaries, compared field-for-field with production. Runtime benchmark
checksums must also agree across variants.

## Initial comparison (2026-09-07, before adopting V1)

Linux x86-64 orb, Intel Xeon @ 2.60 GHz (family 6, model 106), KVM,
Zig `0.17.0-dev.2033+af24fd11a`, LLVM backend, `ReleaseFast`, native CPU target,
pinned to CPU 0. Three separate executions; each cell is the median of their
three reported sample medians. Units: **ns/op, lower is better**.

| Variant | H:M:S throughput | H:M:S latency | Full UTC | Full POSIX DST |
| --- | ---: | ---: | ---: | ---: |
| Original (baseline) | 3.166 | 11.171 | 48.288 | 49.585 |
| Sequential `u32` | 2.431 | 8.468 | 42.062 | 43.355 |
| V1 | 2.429 | 7.573 | 42.335 | 43.372 |
| V2 | 2.434 | 7.211 | 41.991 | 43.275 |
| V2 64-bit | 2.725 | 8.007 | 44.723 | 45.387 |

V1 uses about 12% less time in the full UTC benchmark and 13% less with POSIX
DST. V2 clearly improves the isolated dependency-chain benchmark, but adds
less than 1% over V1 in these aggregate full-conversion results. That small
end-to-end difference does not justify a strong ranking on a shared VM:
individual run medians ranged from 41.0–42.5 ns for V1 UTC and 40.4–42.4 ns
for V2 UTC. The 64-bit formulation was consistently worse than V1/V2 here.

Generated assembly confirms that the original full conversion retains signed
floor-division correction sequences in its H:M:S arithmetic. Most of the
end-to-end gain is already available by narrowing to unsigned arithmetic;
V1's shorter dependency chain is more visible in the isolated latency test.

Decision: adopt V1's readable arithmetic rather than fixed-point constants.
Do not infer Apple ARM or other CPU results from this virtualized x86 host.

## Production verification after adopting V1

Rebuilt with the same compiler/flags and ran the harness against the actual
updated `Instant.time()`. One execution, nine samples per variant:

| Full conversion | Original baseline ns/op | Production V1 ns/op | Time reduction |
| --- | ---: | ---: | ---: |
| UTC | 47.397 | 41.953 | 11.5% |
| POSIX DST | 48.564 | 44.488 | 8.4% |

All checksums agreed. The production V1 path now replaces the benchmark-only
V1 clone, so these results are a fresh measurement rather than an extension
of the initial table. V2 measured 41.218 ns UTC and 43.131 ns POSIX DST in this
run; V1 retains the readable implementation without fixed-point constants.
`zig build test` and `zig build test -Doptimize=ReleaseFast` each passed all
33 tests, including a new 518,400-case full-field regression test covering
every second of the days before and after the Unix epoch at three offsets.
The two standalone benchmark correctness tests also passed in ReleaseSafe.
