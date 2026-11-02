"""The academic edition's hard limit: the number of unknowns.

The academic engine is limited by **how many unknowns it can flatten and
solve in one system** — [`MAX_UNKNOWNS`](@ref) (16,384). Everything else the
engine does (front validation, tasks, inspection, dumps) is unbounded; the
limit is a solve-time limit, not a command-line limit.

The limit is enforced in two places, and it is important to know which one
fires:

* **The engine refuses.** `esml solve` / `esml simulate` flatten the system
  first; a system over the limit is rejected *before* any Newton iteration
  starts. This is the check that protects the user from a 20-minute run
  that was never going to converge. It also covers the commands whose
  envelope does not report a total unknown count (`esml.tasks/v1`,
  `esml.simulate/v1`) — there is nothing for the client to check, so the
  engine has to.
* **The client refuses.** When the `esml.solve/v1` envelope *does* report
  `unknowns`, the client compares it against [`MAX_UNKNOWNS`](@ref) and
  raises `EsmlError(kind = :academic_limit)` before handing the values back.
  This catches a binary that reports a count it should not have been able to
  produce.

A system that fits is not affected: 16,384 unknowns is allowed, 16,385 is
not.
"""

"""
    MAX_UNKNOWNS

The academic edition's maximum number of unknowns in one system: **16,384**.

Systems with more unknowns are refused by the engine when it flattens them
and by the client when the engine reports the count. Going beyond it needs
the commercial engine binary and its commercial client.

```julia
solve("big.esml")  # → EsmlError(kind = :academic_limit) past the cap
```
"""
const MAX_UNKNOWNS = 16_384

"""
    _check_academic_limit(unknowns, op; raw=nothing)

Raise `EsmlError(kind = :academic_limit)` when `unknowns` is over
[`MAX_UNKNOWNS`](@ref). `nothing` (the engine did not report a count) is
accepted — the engine's own flatten-time refusal is the backstop.
"""
function _check_academic_limit(unknowns, op::AbstractString; raw = nothing)
    unknowns === nothing && return nothing
    unknowns isa Integer || return nothing
    unknowns > MAX_UNKNOWNS || return nothing
    throw(
        EsmlError(
            "the document has $(unknowns) unknowns, over the academic limit of " *
            "$(MAX_UNKNOWNS) (学术版上限 $(MAX_UNKNOWNS)，商业版请用商业二进制/客户端)";
            kind = :academic_limit,
            op = op,
            raw = raw,
        ),
    )
end
