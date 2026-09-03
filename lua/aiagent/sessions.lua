---@diagnostic disable: undefined-global
--- Past sessions: find any Claude Code session on this machine and load it back
--- into an agent.
---
--- Claude Code keeps one transcript per session under
--- `~/.claude/projects/<slugified-cwd>/<session-id>.jsonl` and never deletes
--- them, so every conversation ever held is still on disk — including the one
--- whose terminal you closed.  This module lists them searchably and hands the
--- choice to `aiagent.session_load()`.
---
--- Nothing here writes to a transcript.  Loading a session resumes it with
--- `--fork-session`, so the archive is left exactly as it was and can be loaded
--- again, as often as you like.  Choosing a point *inside* a session is
--- |AgentTree|'s job — `<C-t>` on a row opens it.
local M = {}

local uv = vim.uv or vim.loop
local ns = vim.api.nvim_create_namespace('AIAgentSessions')

M.view = nil  -- { win, buf, rows } while the fallback list is open

----------------------------------------------------------------------------
-- Scanning
----------------------------------------------------------------------------

--- Root of Claude Code's transcript store.
---@return string
function M.projects_dir()
  return vim.fn.expand('~/.claude/projects')
end

--- Summarise one transcript, cheaply enough to do it for every session on the
--- machine on every keypress-free open.
---
--- The file is streamed and only the lines that can carry what the list needs
--- get decoded.  Two prefilters do the work: `"type":"user"` (assistant and
--- tool entries outnumber prompts by more than 20:1 and would otherwise
--- dominate the scan) and `"ai-title"` (Claude Code's own name for the
--- session — a far better label than anything we could derive).  `cwd` and
--- `gitBranch` are lifted with a string match instead, because they repeat on
--- nearly every entry and decoding for them would mean decoding the whole file.
---@param path string
---@return table|nil entry { id, path, project, cwd, branch, title, prompt, last, turns, mtime }
function M.inspect(path)
  local stat = uv.fs_stat(path)
  if not stat or stat.type ~= 'file' then return nil end
  local fh = io.open(path, 'r')
  if not fh then return nil end

  local human = require('aiagent.registry')._human_text
  local title, cwd, branch, prompt, last, turns = nil, nil, nil, nil, nil, 0

  for line in fh:lines() do
    if line:find('"type":"user"', 1, true) then
      local ok, entry = pcall(vim.json.decode, line)
      if ok and type(entry) == 'table' and not entry.isSidechain and not entry.isMeta then
        local text = human(entry.message)
        if text then
          turns = turns + 1
          prompt = prompt or text
          last = text
        end
      end
    elseif line:find('"ai-title"', 1, true) then
      local ok, entry = pcall(vim.json.decode, line)
      if ok and type(entry) == 'table' and type(entry.aiTitle) == 'string' then
        title = entry.aiTitle  -- rewritten as the session goes on; the last wins
      end
    end
    if not cwd then cwd = line:match('"cwd":"(.-)"') end
    if not branch then branch = line:match('"gitBranch":"(.-)"') end
  end
  fh:close()

  return {
    id = vim.fn.fnamemodify(path, ':t:r'),
    path = path,
    project = vim.fn.fnamemodify(vim.fn.fnamemodify(path, ':h'), ':t'),
    cwd = cwd,
    branch = branch ~= '' and branch or nil,
    title = title,
    prompt = prompt,
    last = last,
    turns = turns,
    mtime = stat.mtime and stat.mtime.sec or 0,
    size = stat.size,
  }
end

--- Session ids currently held by a running agent anywhere on this machine.
--- Read from the registry rather than guessed: those sessions are still being
--- written to, and a row for one should say so.
---@return table<string,boolean>
local function live_sessions()
  local out = {}
  local ok, entries = pcall(function()
    return require('aiagent.registry').read_all({ derive = false })
  end)
  if not ok or not entries then return out end
  for _, e in ipairs(entries) do
    if e.session then out[e.session] = true end
  end
  return out
end

