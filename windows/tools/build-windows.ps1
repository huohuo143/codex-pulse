param([string]$OutputDirectory)
$ErrorActionPreference = 'Stop'
$sourceRoot = Split-Path -Parent $PSScriptRoot
if (-not $OutputDirectory) { $OutputDirectory = Join-Path $sourceRoot 'dist' }
$buildDirectory = Join-Path $env:LOCALAPPDATA ('CodexPulseBuild/' + [guid]::NewGuid().ToString('N'))
$npmCommand = (Get-Command npm.cmd -ErrorAction Stop).Source
New-Item -ItemType Directory -Path $buildDirectory -Force | Out-Null
foreach ($name in @('src', 'assets', 'test', 'package.json', 'package-lock.json')) {
    Copy-Item -LiteralPath (Join-Path $sourceRoot $name) -Destination $buildDirectory -Recurse
}
Push-Location -LiteralPath $buildDirectory
try {
    & $npmCommand ci
    if ($LASTEXITCODE -ne 0) { throw '依赖安装失败' }
    & $npmCommand test
    if ($LASTEXITCODE -ne 0) { throw '测试失败' }
    & $npmCommand run dist:win
    if ($LASTEXITCODE -ne 0) { throw '打包失败' }
    New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
    $artifacts = Get-ChildItem -LiteralPath (Join-Path $buildDirectory 'dist') -File | Where-Object { $_.Extension -eq '.exe' }
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
} finally { Pop-Location }
