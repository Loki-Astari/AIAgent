---@diagnostic disable: undefined-global
local M = {}

-- Default configuration
M.config = {
  width = 0.4,         -- Width as percentage (0-1) or columns (>1)
  command = "claude",  -- Command to run (default: "claude")
  named_commands = {
    Cursor = "cursor-agent",
  },
  auto_send_context = false, -- Automatically send new buffer context when entering terminal
}

-- Track agents and windows
M.agents = {}           -- { name = { buf, job_id, scroll_mode, command, sent_files } }
M.current_agent = nil   -- name of active agent
M.win = nil             -- shared terminal window
M.header_buf = nil      -- shared header buffer
M.header_win = nil      -- shared header window
M.prev_win = nil        -- Window to return to when exiting terminal mode

--- Get file paths of all open buffers (excluding special buffers)
---@return string[] List of absolute file paths
local function get_open_buffer_files()
  local files = {}
  local seen = {}
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(bufnr) then
      local buftype = vim.api.nvim_get_option_value("buftype", { buf = bufnr })
      -- Only include normal file buffers (not terminals, help, etc.)
      if buftype == "" then
        local name = vim.api.nvim_buf_get_name(bufnr)
        if name ~= "" and not seen[name] then
          -- Check if it's an actual file (not a directory or special path)
          local stat = vim.loop.fs_stat(name)
          if stat and stat.type == "file" then
            seen[name] = true
            table.insert(files, name)
          end
        end
      end
    end
  end
  return files
end

--- Get list of open buffer files not yet sent to an agent
---@param agent_name string Agent name
---@return string[] List of new file paths
local function get_unsent_buffer_files(agent_name)
  local agent = M.agents[agent_name]
  if not agent then
    return {}
  end

  local sent = agent.sent_files or {}
  local all_files = get_open_buffer_files()
  local new_files = {}

  for _, file in ipairs(all_files) do
    if not sent[file] then
      table.insert(new_files, file)
    end
  end

  return new_files
end

--- Send text to the terminal (types it as if user typed it)
---@param agent_name string Agent name
---@param text string Text to send
local function send_to_terminal(agent_name, text)
  local agent = M.agents[agent_name]
  if not agent or not agent.job_id then
    return
  end
  vim.fn.chansend(agent.job_id, text)
end

