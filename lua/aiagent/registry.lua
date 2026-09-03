---@diagnostic disable: undefined-global
-- Cross-instance agent registry.
--
-- Neovim may be running in several terminal windows at once, each with its own
-- agents in its own directory.  Every instance publishes one small JSON sidecar
-- per agent into a shared state directory, so any instance can list every agent
-- on the machine without talking to the other instances at all.
--
-- Two rules keep the registry honest:
--
--  * Liveness is never trusted from the file.  Entries whose owning Neovim or
--    agent process is gone are pruned (and their sidecars unlinked) on read, so
--    a crashed instance leaves nothing behind and no heartbeat is needed.
--  * Anything Claude Code already tracks is read from Claude Code.  Busy/idle
--    status comes from ~/.claude/sessions/<pid>.json and the derived task label
--    from the session transcript; the sidecar only carries what the plugin
--    knows and Claude does not (agent name, worktree slug, colour, the Neovim
--    server socket, and the terminal pane to raise).

local M = {}

local uv = vim.uv

--- Lazy handle on the main module (registry is required from it, so this must
--- never run at load time).
local function core()
  return require('aiagent')
end

----------------------------------------------------------------------------
-- Paths
----------------------------------------------------------------------------

--- Directory holding the sidecar files.  Deliberately outside Neovim's own
--- state dir so a plain shell script can read it too.
---@return string
function M.dir()
  local state = os.getenv('XDG_STATE_HOME')
  if not state or state == '' then
    state = vim.fn.expand('~/.local/state')
  end
  return state .. '/aiagent/agents'
end

--- Sidecar filename for an agent.  Keyed on the owning Neovim pid so two
--- instances can run identically-named agents without colliding.
---@param name string Agent name
---@param nvim_pid number|nil Owning Neovim pid (defaults to this instance)
---@return string
function M.path_for(name, nvim_pid)
  local safe = name:gsub('[^%w%-_]', '_')
  return M.dir() .. '/' .. (nvim_pid or vim.fn.getpid()) .. '-' .. safe .. '.json'
end

----------------------------------------------------------------------------
-- Small helpers
----------------------------------------------------------------------------

--- Does this pid exist?  Signal 0 is the portable existence check.
---@param pid number|nil
---@return boolean
local function alive(pid)
  if type(pid) ~= 'number' or pid <= 0 then return false end
  local ok, res = pcall(uv.kill, pid, 0)
  return ok and res == 0
end

--- Read the last `nbytes` of a file; nil on failure.
---@param path string
---@param nbytes number
---@return string|nil
local function read_tail(path, nbytes)
  local fd = uv.fs_open(path, 'r', 0)
  if not fd then return nil end
  local stat = uv.fs_fstat(fd)
  if not stat then uv.fs_close(fd); return nil end
  local offset = math.max(0, stat.size - nbytes)
  local data = uv.fs_read(fd, nbytes, offset)
  uv.fs_close(fd)
  return data
end

--- Decode a JSON file; nil when missing or malformed.
---@param path string
---@return table|nil
local function read_json(path)
  local fd = uv.fs_open(path, 'r', 0)
  if not fd then return nil end
  local stat = uv.fs_fstat(fd)
  if not stat then uv.fs_close(fd); return nil end
  local data = uv.fs_read(fd, stat.size, 0)
  uv.fs_close(fd)
  if not data or data == '' then return nil end
  local ok, decoded = pcall(vim.fn.json_decode, data)
  if not ok or type(decoded) ~= 'table' then return nil end
  return decoded
end

--- Current git branch of a directory, or nil.
---@param dir string|nil
---@return string|nil
local function branch_of(dir)
  if not dir or dir == '' or vim.fn.isdirectory(dir) == 0 then return nil end
  local out = vim.fn.system({ 'git', '-C', dir, 'branch', '--show-current' })
  if vim.v.shell_error ~= 0 then return nil end
  out = vim.trim(out)
  return out ~= '' and out or nil
end

----------------------------------------------------------------------------
-- Terminal context (for raising the right window later)
----------------------------------------------------------------------------

local _term_cache

