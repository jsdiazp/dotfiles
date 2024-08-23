" Lightline

" Curvy
" let g:lightline = {
"     \ 'colorscheme': 'one',
"     \ 'separator': { 'left': "\ue0b4", 'right': "\ue0b6" },
"     \ 'subseparator': { 'left': "\ue0b5", 'right': "\ue0b7" },
"     \ 'component_function': {
"       \   'filetype': 'MyFiletype',
"       \   'fileformat': 'MyFileformat',
"     \ },
"     \ 'component': {
"       \ 'lineinfo': '%3l:%-2c',
"     \ }
"   \ }

" Angly
let g:lightline = {
    \ 'colorscheme': 'one',
    \ 'separator': { 'left': "\ue0b8", 'right': "\ue0ba" },
    \ 'subseparator': { 'left': "\ue0b9", 'right': "\ue0bb" },
    \ 'active': {
      \ 'left': [ 
      \ [ 'mode', 'paste' ],
      \ [ 'gitbranch', 'readonly', 'filename', 'modified' ] ]
    \ },
    \ 'component_function': {
      \ 'filetype': 'MyFiletype',
      \ 'fileformat': 'MyFileformat',
      \ 'gitbranch': 'gitbranch#name'
    \ },
    \ 'component': {
      \ 'lineinfo': '%3l:%-2c',
    \ }
  \ }
