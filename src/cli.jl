"""Full-function CLI access to the ESML engine binary.

`oneshot.jl` wraps the two calls the academic edition is built around
(`solve` / `simulate`). This file is the **escape hatch**: it forwards *any*
subcommand to the binary and hands back stdout, stderr and the exit code
verbatim — including subcommands that only a commercial engine implements
(`session`, `encrypt`, `decrypt`, `esmlx-info`, …). The client never filters
the command line; the binary decides what it supports and rejects the rest.

The academic edition's only limit is the **unknown count**: the engine binary
refuses to flatten a system with more than [`MAX_UNKNOWNS`](@ref) unknowns.
"""

"""
    CLIResult

Outcome of one `esml` invocation: the captured `stdout`, the captured
`stderr`, and the process exit `code`. A non-zero `code` is **not** an error
here — [`cli`](@ref) reports what the binary said and lets the caller decide.
"""
struct CLIResult
    stdout::String
    stderr::String
    code::Int
end

"""
    cli(args::Vector{String}; input=nothing, timeout=120.0, binary=nothing) -> CLIResult

Run the engine binary with `args` and capture everything it produced.

`args` is the **complete** subcommand argument vector, e.g.
`["check", "model.esml", "--json"]`. The engine executable itself comes from
`binary` (or the usual resolution order: `set_binary_path` preference →
`ESML_BIN` → `PATH`).

* `input` — text written to the process' stdin (closed when omitted). Use it
  for the stdin-driven subcommands (`session`, `pack --apply`, …).
* `timeout` — seconds to wait; the process is killed and an
  `EsmlError(kind = :timeout)` is raised when it overruns. `nothing` waits
  forever.

The exit code is returned, never thrown: a failing `esml` is data, not a
client-side exception. The typed wrappers below (`check`, `check_units`,
`tasks`, …) are the ones that turn a non-zero exit into an `EsmlError`.

```julia
res = cli(["check", "model.esml", "--json"])
res.code == 0 || error(res.stderr)
```
"""
function cli(
    args::AbstractVector{<:AbstractString};
    input = nothing,
    timeout = 120.0,
    binary = nothing,
)
    argv = String[String(a) for a in args]
    exe = find_binary(binary)
    out, err, code = _capture([exe; argv]; input = input, timeout = timeout, op = "cli")
    return CLIResult(out, err, code)
end

"""
    _capture(argv; input=nothing, timeout=nothing, op="cli")

Run `argv` with stdin/stdout/stderr wired to temporary files and return
`(stdout, stderr, exit_code)`. A timeout kills the process (SIGKILL) and
raises `EsmlError(kind = :timeout)`.
"""
function _capture(argv; input = nothing, timeout = nothing, op = "cli")
    out_path, out_io = mktemp()
    close(out_io)
    err_path, err_io = mktemp()
    close(err_io)
    in_path, in_io = mktemp()
    try
        if input === nothing
            close(in_io)                       # empty stdin ⇒ the child sees EOF
        else
            write(in_io, String(input))
            close(in_io)
        end
        proc = run(
            pipeline(ignorestatus(Cmd(argv)), stdin = in_path, stdout = out_path, stderr = err_path);
            wait = false,
        )
        if timeout === nothing
            wait(proc)
        elseif timedwait(() -> Base.process_exited(proc), Float64(timeout)) == :timed_out
            kill(proc, Base.SIGKILL)
            wait(proc)
            throw(
                EsmlError(
                    "`esml $(op)` did not finish within $(timeout)s";
                    kind = :timeout,
                    op = op,
                ),
            )
        end
        return read(out_path, String), read(err_path, String), Int(proc.exitcode)
    finally
        rm(out_path; force = true)
        rm(err_path; force = true)
        rm(in_path; force = true)
    end
end

# ── typed wrappers ─────────────────────────────────────────────────────────

"Append one `-L <dir>` pair per library root (the engine's `--libroot`)."
function _append_libroots!(args, libraries)
    for lib in libraries
        append!(args, ["-L", String(lib)])
    end
    return args
end

"""
Turn a non-zero exit into an `EsmlError`. The engine's stderr is the
message; stdout is kept in `raw` (parsed when it happens to be JSON, so the
caller can still read the report the engine printed next to the failure).
"""
function _exit_error(res::CLIResult, op::AbstractString)
    detail = strip(res.stderr)
    message = isempty(detail) ? "`esml $(op)` exited with code $(res.code)" : detail
    return EsmlError(
        message;
        kind = :engine,
        op = op,
        raw = _maybe_json(res.stdout),
    )