--- Identify the terminal pane this Neovim is displayed in.  These values are
--- fixed for the life of the process, so they are captured once.
---@return table
local function term_context()
  if _term_cache then return _term_cache end
  local t = { program = os.getenv('TERM_PROGRAM') or '' }

  -- A multiplexer wins over the emulator: raising the pane is what actually
  -- reveals the agent, and tmux can do that without any GUI scripting.
  if (os.getenv('TMUX') or '') ~= '' then
    t.tmux = os.getenv('TMUX_PANE')
  end
  -- iTerm2 exports "w0t0p0:<GUID>"; the GUID is the session id AppleScript uses.
  local iterm = os.getenv('ITERM_SESSION_ID')
  if iterm then t.iterm = iterm:match(':(.+)$') end
  if (os.getenv('KITTY_WINDOW_ID') or '') ~= '' then
    t.kitty = os.getenv('KITTY_WINDOW_ID')
    t.kitty_listen = os.getenv('KITTY_LISTEN_ON')
  end
  if (os.getenv('WEZTERM_PANE') or '') ~= '' then
    t.wezterm = os.getenv('WEZTERM_PANE')
  end

  _term_cache = t
  return t
end

----------------------------------------------------------------------------
-- Publish / unpublish
----------------------------------------------------------------------------

--- Write (or rewrite) the sidecar for one live agent.  Cheap enough to call on
--- every state change; failures are silent by design -- the registry is a
--- convenience and must never break opening an agent.
---@param name string Agent name
---@return boolean written
function M.publish(name)
  local aiagent = core()
  local agent = aiagent.agents[name]
  if not agent then return false end

  local job_pid = nil
  if agent.job_id then
    local ok, pid = pcall(vim.fn.jobpid, agent.job_id)
    if ok and type(pid) == 'number' and pid > 0 then job_pid = pid end
  end

  local entry = {
    agent      = name,
    agent_type = agent.agent_type,
    command    = agent.command,
    color      = agent.color,
    task       = agent.task,
    cwd        = agent.worktree or vim.fn.getcwd(),
    worktree   = agent.worktree,
    git_root   = agent.git_root,
    slug       = agent.slug,
    current    = (aiagent.current_agent == name),
    nvim_pid   = vim.fn.getpid(),
    nvim_server = (vim.v.servername ~= '' and vim.v.servername or nil),
    job_pid    = job_pid,
    term       = term_context(),
    started    = agent.started or os.time(),
    updated    = os.time(),
  }
  agent.started = entry.started

  if vim.fn.isdirectory(M.dir()) == 0 then
    vim.fn.mkdir(M.dir(), 'p')
  end
  local ok = pcall(vim.fn.writefile, { vim.fn.json_encode(entry) }, M.path_for(name))
  return ok == true
end

--- Remove one agent's sidecar.
---@param name string Agent name
function M.unpublish(name)
  pcall(uv.fs_unlink, M.path_for(name))
end

--- Republish every agent of this instance (used when the current agent changes,
--- so the `current` flag stays accurate).
function M.publish_all()
  for name, _ in pairs(core().agents) do
    M.publish(name)
  end
end

----------------------------------------------------------------------------
-- Derived task label
----------------------------------------------------------------------------

--- Pull the human-typed text out of a transcript entry's message, or nil when
--- the entry is not a human turn (tool results and injected envelopes are not).
---@param message table|nil
---@return string|nil
local function human_text(message)
  if type(message) ~= 'table' then return nil end
  local content, text = message.content, nil
  if type(content) == 'string' then
    text = content
  elseif type(content) == 'table' then
    local parts = {}
    for _, p in ipairs(content) do
      if type(p) == 'table' then
        if p.type == 'tool_result' then return nil end
        if p.type == 'text' and type(p.text) == 'string' then
          table.insert(parts, p.text)
        end
      end
    end
    text = table.concat(parts, '\n')
  end
  if not text or text == '' then return nil end

  -- Strip the XML-ish envelopes Claude Code injects (slash-command echoes,
  -- system reminders, captured command output): not what the user typed.
  text = text:gsub('<[%w_%-]+>.-</[%w_%-]+>', ' ')
  for _, line in ipairs(vim.split(text, '\n', { plain = true })) do
    line = vim.trim(line)
    if line ~= '' and not line:match('^<') then return line end
  end
  return nil
