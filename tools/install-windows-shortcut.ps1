[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$utf8 = New-Object System.Text.UTF8Encoding($false)
[Console]::InputEncoding = $utf8
[Console]::OutputEncoding = $utf8
$OutputEncoding = $utf8

$projectRoot = Split-Path -Parent $PSScriptRoot
$builtPayload = Join-Path $projectRoot 'dist\Codex-Startup-Windows'
$payload = if (Test-Path -LiteralPath $builtPayload -PathType Container) { $builtPayload } else { $projectRoot }
$installRoot = Join-Path $env:APPDATA 'CodexStartupAnimation'
$desktop = [Environment]::GetFolderPath('Desktop')
$officialShortcutPath = Join-Path $desktop 'ChatGPT.lnk'
$animationShortcutName = 'ChatGPT ' + [char]0x52A8 + [char]0x753B + '.lnk'
$animationShortcutPath = Join-Path $desktop $animationShortcutName

if (-not $env:APPDATA -or -not $desktop) {
    throw 'Windows user profile folders could not be resolved.'
}

$resolvedAppData = [IO.Path]::GetFullPath($env:APPDATA).TrimEnd('\')
$resolvedInstall = [IO.Path]::GetFullPath($installRoot)
if (-not $resolvedInstall.StartsWith($resolvedAppData + '\', [StringComparison]::OrdinalIgnoreCase)) {
    throw 'The install directory must stay inside the current user profile.'
}

New-Item -ItemType Directory -Path $installRoot -Force | Out-Null
Copy-Item -Path (Join-Path $payload '*') -Destination $installRoot -Recurse -Force

function Get-CodexPackageRoot {
    try {
        $package = Get-AppxPackage -Name 'OpenAI.Codex' -ErrorAction Stop |
            Sort-Object Version -Descending |
            Select-Object -First 1
        if ($package.InstallLocation) { return $package.InstallLocation }
    } catch {}

    $repository = 'Registry::HKEY_CURRENT_USER\Software\Classes\Local Settings\Software\Microsoft\Windows\CurrentVersion\AppModel\Repository\Packages'
    $candidate = Get-ChildItem -LiteralPath $repository -ErrorAction Stop | ForEach-Object {
        if ($_.PSChildName -match '^OpenAI\.Codex_([0-9.]+)_(?:x64|arm64)__2p2nqsd0c76g0$') {
            $record = Get-ItemProperty -LiteralPath $_.PSPath
            [pscustomobject]@{Version = [version]$Matches[1]; Root = $record.PackageRootFolder}
        }
    } | Sort-Object Version -Descending | Select-Object -First 1
    if (-not $candidate) { throw 'Microsoft Store Codex/ChatGPT was not found.' }
    return $candidate.Root
}

$packageRoot = Get-CodexPackageRoot
$manifestPath = Join-Path $packageRoot 'AppxManifest.xml'
$packageExecutable = Join-Path $packageRoot 'app\ChatGPT.exe'
$packageNode = Join-Path $packageRoot 'app\resources\cua_node\bin\node.exe'
foreach ($required in @($manifestPath, $packageExecutable, $packageNode)) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
        throw "Required official application file is missing: $required"
    }
}
[xml]$manifest = Get-Content -Raw -LiteralPath $manifestPath
if ([string]$manifest.Package.Identity.Name -ne 'OpenAI.Codex') {
    throw 'The installed package identity is not OpenAI.Codex.'
}
$signature = Get-AuthenticodeSignature -LiteralPath $packageExecutable
$subject = [string]$signature.SignerCertificate.Subject
if ($signature.Status -ne 'Valid' -or $subject -notmatch 'O="?OpenAI OpCo, LLC"?') {
    throw 'The official OpenAI Authenticode signature check failed.'
}
if ((Get-Item -LiteralPath $packageExecutable).VersionInfo.ProductName -ne 'Codex') {
    throw 'The target executable is not the expected Codex desktop app.'
}

$iconCandidates = @(
    (Join-Path $packageRoot 'app\resources\icon-chatgpt.ico'),
    (Join-Path $packageRoot 'app\resources\chatgpt-app-light.ico'),
    (Join-Path $packageRoot 'app\resources\chatgpt-app-dark.ico')
)
$iconSource = $iconCandidates | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
if (-not $iconSource) { throw 'The official ChatGPT icon was not found in the installed package.' }
$iconTarget = Join-Path $installRoot 'assets\chatgpt.ico'
try {
    # A byte-for-byte write strips the Store package encryption attribute while
    # preserving every resolution embedded in the official multi-size ICO.
    [IO.File]::WriteAllBytes($iconTarget, [IO.File]::ReadAllBytes($iconSource))
} catch {
    # Microsoft Store may expose icon files as encrypted package resources.
    # Extracting the executable's embedded icon produces a normal user-owned ICO.
    Add-Type -AssemblyName System.Drawing
    $icon = [Drawing.Icon]::ExtractAssociatedIcon($packageExecutable)
    if (-not $icon) { throw 'The official ChatGPT icon could not be extracted.' }
    $stream = [IO.File]::Open($iconTarget, [IO.FileMode]::Create)
    try { $icon.Save($stream) } finally { $stream.Dispose(); $icon.Dispose() }
}

$cache = Join-Path $installRoot 'launcher-cache.txt'
[IO.File]::WriteAllLines($cache, @($packageRoot, $packageExecutable, $packageNode), (New-Object Text.UTF8Encoding($false)))

$wscript = Join-Path $env:WINDIR 'System32\wscript.exe'
$launcher = Join-Path $installRoot 'tools\launch-windows.vbs'
if (-not (Test-Path -LiteralPath $launcher -PathType Leaf)) { throw 'The installed windowless launcher is missing.' }

$shell = New-Object -ComObject WScript.Shell
Get-ChildItem -LiteralPath $desktop -Filter 'ChatGPT*.lnk' -ErrorAction SilentlyContinue | ForEach-Object {
    if ($_.FullName -ieq $officialShortcutPath -or $_.FullName -ieq $animationShortcutPath) { return }
    $candidate = $shell.CreateShortcut($_.FullName)
    if ($candidate.TargetPath -ieq $wscript -and $candidate.Arguments -like "*$installRoot*") {
        Remove-Item -LiteralPath $_.FullName -Force
    }
}
if (Test-Path -LiteralPath $animationShortcutPath -PathType Leaf) {
    $existing = $shell.CreateShortcut($animationShortcutPath)
    if ($existing.Arguments -notlike "*$installRoot*") {
        throw "A different ChatGPT animation shortcut already exists on the desktop: $animationShortcutPath"
    }
}

$officialShortcut = $shell.CreateShortcut($officialShortcutPath)
$officialShortcut.TargetPath = Join-Path $env:WINDIR 'explorer.exe'
$officialShortcut.Arguments = 'shell:AppsFolder\OpenAI.Codex_2p2nqsd0c76g0!App'
$officialShortcut.WorkingDirectory = $env:USERPROFILE
$officialShortcut.IconLocation = "$iconTarget,0"
$officialShortcut.Description = 'ChatGPT'
$officialShortcut.Save()

$animationShortcut = $shell.CreateShortcut($animationShortcutPath)
$animationShortcut.TargetPath = $wscript
$animationShortcut.Arguments = "//B //Nologo `"$launcher`""
$animationShortcut.WorkingDirectory = $installRoot
$animationShortcut.IconLocation = "$iconTarget,0"
$animationShortcut.Description = 'ChatGPT with startup animation'
$animationShortcut.Save()

[pscustomobject]@{
    Installed = $true
    InstallRoot = $installRoot
    OfficialShortcut = $officialShortcutPath
    AnimationShortcut = $animationShortcutPath
    Icon = $iconTarget
    Launcher = $launcher
} | ConvertTo-Json -Depth 2
