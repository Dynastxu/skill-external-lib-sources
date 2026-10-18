#requires -Version 7.0
<#
.SYNOPSIS
    List Java sources for external Gradle libraries.

.DESCRIPTION
    Read-only helper for the external-lib-sources skill. By default the project
    scope is read from the IntelliJ Gradle import model, which is the same model
    behind the IDE's "External Libraries" tree. -Global switches to a scan of
    the machine-wide Gradle module cache.

    Gradle is not invoked and no jar is extracted. Source jars are read as zip
    streams; in a read-only sandbox the script falls back to tar.

.EXAMPLE
    pwsh libsrc.ps1 info

.EXAMPLE
    pwsh libsrc.ps1 libs jei -SourcesOnly -Paths

.EXAMPLE
    pwsh libsrc.ps1 grep "class TntBlock" -Lib minecraft -Path net/minecraft

.EXAMPLE
    pwsh libsrc.ps1 show com.google.guava:guava:33.6.0-jre!com.google.common.collect.ImmutableList -Lines 1-80
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('info', 'libs', 'find', 'grep', 'show', 'list', 'help')]
    [string]$Command = 'help',

    [Parameter(Position = 1)]
    [string]$Query,

    [Alias('Package')]
    [string]$Path,
    [string]$Lib,
    [int]$Context = 0,
    [string]$Lines,
    [ValidateRange(0, 2147483647)]
    [int]$Max = 0,
    [switch]$All,
    [switch]$Full,
    [switch]$UseTar,
    [switch]$CaseSensitive,
    [switch]$SourcesOnly,
    [switch]$Paths,
    [string]$Cache,
    [string]$GradleHome,
    [string]$ProjectRoot,
    [string]$IdeModel,
    [switch]$Global
)

$ErrorActionPreference = 'Stop'

$script:UseTarMode = [bool]$UseTar
if (-not $script:UseTarMode -and $ExecutionContext.SessionState.LanguageMode -eq 'ConstrainedLanguage') {
    $script:UseTarMode = $true
}

try { [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false) } catch { }

function Get-HomeDir {
    if ($env:USERPROFILE) { return $env:USERPROFILE }
    if ($env:HOME) { return $env:HOME }
    return '.'
}

function Get-LeafName([string]$Path) {
    if (-not $Path) { return '' }
    return ($Path -split '[\\/]')[-1]
}

# A Gradle project root needs both a .git marker and a Gradle marker. The skill
# itself is often installed as a git submodule under .agents/skills, so a bare
# .git check would stop at the skill directory instead of the game project.
function Test-ProjectRoot([string]$Dir) {
    if (-not (Test-Path -LiteralPath (Join-Path $Dir '.git'))) { return $false }
    foreach ($marker in @('settings.gradle', 'settings.gradle.kts', 'gradle.properties')) {
        if (Test-Path -LiteralPath (Join-Path $Dir $marker)) { return $true }
    }
    return $false
}

function Find-ProjectRootUp([string]$Start) {
    $dir = $Start
    while ($dir) {
        if (Test-ProjectRoot $dir) { return $dir }
        $parent = Split-Path -Path $dir -Parent
        if (-not $parent -or $parent -eq $dir) { break }
        $dir = $parent
    }
    return $null
}

function Get-ProjectRoot {
    if ($script:ProjectRootPath) { return $script:ProjectRootPath }
    if ($ProjectRoot) {
        if (-not (Test-Path -LiteralPath $ProjectRoot)) { throw "-ProjectRoot not found: $ProjectRoot" }
        $script:ProjectRootPath = (Resolve-Path -LiteralPath $ProjectRoot).Path
        return $script:ProjectRootPath
    }
    $hit = Find-ProjectRootUp $PSScriptRoot
    if (-not $hit) { $hit = Find-ProjectRootUp (Get-Location).Path }
    if ($hit) {
        $script:ProjectRootPath = $hit
        return $hit
    }
    $script:ProjectRootPath = (Get-Location).Path
    return $script:ProjectRootPath
}

function Get-GradleHome {
    $candidate = $null
    if ($GradleHome) { $candidate = $GradleHome }
    elseif ($env:GRADLE_USER_HOME) { $candidate = $env:GRADLE_USER_HOME }
    else { $candidate = Join-Path (Get-HomeDir) '.gradle' }

    if (-not (Test-Path -LiteralPath $candidate)) {
        throw "Gradle home not found: $candidate"
    }
    return (Resolve-Path -LiteralPath $candidate).Path
}

# -Cache points straight at the module cache, which makes the script usable
# without a Gradle home (tests, other caches, an exported cache snapshot).
function Resolve-CacheRoot {
    if ($script:CacheRoot) { return $script:CacheRoot }

    if ($Cache) {
        if (-not (Test-Path -LiteralPath $Cache)) { throw "-Cache not found: $Cache" }
        $script:CacheRoot = (Resolve-Path -LiteralPath $Cache).Path -replace '[\\/]+$', ''
        return $script:CacheRoot
    }

    $root = Join-Path (Get-GradleHome) 'caches/modules-2/files-2.1'
    if (-not (Test-Path -LiteralPath $root)) {
        throw "Gradle module cache not found at $root; run a Gradle build or IDE sync once so sources are downloaded."
    }
    $script:CacheRoot = (Resolve-Path -LiteralPath $root).Path -replace '[\\/]+$', ''
    return $script:CacheRoot
}

