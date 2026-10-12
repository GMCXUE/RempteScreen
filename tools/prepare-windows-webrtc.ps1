param([string]$Root = 'C:\lk')
$ErrorActionPreference = 'Stop'

# MSVC cannot open some SDK headers under Cargo's deeply nested scratch directory.
# Use the SDK's supported LK_CUSTOM_WEBRTC override, preserving its exact binary version.
$tag = 'webrtc-89d790b'
$sha256 = '5c2349c960bae4f06f71c102f58552d0d09c912a142811acfcadfb7c883cbf58'
$metadata = cargo metadata --locked --format-version 1 | ConvertFrom-Json
if ($LASTEXITCODE -ne 0) { throw 'cargo metadata failed' }
$package = $metadata.packages | Where-Object name -eq 'webrtc-sys-build'
if (@($package).Count -ne 1) { throw 'Expected exactly one webrtc-sys-build package' }
$source = Get-Content (Join-Path (Split-Path $package.manifest_path) 'src/lib.rs') -Raw
if ($source -notmatch 'WEBRTC_TAG:\s*&str\s*=\s*"([^\"]+)"' -or $Matches[1] -ne $tag) {
    throw 'WebRTC SDK version changed; update the pinned Windows archive and SHA256 together'
}
New-Item -ItemType Directory -Force -Path $Root | Out-Null
$archive = Join-Path $Root "$tag.zip"
Invoke-WebRequest "https://github.com/livekit/rust-sdks/releases/download/$tag/webrtc-win-x64-release.zip" -OutFile $archive
if ((Get-FileHash $archive -Algorithm SHA256).Hash.ToLowerInvariant() -ne $sha256) {
    throw 'WebRTC archive SHA256 mismatch'
}
$destination = Join-Path $Root $tag
Expand-Archive -Path $archive -DestinationPath $destination -Force
$sdk = Join-Path $destination 'win-x64-release'
foreach ($relative in @('lib/webrtc.lib', 'webrtc.ninja', 'include/third_party/abseil-cpp/absl/strings/internal/str_format/constexpr_parser.h')) {
    $file = Join-Path $sdk $relative
    if (!(Test-Path $file)) { throw "Incomplete WebRTC SDK: $relative" }
    if ($file.Length -ge 240) { throw "WebRTC SDK path too long: $file" }
}
"LK_CUSTOM_WEBRTC=$sdk" | Out-File -FilePath $env:GITHUB_ENV -Encoding utf8 -Append
Write-Host "Validated WebRTC SDK at $sdk"
