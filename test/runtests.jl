using Test
using ESMLKit

const FAKE = joinpath(@__DIR__, "fake_esml.jl")
const FAKE_ONESHOT = joinpath(@__DIR__, "fake_oneshot.jl")
const FAKE_CLI = joinpath(@__DIR__, "fake_cli.jl")
const ROOT = dirname(@__DIR__)
# Pkg.test runs in a temporary test environment. Point the fake engine at the
# active project (which has JSON), not at the package checkout, so the suite
# also works outside a repository checkout.
const TEST_PROJECT = something(Base.active_project(), joinpath(ROOT, "Project.toml"))
const SHIM_DIR = mktempdir()

# The fake engine runs in a fresh Julia process. Warm JSON's precompile cache
# in the test environment first; otherwise a cold precompile can exceed the
# session-open timeout.
let julia = joinpath(Sys.BINDIR, Base.julia_exename())
    run(`$julia --startup-file=no --project=$TEST_PROJECT -e "using JSON"`)
end

function make_shim(name, fake)
    shim = joinpath(SHIM_DIR, name)
    julia = joinpath(Sys.BINDIR, Base.julia_exename())
    open(shim, "w") do io
        println(io, "#!/bin/sh")
        println(io, "exec '$(julia)' --startup-file=no --project='$(TEST_PROJECT)' '$(fake)' \"\$@\"")
    end
    chmod(shim, 0o755)
    return shim
end

const SHIM = make_shim("esml", FAKE)
const ONESHOT = make_shim("esml-oneshot", FAKE_ONESHOT)
const CLI_SHIM = make_shim("esml-cli", FAKE_CLI)

"Return the exception thrown by `f`, or `nothing`."
function caught(f)
    try
        f()
        return nothing
    catch err
        return err
    end
end

function with_session(f; mode = "ok", timeout = 30.0)
    return withenv("FAKE_ESML_MODE" => mode) do
        session = Session("plant.esml"; binary = SHIM, timeout = timeout)
        try
            f(session)
        finally
            close!(session)
        end
    end
end