end

M._human_text = human_text

-- Tail sizes tried in turn when hunting for the last prompt.  A single turn's
-- tool output can run to hundreds of kilobytes, so the newest prompt is often a
-- long way from EOF; start small (the common case) and only pay for a bigger
-- read when the small one comes up empty.
local TAIL_STEPS = { 64 * 1024, 512 * 1024, 4 * 1024 * 1024 }

--- The most recent prompt of a Claude session, read from its transcript.
--- This is the fallback for "what is it working on" when no explicit task
--- label has been set with :AgentTask.
---@param session_id string|nil
---@param cwd string|nil
---@return string|nil
function M.last_prompt(session_id, cwd)
  if not session_id or not cwd then return nil end
  local project = cwd:gsub('[^%w%-]', '-')
  local path = vim.fn.expand('~/.claude/projects/' .. project .. '/' .. session_id .. '.jsonl')

  local size = (uv.fs_stat(path) or {}).size
  if not size then return nil end

  for step, nbytes in ipairs(TAIL_STEPS) do
    local tail = read_tail(path, nbytes)
    if not tail then return nil end

    -- The window starts mid-file, so the first line is usually a fragment;
    -- json_decode fails on it and it is skipped like any other bad line.
    local lines = vim.split(tail, '\n', { plain = true })
    for i = #lines, 1, -1 do
      if lines[i] ~= '' then
        local ok, entry = pcall(vim.fn.json_decode, lines[i])
        if ok and type(entry) == 'table' and entry.type == 'user' and not entry.isMeta then
          local text = human_text(entry.message)
          if text then return text end
        end
      end
    end

    -- Nothing found and the window already spanned the whole file: give up
    -- rather than re-reading the same bytes at the next step.
    if nbytes >= size then break end
    if step == #TAIL_STEPS then break end
  end
  return nil
end

----------------------------------------------------------------------------
-- Read
----------------------------------------------------------------------------

--- Every live agent published on this machine.
---
--- Dead entries are unlinked as they are found.  Each returned entry is the
--- sidecar plus: `status` ("busy"/"idle"/nil), `status_age` (seconds),
--- `session` (Claude session id), `branch`, `label` (task, explicit or
--- derived), `is_local` (owned by this Neovim).
---@param opts { derive: boolean|nil }|nil  derive=false skips transcript/git lookups
---@return table[] entries  sorted local-first, then by start time
function M.read_all(opts)
  opts = opts or {}
  local derive = opts.derive ~= false
  local self_pid = vim.fn.getpid()
  local entries = {}

  for _, path in ipairs(vim.fn.glob(M.dir() .. '/*.json', true, true)) do
    local entry = read_json(path)
    if not entry or not entry.agent then
      pcall(uv.fs_unlink, path)
      goto continue
    end

    entry.is_local = (entry.nvim_pid == self_pid)

    -- Owning Neovim must still be running.  A lingering socket file after a
    -- crash is not enough on its own, hence the pid check as well.
    if not entry.is_local then
      if not alive(entry.nvim_pid) then
        pcall(uv.fs_unlink, path)
        goto continue
      end
      if entry.nvim_server and not uv.fs_stat(entry.nvim_server) then
        pcall(uv.fs_unlink, path)
        goto continue
      end
    end

    -- The agent process itself must still be running.  Only checked when a pid
    -- was recorded: an agent that never reported one is left alone.
    if entry.job_pid and not alive(entry.job_pid) then
      pcall(uv.fs_unlink, path)
      goto continue
    end

    -- Claude Code maintains its own per-pid session file; it is the authority
    -- on busy/idle and on the session id.
    if entry.job_pid then
      local session = read_json(vim.fn.expand('~/.claude/sessions/' .. entry.job_pid .. '.json'))
      if session then
        entry.status  = session.status
        entry.session = session.sessionId
        entry.cwd     = session.cwd or entry.cwd
        entry.claude_name = session.name
        if type(session.statusUpdatedAt) == 'number' then
          entry.status_age = math.max(0, os.time() - math.floor(session.statusUpdatedAt / 1000))
        end
      end
    end

    if derive then
      entry.branch = branch_of(entry.cwd)
      entry.label  = entry.task
      if not entry.label or entry.label == '' then
        entry.label = M.last_prompt(entry.session, entry.cwd)
        entry.label_derived = true
      end
    else
      entry.label = entry.task
    end

    table.insert(entries, entry)
    ::continue::
  end

  table.sort(entries, function(a, b)
    if a.is_local ~= b.is_local then return a.is_local end
    return (a.started or 0) < (b.started or 0)
  end)
  return entries
