"""ESMLKit.jl — MIT Julia client for the ESML engine.

The engine (`esml`) is a native binary distributed separately under its own
license; this package only launches it and speaks the `esml.session/v1` JSON
protocol over stdin/stdout. No engine code is linked or embedded.
"""

module ESMLKit

using JSON
using Preferences

export Session,
    SolveResult,
    Trajectory,
    Info,
    SolveOutput,
    SimulateOutput,
    EsmlError,
    find_binary,
    set_binary_path,
    engine_version,
    solve,
    simulate,
    predict,
    set_param!,
    set_params!,
    set_state!,
    set_states!,
    clear_state!,
    snapshot,
    restore!,
    info,
    close!,
    stderr_tail,
    cli,
    CLIResult,
    check,
    check_units,
    tasks,
    TasksOutput,
    TaskResult,
    inspect,
    dump,
    version,
    MAX_UNKNOWNS

include("errors.jl")
include("limits.jl")
include("binary.jl")
include("session.jl")
include("oneshot.jl")
include("cli.jl")

end
