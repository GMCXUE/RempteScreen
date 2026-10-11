$ErrorActionPreference = 'Stop'
# Save diagnostics on a separate branch without ever force-pushing source history.
# This also permits diagnosis via Git when the local host has SSH access but no Actions API token.
if (!(Test-Path 'build-log.txt')) { Set-Content 'build-log.txt' 'Build step did not start; see prepare-log.txt and build-status.json.' }
if (!(Test-Path 'prepare-log.txt')) { Set-Content 'prepare-log.txt' 'SDK preparation step did not start.' }
@{ runId = $env:GITHUB_RUN_ID; sha = $env:GITHUB_SHA; outcome = $env:BUILD_OUTCOME; prepareOutcome = $env:PREPARE_OUTCOME } |
    ConvertTo-Json | Set-Content 'build-status.json'
git config user.name 'windows-builder'
git config user.email 'builder@remotescreen.local'
$remote = git ls-remote --heads origin refs/heads/build-logs/windows
if ($LASTEXITCODE -ne 0) { throw 'Cannot read diagnostics branch' }
$parent = $null
if ($remote) {
    git fetch origin refs/heads/build-logs/windows
    if ($LASTEXITCODE -ne 0) { throw 'Cannot fetch diagnostics branch' }
    $parent = git rev-parse FETCH_HEAD
}
$env:GIT_INDEX_FILE = Join-Path $env:RUNNER_TEMP "windows-logs-$env:GITHUB_RUN_ID.index"
try {
    git read-tree --empty
    if ($LASTEXITCODE -ne 0) { throw 'Cannot create diagnostics index' }
    git add -f -- build-log.txt prepare-log.txt build-status.json
    if ($LASTEXITCODE -ne 0) { throw 'Cannot add diagnostics files' }
    $tree = git write-tree
    if ($LASTEXITCODE -ne 0) { throw 'Cannot create diagnostics tree' }
    if ($parent) { $commit = git commit-tree $tree -p $parent -m "Windows build $env:GITHUB_RUN_ID" }
    else { $commit = git commit-tree $tree -m "Windows build $env:GITHUB_RUN_ID" }
    if ($LASTEXITCODE -ne 0) { throw 'Cannot commit diagnostics' }
    git push origin "${commit}:refs/heads/build-logs/windows"
    if ($LASTEXITCODE -ne 0) { throw 'Cannot publish diagnostics (source history was not modified)' }
} finally {
    Remove-Item Env:GIT_INDEX_FILE
}