end

----------------------------------------------------------------------------
-- Focus
----------------------------------------------------------------------------

--- Command that raises `entry`'s terminal pane, or nil when we don't know how.
--- config.focus_cmd, when set, wins and may itself return nil to fall through.
---@param entry table
---@return string[]|nil
function M.focus_cmd(entry)
  local hook = core().config.focus_cmd
  if type(hook) == 'function' then
    local ok, cmd = pcall(hook, entry)
    if ok and type(cmd) == 'table' and #cmd > 0 then return cmd end
  end

  local t = entry.term or {}
  if t.tmux and t.tmux ~= '' then
    -- Works whether the pane is in this client's session or another.
    return { 'tmux', 'switch-client', '-t', t.tmux }
  end
  if t.iterm and t.iterm ~= '' then
    -- iTerm2's session `id` is the GUID half of $ITERM_SESSION_ID.  Selecting
    -- the session already in front is a harmless no-op, so no early exit.
    local script = table.concat({
      'tell application "iTerm2"',
      '  activate',
      '  repeat with w in windows',
      '    repeat with tb in tabs of w',
      '      repeat with s in sessions of tb',
      '        if id of s is "' .. t.iterm .. '" then',
      '          select w',
      '          select tb',
      '          select s',
      '        end if',
      '      end repeat',
      '    end repeat',
      '  end repeat',
      'end tell',
    }, '\n')
    return { 'osascript', '-e', script }
  end
  if t.kitty and t.kitty ~= '' then
    local cmd = { 'kitten', '@' }
    if t.kitty_listen and t.kitty_listen ~= '' then
      vim.list_extend(cmd, { '--to', t.kitty_listen })
    end
    vim.list_extend(cmd, { 'focus-window', '--match', 'id:' .. t.kitty })
    return cmd
  end
  if t.wezterm and t.wezterm ~= '' then
    return { 'wezterm', 'cli', 'activate-pane', '--pane-id', t.wezterm }
  end
  return nil
end

--- Fire off a detached command, reporting rather than raising when it cannot
--- run.  jobstart() throws E475 on a non-executable argv[0], which a missing
--- multiplexer binary or a hand-written config.focus_cmd can easily produce.
---@param cmd string[]
---@param what string  what the command was for, used in the failure message
---@return boolean started
local function spawn(cmd, what)
  if vim.fn.executable(cmd[1]) ~= 1 then
    vim.notify(('AIAgent: cannot %s -- %q is not executable'):format(what, cmd[1]),
      vim.log.levels.WARN)
    return false
  end
  local ok, err = pcall(vim.fn.jobstart, cmd, { detach = true })
  if not ok then
    vim.notify(('AIAgent: cannot %s -- %s'):format(what, tostring(err)), vim.log.levels.WARN)
    return false
  end
  return true
end

--- Bring an agent to the front: show it in its own Neovim instance, then raise
--- the terminal pane that instance is displayed in.  Both steps are async and
--- best-effort; an agent in this instance is just switched to directly.
---@param entry table  an entry from read_all()
function M.focus(entry)
  if not entry then return end

  if entry.is_local then
    core().open(entry.agent)
    return
  end

  if entry.nvim_server then
    -- `or 1` keeps --remote-expr from erroring on a nil result.
    local lua = string.format("require('aiagent').open(%q) or 1", entry.agent)
    spawn({ 'nvim', '--server', entry.nvim_server, '--remote-expr',
      string.format('luaeval(%s)', vim.fn.string(lua)) },
      'switch ' .. entry.agent .. ' in its own Neovim')
  end

  local cmd = M.focus_cmd(entry)
  if cmd then
    spawn(cmd, 'raise the terminal for ' .. entry.agent)
  else
    vim.notify(
      ('Agent %s is in Neovim pid %s (%s) -- no way to raise its terminal; set config.focus_cmd')
        :format(entry.agent, tostring(entry.nvim_pid), entry.cwd or '?'),
      vim.log.levels.WARN)
  end
