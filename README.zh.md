# ESMLKit.jl

[English README](README.md)

ESML 引擎的 **MIT** Julia 客户端。包名从 `ESML` 迁移为 `ESMLKit`，
以满足 Julia General 的包名长度要求；UUID 保持不变。公开面是**一次性调用**
`solve` / `simulate` 加上**全功能 CLI 层**（`cli` / `check` / `check_units` /
`tasks` / `inspect` / `dump` / `version`）：每次调用启动一个 `esml` 进程，
读取 `esml.solve/v1` / `esml.simulate/v1` JSON、校验报告、任务信封，或引擎
自己的文本，调用之间不保留状态。

常驻数字孪生（DTIL）会话 `Session`（`predict` / `snapshot` / `restore`）属于
**商业版**能力，需要商业版引擎；学术版会在 `esml session` 入口响亮拒绝。

本包绑定的是 ESML 引擎二进制；Julia 侧的教育版参考实现是
[`ai4energy/esml-julia`](https://github.com/ai4energy/esml-julia)，
与本包是两件独立的东西。

```julia
using ESMLKit

steady = solve("plant.esml"; system = "Plant")
println(steady.values)
println(get(steady.units, "tank.T", nothing), " ", steady.meta["unitCoverage"])

traj = simulate("plant.esml", (0.0, 60.0), 60; observe = ["tank.T"])
println(traj.series["tank.T"][end], " ", get(traj.units, "tank.T", nothing))
```

## 安装

```julia
using Pkg
Pkg.add("ESMLKit")
```

注册进入 General 之前，临时使用仓库地址安装：

```julia
Pkg.add(url = "https://github.com/ai4energy/ESMLKit.jl")
```

还需要**引擎二进制**：

- 免费学术版（展平未知量 ≤ 16,384，非商业用途）：
  <https://github.com/ai4energy/esml/releases>
- 推荐在 Julia 里设置一次：
  ```julia
  ESMLKit.set_binary_path("/path/to/esml")
  ```
  路径会写成 Julia package preference。解析顺序：显式 `binary=` 参数 →
  `set_binary_path` preference → `ESML_BIN` 环境变量 → `PATH`。
- 显式配置的路径不可执行时**响亮报错**，绝不静默换一个二进制。

## API

一次性调用（学术版即可用）：

| 调用 | 含义 |
| --- | --- |
| `solve(path; system=nothing, libraries=String[], binary=nothing, timeout=120.0)` | 稳态求解 → `SolveOutput(values, unknowns, system, raw, units, meta)` |
| `simulate(path, tspan=(0.0, 1.0), steps=100; observe=nothing, …)` | 一次性时间积分 → `SimulateOutput(t, series, steps, system, raw, units, meta)` |

`units` 是路径 → SI 量纲表达式的映射（模型未声明单位时缺项）；`meta` 含
`engineVersion`、`docHash`（源文件 SHA-256）、`durationMs`、`converged`、
`iterations`、`residual`、`residualTolerance` 与 `unitCoverage`。字段语义见
[结果契约](https://docs.ai4energy.cn/esml/results)。

引擎版本：`units` / `meta` 需引擎 **>= 1.8.1**；`iterations` / `residual` /
`EsmlError.code` 需引擎 **>= 1.9.0**。旧引擎缺少的字段会表现为空的 `meta` /
`units` 或 `None`，客户端不伪造。


`observe` 只接受变量路径；空列表在客户端拒绝，未知/重复路径由引擎拒绝。

### 全功能 CLI 层（v0.5.0）

| 调用 | 含义 |
| --- | --- |
| `cli(args::Vector{String}; input=nothing, timeout=120.0, binary=nothing) -> CLIResult` | 跑**任意** `esml` 子命令 → `CLIResult(stdout, stderr, code)` |
| `check(path; libraries=String[], binary=nothing, timeout=120.0) -> Vector{Dict{String,Any}}` | `esml check --json` —— 前端校验报告，每个文件一份字典 |
| `check_units(path; libraries=String[], binary=nothing, timeout=120.0) -> Vector{Dict{String,Any}}` | `esml check-units --json` —— 单位检查报告 |
| `tasks(path; system=nothing, libraries=String[], jobs=nothing, binary=nothing, timeout=300.0) -> TasksOutput` | `esml tasks --json` —— `esml.tasks/v1` 信封 |
| `inspect(path; system=nothing, libraries=String[], binary=nothing, timeout=120.0) -> String` | `esml inspect` —— 文档/系统报告，文本 |
| `dump(path; system=nothing, binary=nothing, timeout=120.0) -> String` | `esml dump` —— 展平后的结构，文本 |
| `version(; binary=nothing) -> String` | 引擎二进制版本号 |

```julia
using ESMLKit

reports = check("plant.esml"; libraries = ["library"])
println(reports[1]["summary"]["errors"], " 个错误，",
        reports[1]["summary"]["warnings"], " 个警告")

out = tasks("computeTasks.esml"; system = "Plant")
for t in out.tasks
    println(t.name, " → ", t.outcome["status"])
end

println(version())
```

CLI 层的三条硬约定：

- `cli` 是**逃生口**。参数原样转发，不对子命令做白名单，所以商业版专属的
  `session` / `encrypt` / `decrypt` / `esmlx-info` 只要二进制支持就能用——
  支持什么由二进制说了算。**非零退出码是数据不是异常**：`cli` 把它返回
  出去，由上面那些类型化包装把失败的 `esml` 变成 `EsmlError`。`input` 喂给
  子进程的 stdin（stdin 驱动的子命令用得上），超时会杀掉进程并抛
  `EsmlError(kind = :timeout)`。
- `check` / `check_units` 把引擎的报告**原样**返回：字段一个不改名、不丢、
  不改类型，嵌套对象是普通 `Dict`，所以引擎以后加字段时 CI 里 grep 的键名
  不会失效。退出码非零抛 `EsmlError(kind = :engine)`，message 是引擎 stderr，
  同时打印出来的报告挂在 `err.raw` 上；输出不是 JSON 则抛
  `EsmlError(kind = :protocol)`。
- `tasks` 先验信封再交结果：`apiVersion` 必须是 `"esml.tasks/v1"`（否则
  `EsmlError(kind = :protocol)`），`ok` 必须是 `true`（否则
  `EsmlError(kind = :engine)`，message 点名失败的任务）。整个信封挂在
  `err.raw` 上，`TaskResult.raw` 无损保留每个任务对象。
- `dump` 与 `Base.dump` **同名冲突**：`using ESMLKit` 之后不限定名的 `dump`
  会变成未定义（`UndefVarError`），要写 `ESMLKit.dump(...)` 或 `Base.dump`。

> `esml.tasks/v1` 是客户端侧定下的契约。目前公开的开源 `esml` 的
> `esml tasks` 只打印人读文本，那里也没有 `--json`，所以拿这个二进制调
> `tasks` 会得到 `kind = :protocol` 的错误；能吐出该信封的二进制则不需要
> 改客户端就能用。

### 学术版上限：16,384 未知量

`ESMLKit.MAX_UNKNOWNS` 是 **16,384**：一个系统的未知量个数上限。这是**求解
阶段**的限制，不是命令行限制——校验、查看结构这些操作没有上限。

两道闸，区别很重要：

- **引擎侧拒绝，这是主闸。** `esml solve` / `esml simulate` 都是先 flatten
  再解，超限的系统在 Newton 迭代开始之前就被拒掉——这正是防止「跑二十分钟
  然后根本不收敛」的那道闸。信封里不带未知量总数的命令（`esml.tasks/v1`、
  `esml.simulate/v1`）也只能靠引擎在 flatten 阶段拒绝。
- **客户端侧拒绝，这是兜底。** `esml.solve/v1` 信封里报了 `unknowns` 时，
  客户端会拿它跟 `MAX_UNKNOWNS` 比，超了就抛
  `EsmlError(kind = :academic_limit)`，一个值都不返回。16,384 放行，
  16,385 不行。

```julia
try
    solve("big.esml")
catch err
    err.kind == :academic_limit || rethrow()
    println(err.message)   # … over the academic limit of 16384
                            # (学术版上限 16384，商业版请用商业二进制/客户端)
end
```

要越过这个上限，需要商业版引擎二进制和商业版客户端。

### 商业版常驻会话（DTIL）

| 调用 | 含义 |
| --- | --- |
| `Session(path; system=nothing, libraries=String[], binary=nothing, timeout=nothing)` | 常驻会话 |
| `solve(session)` / `simulate(session, tspan, steps; observe)` / `predict(session, horizon, …)` | 求解、链式积分、非推进预测 |
| `set_param!` / `set_params!` / `set_state!` / `set_states!` / `clear_state!` | 热参数与状态注入 |
| `snapshot` / `restore!` / `info` / `close!` | 快照恢复、状态与生命周期 |

`SolveResult` / `Trajectory` 含 `units` 与 `meta`，字段与一次性契约一致。

`EsmlError` 还带 `code` / `hint` / `doc_hash`（来自 `esml.error/v1`）。

失败抛 `EsmlError`，`kind` 区分 `:engine` / `:protocol` / `:timeout` / `:closed` /
`:binary_not_found` / `:academic_limit`；客户端参数错误抛 `ArgumentError`。

## 许可

- **本包**：MIT（见 `LICENSE`）。
- **ESML 引擎**：**商业软件，不是 MIT**（见 `LICENSE-ENGINE.md`）。学术版（≤ 16,384 未知量、不含 DTIL）
  非商业用途免费；商业用途需取得商业许可（mingtao.li@gmail.com）。本包不含引擎
  代码，只通过公开 JSON 协议调用引擎。

## 开发

```bash
julia --project=. -e 'using Pkg; Pkg.instantiate()'
julia --project=. -e 'using Pkg; Pkg.test()'                  # 协议测试（假引擎）
ESML_BIN=/path/to/esml julia --project=. test/runtests.jl     # 含真机集成
```

协议测试使用 `test/fake_esml.jl`（常驻会话）、`test/fake_oneshot.jl`（一次性
solve/simulate）与 `test/fake_cli.jl`（CLI 层）；真机集成只在设置 `ESML_BIN`
时运行。
