" vim-witch-key

" Define prefix dictionary
let g:which_key_map =  {
  \ ',' : [ ':Buffers' , 'Switch Buffer' ],
  \ ':' : [ ':History:' , 'Command History' ],
  \ '/' : [ ':RG' , 'Grep' ],
  \ ' ' : [ ':Files' , 'Find Files' ],
  \ 'w' : { 
    \ 'name' : '+windows',
    \ 's' : [ ':Windows' , 'Switch Window' ],
    \ 'd' : [ '<C-W>c' , 'Delete Window' ],
    \ '-' : ['<C-W>s', 'Split window below'],
    \ '|' : ['<C-W>v', 'Split window right'],
    \ }
  \ }

" To register the descriptions when using the on-demand load feature,
" use the autocmd hook to call which_key#register(), e.g., register for the Space key:
autocmd! User vim-which-key call which_key#register('<Space>', 'g:which_key_map')

" Mappings
nnoremap <silent> <leader> :<c-u>WhichKey '<Space>'<CR>

call which_key#register('<Space>', "g:which_key_map")
