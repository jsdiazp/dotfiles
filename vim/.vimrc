" vim-plug

" Install vim-plug if not found
let data_dir = has('nvim') ? stdpath('data') . '/site' : '~/.vim'
if empty(glob(data_dir . '/autoload/plug.vim'))
  silent execute '!curl -fLo '.data_dir.'/autoload/plug.vim --create-dirs  https://raw.githubusercontent.com/junegunn/vim-plug/master/plug.vim'
  autocmd VimEnter * PlugInstall --sync | source $MYVIMRC
endif

" Run PlugInstall if plugins are missing
autocmd VimEnter * if len(filter(values(g:plugs), '!isdirectory(v:val.dir)'))
  \| PlugInstall --sync | source $MYVIMRC
\| endif

" Plugins
call plug#begin()

Plug 'catppuccin/vim', { 'as': 'catppuccin' }
Plug 'itchyny/lightline.vim'
Plug 'itchyny/vim-gitbranch'
Plug 'ryanoasis/vim-devicons'
Plug 'airblade/vim-gitgutter'
Plug 'liuchengxu/vim-which-key'
Plug 'preservim/nerdtree'
Plug 'neoclide/coc.nvim', { 'branch': 'release' }
Plug 'dense-analysis/ale'
Plug 'junegunn/fzf', { 'do': { -> fzf#install() } }
Plug 'junegunn/fzf.vim'

call plug#end()

" Enable spell check and, if necessary, prompt to download missing languages
autocmd VimEnter * ++once ++nested set spell spelllang=en,es

" Required
source $VIMRUNTIME/defaults.vim " Calls the default Vim configuration
set nocompatible " Disable vi compatibility
set hidden " Hide the buffer when leaving it, keeping the changes
set undofile " Save change history to a file
set autoread " Automatically reread the file if changes are detected outside Vim and it has not been modified within Vim
set encoding=utf-8 " Set the character encoding used in Vim
set timeoutlen=500 " Set the time in milliseconds to wait to complete a key code or key sequence
let g:mapleader = "\<Space>"

" Netrw
" let g:netrw_liststyle=3 " Select tree style
" let g:netrw_preview=1 " Show preview in a vertical split
" let g:netrw_browse_split=4 " Open files in the last opened window
" let g:netrw_winsize=25 " Define its size
" let g:netrw_keepdir=0 " Keep the opening directory
" inoremap <c-b> <Esc>:Lex<cr>:vertical resize 30<cr>
" nnoremap <c-b> <Esc>:Lex<cr>:vertical resize 30<cr>

" Interface
syntax on " Highlight code
colorscheme catppuccin_mocha " Set color palette, recommended: catppuccin_mocha, habamax, pablo, slate, sorbet, wildcharm, and zaibatsu
set termguicolors
if !has('gui_running')
  set t_Co=256
endif
set confirm " Show a dialog asking for confirmation before operations that would normally fail, e.g., ':q' and ':e'
set background=dark " Set a black background
set mouse=a " Enable mouse usage
set ttymouse=sgr
set number " Show line numbers
set relativenumber " Show relative line numbers from the cursor position
set showcmd " Show the command being used at the bottom right
set showmatch " Show matching parentheses
set shortmess-=S " Show the number of search results
set wildmenu " Show a command menu with <Tab>
set cursorline " Highlight the cursor position
set ruler " Show the cursor position at the bottom right
set list " Useful to see the difference between tabs, spaces, and whitespace
set listchars=leadmultispace:│\ ,tab:│\ ,trail:· " Show ( ¦ | ┊ | │ | \| ) for each indentation
set laststatus=2 " Always show the status line
set hlsearch " Highlight search matches
set incsearch " Highlight matches as the search word is typed
set noshowmode " Don't show the editing mode to avoid repetition with 'lightline'

" Colors
highlight Normal guibg=NONE " Transparent background color
highlight SignColumn guibg=NONE ctermbg=NONE
highlight SpecialKey ctermbg=NONE ctermfg=NONE guifg=#45475A term=NONE
highlight VertSplit term=reverse ctermfg=243 ctermbg=243 guifg=#2C323D guibg=#2C323D

" Search
set ignorecase " Ignore case in searches
set smartcase " Only ignore case if all letters are lowercase

" Indentation
set expandtab " Convert <Tab> to <Space>
set tabstop=2 " <Space> taken by a <Tab>
set softtabstop=2 " <Space> taken by a <Tab> in editing, e.g., <Tab> or <BS>
set shiftwidth=2 "  <Space> taken by a <Tab> in (auto)indentation
set backspace=2 " Influences the behavior of <BS>, <Del>, CTRL-W, and CTRL-U in INSERT mode
set smartindent " Enable smart indentation
set autoindent " Copy the current line's indentation

" Folding
set foldmethod=syntax " Syntax-based folding
set foldlevelstart=99 " Don't fold anything when opening a file

" Scrolling
set scrolloff=10 " Set the minimum number of lines to keep above and below the cursor

" Plugin configuration
source ~/.config/vim/plugins/ale.vim
source ~/.config/vim/plugins/lightline.vim
source ~/.config/vim/plugins/vim-devicons.vim
source ~/.config/vim/plugins/vim-which-key.vim
source ~/.config/vim/plugins/nerdtree.vim
source ~/.config/vim/plugins/coc.vim