function ConvertTo-RelativeParts([string]$FullName, [string]$Root) {
    $rel = $FullName.Substring($Root.Length)
    $rel = $rel -replace '^[\\/]+', ''
    return @($rel -split '[\\/]')
}

# The cache layout is <group>/<module>/<version>/<hash>/<artifact>. Walking
# every jar once is cheap (hundreds of files) and gives us binary-only
# libraries as well as source-backed ones.
function Get-CachedLibraries([string]$Root) {
    $map = @{}
    $jars = @(Get-ChildItem -LiteralPath $Root -Recurse -File -Filter '*.jar' -ErrorAction SilentlyContinue)

    foreach ($file in $jars) {
        $parts = ConvertTo-RelativeParts $file.FullName $Root
        if ($parts.Count -lt 5) { continue }

        $group = $parts[0]
        $module = $parts[1]
        $version = $parts[2]
        $key = $group + ':' + $module + ':' + $version

        $rec = $map[$key]
        if (-not $rec) {
            $rec = @{
                Group   = $group
                Module  = $module
                Version = $version
                Sources = $null
                Binary  = $null
            }
            $map[$key] = $rec
        }

        $leaf = $file.Name
        if ($leaf -match '(?i)-javadoc\.jar$') { continue }
        if ($leaf -match '(?i)-sources\.jar$') {
            $preferred = $module + '-' + $version + '-sources.jar'
            if (-not $rec.Sources -or $leaf -eq $preferred) { $rec.Sources = $file.FullName }
            continue
        }
        if ($leaf -match '(?i)-natives-') { continue }

        $main = $module + '-' + $version + '.jar'
        if (-not $rec.Binary -or $leaf -eq $main) { $rec.Binary = $file.FullName }
    }

    return @($map.Values | Where-Object { $_.Sources -or $_.Binary })
}

function Get-JetBrainsCacheRoots {
    $roots = @()
    if ($env:LOCALAPPDATA) { $roots += Join-Path $env:LOCALAPPDATA 'JetBrains' }
    if ($env:APPDATA) { $roots += Join-Path $env:APPDATA 'JetBrains' }
    if ($env:XDG_CACHE_HOME) { $roots += Join-Path $env:XDG_CACHE_HOME 'JetBrains' }
    if ($env:HOME) {
        $roots += Join-Path $env:HOME '.cache/JetBrains'
        $roots += Join-Path $env:HOME 'Library/Caches/JetBrains'
    }

    $existing = @()
    foreach ($root in $roots) {
        if ((Test-Path -LiteralPath $root) -and ($existing -notcontains $root)) {
            $existing += $root
        }
    }
    return $existing
}

# IntelliJ keeps the Gradle import model (the same model behind its
# "External Libraries" tree) under its system directory, not under .idea:
#   <system>/projects/<name>.<hash>/external_build_system/project/libraries.xml
# The hash is not predictable, so match the project path in cache-state.xml
# and fall back to the project-name prefix.
function Find-IdeLibraryModel {
    if ($script:IdeModelPath) { return $script:IdeModelPath }

    if ($IdeModel) {
        if (-not (Test-Path -LiteralPath $IdeModel)) { throw "-IdeModel not found: $IdeModel" }
        $script:IdeModelPath = (Resolve-Path -LiteralPath $IdeModel).Path
        return $script:IdeModelPath
    }

    $projectRoot = Get-ProjectRoot
    $normalized = ($projectRoot -replace '\\', '/').ToLowerInvariant()
    $projectName = Split-Path -Leaf $projectRoot
    $candidates = @()

    foreach ($cacheRoot in Get-JetBrainsCacheRoots) {
        foreach ($product in Get-ChildItem -LiteralPath $cacheRoot -Directory -ErrorAction SilentlyContinue) {
            $projectsDir = Join-Path $product.FullName 'projects'
            if (-not (Test-Path -LiteralPath $projectsDir)) { continue }

            foreach ($dir in Get-ChildItem -LiteralPath $projectsDir -Directory -ErrorAction SilentlyContinue) {
                $model = Join-Path $dir.FullName 'external_build_system/project/libraries.xml'
                if (-not (Test-Path -LiteralPath $model)) { continue }

                $matched = $false
                $state = Join-Path $dir.FullName 'cache-state.xml'
                if (Test-Path -LiteralPath $state) {
                    $text = Get-Content -LiteralPath $state -Raw -ErrorAction SilentlyContinue
                    if ($text -and $text.ToLowerInvariant().IndexOf($normalized) -ge 0) {
                        $matched = $true
                    }
                }
                if (-not $matched -and $projectName) {
                    $prefix = ($projectName + '.').ToLowerInvariant()
                    if ($dir.Name.ToLowerInvariant().StartsWith($prefix)) { $matched = $true }
                }

                if ($matched) {
                    $candidates += @{
                        Model    = $model
                        Modified = (Get-Item -LiteralPath $model).LastWriteTime
                    }
                }
            }
        }
    }

    if ($candidates.Count -eq 0) { return $null }
    $best = $candidates[0]
    foreach ($candidate in $candidates) {
        if ($candidate.Modified -gt $best.Modified) { $best = $candidate }
    }
    $script:IdeModelPath = $best.Model
    return $script:IdeModelPath
}

