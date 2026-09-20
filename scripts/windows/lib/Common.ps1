# Common.ps1 — shared foundation for dotfiles Windows scripts.
#
# Patterns:
#   - Single source of truth: Show-Title, Test-Command, Backup-File,
#     Add-ProfileBlock, Ensure-WingetTool, Ensure-ScoopTool,
#     Ensure-PSModule, Assert-Commands, Invoke-Step.
#   - Configuration as data: callers declare tool manifests; this file owns
#     the install/upgrade mechanics (Strategy over winget/scoop).
#   - Idempotency: profile edits are marker-guarded (no duplicate blocks on
#     re-run); file overwrites always back up first.
#   - Fail-fast boundary: Invoke-Step collects per-step failures so one
#     ecosystem never aborts the whole run silently.

#Requires -Version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:StepFailures = 0

function Show-Title {
  [CmdletBinding()]
  param (
    [Parameter(Mandatory)][string]$Title,
    [switch]$NoPrependBreak,
    [switch]$NoAppendBreak
  )
  if ([string]::IsNullOrWhiteSpace($Title)) { return }
  $text = "⚡️ $Title"
  if (-not $NoPrependBreak) { $text = "`n$text" }
  if (-not $NoAppendBreak) { $text = "$text`n" }
  Write-Host $text -ForegroundColor Magenta
}

function Test-Command {
  [CmdletBinding()]
  param ([Parameter(Mandatory)][string]$Name)
  return [bool](Get-Command $Name -ErrorAction SilentlyContinue)
}

function Backup-File {
  [CmdletBinding()]
  param ([Parameter(Mandatory)][string]$Path)
  if (Test-Path $Path) {
    $stamp = Get-Date -Format 'yyyyMMddHHmmss'
    $backup = "$Path.bak-$stamp"
    Copy-Item -Force $Path $backup
    Write-Host "Backup: $Path -> $backup" -ForegroundColor DarkGray
    return $backup
  }
  return $null
}

function Ensure-Directory {
  [CmdletBinding()]
  param ([Parameter(Mandatory)][string]$Path)
  if (-not (Test-Path $Path)) {
    New-Item -ItemType Directory -Force $Path | Out-Null
  }
}

# Add-ProfileBlock — idempotent $PROFILE edit guarded by markers.
# Replaces raw `Write-Output ... >> $PROFILE` (which duplicated blocks).
function Add-ProfileBlock {
  [CmdletBinding()]
  param (
    [Parameter(Mandatory)][string]$Id,
    [Parameter(Mandatory)][string]$Content,
    [string]$ProfilePath = $PROFILE
  )
  $begin = "# >>> dotfiles:$Id >>>"
  $end = "# <<< dotfiles:$Id <<<"
  Ensure-Directory (Split-Path $ProfilePath -Parent)
  if (-not (Test-Path $ProfilePath)) {
    New-Item -ItemType File -Force $ProfilePath | Out-Null
  }
  $current = Get-Content $ProfilePath -Raw -ErrorAction SilentlyContinue
  if ($null -ne $current -and $current.Contains($begin)) { return }
  Add-Content $ProfilePath "`n$begin`n$Content`n$end`n"
}

function Assert-Commands {
  [CmdletBinding()]
  param ([Parameter(Mandatory)][string[]]$Names)
  $missing = @($Names | Where-Object { -not (Test-Command $_) })
  if ($missing.Count -gt 0) {
    Write-Host ("ERROR: missing commands: " + ($missing -join ', ')) -ForegroundColor Red
    return $false
  }
  return $true
}

# Invoke-Step — Template-Method boundary: title + try/catch + failure count.
function Invoke-Step {
  [CmdletBinding()]
  param (
    [Parameter(Mandatory)][string]$Name,
    [Parameter(Mandatory)][scriptblock]$ScriptBlock,
    [string]$SkipWhen,      # command name; step is skipped when absent
    [string]$SkipMessage
  )
  if ($SkipWhen -and -not (Test-Command $SkipWhen)) {
    if ([string]::IsNullOrEmpty($SkipMessage)) {
      $SkipMessage = "Skipping $Name ($SkipWhen not installed)."
    }
    Write-Host $SkipMessage -ForegroundColor DarkGray
    return
  }
  Show-Title -title $Name
  try {
    & $ScriptBlock
  } catch {
    Write-Host "Step failed: $Name — $_" -ForegroundColor Red
    $script:StepFailures++
  }
}

function Get-StepFailureCount {
  return $script:StepFailures
}

function Reset-StepFailures {
  $script:StepFailures = 0
}

# --- Installer strategies ---------------------------------------------------

$script:WingetCommonArgs = @(
  '--exact',
  '--silent',
  '--disable-interactivity',
  '--accept-source-agreements',
  '--accept-package-agreements'
)

function Ensure-WingetTool {
  [CmdletBinding()]
  param (
    [Parameter(Mandatory)][string]$Test,   # command to probe
    [Parameter(Mandatory)][string]$Id,     # winget id
    [string]$Comment
  )
  if (Test-Command $Test) { return }
  if (-not (Test-Command 'winget')) {
    Write-Host 'WinGet is not installed or not available in the path.' -ForegroundColor Yellow
    return
  }
  if ([string]::IsNullOrEmpty($Comment)) { $label = $Test } else { $label = $Comment }
  Show-Title -title "Installing $label"
  # Copy to a local before splatting (scoped-variable splats vary by host).
  $commonArgs = $script:WingetCommonArgs
  winget install --id $Id @commonArgs
}

function Ensure-ScoopTool {
  [CmdletBinding()]
  param (
    [Parameter(Mandatory)][string]$Test,
    [Parameter(Mandatory)][string]$App,
    [string]$Comment
  )
  if (Test-Command $Test) { return }
  if (-not (Test-Command 'scoop')) {
    Write-Host 'Scoop is not installed or not available in the path.' -ForegroundColor Yellow
    return
  }
  if ([string]::IsNullOrEmpty($Comment)) { $label = $Test } else { $label = $Comment }
  Show-Title -title "Installing $label"
  scoop install $App
}

function Ensure-PSModule {
  [CmdletBinding()]
  param ([Parameter(Mandatory)][string]$Name)
  Show-Title -title "Ensuring PowerShell module $Name"
  if (-not (Get-PackageProvider -Name NuGet -ErrorAction SilentlyContinue)) {
    Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force | Out-Null
  }
  $repo = Get-PSRepository -Name PSGallery -ErrorAction SilentlyContinue
  if ($null -eq $repo -or $repo.InstallationPolicy -ne 'Trusted') {
    Set-PSRepository -Name PSGallery -InstallationPolicy Trusted
  }
  Install-Module -Name $Name -Scope CurrentUser -Force -AllowClobber
}

function Ensure-Scoop {
  if (Test-Command 'scoop') { return }
  Show-Title -title 'Installing Scoop'
  Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser -Force
  Invoke-RestMethod -Uri https://get.scoop.sh | Invoke-Expression
}

function Read-YesNo {
  [CmdletBinding()]
  param (
    [Parameter(Mandatory)][string]$Prompt,
    [string]$Default = 'n'
  )
  $answer = Read-Host "$Prompt [$Default]"
  if ([string]::IsNullOrWhiteSpace($answer)) { $answer = $Default }
  return $answer.Trim().ToLower() -in @('y', 'yes')
}