--- Get the current visual selection
---@return string[] lines, string filetype
local function get_visual_selection()
  -- Get the visual selection marks
  local start_pos = vim.fn.getpos("'<")
  local end_pos = vim.fn.getpos("'>")
  local start_line = start_pos[2]
  local end_line = end_pos[2]

  -- Get the lines
  local lines = vim.api.nvim_buf_get_lines(0, start_line - 1, end_line, false)

  -- Handle partial line selection for visual mode (not line-wise)
  local mode = vim.fn.visualmode()
  if mode == "v" then
    -- Character-wise visual mode
    local start_col = start_pos[3]
    local end_col = end_pos[3]
    if #lines == 1 then
      lines[1] = string.sub(lines[1], start_col, end_col)
    else
      lines[1] = string.sub(lines[1], start_col)
      lines[#lines] = string.sub(lines[#lines], 1, end_col)
    end
  end
  -- For 'V' (line-wise) and '<C-v>' (block), we keep full lines

  local filetype = vim.bo.filetype
  return lines, filetype
end

--- Force cleanup of a single agent
---@param name string Agent name to clean up
local function cleanup_agent(name)
  local agent = M.agents[name]
  if not agent then return end

  -- Stop the job first
  if agent.job_id ~= nil then
    local job = agent.job_id
    agent.job_id = nil  -- Clear first to prevent on_exit callback issues
    -- Close the channel (more reliable than jobstop for terminals)
    pcall(vim.fn.chanclose, job)
    pcall(vim.fn.jobstop, job)
    -- Wait for the job to actually terminate
    pcall(vim.fn.jobwait, { job }, 500)
  end

  -- Delete buffer
  if agent.buf ~= nil and vim.api.nvim_buf_is_valid(agent.buf) then
    pcall(vim.api.nvim_buf_delete, agent.buf, { force = true, unload = false })
  end

  M.agents[name] = nil
end

--- Force cleanup of all agents and windows
local function force_cleanup()
  -- Clean up all agents
  for name, _ in pairs(M.agents) do
    cleanup_agent(name)
  end
  M.agents = {}
  M.current_agent = nil

  -- Close windows
  if M.win ~= nil and vim.api.nvim_win_is_valid(M.win) then
    pcall(vim.api.nvim_win_close, M.win, true)
    M.win = nil
  end
  if M.header_win ~= nil and vim.api.nvim_win_is_valid(M.header_win) then
    pcall(vim.api.nvim_win_close, M.header_win, true)
    M.header_win = nil
  end

  -- Delete header buffer
  if M.header_buf ~= nil and vim.api.nvim_buf_is_valid(M.header_buf) then
    pcall(vim.api.nvim_buf_delete, M.header_buf, { force = true, unload = false })
    M.header_buf = nil
  end
end

--- Setup the plugin with user options
---@param opts table|nil Configuration options
function M.setup(opts)
  M.config = vim.tbl_deep_extend("force", M.config, opts or {})

  -- Handle quit commands - clean up before Neovim checks for running jobs
  vim.api.nvim_create_autocmd("QuitPre", {
    callback = function()
      if next(M.agents) ~= nil then
        force_cleanup()
      end
    end,
    desc = "Close agent terminals before quit check",
  })

  -- Also handle VimLeavePre as a fallback
  vim.api.nvim_create_autocmd("VimLeavePre", {
    callback = function()
      force_cleanup()
    end,
    desc = "Close agent terminals before exiting Neovim",
  })
end

--- Calculate the window width based on config
---@return number
local function get_width()
  local width = M.config.width
  if width > 0 and width <= 1 then
    -- Percentage of total width
    return math.floor(vim.o.columns * width)
  else
    -- Absolute column count
    return math.floor(width)
  end
end

--- Resolve command to run for an agent name
---@param agent_name string
---@param command string|nil
---@return string
local function resolve_command(agent_name, command)
  if command ~= nil and command ~= "" then
    return command
  end

  if type(agent_name) == "string" and agent_name:lower() == "cursor" then
    if vim.fn.executable("cursor-agent") == 1 then
      return "cursor-agent"
    end
    if vim.fn.executable("cursor") == 1 then
      return "cursor"
    end
  end

  local map = M.config.named_commands
  if type(map) == "table" then
    local by_exact = map[agent_name]
    if type(by_exact) == "string" and by_exact ~= "" then
      return by_exact
    end

    local by_lower = map[agent_name:lower()]
    if type(by_lower) == "string" and by_lower ~= "" then
      return by_lower
    end
  end

  return M.config.command
end

--- Get list of agent names
---@return string[]
local function get_agent_names()
  local names = {}
  for name, _ in pairs(M.agents) do
    table.insert(names, name)
  end
  table.sort(names)
  return names
end

--- Update the header with current agent info
local function update_header()
  if M.header_buf == nil or not vim.api.nvim_buf_is_valid(M.header_buf) then
    return
  end

  local agent_names = get_agent_names()
  local count = #agent_names
  local current = M.current_agent or "none"

  -- Build agent list string
  local agent_list = ""
  if count > 1 then
    agent_list = " (" .. table.concat(agent_names, ", ") .. ")"
  end

  local lines = {
    "Agent: " .. current .. agent_list,
    "<C-\\><C-n> exit | <C-\\><C-s> scroll | <C-\\><C-c> send context",
    "<C-\\><C-a> cycle agents | :AgentList to see all",
  }

  vim.api.nvim_set_option_value("modifiable", true, { buf = M.header_buf })
  vim.api.nvim_buf_set_lines(M.header_buf, 0, -1, false, lines)
  vim.api.nvim_set_option_value("modifiable", false, { buf = M.header_buf })
end

--- Check if the agent window is currently open
---@return boolean
function M.is_open()
  return M.win ~= nil and vim.api.nvim_win_is_valid(M.win)
end

--- Switch to an existing agent by name
---@param name string Agent name to switch to
function M.switch(name)
  local agent = M.agents[name]
  if not agent then
    vim.notify("Agent '" .. name .. "' not found", vim.log.levels.ERROR)
    return
  end

  if not M.is_open() then
    vim.notify("Agent window not open", vim.log.levels.ERROR)
    return
  end

  M.current_agent = name
  vim.api.nvim_win_set_buf(M.win, agent.buf)
  update_header()

  -- Focus and enter insert mode (unless in scroll mode)
  vim.api.nvim_set_current_win(M.win)
  if not agent.scroll_mode then
    vim.cmd("startinsert")
  end
end

--- Cycle to the next agent
function M.next_agent()
  local names = get_agent_names()
  if #names <= 1 then
    return
  end

  local current_idx = 1
  for i, name in ipairs(names) do
    if name == M.current_agent then
      current_idx = i
      break
    end
  end

  local next_idx = (current_idx % #names) + 1
  M.switch(names[next_idx])
end

--- Create the window layout (header + terminal area)
local function create_window_layout()
  -- Remember the current window to return to later
  M.prev_win = vim.api.nvim_get_current_win()

  -- Create a vertical split on the right
  vim.cmd("botright vsplit")
  local main_win = vim.api.nvim_get_current_win()

  -- Set the width
  vim.api.nvim_win_set_width(main_win, get_width())

  -- Create the header buffer
  M.header_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_option_value("buftype", "nofile", { buf = M.header_buf })
  vim.api.nvim_win_set_buf(main_win, M.header_buf)
  M.header_win = main_win

  -- Set header window options
  vim.api.nvim_set_option_value("number", false, { win = M.header_win })
  vim.api.nvim_set_option_value("relativenumber", false, { win = M.header_win })
  vim.api.nvim_set_option_value("signcolumn", "no", { win = M.header_win })
  vim.api.nvim_set_option_value("winfixheight", true, { win = M.header_win })

  -- Create a horizontal split below for the terminal
  vim.cmd("belowright split")
  M.win = vim.api.nvim_get_current_win()

  -- Resize header to 3 lines
  vim.api.nvim_win_set_height(M.header_win, 3)

  -- Set terminal window options
  vim.api.nvim_set_option_value("number", false, { win = M.win })
  vim.api.nvim_set_option_value("relativenumber", false, { win = M.win })
  vim.api.nvim_set_option_value("signcolumn", "no", { win = M.win })
end

--- Create a new agent
---@param name string Agent name
---@param cmd string Command to run
local function create_agent(name, cmd)
  -- Create a new buffer for the terminal
  local buf = vim.api.nvim_create_buf(false, true)

  -- Set buffer options before starting terminal
  vim.api.nvim_set_option_value("bufhidden", "hide", { buf = buf })

  -- Store agent before starting terminal (so on_exit can find it)
  M.agents[name] = {
    buf = buf,
    job_id = nil,
    scroll_mode = false,
    command = cmd,
    sent_files = {},  -- Track which files have been sent as context
  }

  -- Show buffer in window and switch to it before starting terminal
  -- (termopen runs in the current window, so we must be in M.win)
  vim.api.nvim_win_set_buf(M.win, buf)
  vim.api.nvim_set_current_win(M.win)

  -- Start the terminal with the AI agent
  local job_id = vim.fn.termopen(cmd, {
    on_exit = function()
      if M.agents[name] then
        M.agents[name].job_id = nil
      end
      M.close(name)
    end,
  })

  M.agents[name].job_id = job_id

  -- Set buffer name for identification
  vim.api.nvim_buf_set_name(buf, "agent:" .. name)

  -- Auto-enter insert mode when entering this buffer (unless in scroll mode)
  -- Also optionally auto-send context for new buffers
  vim.api.nvim_create_autocmd("BufEnter", {
    buffer = buf,
    callback = function()
      local agent = M.agents[name]
      if agent and not agent.scroll_mode then
        -- Auto-send context if enabled
        if M.config.auto_send_context then
          M.send_context(name)
        end
        vim.cmd("startinsert")
      end
    end,
    desc = "Auto-enter terminal mode when focusing agent window",
  })

  -- Add keymap to exit terminal mode and return to previous window
  vim.api.nvim_buf_set_keymap(buf, "t", "<C-\\><C-n>", "", {
    noremap = true,
    callback = function()
      vim.cmd("stopinsert")
      local agent = M.agents[name]
      if agent then
        agent.scroll_mode = false
      end
      if M.prev_win and vim.api.nvim_win_is_valid(M.prev_win) then
        vim.api.nvim_set_current_win(M.prev_win)
      end
    end,
  })

  -- Add keymap to enter scroll mode (stay in agent window)
  vim.api.nvim_buf_set_keymap(buf, "t", "<C-\\><C-s>", "", {
    noremap = true,
    callback = function()
      local agent = M.agents[name]
      if agent then
        agent.scroll_mode = true
      end
      vim.cmd("stopinsert")
    end,
  })

  -- Add keymap to exit scroll mode and resume terminal interaction
  vim.api.nvim_buf_set_keymap(buf, "n", "i", "", {
    noremap = true,
    callback = function()
      local agent = M.agents[name]
      if agent then
        agent.scroll_mode = false
      end
      vim.cmd("startinsert")
    end,
  })

  -- Add keymap to cycle agents
  vim.api.nvim_buf_set_keymap(buf, "t", "<C-\\><C-a>", "", {
    noremap = true,
    callback = function()
      M.next_agent()
    end,
  })

  -- Add keymap to send buffer context
  vim.api.nvim_buf_set_keymap(buf, "t", "<C-\\><C-c>", "", {
    noremap = true,
    callback = function()
      local count = M.send_context(name)
      if count > 0 then
        vim.notify("Sent " .. count .. " file(s) as context", vim.log.levels.INFO)
      else
        vim.notify("No new files to send", vim.log.levels.INFO)
      end
    end,
  })

  return buf
end

--- Open an AI agent in a right-side split
---@param name string|nil Agent name (defaults to "AIAgent")
---@param command string|nil Command to run (defaults to config.command or name-based default)
function M.open(name, command)
  -- Default name and command
  local agent_name = name or "AIAgent"
  local cmd = resolve_command(agent_name, command)

  -- If agent already exists, switch to it
  if M.agents[agent_name] then
    if not M.is_open() then
      -- Window was closed but agent still exists, recreate window
      create_window_layout()
    end
    M.switch(agent_name)
    return
  end

  -- Create window layout if not open
  if not M.is_open() then
    create_window_layout()
  end

  -- Create the new agent
  create_agent(agent_name, cmd)
  M.current_agent = agent_name

  -- Update header and enter insert mode
  update_header()
  vim.cmd("startinsert")
end

--- Close a specific agent or the current one
---@param name string|nil Agent name to close (defaults to current)
function M.close(name)
  local agent_name = name or M.current_agent

  if not agent_name then
    -- No agents, just clean up window
    force_cleanup()
    return
  end

  -- Clean up the specific agent
  cleanup_agent(agent_name)

  -- If that was the current agent, switch to another or close window
  if agent_name == M.current_agent then
    local remaining = get_agent_names()
    if #remaining > 0 then
      M.switch(remaining[1])
    else
      -- No agents left, close the window
      M.current_agent = nil
      if M.win ~= nil and vim.api.nvim_win_is_valid(M.win) then
        pcall(vim.api.nvim_win_close, M.win, true)
        M.win = nil
      end
      if M.header_win ~= nil and vim.api.nvim_win_is_valid(M.header_win) then
        pcall(vim.api.nvim_win_close, M.header_win, true)
        M.header_win = nil
      end
      if M.header_buf ~= nil and vim.api.nvim_buf_is_valid(M.header_buf) then
        pcall(vim.api.nvim_buf_delete, M.header_buf, { force = true, unload = false })
        M.header_buf = nil
      end
    end
  else
    -- Just update header to reflect removed agent
    update_header()
  end
end

--- Close all agents and window
function M.close_all()
  force_cleanup()
end

--- Get list of running agents
---@return string[]
function M.list()
  return get_agent_names()
end

--- Print list of running agents
function M.print_list()
  local names = get_agent_names()
  if #names == 0 then
    vim.notify("No agents running", vim.log.levels.INFO)
  else
    local current = M.current_agent or ""
    local lines = {}
    for _, name in ipairs(names) do
      local marker = (name == current) and " *" or ""
      local agent = M.agents[name]
      local cmd = agent and agent.command or "?"
      table.insert(lines, name .. marker .. " (" .. cmd .. ")")
    end
    vim.notify("Agents:\n" .. table.concat(lines, "\n"), vim.log.levels.INFO)
  end
end

--- Toggle the AI agent window
---@param name string|nil Agent name (defaults to "AIAgent")
---@param command string|nil Optional command to run (defaults to config.command or name-based default)
function M.toggle(name, command)
  local agent_name = name or "AIAgent"

  -- If this specific agent is open and visible, close it
  if M.is_open() and M.current_agent == agent_name then
    M.close(agent_name)
  else
    M.open(agent_name, command)
  end
end

--- Send open buffer context to the current agent
--- Uses @file syntax for Claude Code to read the files
---@param agent_name string|nil Agent name (defaults to current)
---@return number Number of new files sent
function M.send_context(agent_name)
  local name = agent_name or M.current_agent
  if not name then
    vim.notify("No agent active", vim.log.levels.WARN)
    return 0
  end

  local agent = M.agents[name]
  if not agent or not agent.job_id then
    vim.notify("Agent '" .. name .. "' not running", vim.log.levels.WARN)
    return 0
  end

  local new_files = get_unsent_buffer_files(name)
  if #new_files == 0 then
    return 0
  end

  -- Build @file references for Claude Code
  local refs = {}
  for _, file in ipairs(new_files) do
    table.insert(refs, "@" .. file)
    agent.sent_files[file] = true
  end

  -- Send file references to the terminal
  local text = table.concat(refs, " ") .. " "
  send_to_terminal(name, text)

  return #new_files
end

--- Get count of unsent buffer files for the current agent
---@param agent_name string|nil Agent name (defaults to current)
---@return number
function M.pending_context_count(agent_name)
  local name = agent_name or M.current_agent
  if not name then
    return 0
  end
  return #get_unsent_buffer_files(name)
end

--- Reset sent files tracking for an agent (to re-send all context)
---@param agent_name string|nil Agent name (defaults to current)
function M.reset_context(agent_name)
  local name = agent_name or M.current_agent
  if not name then
    return
  end
  local agent = M.agents[name]
  if agent then
    agent.sent_files = {}
    vim.notify("Context reset for agent '" .. name .. "'", vim.log.levels.INFO)
  end
end

--- Send visual selection to the agent terminal
--- Opens the agent if not already open
---@param agent_name string|nil Agent name (defaults to current or "AIAgent")
function M.send_selection(agent_name)
  -- Get selection before we switch windows (marks may change)
  local lines, filetype = get_visual_selection()
  if #lines == 0 or (#lines == 1 and lines[1] == "") then
    vim.notify("No text selected", vim.log.levels.WARN)
    return
  end

  -- Determine which agent to use
  local name = agent_name or M.current_agent or "AIAgent"

  -- Open agent if not running
  if not M.agents[name] then
    M.open(name)
    -- Give terminal time to initialize
    vim.defer_fn(function()
      M.send_selection_to_agent(name, lines, filetype)
    end, 100)
    return
  end

  -- If window isn't open, open it
  if not M.is_open() then
    M.open(name)
  end

  M.send_selection_to_agent(name, lines, filetype)
end

--- Internal: send selection lines to a running agent
---@param name string Agent name
---@param lines string[] Selected lines
---@param filetype string Filetype of the source buffer
function M.send_selection_to_agent(name, lines, filetype)
  local agent = M.agents[name]
  if not agent or not agent.job_id then
    vim.notify("Agent '" .. name .. "' not running", vim.log.levels.ERROR)
    return
  end

  -- Format as markdown code block
  local ft = filetype ~= "" and filetype or "text"
  local code_block = "```" .. ft .. "\n" .. table.concat(lines, "\n") .. "\n```\n"

  -- Send to terminal
  send_to_terminal(name, code_block)

  -- Switch to the agent and enter insert mode
  M.current_agent = name
  vim.api.nvim_win_set_buf(M.win, agent.buf)
  vim.api.nvim_set_current_win(M.win)
  update_header()
  vim.cmd("startinsert")
end

return M
