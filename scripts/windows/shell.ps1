# shell.ps1 — provision a Windows shell (tools, prompt, vim).
#
# Refactor notes:
#   - Configuration as data: $WingetTools manifest + $ProfileBlocks table
#     replace 13 copy-pasted `if (-Not (Get-Command ...)) { winget ... }`
#     blocks and 6 raw `>> $PROFILE` appends.
#   - Idempotency: $PROFILE is backed up (never deleted) and edited via
#     Add-ProfileBlock markers; starship.toml is backed up before overwrite;
#     vim plugin dir is resolved under $HOME (not .\ relative to CWD).
#   - Bug fixes: no hardcoded `vim91` path (resolved dynamically), repo files
#     resolved from $PSScriptRoot (not CWD), `Read-YesNo` accepts Y/yes,
#     winget calls are non-interactive, `return` used instead of `exit`
#     inside functions.

#Requires -Version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. "$PSScriptRoot/lib/Common.ps1"

$RepoRoot = Join-Path $PSScriptRoot '../..' | Resolve-Path | Select-Object -ExpandProperty Path

# Declarative tool manifest: Test = command probe, Id = winget id.
$WingetTools = @(
  @{ Test = 'bat';       Id = 'sharkdp.bat';            Comment = 'bat' }
  @{ Test = 'btm';       Id = 'Clement.bottom';         Comment = 'bottom (resource monitor)' }
  @{ Test = 'bun';       Id = 'Oven-sh.Bun';            Comment = 'bun (JavaScript runtime)' }
  @{ Test = 'fd';        Id = 'sharkdp.fd';             Comment = 'fd (find alternative)' }
  @{ Test = 'fzf';       Id = 'junegunn.fzf';           Comment = 'fzf' }
  @{ Test = 'git';       Id = 'Git.Git';                Comment = 'Git' }
  @{ Test = 'lsd';       Id = 'lsd-rs.lsd';             Comment = 'lsd (ls alternative)' }
  @{ Test = 'fastfetch'; Id = 'fastfetch';              Comment = 'fastfetch (system info)' }
  @{ Test = 'node';      Id = 'OpenJS.NodeJS.LTS';      Comment = 'Node.js LTS' }
  @{ Test = 'rg';        Id = 'BurntSushi.ripgrep.MSVC'; Comment = 'ripgrep' }
  @{ Test = 'sd';        Id = 'chmln.sd';               Comment = 'sd (sed alternative)' }
  @{ Test = 'starship';  Id = 'Starship.Starship';      Comment = 'Starship (prompt)' }
  @{ Test = 'vim';       Id = 'vim.vim';                Comment = 'Vim' }
  @{ Test = 'zoxide';    Id = 'ajeetdsouza.zoxide';     Comment = 'zoxide (smarter cd)' }
)

function Get-VimExe {
  $cmd = Get-Command vim -ErrorAction SilentlyContinue
  if ($cmd) { return $cmd.Source }
  foreach ($base in @($env:ProgramFiles, ${env:ProgramFiles(x86)})) {
    if (-not $base) { continue }
    $hit = Get-ChildItem -Path (Join-Path $base 'Vim') -Filter 'vim.exe' -Recurse -ErrorAction SilentlyContinue |
      Select-Object -First 1
    if ($hit) { return $hit.FullName }
  }
  return 'vim'
}

