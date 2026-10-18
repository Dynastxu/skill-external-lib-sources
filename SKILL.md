---
name: external-lib-sources
description: List and read Java sources for external Gradle libraries (JEI, GeckoLib, Guava, Netty, ...). Project-scoped by default through the IntelliJ Gradle model (the same list as the IDE's External Libraries); -Global scans the whole Gradle module cache. Supports find/grep/show/list, reads jars as streams, and never invokes Gradle or extracts jars.
---

# External Library Source Search

Environment: any Gradle project, preferably imported into IntelliJ IDEA. The IDE/Gradle records dependency jars and source jars in the Gradle module cache (`~/.gradle/caches/modules-2/files-2.1`, or `$GRADLE_USER_HOME/caches/modules-2/files-2.1`). The script reads those paths directly; it never invokes Gradle and never extracts jars.

## Scope

- **Default: project scope.** The script reads IntelliJ's Gradle import model (`<system>/projects/<name>.<hash>/external_build_system/project/libraries.xml`), the same model behind the IDE's **External Libraries** tree. It contains the project's resolved dependencies, including transitive ones, and their source roots.
- **`-Global`: cache-wide.** Lists every library with a jar in the machine-wide Gradle module cache. It is a superset and may contain libraries from other projects.
- If no IntelliJ model is found, the script falls back to the cache-wide list and prints a note.

The model is a snapshot. After changing `build.gradle` or dependencies, re-sync the Gradle project in IntelliJ.

## Commands

Run from the project directory (the script finds the nearest `.git` + Gradle project root):

```powershell
pwsh -NoProfile -File path/to/scripts/libsrc.ps1 <command> [arguments]
```

- `info`: project root, IDE model path, project/cache library counts
- `libs [<regex>]`: list libraries as `group:module version src|bin`
- `find <regex>`: find classes; output `lib!fully.qualified.Name`
- `grep <regex>`: search source text, grouped per file
- `show <class|lib!entry>`: print one class (default: first 600 lines)
- `list [<prefix>]`: list packages (no prefix) or classes under a package

`lib!entry` means `group:module:version!path`. Results from `find`/`list` can be passed straight to `show`; for `grep`, use the `lib!path` token from the `==` header.

### Common parameters

- `-Lib <regex>`: narrow to libraries by `group:module:version` (e.g. `guava`, `com.google`, `net.neoforged`).
- `-Path <package-prefix>`: narrow to a package (`net/minecraft/world` or `world/level/block`).
- `-Context N`: include N lines before/after a grep hit.
- `-Max N` / `-All`: cap/remove cap. Defaults: 500 for `libs`, 40 for `find`/`grep`/`list`.
- `-Lines 40-80` / `-Full`: line range for `show` / do not truncate.
- `-CaseSensitive`: case-sensitive matching.
- `-UseTar`: force the tar fallback (automatic in a read-only sandbox).
- `-Global`: use the whole Gradle module cache instead of the project model.
- `-Cache <files-2.1 dir>`: cache-wide from a specific module cache (implies `-Global`).
- `-IdeModel <libraries.xml>`: use an explicit IntelliJ model.
- `-ProjectRoot <dir>`: project root to look up.
- `-GradleHome <dir>`: override the Gradle user home.

### Output

`libs` (project scope):

```
# scope : project (IntelliJ Gradle model)
# model : C:\Users\...\libraries.xml
# 86 libraries (84 with sources)
com.google.guava:guava  33.6.0-jre  src
...
```

`find`:

```
# scope: project (IntelliJ model); 1 of 86 libraries, 1 with sources
com.google.guava:guava:33.6.0-jre!com.google.common.collect.ImmutableList
```

`grep` — grouped by file, path in the header, `:` marks a hit, `-` a context line:

```
# scope: project (IntelliJ model); 1 of 86 libraries, 1 with sources
== com.google.guava:guava:33.6.0-jre!com/google/common/collect/ImmutableList.java (1 match)
64- @SuppressWarnings("serial")
65: public abstract class ImmutableList<E> extends ImmutableCollection<E>
66-     implements List<E>, RandomAccess {
```

`show`:

```
# com.google.guava:guava:33.6.0-jre!com/google/common/collect/ImmutableList.java  (951 lines)
    1: /*
    2:  * Copyright (C) 2007 The Guava Authors
...
```

`src` means a source jar is available; `bin` means only binary jars are available. Binary-only libraries are skipped by source commands.

## Usage Rules

1. **Narrow first, then broad.** Use `-Lib` and/or `-Path` before grepping; a project can have dozens of source jars.
2. **Pass results to `show`.** `find`/`list` output is ready to pass; for `grep`, take the `lib!path` token from the `==` header.
3. **Ambiguous classes.** If the same class name exists in several libraries, `show` lists candidates and exits non-zero. Add `-Lib` or use the full `lib!entry`.
4. **`show` truncates to 600 lines** by default; use `-Lines` or `-Full`.
5. **No source jar.** If a library is `bin`, enable source download in the IDE (`downloadSources = true`) and re-sync, or check the machine-wide cache with `-Global`.
6. **Project vs cache.** Default results are project-scoped. `-Global` may include unrelated libraries from other projects; filter it with `-Lib`.
7. **Read-only sandbox.** `.NET` is unavailable; the script falls back to `tar`. In that mode `grep` requires `-Path` when a jar has many entries.
8. **Cite** `group:module:version!path:line`, for example `com.google.guava:guava:33.6.0-jre!com/google/common/collect/ImmutableList.java:65`.
9. **Errors** start with `libsrc:`; relay them verbatim and do not guess library contents.

## Examples

- "Which JEI version does this project use?" → `libs jei`
- "Where is Guava's source jar?" → `libs com.google.guava -SourcesOnly -Paths`
- "Find ImmutableList in Guava" → `find ImmutableList -Lib guava`
- "How is ImmutableList declared?" → `grep "class ImmutableList" -Lib guava -Path com/google/common/collect -Context 2`
- "Print the class" → `show com.google.guava:guava:33.6.0-jre!com.google.common.collect.ImmutableList -Lines 1-80`
- "List Guava collection classes" → `list com.google.common.collect -Lib guava -Max 20`
- "Show every cached library on this machine" → `libs -Global`

For Minecraft and NeoForge's own sources, use the `mc-sources` skill instead.