end

"Parse `text` as JSON into plain Julia containers, or `nothing` when it is not JSON."
function _maybe_json(text::AbstractString)
    parsed = try
        JSON.parse(text)
    catch
        nothing
    end
    parsed === nothing && return nothing
    return plain(parsed)
end

"Parse `text` as a JSON array of objects (the `--json` shape of the front validators)."
function _json_objects(text::AbstractString, op::AbstractString)
    parsed = try
        JSON.parse(text)
    catch e
        throw(
            EsmlError(
                "`esml $(op) --json` emitted non-JSON output: $(repr(text)) " *
                "($(sprint(showerror, e)))";
                kind = :protocol,
                op = op,
            ),
        )
    end
    parsed isa AbstractVector || throw(
        EsmlError(
            "expected a JSON array from `esml $(op) --json`";
            kind = :protocol,
            op = op,
            raw = parsed,
        ),
    )
    out = Dict{String,Any}[]
    for item in parsed
        item isa AbstractDict || throw(
            EsmlError(
                "expected a JSON array of objects from `esml $(op) --json`";
                kind = :protocol,
                op = op,
                raw = parsed,
            ),
        )
        push!(out, Dict{String,Any}(String(k) => v for (k, v) in pairs(item)))
    end
    return out
end

"Parse `text` as a JSON object (the `--json` shape of the task envelope)."
function _json_object(text::AbstractString, op::AbstractString)
    parsed = try
        JSON.parse(text)
    catch e
        throw(
            EsmlError(
                "`esml $(op) --json` emitted non-JSON output: $(repr(text)) " *
                "($(sprint(showerror, e)))";
                kind = :protocol,
                op = op,
            ),
        )
    end
    parsed isa AbstractDict || throw(
        EsmlError(
            "expected a JSON object from `esml $(op) --json`";
            kind = :protocol,
            op = op,
            raw = parsed,
        ),
    )
    return Dict{String,Any}(String(k) => plain(v) for (k, v) in pairs(parsed))
end

# ── tasks ─────────────────────────────────────────────────────────────────

"The `apiVersion` the task envelope must carry."
const TASKS_API_VERSION = "esml.tasks/v1"

"""
    TaskResult

One task of an [`esml.tasks/v1`](@ref) envelope.

`name`, `kind` and `target` are the task's identity (which task it is, what
kind of computation it runs, which system it targets). `units` maps an output
path to its unit, `meta` carries task-level metadata (duration, engine
version, …) and `outcome` is the task's result object. `raw` is the task
object exactly as the engine wrote it — the typed fields above are a
convenience, `raw` is the lossless copy.
"""
struct TaskResult
    name::String
    kind::String
    target::String
    units::Dict{String,Any}
    meta::Dict{String,Any}
    outcome::Dict{String,Any}
    raw::Dict{String,Any}
end

"""
    TasksOutput

Result of [`tasks`](@ref): the task list plus the envelope it came from.

`raw` is the complete `esml.tasks/v1` envelope — it keeps the engine's
`system`, `meta` and anything else the envelope carries that the typed
fields above do not model.
"""
struct TasksOutput
    tasks::Vector{TaskResult}
    raw::Dict{String,Any}
end