@testset "ESMLKit.jl" begin
    @testset "open envelope" begin
        with_session() do s
            @test s.doc_hash == 42
            @test s.system == "Fake"
            @test s.unknowns == 2
            @test s.dynamic === true
            @test s.engine_version == "9.9.9-fake"
        end
    end

    @testset "solve + hot parameter" begin
        with_session() do s
            first = solve(s)
            @test Set(keys(first.values)) == Set(["m.x", "m.y"])
            @test first.values["m.x"] ≈ 1.0 / 1.5
            @test first.warm === false
            @test first.iterations == 5

            set_param!(s, "m.lam", 2.0)
            second = solve(s)
            @test second.values["m.x"] ≈ 1.0 / 3.0
            @test second.values["m.y"] ≈ 2.0 / 3.0
            @test second.warm === true
            @test second.iterations == 3
        end
    end

    @testset "set_params! mapping and pairs" begin
        with_session() do s
            set_params!(s, Dict("m.lam" => 1.0))
            @test solve(s).values["m.x"] ≈ 0.5
            set_params!(s, [("m.lam", 3.0)])
            @test solve(s).values["m.x"] ≈ 0.25

            @test_throws ArgumentError set_params!(s, Dict{String,Float64}())
            err = caught(() -> set_params!(s, [("m.missing", 1.0)]))
            @test err isa EsmlError && err.kind == :engine
            @test solve(s).values["m.x"] ≈ 0.25
        end
    end

    @testset "simulate: window, observe, chaining" begin
        with_session() do s
            first = simulate(s, (0.0, 2.0), 4; observe = ["m.y"])
            @test first.steps == 4
            @test length(first.t) == 5
            @test collect(keys(first.series)) == ["m.y"]
            @test first.series["m.y"][1] ≈ 0.5
            @test first.continued === false

            chained = simulate(s, (2.0, 3.0), 2; observe = ["m.x"])
            @test chained.continued === true
            @test chained.series["m.x"][1] ≈ first.series["m.y"][end] / 0.5

            clear_state!(s)
            fresh = simulate(s, (2.0, 3.0), 2; observe = ["m.x"])
            @test fresh.continued === false
            @test fresh.series["m.x"][1] ≈ 1.0
        end
    end

    @testset "simulate defaults to all variables" begin
        with_session() do s
            traj = simulate(s, (0.0, 1.0), 2)
            @test Set(keys(traj.series)) == Set(["m.x", "m.y"])
        end
    end

    @testset "predict does not advance the session" begin
        with_session() do s
            p = predict(s, 1.0, 2; observe = ["m.x"])
            @test p.t ≈ [0.0, 0.5, 1.0]
            @test p.continued === false
            traj = simulate(s, (0.0, 1.0), 2; observe = ["m.x"])
            @test traj.continued === false
        end
    end

    @testset "state injection and info" begin
        with_session() do s
            set_state!(s, "m.x", 2.0)
            status = info(s)
            @test status.pending_states == 1
            @test status.dynamic === true
            @test status.doc_hash == 42
            @test solve(s).values["m.x"] ≈ 2.0 / 1.5

            clear_state!(s)
            @test info(s).pending_states == 0

            err = caught(() -> set_state!(s, "m.y", 1.0))
            @test err isa EsmlError && err.kind == :engine
        end
    end

    @testset "set_states! batch" begin
        with_session() do s
            set_states!(s, Dict("m.x" => 3.0))
            @test info(s).pending_states == 1
            @test solve(s).values["m.x"] ≈ 3.0 / 1.5
            @test_throws ArgumentError set_states!(s, [])
        end
    end

    @testset "snapshot / restore" begin
        with_session() do s
            set_param!(s, "m.lam", 1.5)
            simulate(s, (0.0, 1.0), 2; observe = ["m.x"])
            snap = snapshot(s)
            @test snap["docHash"] == 42
            @test length(snap["params"]) == 1
            @test snap["params"][1][1] == "m.lam"
            @test snap["params"][1][2] ≈ 1.5

            set_param!(s, "m.lam", 0.25)
            clear_state!(s)
            restore!(s, snap)
            @test snapshot(s)["params"][1][2] ≈ 1.5
            chained = simulate(s, (1.0, 2.0), 2; observe = ["m.x"])
            @test chained.continued === true

            @test_throws ArgumentError restore!(s, "not a snapshot")
            bad = Dict{String,Any}(snap)
            bad["docHash"] = 7
            err = caught(() -> restore!(s, bad))
            @test err isa EsmlError && err.kind == :engine
        end
    end

    @testset "engine error carries kind, op, raw envelope" begin
        with_session() do s
            err = caught(() -> set_param!(s, "m.missing", 1.0))
            @test err isa EsmlError
            @test err.kind == :engine
            @test err.op == "set_param"
            @test occursin("not a declared parameter", err.message)
            @test err.raw["op"] == "error"
            @test err.raw["request"] == "set_param"
            @test solve(s).values["m.x"] ≈ 1.0 / 1.5
        end
    end

    @testset "observe rejected by engine" begin
        with_session() do s
            @test_throws EsmlError simulate(s, (0.0, 1.0), 1; observe = ["m.lam"])
            @test_throws EsmlError simulate(s, (0.0, 1.0), 1; observe = ["m.x", "m.x"])
        end
    end

    @testset "client rejects malformed input before sending" begin
        with_session() do s
            @test_throws ArgumentError set_param!(s, "m.lam", NaN)
            @test_throws ArgumentError set_param!(s, "m.lam", Inf)
            @test_throws ArgumentError set_params!(s, Dict("m.lam" => NaN))
            @test_throws ArgumentError simulate(s, (0.0, NaN))
            @test_throws ArgumentError simulate(s, (0.0, 1.0), 1; observe = String[])
            @test_throws ArgumentError simulate(s, (0.0, 1.0), 0)
            @test_throws ArgumentError predict(s, 0.0)
            @test_throws ArgumentError predict(s, -1.0)
            @test_throws ArgumentError set_state!(s, "m.x", NaN)
            @test info(s).doc_hash == 42
        end
    end

    @testset "close is idempotent; ops after close raise" begin
        with_session() do s
            close!(s)
            close!(s)
            @test s.closed
            err = caught(() -> solve(s))
            @test err isa EsmlError && err.kind == :closed
        end
    end

    @testset "bad apiVersion" begin
        err = withenv("FAKE_ESML_MODE" => "bad-version") do
            caught(() -> Session("plant.esml"; binary = SHIM, timeout = 30.0))
        end
        @test err isa EsmlError
        @test err.kind == :protocol
        @test occursin("apiVersion", err.message)
    end

    @testset "engine crash" begin
        err = withenv("FAKE_ESML_MODE" => "crash") do
            session = Session("plant.esml"; binary = SHIM, timeout = 5.0)
            try
                caught(() -> info(session))
            finally
                close!(session)
            end
        end
        @test err isa EsmlError
        @test err.kind == :closed
    end

    @testset "timeout kills the engine" begin
        started = time()
        err = withenv("FAKE_ESML_MODE" => "silent") do
            # 5 s covers the Julia fake's startup (the open envelope) even on
            # slow Julia 1.6 CI runners; `info` still times out because the
            # fake never answers.
            session = Session("plant.esml"; binary = SHIM, timeout = 5.0)
            try
                caught(() -> info(session))
            finally
                close!(session)
            end
        end
        @test err isa EsmlError
        @test err.kind == :timeout
        @test time() - started < 20.0
    end

    @testset "non-JSON output" begin
        session = withenv("FAKE_ESML_MODE" => "garbage") do
            Session("plant.esml"; binary = SHIM, timeout = 5.0)
        end
        err = caught(() -> solve(session))
        @test err isa EsmlError
        @test err.kind == :protocol
        @test session.closed
        close!(session)
    end

    @testset "binary resolution" begin
        missing = joinpath(mktempdir(), "esml")
        err = caught(() -> find_binary(missing))
        @test err isa EsmlError && err.kind == :binary_not_found

        err = withenv("ESML_BIN" => missing) do
            caught(() -> find_binary())
        end
        @test err isa EsmlError && err.kind == :binary_not_found

        plain_file = joinpath(mktempdir(), "esml")
        write(plain_file, "not executable")
        err = caught(() -> find_binary(plain_file))
        @test err isa EsmlError && err.kind == :binary_not_found

        @test find_binary(SHIM) == SHIM
    end

    @testset "one-shot solve" begin
        out = solve("plant.esml"; binary = ONESHOT)
        @test out.values == Dict("m.x" => 0.5, "m.y" => 0.25)
        @test out.units == Dict("m.x" => "1")
        @test out.unknowns == 2
        @test out.system == "S"
        @test out.meta["converged"] == true
    end

    @testset "one-shot simulate" begin
        out = simulate("plant.esml", (0.0, 1.0), 2; binary = ONESHOT)
        @test out.t == [0.0, 1.0]
        @test out.series["m.x"] == [1.0, 0.5]
        @test out.series["m.y"] == [0.5, 0.25]
        @test out.units == Dict("m.x" => "1")
        @test out.steps == 2
        @test out.system == "S"
    end

    @testset "one-shot error envelope" begin
        err = withenv("FAKE_ONESHOT_MODE" => "error") do
            caught(() -> solve("plant.esml"; binary = ONESHOT))
        end
        @test err isa EsmlError
        @test err.kind == :engine
        @test err.code == "model.parse"
        @test err.hint == "fix the document"
        @test err.doc_hash == "abc123"
    end

    @testset "one-shot malformed output" begin
        err = withenv("FAKE_ONESHOT_MODE" => "bad-json") do
            caught(() -> solve("plant.esml"; binary = ONESHOT))
        end
        @test err isa EsmlError && err.kind == :protocol

        err = withenv("FAKE_ONESHOT_MODE" => "bad-api") do
            caught(() -> solve("plant.esml"; binary = ONESHOT))
        end
        @test err isa EsmlError && err.kind == :protocol
        @test occursin("apiVersion", err.message)
    end

    @testset "one-shot timeout" begin
        err = withenv("FAKE_ONESHOT_MODE" => "timeout") do
            caught(() -> solve("plant.esml"; binary = ONESHOT, timeout = 0.5))
        end
        @test err isa EsmlError && err.kind == :timeout
    end

    @testset "cli: full-function pass-through" begin
        res = cli(["check", "plant.esml", "--json"]; binary = CLI_SHIM)
        @test res isa CLIResult
        @test res.code == 0
        @test occursin("well_formed", res.stdout)
        @test isempty(res.stderr)
    end

    @testset "cli: a non-zero exit is data, not an exception" begin
        res = withenv("FAKE_CLI_MODE" => "error") do
            cli(["check", "plant.esml", "--json"]; binary = CLI_SHIM)
        end
        @test res.code == 1
        @test occursin("esml.error/v1", res.stderr)
    end

    @testset "cli: stdin is forwarded" begin
        res = cli(["echo-stdin"]; input = "hello\n", binary = CLI_SHIM)
        @test res.code == 0
        @test strip(res.stdout) == "hello"
    end

    @testset "cli: timeout kills the engine" begin
        started = time()
        err = withenv("FAKE_CLI_MODE" => "timeout") do
            caught(() -> cli(["solve", "plant.esml"]; binary = CLI_SHIM, timeout = 0.5))
        end
        @test err isa EsmlError
        @test err.kind == :timeout
        @test time() - started < 20.0
    end

    @testset "check: the JSON report array is passed through" begin
        reports = check("plant.esml"; binary = CLI_SHIM)
        @test reports isa Vector{Dict{String,Any}}
        @test length(reports) == 1
        report = reports[1]
        @test report["file"] == "plant.esml"
        @test report["well_formed"] == true
        @test report["summary"]["errors"] == 0
        @test report["summary"]["models"] == 2
        @test report["summary"]["five_level_ok"] == true
        @test report["summary"] isa Dict{String,Any}
        @test report["findings"] isa Vector
        @test report["findings"][1]["code"] == "F13"
        @test report["findings"][1]["severity"] == "warning"
    end

    @testset "check: library roots are forwarded" begin
        reports = check("plant.esml"; libraries = ["lib-a", "lib-b"], binary = CLI_SHIM)
        @test reports[1]["summary"]["use_libraries"] == 2
    end

    @testset "check: a non-zero exit raises with stderr" begin
        err = withenv("FAKE_CLI_MODE" => "error") do
            caught(() -> check("plant.esml"; binary = CLI_SHIM))
        end
        @test err isa EsmlError
        @test err.kind == :engine
        @test err.op == "check"
        @test occursin("esml.error/v1", err.message)
    end

    @testset "check: malformed JSON raises a protocol error" begin
        err = withenv("FAKE_CLI_MODE" => "bad-json") do
            caught(() -> check("plant.esml"; binary = CLI_SHIM))
        end
        @test err isa EsmlError
        @test err.kind == :protocol
    end

    @testset "check_units: the JSON report array is passed through" begin
        reports = check_units("plant.esml"; binary = CLI_SHIM)
        @test length(reports) == 1
        @test reports[1]["well_formed"] == true
        @test reports[1]["summary"]["type_unit_decls"] == 3
        @test isempty(reports[1]["findings"])
    end

    @testset "check_units: a non-zero exit raises with stderr" begin
        err = withenv("FAKE_CLI_MODE" => "error") do
            caught(() -> check_units("plant.esml"; binary = CLI_SHIM))
        end
        @test err isa EsmlError
        @test err.kind == :engine
        @test err.op == "check-units"
    end

    @testset "tasks: the esml.tasks/v1 envelope is decoded" begin
        out = tasks("computeTasks.esml"; binary = CLI_SHIM)
        @test out isa TasksOutput
        @test length(out.tasks) == 1
        task = out.tasks[1]
        @test task isa TaskResult
        @test task.name == "forecast"
        @test task.kind == "forecast"
        @test task.target == "S"
        @test task.units["m.x"] == "K"
        @test task.meta["engineVersion"] == "9.9.9-fake"
        @test task.outcome["status"] == "ok"
        @test task.raw["name"] == "forecast"
        @test out.raw["apiVersion"] == "esml.tasks/v1"
        @test out.raw["ok"] == true
        @test out.raw["system"] == "S"
    end

    @testset "tasks: system, library roots and jobs are forwarded" begin
        out = tasks(
            "computeTasks.esml";
            system = "S2",
            libraries = ["lib-a", "lib-b"],
            jobs = 4,
            binary = CLI_SHIM,
        )
        @test out.raw["system"] == "S2"
        @test out.tasks[1].target == "S2"
        @test out.raw["meta"]["jobs"] == "4"
    end

    @testset "tasks: ok=false raises and keeps the envelope" begin
        err = withenv("FAKE_CLI_MODE" => "tasks-fail") do
            caught(() -> tasks("computeTasks.esml"; binary = CLI_SHIM))
        end
        @test err isa EsmlError
        @test err.kind == :engine
        @test err.op == "tasks"
        @test occursin("ok=false", err.message)
        @test occursin("forecast", err.message)
        @test err.raw isa Dict
        @test err.raw["ok"] == false
        @test err.raw["apiVersion"] == "esml.tasks/v1"
    end

    @testset "tasks: a wrong apiVersion is a protocol error" begin
        err = withenv("FAKE_CLI_MODE" => "tasks-bad-api") do
            caught(() -> tasks("computeTasks.esml"; binary = CLI_SHIM))
        end
        @test err isa EsmlError
        @test err.kind == :protocol
        @test occursin("esml.tasks/v1", err.message)
    end

    @testset "tasks: malformed JSON is a protocol error" begin
        err = withenv("FAKE_CLI_MODE" => "bad-json") do
            caught(() -> tasks("computeTasks.esml"; binary = CLI_SHIM))
        end
        @test err isa EsmlError
        @test err.kind == :protocol
    end

    @testset "inspect: the report comes back as text" begin
        text = inspect("plant.esml"; system = "S2", binary = CLI_SHIM)
        @test text isa String
        @test occursin("plant.esml", text)
        @test occursin("S2", text)
    end

    @testset "inspect: a non-zero exit raises with stderr" begin
        err = withenv("FAKE_CLI_MODE" => "error") do
            caught(() -> inspect("plant.esml"; binary = CLI_SHIM))
        end
        @test err isa EsmlError
        @test err.kind == :engine
        @test err.op == "inspect"
        @test occursin("esml.error/v1", err.message)
    end

    @testset "dump: the structure comes back as text" begin
        # `dump` shadows `Base.dump`, so it must be qualified here — the same
        # caveat the README documents.
        text = ESMLKit.dump("plant.esml"; system = "S2", binary = CLI_SHIM)
        @test text isa String
        @test occursin("Model m", text)
        @test occursin("S2", text)
    end

    @testset "dump: a non-zero exit raises with stderr" begin
        err = withenv("FAKE_CLI_MODE" => "error") do
            caught(() -> ESMLKit.dump("plant.esml"; binary = CLI_SHIM))
        end
        @test err isa EsmlError
        @test err.kind == :engine
        @test err.op == "dump"
    end

    @testset "version: the engine version is read" begin
        @test version(binary = CLI_SHIM) == "9.9.9-fake"
    end

    @testset "version: an unparsable version is a protocol error" begin
        err = withenv("FAKE_CLI_MODE" => "no-version") do
            caught(() -> version(binary = CLI_SHIM))
        end
        @test err isa EsmlError
        @test err.kind == :protocol
        @test err.op == "version"
    end

    @testset "academic limit: the constant is 16,384" begin
        @test MAX_UNKNOWNS == 16_384
    end

    @testset "academic limit: exactly 16,384 unknowns is allowed" begin
        out = solve("plant.esml"; binary = CLI_SHIM)
        @test out isa SolveOutput
        @test out.unknowns == 16_384
        @test haskey(out.values, "m.x")
    end

    @testset "academic limit: 16,385 unknowns is refused" begin
        err = withenv("FAKE_CLI_MODE" => "unknowns-over") do
            caught(() -> solve("plant.esml"; binary = CLI_SHIM))
        end
        @test err isa EsmlError
        @test err.kind == :academic_limit
        @test err.op == "solve"
        @test occursin("16385", err.message)
        @test occursin("学术版上限 16384", err.message)
        @test occursin("商业版请用商业二进制/客户端", err.message)
        @test err.raw isa Dict
        @test err.raw["unknowns"] == 16_385
    end

    # ── real engine (opt-in) ─────────────────────────────────────────────
    let bin = get(ENV, "ESML_BIN", nothing)
        if bin === nothing
            @info "ESMLKit.jl: integration tests skipped — set ESML_BIN to a real `esml` binary"
        else
            doc = joinpath(@__DIR__, "decay.esml")
            @testset "real engine" begin
                session = Session(doc; system = "S", binary = bin, timeout = 120.0)
                try
                    @test session.dynamic === true
                    @test session.doc_hash !== nothing
                    @test session.unknowns >= 1

                    err = caught(
                        () -> ESMLKit.solve(
                            "/tmp/esml-missing-for-client.esml";
                            binary = bin,
                        ),
                    )
                    @test err isa EsmlError
                    @test err.code == "io.read"
                    @test err.hint !== nothing
                    @test err.doc_hash === nothing

                    traj = simulate(session, (0.0, 1.0), 20; observe = ["m.x"])
                    @test traj.points == 21
                    @test collect(keys(traj.series)) == ["m.x"]
                    @test traj.series["m.x"][1] ≈ 1.0
                    @test traj.series["m.x"][end] ≈ exp(-0.5) rtol = 2e-3
                    @test traj.continued === false

                    clear_state!(session)
                    set_param!(session, "m.lam", 0.2)
                    hot = simulate(session, (0.0, 1.0), 20; observe = ["m.x"])
                    @test hot.series["m.x"][end] ≈ exp(-0.2) rtol = 2e-3

                    @test_throws EsmlError simulate(
                        session,
                        (0.0, 1.0),
                        2;
                        observe = ["m.lam"],
                    )
                    @test_throws EsmlError simulate(
                        session,
                        (0.0, 1.0),
                        2;
                        observe = ["m.x", "m.x"],
                    )
                    @test info(session).sim_calls == 2

                    clear_state!(session)
                    first = simulate(session, (0.0, 1.0), 10; observe = ["m.x"])
                    @test first.meta["engineVersion"] isa AbstractString
                    @test isempty(first.units)
                    p = predict(session, 0.5, 5; observe = ["m.x"])
                    @test p.continued === true
                    @test p.t[1] == 0.0
                    @test p.series["m.x"][1] ≈ first.series["m.x"][end] rtol = 1e-6
                    chained = simulate(session, (1.0, 2.0), 10; observe = ["m.x"])
                    @test chained.continued === true
                    @test chained.series["m.x"][1] ≈ first.series["m.x"][end] rtol = 1e-6

                    sres = solve(session)
                    @test sres.meta["converged"] == true
                    @test sres.meta["engineVersion"] isa AbstractString
                    @test sres.meta["docHash"] isa AbstractString
                    @test isempty(sres.units)
                    @test sres.iterations !== nothing
                    @test sres.meta["residual"] <= sres.meta["residualTolerance"]

                    one = ESMLKit.solve(doc; system = "S", binary = bin)
                    @test one.values["m.x"] ≈ 0.0 atol = 1e-8
                    @test one.meta["converged"] == true
                    @test one.meta["docHash"] isa AbstractString
                    @test length(one.meta["docHash"]) == 64
                    @test one.meta["unitCoverage"]["total"] == 1
                    @test one.meta["iterations"] >= 1
                    @test one.meta["residual"] <= one.meta["residualTolerance"]
                    @test isempty(one.units)
                    oneshot = ESMLKit.simulate(
                        doc,
                        (0.0, 1.0),
                        10;
                        observe = ["m.x"],
                        system = "S",
                        binary = bin,
                    )
                    @test oneshot.series["m.x"][1] ≈ 1.0
                    @test oneshot.steps == 10
                    @test oneshot.meta["engineVersion"] == one.meta["engineVersion"]
                    @test isempty(oneshot.units)
                finally
                    close!(session)
                end

                @testset "snapshot into a fresh session" begin
                    a = Session(doc; system = "S", binary = bin, timeout = 120.0)
                    b = Session(doc; system = "S", binary = bin, timeout = 120.0)
                    try
                        clear_state!(a)
                        set_param!(a, "m.lam", 0.3)
                        first = simulate(a, (0.0, 1.0), 10; observe = ["m.x"])
                        snap = snapshot(a)
                        @test snap["docHash"] == a.doc_hash
                        restore!(b, snap)
                        @test snapshot(b)["params"] == snap["params"]
                        chained = simulate(b, (1.0, 2.0), 10; observe = ["m.x"])
                        @test chained.continued === true
                        @test chained.series["m.x"][1] ≈ first.series["m.x"][end] rtol = 1e-6
                    finally
                        close!(a)
                        close!(b)
                    end
                end

                @testset "real engine: the CLI layer" begin
                    # `check`/`check-units` on a clean document must be a clean
                    # verdict; the reports come back as plain dictionaries.
                    res = cli(["check", doc, "--json"]; binary = bin)
                    @test res.code == 0
                    reports = check(doc; binary = bin)
                    @test reports isa Vector{Dict{String,Any}}
                    @test length(reports) == 1
                    @test occursin(basename(doc), reports[1]["file"])
                    @test reports[1]["well_formed"] == true
                    @test reports[1]["summary"]["errors"] == 0
                    @test reports[1]["summary"] isa Dict{String,Any}

                    unit_reports = check_units(doc; binary = bin)
                    @test unit_reports isa Vector{Dict{String,Any}}
                    @test length(unit_reports) == 1
                    @test unit_reports[1]["well_formed"] == true

                    # `inspect` and `dump` answer with text.
                    text = inspect(doc; system = "S", binary = bin)
                    @test text isa String
                    @test !isempty(strip(text))
                    structure = ESMLKit.dump(doc; system = "S", binary = bin)
                    @test structure isa String
                    @test !isempty(strip(structure))

                    @test version(binary = bin) isa AbstractString
                end
            end
        end
    end
end