function Install-ShellSection {
  # Backup instead of deleting the whole profile.
  Backup-File $PROFILE | Out-Null

  Ensure-Scoop
  Ensure-PSModule -Name 'PowerShellGet'
  Ensure-PSModule -Name 'PSReadLine'
  Ensure-PSModule -Name 'PSFzf'

  Add-ProfileBlock -Id 'psreadline' -Content @'
# PSReadLine
Set-PSReadlineOption -PredictionViewStyle InlineView
Set-PSReadLineKeyHandler -Key UpArrow -Function HistorySearchBackward
Set-PSReadLineKeyHandler -Key DownArrow -Function HistorySearchForward
Set-PSReadLineKeyHandler -Key Tab -Function MenuComplete
'@

  foreach ($tool in $WingetTools) {
    Ensure-WingetTool -Test $tool.Test -Id $tool.Id -Comment $tool.Comment
  }

  Add-ProfileBlock -Id 'fzf' -Content @'
# fzf
Set-PsFzfOption -PSReadlineChordProvider 'Ctrl+t' -PSReadlineChordReverseHistory 'Ctrl+r'
'@

  Add-ProfileBlock -Id 'lsd' -Content @'
# lsd
if (-Not (Test-Path alias:l)) {
  function L_ALIAS { lsd --blocks permission,size,date,name -la $args }
  New-Alias l L_ALIAS
}
'@

  Add-ProfileBlock -Id 'starship' -Content @'
# Starship
Invoke-Expression (&starship init powershell)
'@

  $vimExe = Get-VimExe
  $vimTutor = Join-Path (Split-Path $vimExe -Parent) 'vimtutor.bat'
  Add-ProfileBlock -Id 'vim' -Content @"
# Vim
if (-Not (Test-Path alias:vim)) {
  function VIM_ALIAS { & '$vimExe' `$args }
  New-Alias vim VIM_ALIAS
}
if ((-Not (Test-Path alias:vimtutor)) -and (Test-Path '$vimTutor')) {
  function VIMTUTOR_ALIAS { & '$vimTutor' `$args }
  New-Alias vimtutor VIMTUTOR_ALIAS
}
"@

  Add-ProfileBlock -Id 'zoxide' -Content @'
# zoxide
Invoke-Expression (& { (zoxide init powershell | Out-String) })
'@

  if (Read-YesNo -Prompt 'Do you want to open a new tab in Windows Terminal to view the changes? (y/n)' -Default 'n') {
    wt --window 0 new-tab
    return
  }
}

function Install-StarshipPresetSection {
  if (-not (Assert-Commands @('starship', 'sd'))) { return }

  $configDir = Join-Path $HOME '.config'
  Ensure-Directory $configDir
  $starshipToml = Join-Path $configDir 'starship.toml'
  Backup-File $starshipToml | Out-Null

  starship preset gruvbox-rainbow -o $starshipToml

  # Upstream preset glyphs require a Nerd Font; these edits are key-based
  # (not glyph-based) so they survive preset updates.
  if (Read-YesNo -Prompt 'Do you want to disable the OS icon? (y/n)' -Default 'n') {
    sd '(?s)\[os\][^\[]*?disabled = false' "[os]`ndisabled = true" $starshipToml
  }

  sd '^"Documents" = ' '# "Documents" = ' $starshipToml
  sd '^"Developer" = ' '# "Developer" = ' $starshipToml
}

function Install-VimSection {
  if (-not (Assert-Commands @('git'))) { return }

  $plugPath = Join-Path $HOME 'vimfiles/autoload/plug.vim'
  Ensure-Directory (Split-Path $plugPath -Parent)
  Invoke-WebRequest -UseBasicParsing https://raw.githubusercontent.com/junegunn/vim-plug/master/plug.vim -OutFile $plugPath

  $repoVimrc = Join-Path $RepoRoot 'vim/.vimrc'
  $homeVimrc = Join-Path $HOME '_vimrc'
  Backup-File $homeVimrc | Out-Null
  Copy-Item -Force $repoVimrc $homeVimrc

  $pluginDir = Join-Path $HOME '.config/vim/plugins'
  Ensure-Directory $pluginDir
  Copy-Item -Force (Join-Path $RepoRoot 'vim/plugins/*') $pluginDir
}

function Main {
  if (Read-YesNo -Prompt '1. Do you want to configure your shell? (y/n)' -Default 'n') {
    Install-ShellSection
  }
  if (Read-YesNo -Prompt "2. Do you want to configure the 'gruvbox-rainbow' preset of Starship? (y/n)" -Default 'n') {
    Install-StarshipPresetSection
  }
  if (Read-YesNo -Prompt '3. Do you want to activate a basic configuration for Vim? (y/n)' -Default 'n') {
    Install-VimSection
  }
}

Main
