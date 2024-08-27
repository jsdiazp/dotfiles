# Functions

function Show-Title {
  param (
    [String]$title,
    [Boolean]$prependLineBreak = $true,
    [Boolean]$appendLineBreak = $true
  )

  if (-not [string]::IsNullOrWhiteSpace($title)) {
    $formattedTitle = "⚡️$title"

    if ($prependLineBreak) {
      $formattedTitle = "`n$formattedTitle"
    }

    if ($appendLineBreak) {
      $formattedTitle = "$formattedTitle`n"
    }

    Write-Host -ForegroundColor Magenta $formattedTitle
  }
}

# Package Managers

# npm
function Update-Npm {
  if (Get-Command npm -ErrorAction SilentlyContinue) {
    Show-Title -title "Updating npm" -prependLineBreak $false
    npm cache clean --force
    npm update --global
    npm cache clean --force
  } else {
    Write-Host "npm is not installed or not available in the path." -ForegroundColor Yellow
  }
}

# PowerShellGet
function Update-PowerShellModule {
  Show-Title -title "Updating PowerShell Modules"
  try {
    Update-Module
  } catch {
    Write-Host "Error updating PowerShell modules: $_" -ForegroundColor Red
  }
}

# Scoop
function Update-Scoop {
  if (Get-Command scoop -ErrorAction SilentlyContinue) {
    Show-Title -title "Updating Scoop"
    scoop update --all
  } else {
    Write-Host "Scoop is not installed or not available in the path." -ForegroundColor Yellow
  }
}

# WinGet
function Update-WinGet {
  if (Get-Command winget -ErrorAction SilentlyContinue) {
    Show-Title -title "Updating WinGet"
    winget upgrade --all
  } else {
    Write-Host "WinGet is not installed or not available in the path." -ForegroundColor Yellow
  }
}
