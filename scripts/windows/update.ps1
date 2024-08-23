# Functions

function Title {

  param (
    [String]$title,
    [Boolean]$prependLineBreak = $true,
    [Boolean]$appendLineBreak = $true
  )

  $value = ""

  if ($title) {
    $value = "⚡️$title"

    if ($prependLineBreak) {
      $value = "`n$value"
    }

    if ($appendLineBreak) {
      $value = "$value`n"
    }

    Write-Host -ForegroundColor Magenta $value
  }

}

# Package managers

# npm
Title -title "npm" -prependLineBreak $false
npm cache clean --force
npm update --global
npm cache clean --force

# Scoop
Title -title "Scoop"
scoop update --all

# WinGet
Title -title "WinGet"
winget update --all