--- Every session on this machine, newest first.
---
--- Sessions with no prompt in them are dropped unless `all`: Claude Code leaves
--- a stub transcript behind for every start that never got a question, and they
--- outnumber the real ones.
---@param opts table|nil { all: boolean|nil, limit: number|nil }
---@return table[] entries
function M.scan(opts)
  opts = opts or {}
  local root = M.projects_dir()
  if vim.fn.isdirectory(root) == 0 then return {} end

  local live = live_sessions()
  local entries = {}
  for _, path in ipairs(vim.fn.glob(root .. '/*/*.jsonl', true, true)) do
    local entry = M.inspect(path)
    if entry and (opts.all or entry.turns > 0) then
      entry.live = live[entry.id] or false
      table.insert(entries, entry)
    end
  end

  table.sort(entries, function(a, b) return a.mtime > b.mtime end)
  if opts.limit and #entries > opts.limit then
    entries = vim.list_slice(entries, 1, opts.limit)
  end
  return entries
end

----------------------------------------------------------------------------
-- Rendering
----------------------------------------------------------------------------

local function ensure_highlights()
  vim.api.nvim_set_hl(0, 'AIAgentSessionLive',    { link = 'Special' })
  vim.api.nvim_set_hl(0, 'AIAgentSessionTime',    { link = 'Comment' })
  vim.api.nvim_set_hl(0, 'AIAgentSessionTurns',   { link = 'Number' })
  vim.api.nvim_set_hl(0, 'AIAgentSessionTitle',   { link = 'Identifier' })
  vim.api.nvim_set_hl(0, 'AIAgentSessionPrompt',  { link = 'Normal' })
  vim.api.nvim_set_hl(0, 'AIAgentSessionProject', { link = 'Comment' })
end

--- When a session was last touched, widening from clock to weekday to date as
--- it ages.  Matches the history tree's column so the two popups read alike.
---@param epoch number|nil
---@return string
local function when(epoch)
  if type(epoch) ~= 'number' or epoch <= 0 then return '' end
  local diff = os.difftime(os.time(), epoch)
  local fmt = (diff < 43200 and '%H:%M') or (diff < 604800 and '%a %H:%M') or '%b %d'
  return tostring(os.date(fmt, epoch))
end

local function truncate(text, width)
  if width < 2 then return '' end
  if vim.fn.strdisplaywidth(text) <= width then return text end
  return vim.fn.strcharpart(text, 0, width - 1) .. '…'
end

local function pad(text, width)
  local gap = width - vim.fn.strdisplaywidth(text)
  return gap > 0 and (text .. string.rep(' ', gap)) or text
end

--- Where a session lived: the worktree or repo basename, not the whole path.
---@param entry table
---@return string
local function place(entry)
  if entry.cwd and entry.cwd ~= '' then
    return vim.fn.fnamemodify(entry.cwd:gsub('/$', ''), ':t')
  end
  return entry.project or ''
end

local TITLE_W, PLACE_W = 26, 16

