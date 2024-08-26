# Shell
# Interface to interact with the operating system

$installShell = Read-Host "1. Do you want to configure your shell? y/n"

if ($installShell -eq "y") {
  # Pre-configuration
  if (Test-Path $PROFILE) {
    Remove-Item $PROFILE
  }

  # PSReadLine (https://github.com/PowerShell/PSReadLine)
  # Readline implementation inspired by bash for PowerShell

  ## Pre-requisites
  Install-Module -Name PowerShellGet

  ## Installation
  Install-Module PSReadLine

  ## Configuration
  Write-Output "# PSReadLine
# Set-PSReadlineOption -PredictionViewStyle ListView
Set-PSReadlineOption -PredictionViewStyle InlineView
Set-PSReadLineKeyHandler -Key UpArrow -Function HistorySearchBackward
Set-PSReadLineKeyHandler -Key DownArrow -Function HistorySearchForward
Set-PSReadlineKeyHandler -Key Tab -Function MenuComplete`n" >>$PROFILE

  # Scoop
  # Command-line installer for Windows

  ## Installation
  if (-Not (Get-Command scoop -ErrorAction SilentlyContinue)) {
    Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser
    Invoke-RestMethod -Uri https://get.scoop.sh | Invoke-Expression
  }

  # bat (https://github.com/sharkdp/bat)
  # Displays the content of a file highlighted and formatted

  ## Installation
  if (-Not (Get-Command bat -ErrorAction SilentlyContinue)) {
    winget install --id sharkdp.bat
  }

  # bottom
  # Resource monitor

  ## Installation
  if (-Not (Get-Command btm -ErrorAction SilentlyContinue)) {
    winget install --id Clement.bottom
  }

  # bun (https://github.com/oven-sh/bun)
  # JavaScript runtime

  ## Installation
  scoop install bun

  # fd (https://github.com/sharkdp/fd)
  # Simple, fast, and user-friendly alternative to "find"

  ## Installation
  if (-Not (Get-Command fd -ErrorAction SilentlyContinue)) {
    winget install --id sharkdp.fd
  }

  # fzf (https://github.com/junegunn/fzf)
  # Improves the functionality of <C-r> and <C-t>

  ## Installation
  if (-Not (Get-Command fzf -ErrorAction SilentlyContinue)) {
    winget install --id junegunn.fzf
  }
  Install-Module -Name PSFzf

  ## Configuration
  Write-Output "# fzf
Set-PsFzfOption -PSReadlineChordProvider 'Ctrl+t' -PSReadlineChordReverseHistory 'Ctrl+r'`n" >>$PROFILE

  # Git
  # Version control system

  ## Installation
  if (-Not (Get-Command git -ErrorAction SilentlyContinue)) {
    winget install --id Git.Git
  }

  # lsd (https://github.com/lsd-rs/lsd)
  # Next-generation 'ls' command

  ## Installation
  if (-Not (Get-Command lsd -ErrorAction SilentlyContinue)) {
    winget install --id lsd-rs.lsd
  }

  ## Configuration
  Write-Output "# lsd
if (-Not (Test-Path alias:l)) {
  function L_ALIAS { lsd --blocks permission,size,date,name -la `$args }
  New-Alias l L_ALIAS
}`n" >>$PROFILE

  # fastfetch
  # Displays system information

  ## Instalación
  if (-Not (Get-Command fastfetch -ErrorAction SilentlyContinue)) {
    winget install fastfetch
  }

  # Node.js
  # JavaScript runtime

  ## Installation
  if (-Not (Get-Command node -ErrorAction SilentlyContinue)) {
    winget install --id OpenJS.NodeJS.LTS
  }

  # ripgrep (https://github.com/BurntSushi/ripgrep)
  # Recursively searches directories for a regex pattern respecting gitignore

  ## Installation
  if (-Not (Get-Command rg -ErrorAction SilentlyContinue)) {
    winget install --id BurntSushi.ripgrep.MSVC
  }

  # sd (https://github.com/chmln/sd)
  # Intuitive CLI for search and replace (alternative to 'sed')

  ## Installation
  if (-Not (Get-Command sd -ErrorAction SilentlyContinue)) {
    winget install --id chmln.sd
  }

  # Starship
  # Improves the terminal prompt (input interface)

  ## Installation
  if (-Not (Get-Command starship -ErrorAction SilentlyContinue)) {
    winget install --id Starship.Starship
  }

  ## Configuration
  Write-Output "# Startship
Invoke-Expression (&starship init powershell)`n" >>$PROFILE

  # Vim
  # Text editor

  ## Installation
  if (-Not (Get-Command vim -ErrorAction SilentlyContinue)) {
    winget install --id vim.vim
  }

  ## Configuration
  Write-Output "# Vim
if (-Not (Test-Path alias:vim)) {
  function VIM_ALIAS { & 'C:\Program Files\Vim\vim91\vim.exe' `$args }
  New-Alias vim VIM_ALIAS
}
if (-Not (Test-Path alias:vimtutor)) {
  function VIMTUTOR_ALIAS { & 'C:\Program Files\Vim\vim91\vimtutor.bat' `$args }
  New-Alias vimtutor VIMTUTOR_ALIAS
}`n" >>$PROFILE

  # zoxide
  # Smarter cd command, inspired by z and autojump

  ## Installation
  if (-Not (Get-Command zoxide -ErrorAction SilentlyContinue)) {
    winget install --id ajeetdsouza.zoxide
  }

  ## Configuration
  Write-Output "# zoxide
Invoke-Expression (& { (zoxide init powershell | Out-String) })`n" >>$PROFILE

  # Open a new tab in Windows Terminal
  $openWindowsTab = Read-Host "> Do you want to open a new tab in Windows Terminal to view the changes? y/n"

  if ($openWindowsTab -eq "y") {
    wt --window 0 new-tab
    exit
  }
}

$setupStarshipPreset = Read-Host "2. Do you want to configure the 'gruvbox-rainbow' preset of Starship? y/n"

if (
  $setupStarshipPreset -eq "y"
) {
  $requirements = 'starship', 'sd'

  foreach ($requirement in $requirements) {
    if (-Not (Get-Command $requirement -ErrorAction SilentlyContinue)) {
      Write-Output "ERROR: Command $requirement not found"
      exit
    }
  }

  if (-Not (Test-Path $HOME\.config)) {
    New-Item -ItemType Directory $HOME\.config 
  }

  starship preset gruvbox-rainbow -o $HOME\.config\starship.toml 

  $removeSystemIcon = Read-Host "> Do you want to disable the system icon? y/n"

  if ($removeSystemIcon -eq "y") {
    sd '\[os\].*\ndisabled\ = false' '[os]\ndisabled = true' $HOME\.config\starship.toml
  }
  else {
    sd 'Windows = "󰍲"' 'Windows = ""' $HOME\.config\starship.toml
  }

  sd '"Documents" = "󰈙 "' '# "Documents" = "󰈙 "' $HOME\.config\starship.toml
  sd '"Music" = "󰝚 "' '"Music" = " "' $HOME\.config\starship.toml
  sd '"Developer" = "󰲋 "' '# "Developer" = "󰲋 "' $HOME\.config\starship.toml
}

$setupVimrc = Read-Host "3. Do you want to activate a basic configuration for Vim? y/n"

if ($setupVimrc -eq "y") {
  $requirements = 'git'

  foreach ($requirement in $requirements) {
    if (-Not (Get-Command $requirement -ErrorAction SilentlyContinue)) {
      Write-Output "ERROR: Command $requirement not found"
      exit
    }
  }

  Invoke-WebRequest -useb https://raw.githubusercontent.com/junegunn/vim-plug/master/plug.vim |`
    New-Item $HOME/vimfiles/autoload/plug.vim -Force

  git clone https://github.com/jsdiazp/dotfiles

  Copy-Item dotfiles/vim/.vimrc ~/_vimrc

  Write-Output (Get-Content ~/_vimrc | Where-Object {
    -not ($_.ReadCount -ge 3 -and $_.ReadCount -le 9)
  }) >~/_vimrc

  if (-Not (Test-Path ~\.config\vim\plugins)) {
    New-Item -ItemType Directory -Path .\.config\vim\plugins -Force
  }
  Copy-Item dotfiles/vim/plugins/* ~/.config/vim/plugins

  Remove-Item -Force dotfiles
}
