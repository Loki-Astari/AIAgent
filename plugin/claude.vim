" claude.nvim - AI agent integration for Neovim
" Maintainer: Your Name
" License: MIT

if exists('g:loaded_claude')
  finish
endif
let g:loaded_claude = 1

command! -nargs=* AgentOpen lua require('claude').open(<f-args>)
command! -nargs=? AgentClose lua require('claude').close(<f-args>)
command! -nargs=* AgentToggle lua require('claude').toggle(<f-args>)
command! -nargs=1 AgentSwitch lua require('claude').switch(<q-args>)
command! AgentList lua require('claude').print_list()
command! AgentCloseAll lua require('claude').close_all()