--- One row: marker, time, prompt count, Claude's title, the opening prompt, and
--- where it ran.
---
--- Pure, and returns byte offsets for the highlight ranges while padding in
--- display width — the `●` marker is three bytes and one cell, so conflating
--- the two shifts every highlight after it.
---@param entry table
---@param width number
---@return string line, table[] highlights  -- { col, end_col, group }
function M.format(entry, width)
  local hls = {}
  local out = ''
  local function add(text, group)
    if group and vim.trim(text) ~= '' then
      table.insert(hls, { col = #out, end_col = #out + #text, group = group })
    end
    out = out .. text
  end

  add(entry.live and '● ' or '  ', 'AIAgentSessionLive')
  add(string.format('%8s  ', when(entry.mtime)), 'AIAgentSessionTime')
  add(string.format('%3d  ', entry.turns or 0), 'AIAgentSessionTurns')
  add(pad(truncate(entry.title or '—', TITLE_W), TITLE_W) .. '  ', 'AIAgentSessionTitle')

  local used = vim.fn.strdisplaywidth(out) + PLACE_W + 2
  local avail = math.max(10, width - used)
  add(pad(truncate(entry.prompt or '', avail), avail) .. '  ', 'AIAgentSessionPrompt')
  add(truncate(place(entry), PLACE_W), 'AIAgentSessionProject')

  return (out:gsub('%s+$', '')), hls
end

--- Build the list body.  Pure, so it is unit tested without a window.
---@param entries table[]
---@param opts table|nil { width }
---@return string[] lines, table[] highlights, table[] rows  -- rows[i].entry
function M.render(entries, opts)
  opts = opts or {}
  local width = opts.width or 110
  local lines, hls, rows = {}, {}, {}
  for i, entry in ipairs(entries) do
    local line, row_hls = M.format(entry, width)
    lines[i] = line
    rows[i] = { entry = entry }
    for _, h in ipairs(row_hls) do
      table.insert(hls, { line = i - 1, col = h.col, end_col = h.end_col, group = h.group })
    end
  end
  return lines, hls, rows
end

--- Everything a search should match on: Claude's title, the first and last
--- prompt, where it ran, and the id (so a session can be pasted in by hand).
---@param entry table
---@return string
function M.search_text(entry)
  return table.concat({
    entry.title or '', entry.prompt or '', entry.last or '',
    place(entry), entry.project or '', entry.branch or '', entry.id,
  }, ' ')
end

----------------------------------------------------------------------------
-- Preview
----------------------------------------------------------------------------

-- Parsing a multi-megabyte transcript for the preview pane is too slow to
-- repeat as the cursor moves, and a transcript that is not being written to
-- cannot change under us.  Keyed by id, cleared when the picker opens.
local _preview_cache = {}

--- Fill `buf` with a session's history tree.
---@param buf number
---@param entry table
---@param width number
local function preview_into(buf, entry, width)
  if not vim.api.nvim_buf_is_valid(buf) then return end
  local history = require('aiagent.history')
  local cached = _preview_cache[entry.id]
  if not cached then
    local tree = history.build(history.parse(entry.path))
    if tree then
      local lines, hls = history.render(tree, { width = width })
      cached = { lines = lines, hls = hls }
    else
      cached = { lines = { '  (no turns recorded in this session)' }, hls = {} }
    end
    _preview_cache[entry.id] = cached
  end

  local header = {
    '  ' .. (entry.title or entry.id),
    '  ' .. (entry.cwd or entry.project or '') ..
      (entry.branch and ('  (' .. entry.branch .. ')') or ''),
    '',
  }
  local lines = vim.list_extend(vim.list_slice(header), cached.lines)
  vim.api.nvim_set_option_value('modifiable', true, { buf = buf })
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.api.nvim_set_option_value('modifiable', false, { buf = buf })
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  for _, h in ipairs(cached.hls) do
    pcall(vim.api.nvim_buf_set_extmark, buf, ns, h.line + #header, h.col,
      { end_col = h.end_col, hl_group = h.group })
  end
end

----------------------------------------------------------------------------
-- The picker
----------------------------------------------------------------------------

--- What selecting a row does, in one place so both pickers agree.
local function on_select(entry)
  require('aiagent').session_load(entry)
end

local function on_tree(entry)
  require('aiagent').history_open(entry.id)
end

--- Telescope picker, when telescope is installed.  Returns false when it is
--- not, so the caller can fall back.
---@param entries table[]
---@param opts table|nil
---@return boolean shown
local function pick_telescope(entries, opts)
  local ok, pickers = pcall(require, 'telescope.pickers')
  if not ok then return false end
  local finders       = require('telescope.finders')
  local conf          = require('telescope.config').values
  local actions       = require('telescope.actions')
  local action_state  = require('telescope.actions.state')
  local previewers    = require('telescope.previewers')

  local width = math.max(60, math.floor(vim.o.columns * 0.45))

  pickers.new(opts and opts.telescope or {}, {
    prompt_title = 'Past sessions  (<CR> load · <C-t> history tree)',
    finder = finders.new_table({
      results = entries,
      entry_maker = function(e)
        local line = M.format(e, width)
        return {
          value = e,
          display = line,
          ordinal = M.search_text(e),
          path = e.path,
        }
      end,
    }),
    sorter = conf.generic_sorter({}),
    previewer = previewers.new_buffer_previewer({
      title = 'Session history',
      define_preview = function(self, entry)
        preview_into(self.state.bufnr, entry.value,
          math.max(40, vim.api.nvim_win_get_width(self.state.winid) - 2))
      end,
    }),
    attach_mappings = function(bufnr, map)
      actions.select_default:replace(function()
        local sel = action_state.get_selected_entry()
        actions.close(bufnr)
        if sel then vim.schedule(function() on_select(sel.value) end) end
      end)
      -- <C-t> is telescope's open-in-tab by default; a session's history tree
      -- is the more useful thing to reach from here.
      local function tree()
        local sel = action_state.get_selected_entry()
        actions.close(bufnr)
        if sel then vim.schedule(function() on_tree(sel.value) end) end
      end
      map('i', '<C-t>', tree)
      map('n', '<C-t>', tree)
      return true
    end,
  }):find()
  return true
end

function M.close_view()
  local v = M.view
  M.view = nil
  if not v then return end
  if v.win and vim.api.nvim_win_is_valid(v.win) then
    pcall(vim.api.nvim_win_close, v.win, true)
  end
  if v.buf and vim.api.nvim_buf_is_valid(v.buf) then
    pcall(vim.api.nvim_buf_delete, v.buf, { force = true })
  end
end

--- Fallback list: the plugin's own float, in the shape of the other popups.
--- Not `vim.ui.select` — see the note on `history.menu`.  Searching is `/`,
--- which is what a scratch buffer gives for free.
---@param entries table[]
local function pick_float(entries)
  M.close_view()
  ensure_highlights()

  local width = math.min(120, vim.o.columns - 8)
  local lines, hls, rows = M.render(entries, { width = width })
  local title = ' Past sessions  (<CR> load · t history tree · / search · q close) '

  local w = vim.fn.strdisplaywidth(title)
  for _, l in ipairs(lines) do w = math.max(w, vim.fn.strdisplaywidth(l)) end
  w = math.min(w + 2, vim.o.columns - 4)
  local height = math.max(1, math.min(#lines, math.min(40, math.floor(vim.o.lines * 0.8))))

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  for _, h in ipairs(hls) do
    pcall(vim.api.nvim_buf_set_extmark, buf, ns, h.line, h.col,
      { end_col = h.end_col, hl_group = h.group })
  end
  vim.api.nvim_set_option_value('modifiable', false, { buf = buf })
  vim.api.nvim_set_option_value('filetype', 'aiagentsessions', { buf = buf })

  local win = vim.api.nvim_open_win(buf, true, {
    relative = 'editor',
    row = math.max(0, math.floor((vim.o.lines - height) / 2) - 1),
    col = math.max(0, math.floor((vim.o.columns - w) / 2)),
    width = w,
    height = height,
    style = 'minimal',
    border = 'rounded',
    title = title,
    title_pos = 'center',
  })
  vim.api.nvim_set_option_value('cursorline', true, { win = win })

  M.view = { win = win, buf = buf, rows = rows }

  local function under_cursor()
    local v = M.view
    if not v then return nil end
    local row = v.rows[vim.api.nvim_win_get_cursor(v.win)[1]]
    return row and row.entry
  end
  local function map(lhs, fn)
    vim.keymap.set('n', lhs, fn, { buffer = buf, nowait = true, silent = true })
  end
  map('q', M.close_view)
  map('<Esc>', M.close_view)
  map('<CR>', function()
    local entry = under_cursor()
    M.close_view()
    if entry then vim.schedule(function() on_select(entry) end) end
  end)
  map('t', function()
    local entry = under_cursor()
    M.close_view()
    if entry then vim.schedule(function() on_tree(entry) end) end
  end)

  vim.api.nvim_create_autocmd('WinClosed', {
    pattern = tostring(win),
    once = true,
    callback = function() M.view = nil end,
  })
end

--- Find a past session and load it back.
---@param opts table|nil { all: boolean|nil }
function M.pick(opts)
  opts = opts or {}
  _preview_cache = {}

  local entries = M.scan(opts)
  if #entries == 0 then
    vim.notify('No Claude sessions found under ' .. M.projects_dir(), vim.log.levels.WARN)
    return
  end
  if not pick_telescope(entries, opts) then
    pick_float(entries)
  end
end

M._when = when
M._place = place
M._preview_into = preview_into

return M
