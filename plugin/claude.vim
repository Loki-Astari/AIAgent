" claude.nvim - AI agent integration for Neovim
" Maintainer: Your Name
" License: MIT

if exists('g:loaded_claude')
  finish
endif
let g:loaded_claude = 1

command! -nargs=? AgentOpen lua require('claude').open(<f-args>)
command! AgentClose lua require('claude').close()
command! -nargs=? AgentToggle lua require('claude').toggle(<f-args>)
