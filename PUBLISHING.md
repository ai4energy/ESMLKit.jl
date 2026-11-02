# 注册到 Julia General（准备清单）

当前状态：**未注册，暂缓提交**。Julia General 中 `ESMLKit` 为空
（2026-11-02 检查）；包 UUID 为 `6fa1d99e-4a66-4af0-9128-1d23b8695e9c`。

首个 General 登记版本定为 **0.4.1**；v0.1.0–v0.4.1 是登记前的开发 tag。
General 维护者建议：注册完成后由 TagBot 创建 tag，不在注册前预打 tag。

## 前提

- `Project.toml` 的 `version` 与 `[compat]` 已定稿（当前 `0.4.1`）；
- `Pkg.test("ESMLKit")` 在包外环境通过（协议测试；集成测试需 `ESML_BIN`）；
- 仓库已安装 TagBot（`.github/workflows/TagBot.yml`）；
- 注册前清理预注册 tag（`v0.4.1`、`v1.0.0` 等），避免 tag 与最终注册 commit 不一致。

## 推荐路径：JuliaRegistrator

1. JuliaRegistrator 已由 ai4energy 组织安装（`juliateam-registrator`，
   repository selection = all），无需再装到本仓。
2. 在待注册 commit 上评论：
   ```
   @JuliaRegistrator register
   ```
3. 等待 AutoMerge / General 维护者评审。合并后由 TagBot 创建 tag，
   用户即可 `Pkg.add("ESMLKit")`。

## 备选：手工 PR

在 `ai4energy/General` 的 fork 中添加 `E/ESMLKit/`：

- `Package.toml`
  ```toml
  name = "ESMLKit"
  uuid = "6fa1d99e-4a66-4af0-9128-1d23b8695e9c"
  repo = "https://github.com/ai4energy/ESMLKit.jl.git"
  ```
- `Versions.toml`
  ```toml
  ["0.4.1"]
  git-tree-sha1 = "<git rev-parse <registration-commit>^{tree}>"
  ```
- `Deps.toml`：`JSON`（`682c06a0-de6a-54ab-a142-c8b1cf79cde6`）、
  `Preferences`（`21216c6a-2e73-6563-6e65-726566657250`）
- `Compat.toml`：`julia = "1.10"`、`JSON = "1"`、`Preferences = "1"`

然后向 `JuliaRegistries/General` 提 PR。

## 注册前验证

```bash
julia -e 'using Pkg; Pkg.activate(temp=true);
          Pkg.add(url="https://github.com/ai4energy/ESMLKit.jl", rev="<registration-commit>");
          using ESMLKit; println(ESMLKit.engine_version(ESMLKit.find_binary()))'
```