"""
    tasks(path; system=nothing, libraries=String[], jobs=nothing,
          binary=nothing, timeout=300.0) -> TasksOutput

Run a `<computeTasks>` document through the engine's task runner and return
the tasks it executed.

The engine answers with an `esml.tasks/v1` envelope:

```json
{
  "apiVersion": "esml.tasks/v1",
  "ok": true,
  "system": "S",
  "tasks": [
    {"name": "forecast", "kind": "forecast", "target": "S",
     "units": {"m.x": "K"}, "meta": {"durationMs": 1},
     "outcome": {"kind": "forecast", "status": "ok"}}
  ],
  "meta": {"engineVersion": "9.9.9"}
}
```

The envelope is validated before it is handed back:

* `apiVersion` must be `"esml.tasks/v1"` — anything else is a
  `EsmlError(kind = :protocol)` (a binary that speaks a different envelope
  version is not something this client can interpret).
* `ok` must be `true` — `ok = false` raises an `EsmlError(kind = :engine)`
  whose `raw` is the whole envelope, so the caller can see *which* task
  failed and why.

`system` selects the system (`--system`), `libraries` are library roots
(`-L`), `jobs` is the parallelism the engine may use (`--jobs`).

```julia
out = tasks("computeTasks.esml"; system = "S")
out.tasks[1].name
```
"""
function tasks(
    path::AbstractString;
    system = nothing,
    libraries = String[],
    jobs = nothing,
    binary = nothing,
    timeout = 300.0,
)
    args = String["tasks", String(path), "--json"]
    system === nothing || append!(args, ["--system", String(system)])
    _append_libroots!(args, libraries)
    jobs === nothing || append!(args, ["--jobs", string(jobs)])
    res = cli(args; timeout = timeout, binary = binary)
    res.code == 0 || throw(_exit_error(res, "tasks"))
    envelope = _json_object(res.stdout, "tasks")

    api = get(envelope, "apiVersion", "")
    api == TASKS_API_VERSION || throw(
        EsmlError(
            "expected apiVersion \"$(TASKS_API_VERSION)\" from `esml tasks --json`, " *
            "got \"$(api)\"";
            kind = :protocol,
            op = "tasks",
            raw = envelope,
        ),
    )

    list = get(envelope, "tasks", nothing)
    list isa AbstractVector || throw(
        EsmlError(
            "`esml tasks --json` envelope has no `tasks` array";
            kind = :protocol,
            op = "tasks",
            raw = envelope,
        ),
    )

    results = TaskResult[]
    for item in list
        item isa AbstractDict || throw(
            EsmlError(
                "expected a JSON array of objects from `esml tasks --json`";
                kind = :protocol,
                op = "tasks",
                raw = envelope,
            ),
        )
        raw = Dict{String,Any}(String(k) => plain(v) for (k, v) in pairs(item))
        for key in ("name", "kind")
            get(raw, key, nothing) isa AbstractString || throw(
                EsmlError(
                    "`esml tasks --json` task entry is missing the string field `$(key)`";
                    kind = :protocol,
                    op = "tasks",
                    raw = envelope,
                ),
            )
        end
        push!(
            results,
            TaskResult(
                String(raw["name"]),
                String(raw["kind"]),
                String(get(raw, "target", "")),
                _plain_dict(get(raw, "units", Dict{String,Any}())),
                _plain_dict(get(raw, "meta", Dict{String,Any}())),
                _plain_dict(get(raw, "outcome", Dict{String,Any}())),
                raw,
            ),
        )
    end

    ok = get(envelope, "ok", false)
    ok === true || throw(
        EsmlError(
            "`esml tasks` reported ok=false" *
            _failed_task_suffix(results);
            kind = :engine,
            op = "tasks",
            raw = envelope,
        ),
    )

    return TasksOutput(results, envelope)
end

"Naming the tasks that did not report a successful status (for error messages)."
function _failed_task_suffix(results)
    failed = [r for r in results if get(r.outcome, "status", "ok") != "ok"]
    isempty(failed) && return ""
    names = join(("`$(r.name)`" for r in failed), ", ")
    return ": failed task(s) $(names)"
end

"Coerce a JSON value to a plain `Dict{String,Any}` (empty when it is not an object)."
function _plain_dict(value)
    value isa AbstractDict || return Dict{String,Any}()
    return Dict{String,Any}(String(k) => plain(v) for (k, v) in pairs(value))
end

"""
    inspect(path; system=nothing, libraries=String[], binary=nothing, timeout=120.0) -> String

Ask the engine to describe a document and return its report as text.

`system` selects the system (`--system`) and `libraries` are library roots
(`-L`). The engine's `inspect` prints a human-readable report — models,
systems, unknown/equation counts — and that text is returned unchanged.

A non-zero exit raises `EsmlError(kind = :engine)` with the engine's stderr.

```julia
println(inspect("plant.esml"; system = "S"))
```
"""
function inspect(
    path::AbstractString;
    system = nothing,
    libraries = String[],
    binary = nothing,
    timeout = 120.0,
)
    args = String["inspect", String(path)]
    system === nothing || append!(args, ["--system", String(system)])
    _append_libroots!(args, libraries)
    res = cli(args; timeout = timeout, binary = binary)
    res.code == 0 || throw(_exit_error(res, "inspect"))
    return res.stdout
