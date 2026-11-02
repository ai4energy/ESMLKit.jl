#!/usr/bin/env julia
"""Fake `esml` CLI for the full-function client tests (no engine needed).

It mirrors the subcommands the client wraps — `check`, `check-units`,
`tasks`, `inspect`, `dump`, `solve`, `simulate` — using the JSON shapes the
real engine emits (`esml check --json` is an array of per-file reports,
`esml tasks --json` is an `esml.tasks/v1` envelope, …).

Set `FAKE_CLI_MODE` to exercise the failure modes:

* `ok` (default)  — normal output
* `error`         — non-zero exit, `esml.error/v1` envelope on stderr
* `bad-json`      — stdout carries something that is not JSON
* `timeout`       — never answers (timeout test)
* `tasks-fail`    — `tasks` envelope with `ok = false`
* `tasks-bad-api` — `tasks` envelope with the wrong `apiVersion`
* `unknowns-over` — `solve` reports 16385 unknowns (over the academic cap)
"""

using JSON

const MODE = get(ENV, "FAKE_CLI_MODE", "ok")
const TASKS_API = "esml.tasks/v1"
const ENGINE_VERSION = "9.9.9-fake"
const ACADEMIC_CAP = 16_384

"""Positional arguments of `args`, skipping flags and their values."""
function positionals(args)
    out = String[]
    skip = false
    for arg in args
        if skip
            skip = false
            continue
        end
        if arg in ("-L", "--libroot", "--system", "--source", "--jobs", "-s")
            skip = true
            continue
        end
        startswith(arg, "-") && continue
        push!(out, arg)
    end
    return out
end

function has_flag(args, name)
    return any(a -> a == name, args)
end

"Number of `-L` / `--libroot` roots the caller passed (the engine audits that many)."
function libroot_count(args)
    n = 0
    for (i, arg) in enumerate(args)
        (arg == "-L" || arg == "--libroot") && (n += 1)
    end
    return n
end

function check_report(file, nlibs)
    return Dict{String,Any}(
        "file" => file,
        "well_formed" => true,
        "summary" => Dict{String,Any}(
            "errors" => 0,
            "warnings" => 1,
            "models" => 2,
            "systems" => 1,
            "types" => 3,
            "port_types" => 0,
            "units" => 5,
            "functions" => 0,
            "use_libraries" => nlibs,
            "five_level_ok" => true,
            "connect_rules_total" => 0,
        ),
        "findings" => Any[
            Dict{String,Any}(
                "severity" => "warning",
                "code" => "F13",
                "location" => "$(file):3:1",
                "message" => "library registry was not audited",
                "advice" => "pass -L <dir>",
                "count" => 1,
            ),
        ],
    )
end

function check_units_report(file)
    return Dict{String,Any}(
        "file" => file,
        "well_formed" => true,
        "summary" => Dict{String,Any}(
            "errors" => 0,
            "warnings" => 0,
            "unit_block_rows" => 2,
            "type_unit_decls" => 3,
            "invalid_type_units" => 0,
            "unknown_anchors" => 0,
            "dimension_mismatches" => 0,
        ),
        "findings" => Any[],
    )
end

"Value of `name` in `args`, or `nothing` when the flag was not given."
function flag_value(args, name)
    for (i, arg) in enumerate(args)
        if arg == name
            return i < length(args) ? args[i + 1] : nothing
        end
    end
    return nothing
end

function tasks_envelope(ok, args = String[])
    api = MODE == "tasks-bad-api" ? "esml.tasks/v0" : TASKS_API
    system = something(flag_value(args, "--system"), flag_value(args, "-s"), "S")
    jobs = flag_value(args, "--jobs")
    task = Dict{String,Any}(
        "name" => "forecast",
        "kind" => "forecast",
        "target" => system,
        "units" => Dict{String,Any}("m.x" => "K"),
        "meta" => Dict{String,Any}("durationMs" => 1, "engineVersion" => ENGINE_VERSION),
        "outcome" => Dict{String,Any}("kind" => "forecast", "status" => ok ? "ok" : "failed"),
    )
    return Dict{String,Any}(
        "apiVersion" => api,
        "ok" => ok,
        "system" => system,
        "tasks" => Any[task],
        "meta" => Dict{String,Any}(
            "engineVersion" => ENGINE_VERSION,
            "durationMs" => 1,
            "jobs" => jobs,
        ),
    )