end

----------------------------------------------------------------------------
-- Viewer
----------------------------------------------------------------------------

-- Foreground colour per agent colour name, for the name column.
local NAME_FG = {
  blue    = '#60a5fa',
  green   = '#4ade80',
  yellow  = '#facc15',
  red     = '#f87171',
  pink    = '#f472b6',
  cyan    = '#22d3ee',
  orange  = '#fb923c',
  purple  = '#a78bfa',
}

local ns = vim.api.nvim_create_namespace('AIAgentList')

M.view = nil  -- { win, buf, entries } while the list is open

local function ensure_highlights()
  for color, fg in pairs(NAME_FG) do
    vim.api.nvim_set_hl(0, 'AIAgentListName_' .. color, { fg = fg, bold = true })
  end
  vim.api.nvim_set_hl(0, 'AIAgentListName', { link = 'Identifier' })
  -- Idle means the agent has stopped and is waiting on the user: the one status
  -- worth drawing the eye.  Busy is deliberately dim.
  vim.api.nvim_set_hl(0, 'AIAgentListIdle', { link = 'DiagnosticOk' })
  vim.api.nvim_set_hl(0, 'AIAgentListBusy', { link = 'Comment' })
  vim.api.nvim_set_hl(0, 'AIAgentListDim',  { link = 'Comment' })
  vim.api.nvim_set_hl(0, 'AIAgentListHere', { link = 'Special' })
end

