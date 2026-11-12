param(
    [Parameter(Mandatory)][string]$ReleasesUrl,
    # Kept so existing callers still parse: `dist` and `release` both build
    # the Zig app and engine ReleaseSafe. Nothing here runs cargo.
    [ValidateSet('dist', 'release')][string]$CargoProfile = 'dist',
    [ValidateSet('Debug', 'ReleaseSafe', 'ReleaseFast', 'ReleaseSmall')][string]$Optimize = 'ReleaseSafe'
)
# Windows packaging: only Zig output ships. harness-nano.exe is the app;
# harness-engine.exe is the engine the app starts beside it (and the CLI:
# login, logout, status, sync, mcp). No cargo, no Rust binary.
$ErrorActionPreference = 'Stop'
if (-not $ReleasesUrl.StartsWith('https://')) { throw 'Release feed must use HTTPS' }
$root = Split-Path $PSScriptRoot -Parent
Push-Location $root
try {
    Push-Location (Join-Path $root 'apps/nano')
    try {
        zig build -Dtarget=x86_64-windows-gnu "-Doptimize=$Optimize"
        if ($LASTEXITCODE -ne 0) { throw 'Windows Zig build failed' }
    } finally { Pop-Location }
    $bin = Join-Path $root 'apps/nano/zig-out/bin'
    $app = Join-Path $bin 'harness-nano.exe'
    $engine = Join-Path $bin 'harness-engine.exe'
    foreach ($exe in @($app, $engine)) {
        if (-not (Test-Path -LiteralPath $exe)) { throw "missing build output: $exe" }
    }
    # The version comes from the engine itself, so a stale build cache can't
    # package one version under another's name.
    $probe = [Diagnostics.ProcessStartInfo]::new()
    $probe.FileName = (Resolve-Path -LiteralPath $engine).Path
    $probe.Arguments = '--version'
    $probe.UseShellExecute = $false
    $probe.CreateNoWindow = $true
    $probe.RedirectStandardOutput = $true
    $probe.RedirectStandardError = $true
    $process = [Diagnostics.Process]::Start($probe)
    try {
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(10000)) {
            $process.Kill()
            throw 'Executable version probe timed out'
        }
        $versionMatch = [regex]::Match($stdout.Result.Trim(), '\Aharness-engine (\d+\.\d+\.\d+)\z')
        if ($process.ExitCode -ne 0 -or -not $versionMatch.Success) {
            throw "Cannot read executable version: $($stderr.Result)"
        }
        $version = $versionMatch.Groups[1].Value
    } finally { $process.Dispose() }
    $out = Join-Path $root 'target/package'
    $stage = Join-Path $out "harness-$version-windows-x86_64"
    if (Test-Path -LiteralPath $stage) { Remove-Item -Recurse -Force -LiteralPath $stage }
    New-Item -ItemType Directory -Force -Path $stage | Out-Null
    Copy-Item -LiteralPath $app -Destination (Join-Path $stage 'harness-nano.exe')
    Copy-Item -LiteralPath $engine -Destination (Join-Path $stage 'harness-engine.exe')
    if (Test-Path -LiteralPath (Join-Path $stage 'harness.exe')) { throw 'a Rust harness.exe is in the package' }
    @{ releases_url = $ReleasesUrl } | ConvertTo-Json | Set-Content -Encoding utf8NoBOM -LiteralPath (Join-Path $stage 'harness-update.json')
    Copy-Item -LiteralPath 'LICENSE','THIRD_PARTY_NOTICES.md' -Destination $stage
    $licenses = Join-Path $stage 'licenses/fonts'
    New-Item -ItemType Directory -Force -Path $licenses | Out-Null
    Copy-Item -Path 'apps/nano/assets/fonts/licenses/*' -Destination $licenses
    Copy-Item -LiteralPath 'third_party/licenses/Zeron-MIT.txt' -Destination (Join-Path $stage 'licenses')
    Copy-Item -LiteralPath 'third_party/licenses/CodeGraff-LICENSE.txt' -Destination (Join-Path $stage 'licenses')
    Compress-Archive -Path "$stage/*" -DestinationPath "$stage.zip" -Force
    # The portable zip is the release artifact: the app needs both
    # executables, so the single-exe updater artifact isn't produced.
    $file = Split-Path "$stage.zip" -Leaf
    $hash = (Get-FileHash -LiteralPath "$stage.zip" -Algorithm SHA256).Hash.ToLowerInvariant()
    @{ version = $version; files = @{ $file = @{ sha256 = $hash } } } |
        ConvertTo-Json -Depth 4 | Set-Content -Encoding utf8NoBOM -LiteralPath (Join-Path $out 'manifest.json')
    Write-Host "Packaged $stage.zip"
} finally { Pop-Location }
