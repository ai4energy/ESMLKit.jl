#!/usr/bin/env julia
"""Fake `esml solve` / `esml simulate` for one-shot client tests."""

using JSON

const MODE = get(ENV, "FAKE_ONESHOT_MODE", "ok")

if MODE == "timeout"
    sleep(30)
    exit(0)
elseif MODE == "error"
    println(stderr, "fake engine: model failed")
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
    exit(1)
elseif MODE == "bad-json"
    println("this is not a json envelope")
    exit(0)
elseif MODE == "bad-api"
    println(JSON.json(Dict("apiVersion" => "esml.solve/v0")))
    exit(0)
end

op = isempty(ARGS) ? "" : ARGS[1]
if op == "solve"
    println(
        JSON.json(
            Dict(
                "apiVersion" => "esml.solve/v1",
                "values" => [
                    Dict("path" => "m.x", "value" => 0.5, "unit" => "1"),
                    Dict("path" => "m.y", "value" => 0.25),
                ],
                "unknowns" => 2,
                "system" => "S",
                "meta" => Dict(
                    "engineVersion" => "9.9.9-fake",
                    "docHash" => "abc123",
                    "converged" => true,
                    "unitCoverage" => Dict(
                        "known" => 2,
                        "total" => 2,
                        "complete" => true,
                    ),
                ),
            ),
        ),
    )
    exit(0)
elseif op == "simulate"
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
                "meta" => Dict("engineVersion" => "9.9.9-fake"),
            ),
        ),
    )
    exit(0)
else
    println(stderr, "fake engine: expected solve or simulate")
    exit(2)
end
