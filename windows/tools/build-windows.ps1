param([string]$OutputDirectory, [string]$NpmCli)
$ErrorActionPreference = 'Stop'
$sourceRoot = Split-Path -Parent $PSScriptRoot
if (-not $OutputDirectory) { $OutputDirectory = Join-Path $sourceRoot 'dist' }
$OutputDirectory = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputDirectory)
$buildDirectory = Join-Path $env:LOCALAPPDATA ('CodexPulseBuild/' + [guid]::NewGuid().ToString('N'))
$nodeCommand = (Get-Command node.exe -ErrorAction Stop).Source
$npmEntry = Get-Command npm.cmd -ErrorAction SilentlyContinue
if ($NpmCli) {
    $NpmCli = (Resolve-Path -LiteralPath $NpmCli).Path
} elseif (-not $npmEntry) {
    throw '构建需要带 npm 的 Node.js，或使用 -NpmCli 指定 npm-cli.js'
}
function Invoke-TaskNpm {
    if ($NpmCli) { & $nodeCommand $NpmCli @args }
    else { & $npmEntry.Source @args }
    if ($LASTEXITCODE -ne 0) { throw "npm $args 失败（$LASTEXITCODE）" }
}
New-Item -ItemType Directory -Path $buildDirectory -Force | Out-Null
$originalTaskPath = $env:PATH
if ($NpmCli) {
    $proxyDirectory = Join-Path $buildDirectory '.build-tools'
    New-Item -ItemType Directory -Path $proxyDirectory -Force | Out-Null
    $proxyContent = '@echo off' + [Environment]::NewLine + '"' + $nodeCommand.Replace('%', '%%') + '" "' + $NpmCli.Replace('%', '%%') + '" %*'
    Set-Content -LiteralPath (Join-Path $proxyDirectory 'npm.cmd') -Value $proxyContent -Encoding oem
    $env:PATH = $proxyDirectory + ';' + (Split-Path -Parent $nodeCommand) + ';' + $env:PATH
}
foreach ($name in @('src', 'assets', 'test', 'package.json', 'package-lock.json')) {
    Copy-Item -LiteralPath (Join-Path $sourceRoot $name) -Destination $buildDirectory -Recurse
}
Push-Location -LiteralPath $buildDirectory
try {
    Invoke-TaskNpm ci --no-audit --no-fund --ignore-scripts=false
    Invoke-TaskNpm test
    Invoke-TaskNpm run dist:win
    New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
    $artifacts = Get-ChildItem -LiteralPath (Join-Path $buildDirectory 'dist') -File | Where-Object { $_.Extension -eq '.exe' }
    if ($artifacts.Count -ne 2) { throw '预期应生成安装版和免安装版两个交付文件' }
    foreach ($artifact in $artifacts) {
        if (Test-Path -LiteralPath (Join-Path $OutputDirectory $artifact.Name)) { throw "交付文件已存在：$($artifact.Name)" }
    }
    foreach ($artifact in $artifacts) {
        $destination = Join-Path $OutputDirectory $artifact.Name
        if (Test-Path -LiteralPath $destination) { throw "交付文件已存在：$destination" }
        Copy-Item -LiteralPath $artifact.FullName -Destination $destination
    }
    $version = (Get-Content -LiteralPath 'package.json' -Raw | ConvertFrom-Json).version
    $checksums = foreach ($artifact in $artifacts) {
        $hash = (Get-FileHash -LiteralPath $artifact.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
        "$hash  $($artifact.Name)"
    }
    $checksums | Set-Content -LiteralPath (Join-Path $OutputDirectory "SHA256SUMS-$version.txt") -Encoding utf8
    Write-Output "交付目录：$OutputDirectory"
    Write-Output "保留构建目录：$buildDirectory"
} finally { Pop-Location; $env:PATH = $originalTaskPath }