--- Compact a directory for display: home as ~, and long paths elided to their
--- last two components.
---@param dir string|nil
---@return string
local function short_dir(dir)
  if not dir or dir == '' then return '' end
  local out = vim.fn.fnamemodify(dir, ':~')
  if #out <= 28 then return out end
  local parts = vim.split(out, '/', { plain = true })
  if #parts <= 2 then return out end
  return '…/' .. table.concat({ parts[#parts - 1], parts[#parts] }, '/')
end

--- Human-readable age.
---@param secs number|nil
---@return string
local function age(secs)
  if not secs then return '' end
  if secs < 60 then return secs .. 's' end
  if secs < 3600 then return math.floor(secs / 60) .. 'm' end
  return math.floor(secs / 3600) .. 'h'
end

--- Clip text to a display width, marking the cut with an ellipsis.
---@param text string
---@param width number
---@return string
local function truncate(text, width)
  if vim.fn.strdisplaywidth(text) <= width then return text end
  return vim.fn.strcharpart(text, 0, width - 1) .. '…'
end

--- Status cell text plus its highlight group.
---@param entry table
---@return string, string
local function status_cell(entry)
  if entry.status == 'idle' then
    local a = age(entry.status_age)
    return (a ~= '' and ('idle ' .. a) or 'idle'), 'AIAgentListIdle'
  elseif entry.status == 'busy' then
    return 'busy', 'AIAgentListBusy'
  end
  return '-', 'AIAgentListDim'
end

--- Build display lines and their highlight ranges from registry entries.
--- Returned separately from rendering so it can be unit-tested.
---@param entries table[]
---@return string[] lines, table[] highlights  -- { line, col, end_col, group }
function M.render(entries)
  local rows = {}
  local w = { name = 4, status = 6, branch = 6, dir = 3 }

  for _, e in ipairs(entries) do
    local status, status_hl = status_cell(e)
    local row = {
      entry  = e,
      mark   = e.current and e.is_local and '▶' or ' ',
      name   = e.agent,
      status = status,
      status_hl = status_hl,
      branch = e.branch or '',
      dir    = short_dir(e.cwd),
      label  = truncate(e.label or '', 60),
    }
    w.name   = math.max(w.name, vim.fn.strdisplaywidth(row.name))
    w.status = math.max(w.status, vim.fn.strdisplaywidth(row.status))
    w.branch = math.max(w.branch, vim.fn.strdisplaywidth(row.branch))
    w.dir    = math.max(w.dir, vim.fn.strdisplaywidth(row.dir))
    table.insert(rows, row)
  end

  local lines, hls = {}, {}
  for i, row in ipairs(rows) do
    local parts = {}
    local function put(text, group, width)
      local pad = width and (width - vim.fn.strdisplaywidth(text)) or 0
      local col = 0
      for _, p in ipairs(parts) do col = col + #p end
      table.insert(parts, text)
      if group and text ~= '' then
        table.insert(hls, { line = i - 1, col = col, end_col = col + #text, group = group })
      end
      if pad > 0 then table.insert(parts, string.rep(' ', pad)) end
    end

    put(' ' .. row.mark .. ' ', 'AIAgentListHere')
    local name_hl = (row.entry.color and NAME_FG[row.entry.color])
      and ('AIAgentListName_' .. row.entry.color) or 'AIAgentListName'
    put(row.name, name_hl, w.name)
    put('  ', nil)
    put(row.status, row.status_hl, w.status)
    put('  ', nil)
    put(row.branch, 'AIAgentListDim', w.branch)
    put('  ', nil)
    put(row.dir, 'AIAgentListDim', w.dir)
    put('  ', nil)
    put(row.label, row.entry.label_derived and 'AIAgentListDim' or nil)

    table.insert(lines, (table.concat(parts):gsub('%s+$', '')))
  end
  return lines, hls
end

--- Close the agent list window.
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

--- Show every live agent on the machine in a floating list.
--- <CR> focuses the agent under the cursor, r refreshes, q closes.
function M.show()
  M.close_view()  -- refresh rather than stack windows

  local entries = M.read_all()
  if #entries == 0 then
    vim.notify('No agents published on this machine', vim.log.levels.INFO)
    return
  end

  ensure_highlights()
  local lines, hls = M.render(entries)
  local title = ' Agents  (<CR> focus · r refresh · q close) '

  local width = vim.fn.strdisplaywidth(title)
  for _, l in ipairs(lines) do
    width = math.max(width, vim.fn.strdisplaywidth(l))
  end
  width = math.min(width + 2, vim.o.columns - 4)
  local height = math.min(#lines, vim.o.lines - 6)

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  for _, h in ipairs(hls) do
    pcall(vim.api.nvim_buf_set_extmark, buf, ns, h.line, h.col,
      { end_col = h.end_col, hl_group = h.group })
  end
  vim.api.nvim_set_option_value('modifiable', false, { buf = buf })
  vim.api.nvim_set_option_value('filetype', 'aiagentlist', { buf = buf })

  local win = vim.api.nvim_open_win(buf, true, {
    relative = 'editor',
    row = math.max(0, math.floor((vim.o.lines - height) / 2) - 1),
    col = math.max(0, math.floor((vim.o.columns - width) / 2)),
    width = width,
    height = height,
    style = 'minimal',
    border = 'rounded',
    title = title,
    title_pos = 'center',
  })
  vim.api.nvim_set_option_value('cursorline', true, { win = win })

  M.view = { win = win, buf = buf, entries = entries }

  local function map(lhs, fn)
    vim.keymap.set('n', lhs, fn, { buffer = buf, nowait = true, silent = true })
  end
  map('q', M.close_view)
  map('<Esc>', M.close_view)
  map('r', M.show)
  map('<CR>', function()
    local row = vim.api.nvim_win_get_cursor(win)[1]
    local entry = M.view and M.view.entries[row]
    M.close_view()
    if entry then M.focus(entry) end
  end)

  vim.api.nvim_create_autocmd('WinClosed', {
    pattern = tostring(win),
    once = true,
    callback = function() M.view = nil end,
  })
end

M._alive = alive
M._branch_of = branch_of
M._term_context = term_context
M._short_dir = short_dir

return M
