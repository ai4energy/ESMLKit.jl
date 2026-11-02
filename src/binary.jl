"""Locate the ESML **engine binary** and read its version.

Only the engine binary is required: this package does not need (or ship) the
worker, the MCP server, or any platform component. The whole client/server
contract is the `esml session` JSON protocol (`esml.session/v1`).
"""

const _VERSION_RE = r"\bv(\d+\.\d+\.\d+(?:[-+][0-9A-Za-z.-]+)?)\b"
const _BINARY_PREFERENCE = "binary_path"

"""
    set_binary_path(path) -> String

Persist the path to the ESML engine binary as a Julia package preference.
The preference is read by [`find_binary`](@ref) before `ESML_BIN` and `PATH`,
so client code does not need an environment variable.

The path must already be an executable file; this function does not download
or install the engine.
"""
function set_binary_path(path::AbstractString)
    expanded = abspath(expanduser(String(path)))
    if !(isfile(expanded) && Sys.isexecutable(expanded))
        throw(
            ArgumentError(
                "the ESML engine binary is not an executable file: $(repr(expanded))",
            ),
        )
    end
    Preferences.set_preferences!("ESMLKit", _BINARY_PREFERENCE => expanded)
    return expanded
end

"""
    find_binary(explicit=nothing) -> String

Return the path to the `esml` executable.

Resolution order: `explicit` argument → `set_binary_path` preference →
`ENV["ESML_BIN"]` → `PATH`. A path that was given explicitly, by preference,
or via `ESML_BIN` but is not an executable file is a loud error — the client
never silently falls back to another binary.
"""
function find_binary(explicit = nothing)
    preference = @load_preference("binary_path", nothing)
    for (source, candidate) in (
        ("argument", explicit),
        ("ESMLKit.set_binary_path", preference),
        ("ESML_BIN", get(ENV, "ESML_BIN", nothing)),
    )
        candidate === nothing && continue
        path = expanduser(String(candidate))
        if isfile(path) && Sys.isexecutable(path)
            return path
        end
        throw(
            EsmlError(
                "the ESML engine binary from $(source) is not an executable file: $(repr(path))";
                kind = :binary_not_found,
            ),
        )
    end
    found = Sys.which("esml")
    found === nothing || return String(found)
    throw(
        EsmlError(
            "the ESML engine binary (`esml`) was not found: call " *
            "`ESMLKit.set_binary_path(\"/path/to/esml\")`, set `ESML_BIN`, or " *
            "put it on `PATH`. Only the engine binary is required — no worker, " *
            "MCP server, or platform component is needed.";
            kind = :binary_not_found,
        ),
    )
end

"""
    engine_version(binary) -> Union{Nothing,String}

Return the engine version string (e.g. `"1.8.0"`), or `nothing`.

The version is informational; protocol compatibility is checked by the
`apiVersion` of the first envelope, not by this string.
"""
function engine_version(binary::AbstractString)
    out = try
        read(ignorestatus(Cmd([String(binary), "--version"])))
    catch
        return nothing
    end
    return parse_engine_version(String(out))
end

"""
    parse_engine_version(text) -> Union{Nothing,String}

Extract the version string from raw `esml --version` output, or `nothing`
when the text carries no version.

Shared by [`engine_version`](@ref) and [`version`](@ref) so both agree on
what an engine version looks like.
"""
function parse_engine_version(text::AbstractString)
    m = match(_VERSION_RE, String(text))
    return m === nothing ? nothing : String(m.captures[1])
end
