[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$distRoot = Join-Path $projectRoot 'dist'
$target = Join-Path $distRoot 'Codex-Startup-Windows'
$archive = Join-Path $distRoot 'Codex-Startup-Windows.zip'

$resolvedProject = [IO.Path]::GetFullPath($projectRoot).TrimEnd('\')
$resolvedTarget = [IO.Path]::GetFullPath($target)
if (-not $resolvedTarget.StartsWith($resolvedProject + '\', [StringComparison]::OrdinalIgnoreCase)) {
    throw 'The build output directory must stay inside the project.'
}

if (Test-Path -LiteralPath $target) {
    Remove-Item -LiteralPath $target -Recurse -Force
}
New-Item -ItemType Directory -Path (Join-Path $target 'assets'), (Join-Path $target 'extension'), (Join-Path $target 'tools') -Force | Out-Null

Copy-Item -LiteralPath (Join-Path $projectRoot 'index.html'), (Join-Path $projectRoot 'style.css'), (Join-Path $projectRoot 'animation.js'), (Join-Path $projectRoot 'image-settings.js'), (Join-Path $projectRoot 'README-Windows.md') -Destination $target
Get-ChildItem -LiteralPath $projectRoot -Filter '*.cmd' -File | Copy-Item -Destination $target
Copy-Item -LiteralPath (Join-Path $projectRoot 'assets\avatar.jpg'), (Join-Path $projectRoot 'assets\artwork.jpg'), (Join-Path $projectRoot 'assets\contours.js') -Destination (Join-Path $target 'assets')
Copy-Item -LiteralPath (Join-Path $projectRoot 'extension\cdp.mjs'), (Join-Path $projectRoot 'extension\payload.mjs'), (Join-Path $projectRoot 'extension\renderer.mjs'), (Join-Path $projectRoot 'extension\run-windows.mjs'), (Join-Path $projectRoot 'extension\wallpaper.css') -Destination (Join-Path $target 'extension')
Copy-Item -LiteralPath (Join-Path $projectRoot 'tools\launch-windows.ps1'), (Join-Path $projectRoot 'tools\launch-windows.vbs'), (Join-Path $projectRoot 'tools\show-chatgpt-window.ps1'), (Join-Path $projectRoot 'tools\install-windows-shortcut.ps1'), (Join-Path $projectRoot 'tools\browser-smoke-windows.mjs') -Destination (Join-Path $target 'tools')

if (Test-Path -LiteralPath $archive) {
    Remove-Item -LiteralPath $archive -Force
}
Compress-Archive -Path (Join-Path $target '*') -DestinationPath $archive -CompressionLevel Optimal

Write-Output "Built: $target"
Write-Output "Archive: $archive"