end

"""
    dump(path; system=nothing, binary=nothing, timeout=120.0) -> String

Ask the engine for the flattened structure of a document and return it as
text.

The dump lists every model, its parameters, variables, ports, equations and
instances, plus the system's flattened unknown/equation counts. It is the
quickest way to see *what the engine thinks the model is* before solving.

The engine's unit warnings are written to stderr and are therefore not part
of the returned text; use [`cli`](@ref) directly if you need both streams.

A non-zero exit raises `EsmlError(kind = :engine)` with the engine's stderr.

!!! note
    This name shadows `Base.dump`. `using ESMLKit` therefore makes an
    unqualified `dump` ambiguous with `Base.dump`; call `ESMLKit.dump` (or
    `Base.dump`) when both are needed.

```julia
println(ESMLKit.dump("plant.esml"))
```
"""
function dump(
    path::AbstractString;
    system = nothing,
    binary = nothing,
    timeout = 120.0,
)
    args = String["dump", String(path)]
    system === nothing || append!(args, ["--system", String(system)])
    res = cli(args; timeout = timeout, binary = binary)
    res.code == 0 || throw(_exit_error(res, "dump"))
    return res.stdout
end

"""
    version(; binary=nothing) -> String

Return the version of the engine binary the client will drive.

The binary is resolved with the usual order (explicit argument →
`set_binary_path` preference → `ESML_BIN` → `PATH`) and queried with
`--version`. The version string is parsed exactly the way
[`engine_version`](@ref) parses it.

An engine that cannot be run raises `EsmlError(kind = :engine)`; an engine
that runs but reports no parsable version raises
`EsmlError(kind = :protocol)` with its raw output attached.

```julia
version()  # e.g. "1.8.0"
version(binary = "/opt/esml/bin/esml")
```
"""
function version(; binary = nothing)
    exe = find_binary(binary)
    out = try
        String(read(ignorestatus(Cmd([exe, "--version"]))))
    catch e
        throw(
            EsmlError(
                "could not run `$(exe) --version`: $(sprint(showerror, e))";
                kind = :engine,
                op = "version",
            ),
        )
    end
    parsed = parse_engine_version(out)
    parsed === nothing && throw(
        EsmlError(
            "could not read a version from `$(exe) --version`: $(repr(out))";
            kind = :protocol,
            op = "version",
            raw = out,
        ),
    )
    return parsed
end

"""
    check(path; libraries=String[], binary=nothing, timeout=120.0) -> Vector{Dict{String,Any}}

Run the engine's front validator (`esml check --json`) and return one
dictionary per validated file.

The report is returned **as the engine wrote it** — no field is renamed,
dropped or re-typed. Typical keys are `file`, `well_formed`, `summary`
(`errors`, `warnings`, `models`, `systems`, `types`, `units`, …) and
`findings` (each with `severity`, `code`, `location`, `message`, `advice`).

A non-zero exit (the validator found an error) raises `EsmlError` with the
engine's stderr as the message; the report the engine printed is kept in
`err.raw`.

```julia
reports = check("model.esml"; libraries = ["library"])
isempty(reports[1]["findings"]) || @show reports[1]["findings"]
```
"""
function check(
    path::AbstractString;
    libraries = String[],
    binary = nothing,
    timeout = 120.0,
)
    args = String["check", String(path), "--json"]
    _append_libroots!(args, libraries)
    res = cli(args; timeout = timeout, binary = binary)
    res.code == 0 || throw(_exit_error(res, "check"))
    return _json_objects(res.stdout, "check")
end

"""
    check_units(path; libraries=String[], binary=nothing, timeout=120.0) -> Vector{Dict{String,Any}}

Run the engine's unit checker (`esml check-units --json`) and return one
dictionary per checked file.

Same shape and same error semantics as [`check`](@ref): the report is passed
through unchanged, and a non-zero exit raises `EsmlError` carrying stderr.
"""
function check_units(
    path::AbstractString;
    libraries = String[],
    binary = nothing,
    timeout = 120.0,
)
    args = String["check-units", String(path), "--json"]
    _append_libroots!(args, libraries)
    res = cli(args; timeout = timeout, binary = binary)
    res.code == 0 || throw(_exit_error(res, "check-units"))
    return _json_objects(res.stdout, "check-units")
end
