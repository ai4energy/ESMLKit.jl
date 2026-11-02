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
