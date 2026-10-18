[CmdletBinding()]
param(
    [switch]$Probe,
    [switch]$NoDialog,
    [string]$PackageRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$utf8 = New-Object System.Text.UTF8Encoding($false)
[Console]::InputEncoding = $utf8
[Console]::OutputEncoding = $utf8
$OutputEncoding = $utf8
$projectRoot = Split-Path -Parent $PSScriptRoot

function Get-CodexPackageRoot {
    if ($PackageRoot) {
        return (Resolve-Path -LiteralPath $PackageRoot).Path
    }

    try {
        $package = Get-AppxPackage -Name 'OpenAI.Codex' -ErrorAction Stop |
            Sort-Object Version -Descending |
            Select-Object -First 1
        if ($package.InstallLocation) {
            return (Resolve-Path -LiteralPath $package.InstallLocation).Path
        }
    } catch {
        # Some sandboxes block Get-AppxPackage. The per-user package repository
        # contains the same signed install location and works as a fallback.
    }

    $repository = 'Registry::HKEY_CURRENT_USER\Software\Classes\Local Settings\Software\Microsoft\Windows\CurrentVersion\AppModel\Repository\Packages'
    $candidates = @(Get-ChildItem -LiteralPath $repository -ErrorAction Stop | ForEach-Object {
        if ($_.PSChildName -match '^OpenAI\.Codex_([0-9.]+)_(?:x64|arm64)__2p2nqsd0c76g0$') {
            $record = Get-ItemProperty -LiteralPath $_.PSPath
            [pscustomobject]@{Version = [version]$Matches[1]; Root = $record.PackageRootFolder}
        }
    } | Sort-Object Version -Descending)
    if (-not $candidates) {
        throw 'Microsoft Store Codex/ChatGPT was not found. Install or update the official desktop app first.'
    }
    return (Resolve-Path -LiteralPath $candidates[0].Root).Path
}

function Show-LauncherError([string]$Message) {
    if (-not $NoDialog -and [Environment]::UserInteractive) {
        Add-Type -AssemblyName System.Windows.Forms
        [void][System.Windows.Forms.MessageBox]::Show(
            $Message,
            'Codex Startup Animation',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error
        )
    }
    Write-Error $Message -ErrorAction Continue
}

try {
    if (-not [Environment]::Is64BitOperatingSystem) {
        throw 'This launcher requires 64-bit Windows.'
    }

    $bundle = Get-CodexPackageRoot
    $manifestPath = Join-Path $bundle 'AppxManifest.xml'
    $executable = Join-Path $bundle 'app\ChatGPT.exe'
    $node = Join-Path $bundle 'app\resources\cua_node\bin\node.exe'
    $runner = Join-Path $projectRoot 'extension\run-windows.mjs'

    foreach ($required in @($manifestPath, $executable, $node, $runner)) {
        if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
            throw "Required file is missing: $required"
        }
    }

    [xml]$manifest = Get-Content -Raw -LiteralPath $manifestPath
    $identity = $manifest.Package.Identity
    if ($identity.Name -ne 'OpenAI.Codex') {
        throw 'The application package identity does not match OpenAI.Codex.'
    }

    $signature = Get-AuthenticodeSignature -LiteralPath $executable
    $subject = [string]$signature.SignerCertificate.Subject
    if ($signature.Status -ne 'Valid' -or $subject -notmatch 'O="?OpenAI OpCo, LLC"?') {
        throw 'The official OpenAI Authenticode signature check failed.'
    }

    $versionInfo = (Get-Item -LiteralPath $executable).VersionInfo
    if ($versionInfo.ProductName -ne 'Codex') {
        throw 'The target executable is not the expected Codex desktop app.'
    }

    $resolvedExecutable = (Resolve-Path -LiteralPath $executable).Path
    $installedRoot = Join-Path $env:APPDATA 'CodexStartupAnimation'
    if ($env:APPDATA -and ([IO.Path]::GetFullPath($projectRoot).TrimEnd('\') -ieq [IO.Path]::GetFullPath($installedRoot).TrimEnd('\'))) {
        $cachePath = Join-Path $projectRoot 'launcher-cache.txt'
        [IO.File]::WriteAllLines(
            $cachePath,
            @($bundle, $resolvedExecutable, (Resolve-Path -LiteralPath $node).Path),
            (New-Object Text.UTF8Encoding($false))
        )
    }
    $running = @(Get-Process -Name 'ChatGPT' -ErrorAction SilentlyContinue | Where-Object {
        try { $_.Path -and ((Resolve-Path -LiteralPath $_.Path).Path -ieq $resolvedExecutable) } catch { $false }
    })

    $result = [ordered]@{
        Supported = $true
        OS = [Environment]::OSVersion.VersionString
        Architecture = [Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString()
        PackageVersion = [string]$identity.Version
        PackageRoot = $bundle
        Executable = $resolvedExecutable
        ProductVersion = $versionInfo.ProductVersion
        Signer = $subject
        BundledNode = (Resolve-Path -LiteralPath $node).Path
        Running = ($running.Count -gt 0)
    }

    if ($Probe) {
        [pscustomobject]$result | ConvertTo-Json -Depth 3
        exit 0
    }

    $output = @(& $node $runner '--bundle' $bundle '--executable' $resolvedExecutable 2>&1)
    if ($LASTEXITCODE -ne 0) {
        $message = ($output | ForEach-Object { $_.ToString() }) -join [Environment]::NewLine
        $message = $message.Trim()
        if (-not $message) { $message = 'Codex failed to start.' }
        throw $message
    }
    exit 0
} catch {
    Show-LauncherError $_.Exception.Message
    exit 1
}
