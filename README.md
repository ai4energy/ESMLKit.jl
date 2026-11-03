# ESMLKit.jl

[![CI](https://github.com/ai4energy/ESMLKit.jl/actions/workflows/ci.yml/badge.svg)](https://github.com/ai4energy/ESMLKit.jl/actions/workflows/ci.yml)
[![codecov](https://codecov.io/gh/ai4energy/ESMLKit.jl/branch/main/graph/badge.svg)](https://codecov.io/gh/ai4energy/ESMLKit.jl)

[中文说明](README.zh.md)

ESMLKit.jl is the **MIT-licensed Julia client** for the ESML engine. It launches
the separate `esml` binary and speaks the `esml.session/v1` JSON protocol over
stdin/stdout; no engine code is linked or embedded.

The public surface is **one-shot** `solve` / `simulate` plus a **full-function
CLI layer** (`cli`, `check`, `check_units`, `tasks`, `inspect`, `dump`,
`version`): each call starts an `esml` process and returns an
`esml.solve/v1` / `esml.simulate/v1` envelope, a JSON validation report, a
task envelope, or the engine's own text. Resident digital-twin sessions
(`Session`, `predict`, `snapshot`, `restore!`) require the commercial engine
edition; the academic edition rejects `esml session` at startup.

The **educational, Julia-native reference implementation** of the engine lives
in [`ai4energy/esml-julia`](https://github.com/ai4energy/esml-julia). It is a
separate project; ESMLKit.jl is the client for the Rust engine binary.

```julia
using ESMLKit

steady = solve("plant.esml"; system = "Plant")
println(steady.values)
println(get(steady.units, "tank.T", nothing), " ", steady.meta["unitCoverage"])

traj = simulate("plant.esml", (0.0, 60.0), 60; observe = ["tank.T"])
println(traj.series["tank.T"][end], " ", get(traj.units, "tank.T", nothing))
```

## Installation

```julia
using Pkg
Pkg.add("ESMLKit")
```

Until the package is registered in General, install it from the repository URL:

```julia
Pkg.add(url = "https://github.com/ai4energy/ESMLKit.jl")
```

### Engine binary

The client needs the ESML engine binary:

- Academic edition (flattened unknowns ≤ 16,384, non-commercial use):
  <https://github.com/ai4energy/esml/releases>
- Point the client at the binary once:
  ```julia
  ESMLKit.set_binary_path("/path/to/esml")
  ```
  The path is stored as a Julia package preference. The resolution order is
  explicit `binary=` argument → `set_binary_path` preference → `ESML_BIN`
  environment variable → `PATH`.
- A path that is explicitly configured but is not executable raises a loud
  error; the client never silently falls back to another binary.

## API

### One-shot calls (available with the academic engine)

| Call | Meaning |
| --- | --- |
| `solve(path; system=nothing, libraries=String[], binary=nothing, timeout=120.0)` | Steady-state solve → `SolveOutput(values, unknowns, system, raw, units, meta)` |
| `simulate(path, tspan=(0.0, 1.0), steps=100; observe=nothing, …)` | One time integration → `SimulateOutput(t, series, steps, system, raw, units, meta)` |

`units` maps variable paths to SI dimension expressions. `meta` contains
`engineVersion`, `docHash`, `durationMs`, `converged`, `iterations`,
`residual`, `residualTolerance`, and `unitCoverage`.

`observe` accepts variable paths only; an empty list is rejected by the client,
and unknown or duplicate paths are rejected by the engine.

### Full-function CLI

| Call | Meaning |
| --- | --- |
| `cli(args::Vector{String}; input=nothing, timeout=120.0, binary=nothing) -> CLIResult` | Run **any** `esml` subcommand → `CLIResult(stdout, stderr, code)` |
| `check(path; libraries=String[], binary=nothing, timeout=120.0) -> Vector{Dict{String,Any}}` | `esml check --json` — front-validation report, one dictionary per file |
| `check_units(path; libraries=String[], binary=nothing, timeout=120.0) -> Vector{Dict{String,Any}}` | `esml check-units --json` — unit-checker report |
| `tasks(path; system=nothing, libraries=String[], jobs=nothing, binary=nothing, timeout=300.0) -> TasksOutput` | `esml tasks --json` — the `esml.tasks/v1` envelope |
| `inspect(path; system=nothing, libraries=String[], binary=nothing, timeout=120.0) -> String` | `esml inspect` — document/system report, as text |
| `dump(path; system=nothing, binary=nothing, timeout=120.0) -> String` | `esml dump` — flattened structure, as text |
| `version(; binary=nothing) -> String` | Version of the engine binary |

```julia
using ESMLKit

reports = check("plant.esml"; libraries = ["library"])
println(reports[1]["summary"]["errors"], " error(s), ",
        reports[1]["summary"]["warnings"], " warning(s)")

out = tasks("computeTasks.esml"; system = "Plant")
for t in out.tasks
    println(t.name, " → ", t.outcome["status"])
end

println(version())
```

What the CLI layer guarantees:

- `cli` is the **escape hatch**. It forwards the argument vector verbatim and
  never filters subcommands, so commercial-only ones (`session`, `encrypt`,
  `decrypt`, `esmlx-info`) work as soon as the binary supports them — the
  binary decides what it accepts. A non-zero exit code is **data, not an
  exception**: `cli` returns it; the typed wrappers are what turn a failing
  `esml` into an `EsmlError`. `input` feeds the process' stdin (for the
  stdin-driven subcommands), and a timeout kills the process and raises
  `EsmlError(kind = :timeout)`.
- `check` / `check_units` return the engine's report **unchanged** — no field
  is renamed, dropped or re-typed, and nested objects are plain `Dict`s — so
  CI greps keep working when the engine adds fields. A non-zero exit raises
  `EsmlError(kind = :engine)` with the engine's stderr as the message and the
  printed report in `err.raw`; output that is not JSON raises
  `EsmlError(kind = :protocol)`.
- `tasks` validates the envelope before handing it back: `apiVersion` must be
  `"esml.tasks/v1"` (otherwise `EsmlError(kind = :protocol)`) and `ok` must be
  `true` (otherwise `EsmlError(kind = :engine)` naming the failed tasks). The
  whole envelope is attached in `err.raw`; `TaskResult.raw` keeps each task
  object losslessly.
- `dump` **shadows `Base.dump`**. After `using ESMLKit` an unqualified `dump`
  is undefined (`UndefVarError`); write `ESMLKit.dump(...)` or `Base.dump`.

> The `esml.tasks/v1` envelope is the client-side contract. The currently
> published open-source `esml` prints human-readable text for `esml tasks`
> and has no `--json` flag there, so that binary answers `tasks` with a
> `kind = :protocol` error. A binary that emits the envelope works with this
> client unchanged.

### The academic limit: 16,384 unknowns

`ESMLKit.MAX_UNKNOWNS` is **16,384**. That is the number of unknowns one
system may have in the academic edition; the limit is a *solve-time* limit,
not a command-line limit — validation, inspection and dumps are unbounded.

Two checks enforce it, and it matters which one fires:

- **The engine refuses — this is the main gate.** `esml solve` and
  `esml simulate` flatten the system first, so an oversized system is
  rejected *before* any Newton iteration starts. That is what stops a
  twenty-minute run that was never going to converge. It is also the only
  check that covers the commands whose envelope does not report a total
  unknown count: `esml.tasks/v1` and `esml.simulate/v1` carry no such field,
  so for those the engine must refuse during flattening.
- **The client refuses — this is the backstop.** When the `esml.solve/v1`
  envelope does report `unknowns`, the client compares it against
  `MAX_UNKNOWNS` and raises `EsmlError(kind = :academic_limit)` before
  returning any values. 16,384 unknowns pass, 16,385 do not.

```julia
try
    solve("big.esml")
catch err
    err.kind == :academic_limit || rethrow()
    println(err.message)   # … over the academic limit of 16384
                            # (学术版上限 16384，商业版请用商业二进制/客户端)
end
```

Going past the cap needs the commercial engine binary and its commercial
client.

### Commercial resident sessions (DTIL)

| Call | Meaning |
| --- | --- |
| `Session(path; system=nothing, libraries=String[], binary=nothing, timeout=nothing)` | Resident session |
| `solve(session)`, `simulate(session, tspan, steps; observe)`, `predict(session, horizon, …)` | Solve, chained integration, non-advancing prediction |
| `set_param!`, `set_params!`, `set_state!`, `set_states!`, `clear_state!` | Hot parameters and state injection |
| `snapshot`, `restore!`, `info`, `close!` | Snapshot, restore, state, and lifecycle |

`SolveResult` and `Trajectory` carry `units` and `meta` with the same contract
as the one-shot calls. `EsmlError` also exposes `code`, `hint`, and `doc_hash`
from `esml.error/v1`.

Errors raise `EsmlError` with `kind` set to `:engine`, `:protocol`, `:timeout`,
`:closed`, `:binary_not_found`, or `:academic_limit`; invalid client arguments
raise `ArgumentError`.

## Development

```bash
julia --project=. -e 'using Pkg; Pkg.instantiate()'
julia --project=. -e 'using Pkg; Pkg.test()'                  # fake engine
julia --project=. -e 'using ESMLKit; ESMLKit.set_binary_path("/path/to/esml")'
julia --project=. test/runtests.jl                            # real engine
```

The protocol tests use `test/fake_esml.jl` (resident session), `test/fake_oneshot.jl`
(one-shot solve/simulate) and `test/fake_cli.jl` (the CLI layer); the real-engine
tests run only when a binary is configured — either through
`ESMLKit.set_binary_path` or, as a CI fallback, the `ESML_BIN` environment
variable.

## License

- **This package**: MIT (see `LICENSE`).
- **ESML engine**: commercial software (see `LICENSE-ENGINE.md`). The academic
  edition is free for academic, teaching, and personal non-commercial use;
  commercial use requires a license (mingtao.li@gmail.com). This package
  contains no engine code and only calls the public JSON protocol.