function ConvertFrom-IdeRootUrl([string]$Url, [string]$ProjectRoot) {
    if (-not $Url) { return $null }

    $path = $Url
    $lower = $path.ToLowerInvariant()
    if ($lower.StartsWith('jar://')) { $path = $path.Substring(6) }
    elseif ($lower.StartsWith('file://')) { $path = $path.Substring(7) }

    if ($path.EndsWith('!/')) { $path = $path.Substring(0, $path.Length - 2) }
    $path = $path -replace '&amp;', '&'
    $path = $path -replace '%20', ' '

    if ($path.StartsWith('$USER_HOME$')) {
        $path = (Get-HomeDir) + $path.Substring('$USER_HOME$'.Length)
    }
    elseif ($path.StartsWith('$PROJECT_DIR$')) {
        $path = $ProjectRoot + $path.Substring('$PROJECT_DIR$'.Length)
    }

    try { $path = [System.Uri]::UnescapeDataString($path) } catch { }
    if ($env:OS -eq 'Windows_NT') { $path = $path -replace '/', '\' }
    return $path
}

function Read-IdeLibraries([string]$ModelPath, [string]$ProjectRoot) {
    $xml = Get-Content -LiteralPath $ModelPath -Raw -ErrorAction SilentlyContinue
    if (-not $xml) { return @() }

    $blocks = [regex]::Matches($xml, '<library\s+name="([^"]+)"[^>]*>(.*?)</library>', [System.Text.RegularExpressions.RegexOptions]::Singleline)
    $map = @{}

    foreach ($block in $blocks) {
        $name = $block.Groups[1].Value
        $body = $block.Groups[2].Value

        $group = [regex]::Match($body, 'groupId="([^"]+)"').Groups[1].Value
        $module = [regex]::Match($body, 'artifactId="([^"]+)"').Groups[1].Value
        $version = [regex]::Match($body, 'version="([^"]+)"').Groups[1].Value

        if ((-not $group -or -not $module -or -not $version) -and $name.StartsWith('Gradle: ')) {
            $coords = $name.Substring(8).Split(':')
            if ($coords.Count -ge 3) {
                $group = $coords[0]
                $module = $coords[1]
                $version = $coords[$coords.Count - 1]
            }
        }
        if (-not $group -or -not $module -or -not $version) { continue }

        $key = $group + ':' + $module + ':' + $version
        $mainName = $module + '-' + $version + '.jar'
        $mainSources = $module + '-' + $version + '-sources.jar'

        $classesBlock = [regex]::Match($body, '<CLASSES\b[^>]*>(.*?)</CLASSES>', [System.Text.RegularExpressions.RegexOptions]::Singleline).Groups[1].Value
        $sourcesBlock = [regex]::Match($body, '<SOURCES\b[^>]*>(.*?)</SOURCES>', [System.Text.RegularExpressions.RegexOptions]::Singleline).Groups[1].Value

        $binary = $null
        foreach ($m in [regex]::Matches($classesBlock, '<root\s+url="([^"]+)"')) {
            $candidate = ConvertFrom-IdeRootUrl $m.Groups[1].Value $ProjectRoot
            if (-not $candidate -or $candidate -notmatch '(?i)\.jar$') { continue }
            if (-not $binary -or (Get-LeafName $candidate) -eq $mainName) { $binary = $candidate }
        }

        $sources = $null
        foreach ($m in [regex]::Matches($sourcesBlock, '<root\s+url="([^"]+)"')) {
            $candidate = ConvertFrom-IdeRootUrl $m.Groups[1].Value $ProjectRoot
            if (-not $candidate -or $candidate -notmatch '(?i)\.jar$') { continue }
            if (-not $sources -or (Get-LeafName $candidate) -eq $mainSources) { $sources = $candidate }
        }

        $rec = $map[$key]
        if (-not $rec) {
            $map[$key] = @{
                Group   = $group
                Module  = $module
                Version = $version
                Sources = $sources
                Binary  = $binary
            }
        }
        else {
            if ($sources) {
                if (-not $rec.Sources -or (Get-LeafName $sources) -eq $mainSources) { $rec.Sources = $sources }
            }
            if ($binary) {
                if (-not $rec.Binary -or (Get-LeafName $binary) -eq $mainName) { $rec.Binary = $binary }
            }
        }
    }

    return @($map.Values)
}

function Get-EntryNames([string]$JarPath) {
    if ($script:UseTarMode) {
        $names = & tar -tf $JarPath
        if ($LASTEXITCODE -ne 0) { throw "tar failed to list $JarPath" }
        return @($names | Where-Object { $_ -and -not $_.EndsWith('/') })
    }
    $zip = [System.IO.Compression.ZipFile]::OpenRead($JarPath)
    try {
        return @($zip.Entries | ForEach-Object { $_.FullName })
    }
    finally { $zip.Dispose() }
}

function Read-EntryText([string]$JarPath, [string]$Name) {
    if ($script:UseTarMode) {
        $raw = & tar -xOf $JarPath $Name
        if ($LASTEXITCODE -ne 0) { throw "tar failed to read $Name" }
        return ($raw -join "`n")
    }
    $zip = [System.IO.Compression.ZipFile]::OpenRead($JarPath)
    try {
        $entry = $zip.GetEntry($Name)
        if (-not $entry) { throw "entry not found: $Name" }
        $reader = [System.IO.StreamReader]::new($entry.Open(), [System.Text.UTF8Encoding]::new($false), $true)
        try { return $reader.ReadToEnd() } finally { $reader.Dispose() }
    }
    finally { $zip.Dispose() }
}

function ConvertTo-Lines([string]$Text) {
    if ([string]::IsNullOrEmpty($Text)) { return @() }
    $lines = @($Text -split "`r?`n")
    if ($lines.Count -gt 0 -and $lines[$lines.Count - 1] -eq '') {
        if ($lines.Count -eq 1) { return @() }
        $lines = @($lines[0..($lines.Count - 2)])
    }
    Write-Output -NoEnumerate $lines
}

function ConvertTo-Prefix([string]$Value) {
    if (-not $Value -or $Value.Trim().Length -eq 0) { return $null }
    $p = $Value -replace '\\', '/'
    $p = $p.Trim('/')
    if ($p -notmatch '/' -and $p -match '\.' -and -not $p.EndsWith('.java')) {
        $p = $p -replace '\.', '/'
    }
    if (-not $p.EndsWith('/') -and -not $p.EndsWith('.java')) { $p += '/' }
    return $p
}

function Test-Prefix([string]$Name, [string]$Prefix) {
    if (-not $Prefix) { return $true }
    $lowerName = $Name.ToLowerInvariant()
    $lowerPrefix = $Prefix.ToLowerInvariant()
    if ($lowerName.StartsWith($lowerPrefix)) { return $true }
    return $lowerName.IndexOf('/' + $lowerPrefix) -ge 0
}

function Find-Matches([string]$Text, [string]$Pattern, [int]$Limit = 2147483647) {
    $textLines = ConvertTo-Lines $Text
    $hits = @()
    for ($i = 0; $i -lt $textLines.Count; $i++) {
        $hit = if ($CaseSensitive) { $textLines[$i] -cmatch $Pattern } else { $textLines[$i] -match $Pattern }
        if (-not $hit) { continue }
        $hits += $i
        if (-not $All -and $hits.Count -ge $Limit) { break }
    }
    return @{
        Lines = $textLines
        Hits  = $hits
    }
}

# Prints one file's hits once with the path in a header, so long paths are not
# repeated on every line. Output shape (':' marks a hit, '-' a context line):
#
#   == lib!net/foo/Bar.java (2 matches)
#    565:     public void bar(...)
#    566:         this.bar(
#    567-             source,
function Format-MatchGroup([string]$Name, [string[]]$TextLines, $Hits, [int]$ContextLines) {
    if ($Hits.Count -eq 0) { return @() }

    $hitSet = @{}
    foreach ($i in $Hits) { $hitSet[$i] = $true }

    $ranges = @()
    foreach ($i in $Hits) {
        $from = $i - $ContextLines
        if ($from -lt 0) { $from = 0 }
        $to = $i + $ContextLines
        if ($to -ge $TextLines.Count) { $to = $TextLines.Count - 1 }
        if ($ranges.Count -gt 0) {
            $last = $ranges[$ranges.Count - 1]
            if ($from -le ($last.To + 1)) {
                if ($to -gt $last.To) { $last.To = $to }
                continue
            }
        }
        $range = @{}
        $range.From = $from
        $range.To = $to
        $ranges += $range
    }

    $width = ([string]($ranges[$ranges.Count - 1].To + 1)).Length
    $out = @()
    $label = if ($Hits.Count -eq 1) { '1 match' } else { "$($Hits.Count) matches" }
    $out += "== $Name ($label)"
    for ($r = 0; $r -lt $ranges.Count; $r++) {
        if ($r -gt 0 -and $ContextLines -gt 0) { $out += '   ...' }
        $range = $ranges[$r]
        for ($j = $range.From; $j -le $range.To; $j++) {
            $sep = if ($hitSet.ContainsKey($j)) { ':' } else { '-' }
            $out += ("{0,$width}{1} {2}" -f ($j + 1), $sep, $TextLines[$j])
        }
    }
    return $out
}

function Get-LibraryId($Library) {
    return $Library.Group + ':' + $Library.Module + ':' + $Library.Version
}

function Get-ExactEntries([string[]]$Names, [string]$Value) {
    $norm = $Value.Trim() -replace '\\', '/'
    $candidates = @()
    if ($norm.EndsWith('.java')) { $candidates += $norm }
    elseif ($norm -match '/') { $candidates += ($norm + '.java') }
    elseif ($norm -match '\.') { $candidates += (($norm -replace '\.', '/') + '.java') }

    $hits = @()
    foreach ($candidate in $candidates) {
        foreach ($name in $Names) {
            if ($name -ieq $candidate) { $hits += $name; break }
        }
    }
    return @($hits | Select-Object -Unique)
}

function Get-LeafEntries([string[]]$Names, [string]$Value) {
    $norm = $Value.Trim() -replace '\\', '/'
    if ($norm -match '/') { $leaf = Get-LeafName $norm }
    elseif ($norm -match '\.') { $leaf = ($norm -split '\.')[-1] }
    else { $leaf = $norm }
    $leaf = $leaf -replace '\.java$', ''

    return @($Names | Where-Object {
            $_.EndsWith('.java') -and ((Get-LeafName $_) -replace '\.java$', '') -ieq $leaf
        })
}

function Select-ScopeLibraries($Libraries, [string]$LibQuery) {
    if (-not $LibQuery -or $LibQuery.Trim().Length -eq 0) { return @($Libraries) }
    $pattern = Get-Pattern $LibQuery
    return @($Libraries | Where-Object {
            $id = Get-LibraryId $_
            if ($CaseSensitive) { $id -cmatch $pattern } else { $id -match $pattern }
        })
}

function Write-ScopeHeader($ScopeInfo, [int]$SelectedCount, [int]$SourceCount) {
    if ($ScopeInfo.Scope -eq 'project') {
        Write-Output ("# scope: project (IntelliJ model); {0} of {1} libraries, {2} with sources" -f $SelectedCount, $ScopeInfo.Libraries.Count, $SourceCount)
    }
    else {
        Write-Output ("# scope: cache-wide; {0} of {1} libraries, {2} with sources" -f $SelectedCount, $ScopeInfo.Libraries.Count, $SourceCount)
        if ($ScopeInfo.FallbackNote) { Write-Output ("# note : " + $ScopeInfo.FallbackNote) }
    }
}

function Get-Pattern([string]$Value) {
    if (-not $Value -or $Value.Trim().Length -eq 0) { return $null }
    if ($CaseSensitive) { return $Value }
    return '(?i)' + $Value
}

function Invoke-Info {
    $root = Get-ProjectRoot
    $model = $null
    try { $model = Find-IdeLibraryModel } catch { }

    Write-Output ("project    : " + $root)
    if ($model) {
        $projectLibs = @(Read-IdeLibraries $model $root)
        $projectSources = @($projectLibs | Where-Object { $_.Sources }).Count
        Write-Output ("model      : " + $model)
        Write-Output ("libraries  : {0} ({1} with sources)" -f $projectLibs.Count, $projectSources)
    }
    else {
        Write-Output "model      : not found (run an IntelliJ Gradle sync for project scope)"
    }

    try {
        $cacheRoot = Resolve-CacheRoot
        $cacheLibs = @(Get-CachedLibraries $cacheRoot)
        $cacheSources = @($cacheLibs | Where-Object { $_.Sources }).Count
        Write-Output ("cache      : {0} ({1} libraries, {2} with sources)" -f $cacheRoot, $cacheLibs.Count, $cacheSources)
    }
    catch {
        Write-Output ("cache      : not found (" + $_.Exception.Message + ")")
    }

    Write-Output "mode       : project scope by default; use `libs -Global` for the whole cache"
}

function Get-ScopeLibraries {
    if ($Global -and $IdeModel) { throw '-Global and -IdeModel cannot be used together' }
    if ($Cache -and $IdeModel) { throw '-Cache and -IdeModel cannot be used together' }

    $scope = 'project'
    $sourceLabel = $null
    $libraries = $null
    $fallbackNote = $null

    if (-not $Global -and -not $Cache) {
        $model = Find-IdeLibraryModel
        if ($model) {
            $sourceLabel = $model
            $libraries = @(Read-IdeLibraries $model (Get-ProjectRoot))
            if ($libraries.Count -eq 0) {
                $fallbackNote = "the IntelliJ model has no libraries ($model)"
                $libraries = $null
            }
        }
        else {
            $fallbackNote = 'no IntelliJ Gradle model found for this project'
        }
    }

    if (-not $libraries) {
        $scope = 'cache'
        $sourceLabel = Resolve-CacheRoot
        $libraries = @(Get-CachedLibraries $sourceLabel)
    }

    return @{
        Scope        = $scope
        Source       = $sourceLabel
        Libraries    = $libraries
        FallbackNote = $fallbackNote
    }
}

function Invoke-Libs {
    $scopeInfo = Get-ScopeLibraries
    $libraries = $scopeInfo.Libraries
    $pattern = Get-Pattern $Query

    $selected = @($libraries | Where-Object {
            if ($SourcesOnly -and -not $_.Sources) { return $false }
            if ($pattern) {
                $id = Get-LibraryId $_
                $matched = if ($CaseSensitive) { $id -cmatch $pattern } else { $id -match $pattern }
                if (-not $matched) { return $false }
            }
            return $true
        })

    if ($selected.Count -eq 0) {
        if ($pattern) { Write-Output ("# no library matching '" + $Query + "'") }
        elseif ($scopeInfo.Scope -eq 'cache') { Write-Output ("# no cached libraries in " + $scopeInfo.Source) }
        else { Write-Output ("# no libraries in " + $scopeInfo.Source) }
        return
    }

    if ($scopeInfo.Scope -eq 'project') {
        Write-Output "# scope : project (IntelliJ Gradle model)"
        Write-Output ("# model : " + $scopeInfo.Source)
    }
    else {
        Write-Output "# scope : cache-wide (machine-wide)"
        Write-Output ("# cache : " + $scopeInfo.Source)
        if ($scopeInfo.FallbackNote) {
            Write-Output ("# note  : " + $scopeInfo.FallbackNote + "; showing cache-wide")
        }
    }

    $withSources = @($selected | Where-Object { $_.Sources }).Count
    if ($pattern) {
        Write-Output ("# {0} libraries matching '{1}' ({2} with sources)" -f $selected.Count, $Query, $withSources)
    }
    else {
        Write-Output ("# {0} libraries ({1} with sources)" -f $selected.Count, $withSources)
    }

    $limit = if ($Max -gt 0) { $Max } else { 500 }
    $byId = @{}
    foreach ($lib in $selected) { $byId[(Get-LibraryId $lib)] = $lib }
    $ids = @($byId.Keys) | Sort-Object
    $capped = $false
    if (-not $All -and $ids.Count -gt $limit) {
        $ids = @($ids[0..($limit - 1)])
        $capped = $true
    }
    $shown = @($ids | ForEach-Object { $byId[$_] })

    $idWidth = 20
    $verWidth = 10
    foreach ($lib in $shown) {
        $id = $lib.Group + ':' + $lib.Module
        if ($id.Length -gt $idWidth -and $id.Length -le 72) { $idWidth = $id.Length }
        if ($lib.Version.Length -gt $verWidth -and $lib.Version.Length -le 24) { $verWidth = $lib.Version.Length }
    }

    foreach ($lib in $shown) {
        $id = $lib.Group + ':' + $lib.Module
        if ($id.Length -lt $idWidth) { $id = $id + (' ' * ($idWidth - $id.Length)) }

        $ver = $lib.Version
        if ($ver.Length -lt $verWidth) { $ver = $ver + (' ' * ($verWidth - $ver.Length)) }

        $mark = if ($lib.Sources) { 'src' } else { 'bin' }
        Write-Output ($id + '  ' + $ver + '  ' + $mark)

        if ($Paths) {
            if ($lib.Sources) { Write-Output ('    sources: ' + $lib.Sources) }
            if ($lib.Binary) { Write-Output ('    jar    : ' + $lib.Binary) }
        }
    }

    if ($capped) {
        Write-Output ("# capped at {0}; use -All for all {1}" -f $limit, $selected.Count)
    }
}

function Get-SourceLibraries($ScopeInfo, [string]$LibQuery) {
    $selected = @(Select-ScopeLibraries $ScopeInfo.Libraries $LibQuery)
    if ($selected.Count -eq 0) {
        if ($LibQuery) { throw "no library matching '$LibQuery'" }
        throw 'no libraries in scope'
    }

    $sources = @($selected | Where-Object { $_.Sources })
    if ($sources.Count -eq 0) {
        throw 'no source jars in scope; enable source download in the IDE/Gradle, or use -Global'
    }

    return @{
        Selected = $selected
        Sources  = $sources
    }
}

function Invoke-Find {
    $pattern = Get-Pattern $Query
    $prefix = ConvertTo-Prefix $Path
    $scopeInfo = Get-ScopeLibraries
    $selection = Get-SourceLibraries $scopeInfo $Lib
    $limit = if ($Max -gt 0) { $Max } else { 40 }

    Write-ScopeHeader $scopeInfo $selection.Selected.Count $selection.Sources.Count
    $found = @()
    $seen = @{}
    $byPath = $Query -match '[./]'

    foreach ($lib in $selection.Sources) {
        $id = Get-LibraryId $lib
        $names = Get-EntryNames $lib.Sources
        foreach ($name in $names) {
            if (-not $name.EndsWith('.java')) { continue }
            if (-not (Test-Prefix $name $prefix)) { continue }

            $fqcn = $name.Substring(0, $name.Length - 5) -replace '/', '.'
            $leaf = (Get-LeafName $name) -replace '\.java$', ''
            $haystack = if ($byPath) { $fqcn } else { $leaf }
            $matched = if ($CaseSensitive) { $haystack -cmatch $pattern } else { $haystack -match $pattern }
            if (-not $matched) { continue }

            $display = $id + '!' + $fqcn
            if (-not $seen.ContainsKey($display)) {
                $seen[$display] = $true
                $found += $display
            }
            if (-not $All -and $found.Count -ge $limit) { break }
        }
        if (-not $All -and $found.Count -ge $limit) { break }
    }

    if ($found.Count -eq 0) {
        Write-Output ("# no class matching '" + $Query + "'")
        return
    }
    $found | Sort-Object
    if (-not $All -and $found.Count -ge $limit) {
        Write-Output ("# capped at $limit results; use -All for everything")
    }
}

function Invoke-Grep {
    $pattern = Get-Pattern $Query
    $prefix = ConvertTo-Prefix $Path
    $scopeInfo = Get-ScopeLibraries
    $selection = Get-SourceLibraries $scopeInfo $Lib
    $limit = if ($Max -gt 0) { $Max } else { 40 }

    Write-ScopeHeader $scopeInfo $selection.Selected.Count $selection.Sources.Count
    $total = 0

    foreach ($lib in $selection.Sources) {
        $id = Get-LibraryId $lib

        if ($script:UseTarMode) {
            $names = @(Get-EntryNames $lib.Sources | Where-Object {
                    $_.EndsWith('.java') -and (Test-Prefix $_ $prefix)
                })
            if (-not $prefix -and $names.Count -gt 400) {
                throw "read-only fallback would read $($names.Count) entries through tar; pass -Path to narrow the search"
            }
            foreach ($name in $names) {
                $text = Read-EntryText $lib.Sources $name
                $remaining = $limit - $total
                if ($remaining -lt 1) { $remaining = 1 }
                $found = Find-Matches $text $pattern $remaining
                if ($found.Hits.Count -gt 0) {
                    Format-MatchGroup ($id + '!' + $name) $found.Lines $found.Hits $Context
                }
                $total += $found.Hits.Count
                if (-not $All -and $total -ge $limit) { break }
            }
        }
        else {
            $zip = [System.IO.Compression.ZipFile]::OpenRead($lib.Sources)
            try {
                foreach ($entry in $zip.Entries) {
                    if (-not $entry.FullName.EndsWith('.java')) { continue }
                    if (-not (Test-Prefix $entry.FullName $prefix)) { continue }

                    $reader = [System.IO.StreamReader]::new($entry.Open(), [System.Text.UTF8Encoding]::new($false), $true)
                    try { $text = $reader.ReadToEnd() } finally { $reader.Dispose() }

                    $remaining = $limit - $total
                    if ($remaining -lt 1) { $remaining = 1 }
                    $found = Find-Matches $text $pattern $remaining
                    if ($found.Hits.Count -gt 0) {
                        Format-MatchGroup ($id + '!' + $entry.FullName) $found.Lines $found.Hits $Context
                    }
                    $total += $found.Hits.Count
                    if (-not $All -and $total -ge $limit) { break }
                }
            }
            finally { $zip.Dispose() }
        }

        if (-not $All -and $total -ge $limit) { break }
    }

    if ($total -eq 0) {
        Write-Output ("# no match for '" + $Query + "'")
        return
    }
    if (-not $All -and $total -ge $limit) {
        Write-Output ("# capped at $limit matches; use -All or narrow with -Lib/-Path")
    }
}

function Resolve-SourceEntry($Selection, [string]$Value) {
    $libSpec = $null
    $entryQuery = $Value
    $bang = $Value.IndexOf('!')
    if ($bang -ge 0) {
        $libSpec = $Value.Substring(0, $bang)
        $entryQuery = $Value.Substring($bang + 1)
    }

    $libs = @($Selection.Sources)
    if ($libSpec) {
        $libs = @($libs | Where-Object { (Get-LibraryId $_) -ieq $libSpec })
        if ($libs.Count -eq 0) { throw "no source library '$libSpec' in scope" }
    }

    $exact = @()
    foreach ($lib in $libs) {
        $names = Get-EntryNames $lib.Sources
        foreach ($entry in @(Get-ExactEntries $names $entryQuery)) {
            $exact += @{ Library = $lib; Entry = $entry }
        }
    }
    if ($exact.Count -gt 0) { return $exact }

    $leaf = @()
    foreach ($lib in $libs) {
        $names = Get-EntryNames $lib.Sources
        foreach ($entry in @(Get-LeafEntries $names $entryQuery)) {
            $leaf += @{ Library = $lib; Entry = $entry }
        }
    }
    return $leaf
}

function Invoke-Show {
    if (-not $Query -or $Query.Trim().Length -eq 0) { throw 'missing class name' }

    $scopeInfo = Get-ScopeLibraries
    $selection = Get-SourceLibraries $scopeInfo $Lib
    $candidates = @(Resolve-SourceEntry $selection $Query)

    if ($candidates.Count -eq 0) { throw "no source entry matching '$Query'" }
    if ($candidates.Count -gt 1) {
        $sample = ($candidates | Select-Object -First 20 | ForEach-Object {
                '  ' + (Get-LibraryId $_.Library) + '!' + $_.Entry
            }) -join "`n"
        throw "ambiguous '$Query'; candidates:`n$sample"
    }

    $hit = $candidates[0]
    $id = Get-LibraryId $hit.Library
    $text = Read-EntryText $hit.Library.Sources $hit.Entry
    $textLines = ConvertTo-Lines $text

    $from = 1
    $to = $textLines.Count
    if ($Lines) {
        if ($Lines -match '^\s*(\d+)\s*-\s*(\d+)\s*$') {
            $from = [int]$Matches[1]
            $to = [int]$Matches[2]
        }
        elseif ($Lines -match '^\s*(\d+)\s*$') {
            $from = [int]$Matches[1]
            $to = $from + 79
            if ($to -gt $textLines.Count) { $to = $textLines.Count }
        }
        else { throw "bad -Lines '$Lines'; use '40' or '40-80'" }
    }
    elseif (-not $Full -and $textLines.Count -gt 600) {
        $to = 600
    }

    if ($from -lt 1) { $from = 1 }
    if ($to -gt $textLines.Count) { $to = $textLines.Count }
    if ($from -gt $to) { throw "-Lines range is outside 1..$($textLines.Count)" }

    Write-Output ("# {0}!{1}  ({2} lines)" -f $id, $hit.Entry, $textLines.Count)
    for ($i = $from; $i -le $to; $i++) {
        Write-Output ("{0,5}: {1}" -f $i, $textLines[$i - 1])
    }
    if ($to -lt $textLines.Count) {
        Write-Output ("# ... {0} more lines; use -Lines {1}-{2} or -Full" -f ($textLines.Count - $to), ($to + 1), $textLines.Count)
    }
}

function Invoke-List {
    $prefix = ConvertTo-Prefix $Query
    $scopeInfo = Get-ScopeLibraries
    $selection = Get-SourceLibraries $scopeInfo $Lib
    $limit = if ($Max -gt 0) { $Max } else { 40 }

    Write-ScopeHeader $scopeInfo $selection.Selected.Count $selection.Sources.Count

    if (-not $prefix) {
        $counts = @{}
        foreach ($lib in $selection.Sources) {
            foreach ($name in @(Get-EntryNames $lib.Sources)) {
                if (-not $name.EndsWith('.java')) { continue }
                $top = ($name -split '/')[0]
                if (-not $counts.ContainsKey($top)) { $counts[$top] = 0 }
                $counts[$top]++
            }
        }
        if ($counts.Count -eq 0) { Write-Output '# no java sources in scope'; return }
        $topNames = @($counts.Keys) | Sort-Object
        foreach ($topName in $topNames) {
            Write-Output ("{0}/ ({1} classes)" -f $topName, $counts[$topName])
        }
        return
    }

    $entries = @()
    foreach ($lib in $selection.Sources) {
        $id = Get-LibraryId $lib
        foreach ($name in @(Get-EntryNames $lib.Sources)) {
            if (-not $name.EndsWith('.java')) { continue }
            if (-not (Test-Prefix $name $prefix)) { continue }
            $fqcn = $name.Substring(0, $name.Length - 5) -replace '/', '.'
            $entries += $id + '!' + $fqcn
        }
    }

    if ($entries.Count -eq 0) {
        Write-Output ("# no java sources under '" + $prefix + "'")
        return
    }

    if ($All) {
        $entries | Sort-Object
    }
    else {
        $entries | Sort-Object | Select-Object -First $limit
        if ($entries.Count -gt $limit) {
            Write-Output ("# ... {0} more; raise -Max or use -All" -f ($entries.Count - $limit))
        }
    }
}

function Invoke-Help {
    Write-Output @'
libsrc - external library sources (read-only)

  info                         project model, library/source counts, cache
  libs [<regex>]               list libraries (group:module version src|bin)
       [-SourcesOnly]          only libraries with a cached -sources.jar
       [-Paths]                also print source / binary jar paths
       [-Max N] [-All]         result cap (default 500) / no cap
  find <regex>                 find classes; output lib!fully.qualified.Name
  grep <regex>                 search source text, grouped per file:
                               '== lib!path (N matches)' then 'NNN: hit'
       [-Context N] [-Max N] [-All] [-Path <prefix>] [-Lib <regex>]
  show <class|lib!entry>       print one class (default: first 600 lines)
       [-Lines 40-80] [-Full]
  list [<prefix>]              list packages / classes

Source commands default to a 40-result cap; use -Max/-All to change it.
-Lib narrows libraries by regex on group:module:version. -Path narrows by
package prefix (net/minecraft/world). Results use lib!path so they can be
passed straight to show.

Scope:
  Default                      project scope from the IntelliJ Gradle model
                               (the same libraries IDEA shows under External
                               Libraries, including transitive dependencies)
  -Global                      the whole Gradle module cache (machine-wide)
  -Cache <files-2.1 dir>       cache-wide from a specific module cache
  -IdeModel <libraries.xml>    use an explicit IntelliJ model
  -ProjectRoot <dir>           project root to look up

Global: -GradleHome <gradle user home>  -CaseSensitive  -UseTar

`src` means a source jar is available; `bin` means only binary jars are.
If no IntelliJ model is found, `libs` falls back to the cache-wide list.
The cache is machine-wide, so it can contain libraries from other projects;
filter with a regex, e.g. `libs jei` or `libs com.google`.

Examples:
  pwsh libsrc.ps1 info
  pwsh libsrc.ps1 libs jei -SourcesOnly -Paths
  pwsh libsrc.ps1 find ImmutableList -Lib guava
  pwsh libsrc.ps1 grep "class ImmutableList" -Lib guava -Path com/google/common/collect
  pwsh libsrc.ps1 show com.google.guava:guava:33.6.0-jre!com.google.common.collect.ImmutableList -Lines 1-80
  pwsh libsrc.ps1 list com.google.common.collect -Lib guava -Max 20
'@
}

# Tests dot-source this file to reach the helpers; skip the command dispatcher.
if ($env:LIBSRC_SOURCE_ONLY -eq '1') { return }

try {
    switch ($Command) {
        'info' { Invoke-Info }
        'libs' { Invoke-Libs }
        'find' { Invoke-Find }
        'grep' { Invoke-Grep }
        'show' { Invoke-Show }
        'list' { Invoke-List }
        default { Invoke-Help }
    }
}
catch {
    Write-Output ("libsrc: " + $_.Exception.Message)
    if ($env:LIBSRC_DEBUG) {
        Write-Output $_.InvocationInfo.PositionMessage
        Write-Output $_.ScriptStackTrace
    }
    exit 2
}
