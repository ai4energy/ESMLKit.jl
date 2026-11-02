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
