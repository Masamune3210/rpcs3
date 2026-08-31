@echo off
setlocal EnableExtensions
title RPCS3 Upstream Update

cd /d "%~dp0"

set "TEMP_PS1=%TEMP%\Update-RPCS3-Upstream-%RANDOM%-%RANDOM%.ps1"
set "UPDATER_SELF=%~f0"
set "UPDATER_TEMP=%TEMP_PS1%"

powershell.exe -NoProfile -ExecutionPolicy Bypass -Command ^
  "$src=$env:UPDATER_SELF; $dst=$env:UPDATER_TEMP; if([string]::IsNullOrWhiteSpace($src) -or [string]::IsNullOrWhiteSpace($dst)){exit 2}; $lines=Get-Content -LiteralPath $src; $marker=[Array]::LastIndexOf($lines,'::POWERSHELL_PAYLOAD'); if($marker -lt 0 -or $marker -ge ($lines.Count-1)){exit 3}; $lines[($marker+1)..($lines.Count-1)] | Set-Content -LiteralPath $dst -Encoding UTF8"

if errorlevel 1 (
    echo ERROR: Could not extract the updater payload.
    pause
    exit /b 1
)

where pwsh.exe >nul 2>&1
if errorlevel 1 (
    set "PS_EXE=powershell.exe"
) else (
    set "PS_EXE=pwsh.exe"
)

start "RPCS3 Upstream Update" "%PS_EXE%" -NoLogo -NoProfile -NoExit -ExecutionPolicy Bypass -File "%TEMP_PS1%" -RepositoryPath "%CD%"
exit /b 0

::POWERSHELL_PAYLOAD
[CmdletBinding()]
param(
    [string] $RepositoryPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repositoryLabel = 'RPCS3'
$defaultUpstreamUrl = 'https://github.com/RPCS3/rpcs3.git'

# The batch launcher extracts this payload to a temporary file. PowerShell
# has already loaded it, so remove that temporary copy immediately.
if ($MyInvocation.MyCommand.Path) {
    Remove-Item -LiteralPath $MyInvocation.MyCommand.Path -Force -ErrorAction SilentlyContinue
}

function Wait-ForClose {
    Write-Host
    [void](Read-Host 'Press Enter to close')
}

function Invoke-Git {
    param(
        [Parameter(Mandatory)]
        [string[]] $Arguments,

        [switch] $AllowFailure
    )

    & git @Arguments
    $code = $LASTEXITCODE

    if (-not $AllowFailure -and $code -ne 0) {
        throw "Git command failed with exit code ${code}: git $($Arguments -join ' ')"
    }

    return $code
}

function Get-GitOutput {
    param(
        [Parameter(Mandatory)]
        [string[]] $Arguments
    )

    $output = & git @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "Git command failed: git $($Arguments -join ' ')"
    }

    return @($output)
}

function Get-GitFirstLine {
    param(
        [Parameter(Mandatory)]
        [string[]] $Arguments
    )

    $lines = @(Get-GitOutput -Arguments $Arguments)
    if ($lines.Count -eq 0) {
        throw "Git command returned no output: git $($Arguments -join ' ')"
    }

    return [string]$lines[0]
}

function Test-GitRef {
    param(
        [Parameter(Mandatory)]
        [string] $Ref
    )

    & git show-ref --verify --quiet $Ref
    return ($LASTEXITCODE -eq 0)
}

function Get-RemoteDefaultBranch {
    param(
        [Parameter(Mandatory)]
        [string] $Remote
    )

    $lines = @(& git ls-remote --symref $Remote HEAD 2>$null)
    if ($LASTEXITCODE -eq 0) {
        foreach ($line in $lines) {
            if ($line -match '^ref:\s+refs/heads/(.+?)\s+HEAD$') {
                return $Matches[1]
            }
        }
    }

    & git remote set-head $Remote --auto *> $null

    $symbolic = @(& git symbolic-ref --quiet --short "refs/remotes/$Remote/HEAD" 2>$null)
    if ($LASTEXITCODE -eq 0 -and $symbolic.Count -gt 0) {
        return ($symbolic[0] -replace "^$([regex]::Escape($Remote))/", '')
    }

    throw "Could not determine the default branch of remote '$Remote'."
}

