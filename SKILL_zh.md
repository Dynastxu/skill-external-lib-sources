---
name: external-lib-sources
description: 列出并读取外部 Gradle 库（JEI、GeckoLib、Guava、Netty 等）的 Java 源码。默认通过 IntelliJ 的 Gradle 模型按当前项目取库（与 IDE 的 External Libraries 一致）；-Global 扫描整个 Gradle 模块缓存。支持 find/grep/show/list，流式读取 jar，不调用 Gradle、不解压。
---

# 外部库源码检索

环境要求：任意 Gradle 项目，最好已在 IntelliJ IDEA 中导入。IDE/Gradle 会把依赖 jar 与源码 jar 记录到 Gradle 模块缓存（`~/.gradle/caches/modules-2/files-2.1`，或 `$GRADLE_USER_HOME/caches/modules-2/files-2.1`）。脚本直接读取这些路径，不调用 Gradle，也不解压 jar。

## 范围

- **默认：项目级。** 脚本读取 IntelliJ 的 Gradle 导入模型（`<system>/projects/<name>.<hash>/external_build_system/project/libraries.xml`），也就是 IDE **External Libraries** 面板背后的同一份模型。它包含项目解析出的依赖（含传递依赖）及源码根。
- **`-Global`：用户级。** 列出本机 Gradle 模块缓存中所有带 jar 的库，是项目级的超集，可能包含其他项目下载的库。
- 找不到 IntelliJ 模型时，脚本会退回用户级列表并打印提示。

模型是快照。修改 `build.gradle` 或依赖后，需要在 IntelliJ 里重新同步 Gradle。

## 命令

在项目目录执行（脚本会自己定位最近的 `.git` + Gradle 项目根）：

```powershell
pwsh -NoProfile -File path/to/scripts/libsrc.ps1 <命令> [参数]
```

- `info`：项目根、IDE 模型路径、项目/缓存库数量
- `libs [<regex>]`：按 `group:module version src|bin` 列出库
- `find <regex>`：按类名找类，输出 `lib!全限定名`
- `grep <regex>`：查找正文，按文件分组
- `show <类|lib!entry>`：打印单个类（默认前 600 行）
- `list [<前缀>]`：无前缀时列包，有前缀时列该包下的类

`lib!entry` 指 `group:module:version!path`。`find`/`list` 的结果可以直接传给 `show`；`grep` 则取 `==` 文件头里的 `lib!path` 部分。

### 通用参数

- `-Lib <regex>`：按 `group:module:version` 收窄库（如 `guava`、`com.google`、`net.neoforged`）。
- `-Path <包前缀>`：只搜某个包（`net/minecraft/world` 或 `world/level/block`）。
- `-Context N`：grep 时带前后 N 行。
- `-Max N` / `-All`：限制/取消上限。默认：`libs` 500，`find`/`grep`/`list` 40。
- `-Lines 40-80` / `-Full`：show 的行范围 / 不截断。
- `-CaseSensitive`：区分大小写。
- `-UseTar`：强制使用 tar 回退（只读沙箱会自动启用）。
- `-Global`：改用整个 Gradle 模块缓存，而不是项目模型。
- `-Cache <files-2.1 目录>`：从指定模块缓存做用户级检索（隐含 `-Global`）。
- `-IdeModel <libraries.xml>`：显式指定 IntelliJ 模型。
- `-ProjectRoot <目录>`：指定项目根。
- `-GradleHome <目录>`：覆盖 Gradle 用户目录。

### 输出

`grep` —— 按文件分组，路径在文件头，`:` 是命中行，`-` 是上下文行：

`src` 表示有源码包；`bin` 表示只有二进制 jar。源码命令会跳过 `bin` 库。

## 使用规则

1. **先窄后宽。** 先 `-Lib` 和/或 `-Path` 收窄，再 grep；一个项目可能有几十个源码包。
2. **结果直接传给 `show`。** `find`/`list` 的输出可直接用；`grep` 取 `==` 文件头里的 `lib!path` 部分。
3. **同名类。** 多个库里有同名类时，`show` 会列出候选并非零退出；加 `-Lib` 或用完整的 `lib!entry`。
4. **`show` 默认截断到 600 行**；用 `-Lines` 或 `-Full`。
5. **没有源码包。** `bin` 库需要在 IDE 里开启源码下载（`downloadSources = true`）并重新同步，或用 `-Global` 看本机缓存。
6. **项目级 vs 用户级。** 默认是项目级；`-Global` 可能混入其他项目的库，用 `-Lib` 收窄。
7. **只读沙箱。** `.NET` 不可用时脚本退回 `tar`；此时某 jar 条目很多时 `grep` 必须带 `-Path`。
8. **引用格式**：`group:module:version!path:line`，例如 `com.google.guava:guava:33.6.0-jre!com/google/common/collect/ImmutableList.java:65`。
9. **错误**以 `libsrc:` 开头；把消息原样转述，不要猜测库内容。

## 示例

- “这个项目用的哪个版本的 JEI？” → `libs jei`
- “Guava 的源码包在哪？” → `libs com.google.guava -SourcesOnly -Paths`
- “在 Guava 里找 ImmutableList” → `find ImmutableList -Lib guava`
- “ImmutableList 怎么声明的？” → `grep "class ImmutableList" -Lib guava -Path com/google/common/collect -Context 2`
- “打印这个类” → `show com.google.guava:guava:33.6.0-jre!com.google.common.collect.ImmutableList -Lines 1-80`
- “列出 Guava 的 collection 类” → `list com.google.common.collect -Lib guava -Max 20`
- “本机缓存了哪些库？” → `libs -Global`
