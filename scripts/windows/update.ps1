# update.ps1 — update Windows packages and global tooling.
#
# Patterns: declarative updater registry + Invoke-Step boundary (one failure
# never aborts the run; exit code reflects failure count).

#Requires -Version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. "$PSScriptRoot/lib/Common.ps1"

function Update-Npm {
  Invoke-Step -Name 'Updating npm' -SkipWhen 'npm' -ScriptBlock {
    npm install -g npm@latest
    npm update --global
  }
}

function Update-PowerShellModule {
  Invoke-Step -Name 'Updating PowerShell Modules' -ScriptBlock {
    try {
      Update-Module -ErrorAction Stop
    } catch {
      Write-Host "Error updating PowerShell modules: $_" -ForegroundColor Red
      throw
    }
  }
}

function Update-Scoop {
  Invoke-Step -Name 'Updating Scoop' -SkipWhen 'scoop' -ScriptBlock {
    scoop update *
    scoop cleanup *
    scoop cache rm *
  }
}

function Update-WinGet {
  Invoke-Step -Name 'Updating WinGet' -SkipWhen 'winget' -ScriptBlock {
    winget upgrade --all `
      --include-unknown `
      --silent `
      --disable-interactivity `
      --accept-source-agreements `
      --accept-package-agreements
  }
}

function Main {
  [CmdletBinding()]
  param (
    [string[]]$Only = @('Npm', 'PowerShellModule', 'Scoop', 'WinGet')
  )
  Reset-StepFailures
  Show-Title 'Starting System Updates' -NoPrependBreak
  $updaters = @{
    Npm               = ${function:Update-Npm}
    PowerShellModule  = ${function:Update-PowerShellModule}
    Scoop             = ${function:Update-Scoop}
    WinGet            = ${function:Update-WinGet}
  }
  foreach ($name in $Only) {
    if ($updaters.ContainsKey($name)) {
      & $updaters[$name]
    } else {
      Write-Host "Unknown updater: $name" -ForegroundColor Yellow
    }
  }
  Show-Title 'System Updates Completed'
  $failures = Get-StepFailureCount
  if ($failures -gt 0) {
    Write-Host "Completed with $failures failure(s)." -ForegroundColor Red
    exit 1
  }
}

Main @args
