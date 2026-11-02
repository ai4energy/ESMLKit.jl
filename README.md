# ESMLKit.jl

[中文说明](README.zh.md)

ESMLKit.jl is the **MIT-licensed Julia client** for the ESML engine. It launches
the separate `esml` binary and speaks the `esml.session/v1` JSON protocol over
stdin/stdout; no engine code is linked or embedded.

The public surface is **one-shot** `solve` / `simulate`: each call starts an
`esml` process and returns an `esml.solve/v1` / `esml.simulate/v1` envelope.
Resident digital-twin sessions (`Session`, `predict`, `snapshot`, `restore!`)
require the commercial engine edition; the academic edition rejects
`esml session` at startup.

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

One-shot calls (available with the academic engine):

| Call | Meaning |
| --- | --- |
| `solve(path; system=nothing, libraries=String[], binary=nothing, timeout=120.0)` | Steady-state solve → `SolveOutput(values, unknowns, system, raw, units, meta)` |
| `simulate(path, tspan=(0.0, 1.0), steps=100; observe=nothing, …)` | One time integration → `SimulateOutput(t, series, steps, system, raw, units, meta)` |

`units` maps variable paths to SI dimension expressions. `meta` contains
`engineVersion`, `docHash`, `durationMs`, `converged`, `iterations`,
`residual`, `residualTolerance`, and `unitCoverage`.

`observe` accepts variable paths only; an empty list is rejected by the client,
and unknown or duplicate paths are rejected by the engine.

Commercial resident sessions (DTIL):

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
`:closed`, or `:binary_not_found`; invalid client arguments raise
`ArgumentError`.

## Development

```bash
julia --project=. -e 'using Pkg; Pkg.instantiate()'
julia --project=. -e 'using Pkg; Pkg.test()'                  # fake engine
ESML_BIN=/path/to/esml julia --project=. test/runtests.jl     # real engine
```

The protocol tests use `test/fake_esml.jl`; the real-engine tests run only when
`ESML_BIN` is set.

## License

- **This package**: MIT (see `LICENSE`).
- **ESML engine**: commercial software (see `LICENSE-ENGINE.md`). The academic
  edition is free for academic, teaching, and personal non-commercial use;
  commercial use requires a license (mingtao.li@gmail.com). This package
  contains no engine code and only calls the public JSON protocol.