function Restore-StartingBranch {
    param(
        [string] $StartingBranch,
        [string] $CurrentBranch
    )

    if ($StartingBranch -and $CurrentBranch -ne $StartingBranch) {
        Write-Host
        Write-Host "Returning to the starting branch: $StartingBranch"
        Invoke-Git -Arguments @('switch', '--no-guess', $StartingBranch) | Out-Null
    }
}

try {
    if ($RepositoryPath) {
        Set-Location -LiteralPath $RepositoryPath
    }

    $repoRoot = (Get-GitFirstLine -Arguments @('rev-parse', '--show-toplevel')).Trim()
    Set-Location $repoRoot

    $gitDir = (Get-GitFirstLine -Arguments @('rev-parse', '--git-dir')).Trim()
    if (-not [System.IO.Path]::IsPathRooted($gitDir)) {
        $gitDir = Join-Path $repoRoot $gitDir
    }

    if ((Test-Path (Join-Path $gitDir 'rebase-merge')) -or
        (Test-Path (Join-Path $gitDir 'rebase-apply'))) {
        throw @"
A rebase is already in progress.

Finish it with:
  git status
  git add <resolved files>
  git rebase --continue

Or abandon it with:
  git rebase --abort
"@
    }

    $startingBranch = (Get-GitFirstLine -Arguments @('branch', '--show-current')).Trim()

    if (-not $startingBranch) {
        throw 'The repository is in detached-HEAD state.'
    }

    $dirty = @(Get-GitOutput -Arguments @('status', '--porcelain', '--untracked-files=all'))
    if ($dirty.Count -gt 0) {
        throw 'The worktree has uncommitted or untracked changes. Commit, stash, or remove them first.'
    }

    Invoke-Git -Arguments @('remote', 'get-url', 'origin') | Out-Null

    & git remote get-url upstream *> $null
    $upstreamExists = ($LASTEXITCODE -eq 0)

    if (-not $upstreamExists) {
        Write-Host
        Write-Host "Adding the upstream remote for $repositoryLabel..."
        Invoke-Git -Arguments @('remote', 'add', 'upstream', $defaultUpstreamUrl) | Out-Null
    } else {
        $configuredFetch = (Get-GitFirstLine -Arguments @('remote', 'get-url', 'upstream')).Trim()

        if ($configuredFetch -ne $defaultUpstreamUrl) {
            Write-Host
            Write-Host 'Correcting the upstream fetch URL:'
            Write-Host "  old: $configuredFetch"
            Write-Host "  new: $defaultUpstreamUrl"
            Invoke-Git -Arguments @('remote', 'set-url', 'upstream', $defaultUpstreamUrl) | Out-Null
        }
    }

    $configuredPush = (Get-GitFirstLine -Arguments @('remote', 'get-url', '--push', 'upstream')).Trim()
    if ($configuredPush -ne 'no_push') {
        Write-Host
        Write-Host 'Setting the upstream push URL to no_push...'
        Invoke-Git -Arguments @('remote', 'set-url', '--push', 'upstream', 'no_push') | Out-Null
    }

    $upstreamFetch = (Get-GitFirstLine -Arguments @('remote', 'get-url', 'upstream')).Trim()
    $upstreamPush = (Get-GitFirstLine -Arguments @('remote', 'get-url', '--push', 'upstream')).Trim()

    $upstreamBranch = Get-RemoteDefaultBranch -Remote 'upstream'
    $primaryBranch = Get-RemoteDefaultBranch -Remote 'origin'

    $upstreamRemoteRef = "refs/remotes/upstream/$upstreamBranch"
    $originPrimaryRef = "refs/remotes/origin/$primaryBranch"
    $localUpstreamRef = 'refs/heads/upstream'
    $localPrimaryRef = "refs/heads/$primaryBranch"

    Write-Host
    Write-Host 'Repository configuration:'
    Write-Host "  upstream fetch:  $upstreamFetch"
    Write-Host "  upstream branch: $upstreamBranch"
    Write-Host "  primary branch:  $primaryBranch"
    Write-Host

    Write-Host 'Fetching upstream and origin...'
    Invoke-Git -Arguments @('fetch', 'upstream', '--prune') | Out-Null
    Invoke-Git -Arguments @('fetch', 'origin', '--prune') | Out-Null

    if (-not (Test-GitRef -Ref $upstreamRemoteRef)) {
        throw "$upstreamRemoteRef was not found after fetching."
    }

    # Keep the script safe on the primary branch while updating the clean
    # upstream reference. No checkout of the upstream branch is required.
    $currentBranch = (Get-GitFirstLine -Arguments @('branch', '--show-current')).Trim()
    if ($currentBranch -ne $primaryBranch) {
        Write-Host
        Write-Host "Switching to the primary branch: $primaryBranch"
        Invoke-Git -Arguments @('switch', '--no-guess', $primaryBranch) | Out-Null
    }

    Write-Host
    Write-Host 'Updating the clean local upstream branch...'

    if (Test-GitRef -Ref $localUpstreamRef) {
        $ancestorCode = Invoke-Git `
            -Arguments @('merge-base', '--is-ancestor', $localUpstreamRef, $upstreamRemoteRef) `
            -AllowFailure

        if ($ancestorCode -ne 0) {
            throw @"
The local upstream branch contains commits that are not in $upstreamRemoteRef.
It was not reset or rewritten.
"@
        }

        Invoke-Git -Arguments @('branch', '-f', 'upstream', $upstreamRemoteRef) | Out-Null
    } else {
        Invoke-Git -Arguments @('branch', '--track', 'upstream', $upstreamRemoteRef) | Out-Null
    }

    Invoke-Git -Arguments @('config', 'branch.upstream.remote', 'upstream') | Out-Null
    Invoke-Git -Arguments @('config', 'branch.upstream.merge', "refs/heads/$upstreamBranch") | Out-Null

    Write-Host
    Write-Host 'Publishing the clean upstream branch directly to origin...'
    Invoke-Git -Arguments @(
        'push',
        '--force-with-lease',
        'origin',
        'refs/heads/upstream:refs/heads/upstream'
    ) | Out-Null

    Write-Host
    $answer = Read-Host "Catch $primaryBranch up to upstream and push it directly to origin? [Y/N]"

    if ($answer -notmatch '^(?i)y(?:es)?$') {
        $currentBranch = (Get-GitFirstLine -Arguments @('branch', '--show-current')).Trim()
        Restore-StartingBranch -StartingBranch $startingBranch -CurrentBranch $currentBranch

        Write-Host
        Write-Host 'Finished. The upstream branch was updated; the primary branch was left unchanged.'
        Wait-ForClose
        exit 0
    }

    Write-Host
    Write-Host "Updating $primaryBranch while preserving its local-only commits..."

    Invoke-Git -Arguments @('config', "branch.$primaryBranch.remote", 'origin') | Out-Null
    Invoke-Git -Arguments @('config', "branch.$primaryBranch.merge", "refs/heads/$primaryBranch") | Out-Null

    $backupBranch = "$primaryBranch-before-catchup"
    $backupRef = "refs/heads/$backupBranch"
    $completedRebasePendingPush = $false

    if (Test-GitRef -Ref $originPrimaryRef) {
        $localSha = (Get-GitFirstLine -Arguments @('rev-parse', $localPrimaryRef)).Trim()
        $originSha = (Get-GitFirstLine -Arguments @('rev-parse', $originPrimaryRef)).Trim()

        if ($localSha -eq $originSha) {
            Write-Host 'Local and origin primary branches currently match.'
        } else {
            $originIsAncestor = (
                Invoke-Git `
                    -Arguments @('merge-base', '--is-ancestor', $originPrimaryRef, $localPrimaryRef) `
                    -AllowFailure
            ) -eq 0

            $localIsAncestor = (
                Invoke-Git `
                    -Arguments @('merge-base', '--is-ancestor', $localPrimaryRef, $originPrimaryRef) `
                    -AllowFailure
            ) -eq 0

            if ($originIsAncestor) {
                Write-Host "Local $primaryBranch is ahead of origin/$primaryBranch."
            } elseif ($localIsAncestor) {
                Write-Host "Fast-forwarding local $primaryBranch from origin/$primaryBranch..."
                Invoke-Git -Arguments @('merge', '--ff-only', $originPrimaryRef) | Out-Null
            } elseif (Test-GitRef -Ref $backupRef) {
                $backupSha = (Get-GitFirstLine -Arguments @('rev-parse', $backupRef)).Trim()

                if ($backupSha -eq $originSha) {
                    $completedRebasePendingPush = $true
                    Write-Host
                    Write-Host 'Detected a completed local rebase that has not been pushed yet.'
                    Write-Host "origin/$primaryBranch still matches $backupBranch."
                    Write-Host 'The rewritten local history will be pushed with force-with-lease.'
                } else {
                    throw @"
Local $primaryBranch and origin/$primaryBranch have diverged for an unknown reason.
The safety backup $backupBranch does not match origin/$primaryBranch.
Nothing was merged or rewritten.
"@
                }
            } else {
                throw @"
Local $primaryBranch and origin/$primaryBranch have diverged, and no matching
$backupBranch safety reference exists. Nothing was merged or rewritten.
"@
            }
        }
    }

    if (-not $completedRebasePendingPush) {
        Invoke-Git -Arguments @('branch', '-f', $backupBranch, $localPrimaryRef) | Out-Null
    }

    Write-Host
    Write-Host 'Enabling Git rerere so accepted conflict resolutions can be reused...'
    Invoke-Git -Arguments @('config', 'rerere.enabled', 'true') | Out-Null
    Invoke-Git -Arguments @('config', 'rerere.autoupdate', 'true') | Out-Null

    $upstreamAlreadyContained = (
        Invoke-Git `
            -Arguments @('merge-base', '--is-ancestor', $localUpstreamRef, $localPrimaryRef) `
            -AllowFailure
    ) -eq 0

    if ($upstreamAlreadyContained) {
        Write-Host
        Write-Host "$primaryBranch already contains the refreshed upstream history."
        Write-Host 'No additional rebase is needed.'
    } else {
        Write-Host
        Write-Host "Rebasing $primaryBranch-only commits onto the refreshed upstream branch..."
        Write-Host 'This preserves local commits while keeping the history linear.'

        $rebaseCode = Invoke-Git -Arguments @('rebase', $localUpstreamRef) -AllowFailure
        if ($rebaseCode -ne 0) {
        Write-Host
        Write-Host 'The rebase stopped on a real content conflict.'
        Write-Host 'It has been left in progress so you can resolve it.'
        Write-Host
        Write-Host 'Next steps:'
        Write-Host '  1. git status'
        Write-Host '  2. Edit each UU file and remove the conflict markers.'
        Write-Host '  3. git add <resolved files>'
        Write-Host '  4. git rebase --continue'
        Write-Host '  5. Repeat until the rebase finishes.'
        Write-Host "  6. git push --force-with-lease origin ${localPrimaryRef}:refs/heads/$primaryBranch"
        Write-Host
        Write-Host 'To abandon the update:'
        Write-Host '  git rebase --abort'
            Wait-ForClose
            exit 2
        }
    }

    Write-Host
    Write-Host "Pushing $primaryBranch directly with force-with-lease..."
    Invoke-Git -Arguments @(
        'push',
        '--force-with-lease',
        'origin',
        "${localPrimaryRef}:refs/heads/$primaryBranch"
    ) | Out-Null

    Write-Host
    Write-Host "$primaryBranch was rebased onto upstream and pushed directly."
    Write-Host 'No pull request or merge commit was created.'

    $currentBranch = (Get-GitFirstLine -Arguments @('branch', '--show-current')).Trim()
    Restore-StartingBranch -StartingBranch $startingBranch -CurrentBranch $currentBranch

    Write-Host
    Write-Host 'Finished.'
    Invoke-Git -Arguments @('branch', '-vv') | Out-Null
    Wait-ForClose
    exit 0
}
catch {
    Write-Error $_
    Wait-ForClose
    exit 1
}
