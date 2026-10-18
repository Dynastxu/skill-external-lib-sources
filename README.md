# skill-external-lib-sources

List and read Java sources for external libraries, scoped to the current project by default.

Environment requirement: any Gradle project imported into IntelliJ IDEA (best experience). The IDE/Gradle records dependency jars and source jars in the Gradle module cache (`~/.gradle/caches/modules-2/files-2.1`, or `$GRADLE_USER_HOME/caches/modules-2/files-2.1`).

Principle:

- **Project scope (default):** read the IntelliJ Gradle import model (`external_build_system/project/libraries.xml`), the same model behind the IDE's External Libraries tree.
- **Cache scope (`-Global`):** scan the machine-wide Gradle module cache.
- Source jars are read as zip streams; `tar` is the read-only fallback. Gradle is not invoked and nothing is extracted.

## Commands Examples

```powershell
pwsh -NoProfile -File scripts/libsrc.ps1 info
pwsh -NoProfile -File scripts/libsrc.ps1 libs jei -SourcesOnly -Paths
pwsh -NoProfile -File scripts/libsrc.ps1 find ImmutableList -Lib guava
pwsh -NoProfile -File scripts/libsrc.ps1 grep "class ImmutableList" -Lib guava -Path com/google/common/collect -Context 2
pwsh -NoProfile -File scripts/libsrc.ps1 show com.google.guava:guava:33.6.0-jre!com.google.common.collect.ImmutableList -Lines 1-80
pwsh -NoProfile -File scripts/libsrc.ps1 list com.google.common.collect -Lib guava -Max 20
pwsh -NoProfile -File scripts/libsrc.ps1 libs -Global -SourcesOnly
```

Results use `lib!path` form so `find`/`list` output and `grep` file headers can be passed directly to `show`.