end

function main(args)
    if "--version" in args
        println("ESML v$(ENGINE_VERSION) · fake CLI for client tests")
        return 0
    end
    if isempty(args)
        println("fake esml: expected a subcommand")
        return 2
    end
    cmd = args[1]
    rest = args[2:end]
    MODE == "timeout" && (sleep(30); return 0)
    if MODE == "error"
        println(stderr, "fake esml: the document failed to load")
        println(
            stderr,
            JSON.json(
                Dict(
                    "apiVersion" => "esml.error/v1",
                    "code" => "model.parse",
                    "hint" => "fix the document",
                    "docHash" => "abc123",
                ),
            ),
        )
        return 1
    end
    MODE == "bad-json" && (println("this is not a json envelope"); return 0)

    pos = positionals(rest)
    file = isempty(pos) ? "model.esml" : pos[1]

    if cmd == "check"
        if has_flag(rest, "--json")
            println(JSON.json([check_report(file, libroot_count(rest))], 2))
        else
            # the human-readable form of the same verdict
            println("=== $(file)")
            println("ok")
        end
        return 0
    elseif cmd == "check-units"
        if has_flag(rest, "--json")
            println(JSON.json([check_units_report(file)], 2))
        else
            println("=== $(file)")
            println("ok")
        end
        return 0
    elseif cmd == "tasks"
        if has_flag(rest, "--json")
            println(JSON.json(tasks_envelope(MODE != "tasks-fail", rest), 2))
        else
            # the human-readable form of the same run
            println("task forecast (forecast) [S]: ok")
        end
        return 0
    elseif cmd == "inspect"
        println("document : $(file) (2 models)")
        println("system   : S -> 2 unknowns, 2 equations, 1 params")
        return 0
    elseif cmd == "dump"
        println("document : $(file) (2 models)")
        println("  Model m: 1 params, 2 vars, 0 ports, 2 eqs, 0 instances")
        println("system   : S -> 2 unknowns, 2 equations, 1 params")
        return 0
    elseif cmd == "echo-stdin"
        # stdin plumbing check: the client must be able to feed the process
        print(read(stdin, String))
        return 0
    elseif cmd == "solve"
        unknowns = MODE == "unknowns-over" ? ACADEMIC_CAP + 1 : ACADEMIC_CAP
        println(
            JSON.json(
                Dict(
                    "apiVersion" => "esml.solve/v1",
                    "values" => [
                        Dict("path" => "m.x", "value" => 0.5, "unit" => "1"),
                        Dict("path" => "m.y", "value" => 0.25),
                    ],
                    "unknowns" => unknowns,
                    "system" => "S",
                    "meta" => Dict(
                        "engineVersion" => ENGINE_VERSION,
                        "docHash" => "abc123",
                        "converged" => true,
                    ),
                ),
            ),
        )
        return 0
    elseif cmd == "simulate"
        println(
            JSON.json(
                Dict(
                    "apiVersion" => "esml.simulate/v1",
                    "columns" => ["m.x", "m.y"],
                    "t" => [0.0, 1.0],
                    "rows" => [[1.0, 0.5], [0.5, 0.25]],
                    "steps" => 2,
                    "system" => "S",
                    "units" => Dict("m.x" => "1"),
                    "meta" => Dict("engineVersion" => ENGINE_VERSION),
                ),
            ),
        )
        return 0
    end
    println(stderr, "fake esml: unknown subcommand `$(cmd)`")
    return 2
end

exit(main(ARGS))
