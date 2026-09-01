local aiagent = require("aiagent")

-- Reset module state between tests
local function reset()
  aiagent.close_all()
  aiagent.setup({})
end

describe("aiagent._is_under", function()
  local is_under = aiagent._is_under

  it("exact match returns true", function()
    assert.is_true(is_under("/foo/bar", "/foo/bar"))
  end)

  it("child path returns true", function()
    assert.is_true(is_under("/foo/bar/baz.lua", "/foo/bar"))
    assert.is_true(is_under("/foo/bar/baz/qux", "/foo/bar"))
  end)

  it("sibling with shared prefix returns false", function()
    -- /foo/barbaz must NOT match parent /foo/bar
    assert.is_false(is_under("/foo/barbaz", "/foo/bar"))
    assert.is_false(is_under("/tmp/nvim-agent-foobar/x", "/tmp/nvim-agent-foo"))
  end)

  it("child shorter than parent returns false", function()
    assert.is_false(is_under("/foo", "/foo/bar"))
  end)

  it("unrelated paths return false", function()
    assert.is_false(is_under("/other/path/file.lua", "/foo/bar"))
  end)

  it("root path edge case", function()
    assert.is_true(is_under("/foo", "/"))
    assert.is_true(is_under("/", "/"))
  end)
end)

describe("aiagent.set", function()
  before_each(reset)

  it("accepts a known agent and notifies success", function()
    local notified_level = nil
    local orig = vim.notify
    vim.notify = function(_, level) notified_level = level end

    aiagent.set("claude")

    vim.notify = orig
    assert.equals(vim.log.levels.INFO, notified_level)
  end)

  it("rejects an unknown agent with a warning and does not change type", function()
    -- Set to a known baseline first
    aiagent.set("claude")
    local before = aiagent.current_agent_type

    local notified_level = nil
    local orig = vim.notify
    vim.notify = function(_, level) notified_level = level end

    aiagent.set("nonexistent_agent_xyz_abc")

    vim.notify = orig
    assert.equals(vim.log.levels.WARN, notified_level)
    -- Type must not have changed
    assert.equals(before, aiagent.current_agent_type)
  end)
end)

describe("aiagent.bufferline_name_formatter", function()
  it("returns nil for a plain buffer with no agent tag", function()
    local buf = vim.api.nvim_create_buf(false, true)
    local result = aiagent.bufferline_name_formatter({
      bufnr = buf,
      path  = "/some/project/src/main.lua",
      name  = "main.lua",
    })
    assert.is_nil(result)
    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it("returns 'slug: filename' for a worktree-tagged buffer with a registered agent slug", function()
    local buf = vim.api.nvim_create_buf(false, true)
    vim.b[buf].aiagent_name = "Feature"
    aiagent.agents["Feature"] = { slug = "my-feature" }

    local result = aiagent.bufferline_name_formatter({
      bufnr = buf,
      path  = "/tmp/nvim-agent-repo-my-feature/src/main.lua",
      name  = "main.lua",
    })

    assert.equals("my-feature: main.lua", result)
    vim.api.nvim_buf_delete(buf, { force = true })
    aiagent.agents["Feature"] = nil
  end)

  it("returns nil for a worktree-tagged buffer whose agent has no slug", function()
    local buf = vim.api.nvim_create_buf(false, true)
    vim.b[buf].aiagent_name = "Feature"
    aiagent.agents["Feature"] = { slug = nil }

    local result = aiagent.bufferline_name_formatter({
      bufnr = buf,
      path  = "/some/path/main.lua",
      name  = "main.lua",
    })

    assert.is_nil(result)
    vim.api.nvim_buf_delete(buf, { force = true })
    aiagent.agents["Feature"] = nil
  end)
end)

describe("aiagent state", function()
  before_each(reset)

  it("list() returns empty table when no agents are running", function()
    assert.same({}, aiagent.list())
  end)

  it("is_open() returns false before any agent is opened", function()
    assert.is_false(aiagent.is_open())
  end)

  it("pending_context_count() returns 0 when no agent is active", function()
    assert.equals(0, aiagent.pending_context_count())
  end)
end)

describe("aiagent.install_skill", function()
  local dest

  before_each(function()
    dest = vim.fn.tempname() .. "/skills/prompt-history"
  end)
  after_each(function()
    vim.fn.delete(vim.fn.fnamemodify(dest, ":h:h"), "rf")
  end)

  it("copies the bundled skill and substitutes the real hooks path", function()
    -- hooks = false: skip the (interactive) settings.json wiring.
    assert.is_true(aiagent.install_skill({ dest = dest, hooks = false }))

    -- Files land at the destination, preserving the reference/ subdirectory.
    assert.equals(1, vim.fn.filereadable(dest .. "/SKILL.md"))
    assert.equals(1, vim.fn.filereadable(dest .. "/reference/install.md"))

    -- The placeholder is gone, replaced by this install's absolute hooks dir.
    local hooks = aiagent._plugin_root() .. "/hooks"
    local skill = table.concat(vim.fn.readfile(dest .. "/SKILL.md"), "\n")
    assert.is_nil(skill:find("__AIAGENT_HOOKS_DIR__", 1, true))
    assert.is_not_nil(skill:find(hooks .. "/prompt_history_inspect.sh", 1, true))
  end)

  it("refuses to overwrite an existing install unless forced", function()
    assert.is_true(aiagent.install_skill({ dest = dest, hooks = false }))

    local level
    local orig = vim.notify
    vim.notify = function(_, lvl) level = lvl end
    local result = aiagent.install_skill({ dest = dest, hooks = false })
    vim.notify = orig

    assert.is_false(result)
    assert.equals(vim.log.levels.WARN, level)

    -- force = true goes through.
    assert.is_true(aiagent.install_skill({ dest = dest, force = true, hooks = false }))
  end)
end)

describe("aiagent.install_hooks", function()
  local settings

  before_each(function()
    settings = vim.fn.tempname() .. "/settings.json"
    vim.fn.mkdir(vim.fn.fnamemodify(settings, ":h"), "p")
  end)
  after_each(function()
    vim.fn.delete(vim.fn.fnamemodify(settings, ":h"), "rf")
  end)

  it("adds both capture hooks while preserving unrelated settings", function()
    -- An empty array would become {} under a naive JSON round-trip — the jq
    -- merge must keep it an array.
    vim.fn.writefile(vim.split(vim.fn.json_encode({
      permissions = { allow = {} },
      hooks = { PreToolUse = { { hooks = { { type = "command", command = "/x/other.sh" } } } } },
    }), "\n"), settings)

    local changes, wrote = aiagent.install_hooks({ settings = settings })
    assert.is_true(wrote)
    assert.equals(2, #changes)

    local result = vim.fn.json_decode(vim.fn.readfile(settings))
    assert.equals("table", type(result.permissions.allow))
    assert.equals(0, #result.permissions.allow)            -- still an empty array
    assert.is_not_nil(result.hooks.PreToolUse)             -- unrelated hook kept
    local cmd = result.hooks.UserPromptSubmit[1].hooks[1].command
    assert.is_not_nil(cmd:find("prompt_snapshot.sh pre", 1, true))
    -- A backup of the original was written.
    assert.equals(1, vim.fn.filereadable(settings .. ".bak"))
  end)

  it("is idempotent — a second run wires nothing", function()
    aiagent.install_hooks({ settings = settings })
    local changes, wrote = aiagent.install_hooks({ settings = settings })
    assert.is_false(wrote)
    for _, c in ipairs(changes) do
      assert.is_not_nil(c:find("already wired", 1, true))
    end
  end)
end)

describe("prompthistory.build_primer", function()
  local ph = require("aiagent.prompthistory")
  local repo

  -- Run a git command in the temp repo and return trimmed stdout.
  local function git(...)
    local args = { "git", "-C", repo }
    for _, a in ipairs({ ... }) do table.insert(args, a) end
    local out = vim.fn.system(args)
    return (out:gsub("%s+$", ""))
  end

  before_each(function()
    repo = vim.fn.tempname()
    vim.fn.mkdir(repo, "p")
    git("init", "-q")
    git("config", "user.email", "t@t.t")
    git("config", "user.name", "t")
  end)
  after_each(function()
    vim.fn.delete(repo, "rf")
  end)

  -- Snapshot the working tree into the object store the way the capture hook
  -- does, returning the resulting tree SHA.
  local function write_tree()
    git("add", "-A")
    return git("write-tree")
  end

  it("renders prompts, changed files, and diffs from a session log", function()
    vim.fn.writefile({ "one" }, repo .. "/a.txt")
    local before = write_tree()
    vim.fn.writefile({ "two" }, repo .. "/a.txt")
    vim.fn.writefile({ "new" }, repo .. "/b.txt")
    local after = write_tree()

    local hist = repo .. "/.prompt-history/sessions"
    vim.fn.mkdir(hist, "p")
    local rec = {
      session = "sess1", started = "2026-06-26", ended = "2026-06-26",
      prompt = "change a and add b", before_tree = before, after_tree = after,
      changed_files = 2,
    }
    vim.fn.writefile({ vim.fn.json_encode(rec) }, hist .. "/sess1.jsonl")

    local text, err = ph.build_primer("sess1", repo)
    assert.is_nil(err)
    assert.is_not_nil(text)
    assert.is_not_nil(text:find("change a and add b", 1, true))   -- the prompt
    assert.is_not_nil(text:find("M  a.txt", 1, true))             -- modified file
    assert.is_not_nil(text:find("A  b.txt", 1, true))             -- added file
    assert.is_not_nil(text:find("```diff", 1, true))              -- diff fence
    assert.is_not_nil(text:find("+two", 1, true))                 -- diff content
    assert.is_not_nil(text:find("USER's prompts only", 1, true))  -- the caveat
    -- The capture-skip sentinel must be the very first line so the hook can
    -- recognise the primer and not re-record it.
    assert.equals(ph.PRIMER_MARKER, text:match("^[^\n]*"))
  end)

  it("returns an error for an unknown session", function()
    local text, err = ph.build_primer("nope", repo)
    assert.is_nil(text)
    assert.is_not_nil(err)
  end)
end)

describe("aiagent.registry", function()
  local registry = require("aiagent.registry")
  local state_dir, orig_state

  before_each(function()
    orig_state = vim.env.XDG_STATE_HOME
    state_dir = vim.fn.tempname()
    vim.env.XDG_STATE_HOME = state_dir
    aiagent.close_all()
    aiagent.setup({})
    -- setup() merges with tbl_deep_extend, which cannot delete keys, so a
    -- focus_cmd left by an earlier test has to be unset directly.
    aiagent.config.focus_cmd = nil
  end)

  after_each(function()
    aiagent.close_all()
    aiagent.config.focus_cmd = nil
    vim.env.XDG_STATE_HOME = orig_state
    vim.fn.delete(state_dir, "rf")
  end)

  --- Register a fake agent backed by a real process, so its job pid is alive.
  local function fake_agent(name, fields)
    local job = vim.fn.jobstart({ "sleep", "30" })
    aiagent.agents[name] = vim.tbl_extend("force", {
      buf = nil, job_id = job, agent_type = "claude", command = "claude",
      color = "red", sent_files = {},
    }, fields or {})
    aiagent.current_agent = name
    return job
  end

  it("publishes a sidecar and reads it back", function()
    local job = fake_agent("Pub")
    assert.is_true(registry.publish("Pub"))
    assert.equals(1, vim.fn.filereadable(registry.path_for("Pub")))

    local entries = registry.read_all({ derive = false })
    assert.equals(1, #entries)
    assert.equals("Pub", entries[1].agent)
    assert.is_true(entries[1].is_local)
    assert.is_true(entries[1].current)
    assert.equals(vim.fn.getpid(), entries[1].nvim_pid)
    assert.equals(vim.fn.jobpid(job), entries[1].job_pid)

    registry.unpublish("Pub")
    assert.equals(0, vim.fn.filereadable(registry.path_for("Pub")))
    vim.fn.jobstop(job)
  end)

  it("drops the sidecar when the agent is closed", function()
    fake_agent("Gone")
    registry.publish("Gone")
    aiagent.close("Gone")
    assert.equals(0, vim.fn.filereadable(registry.path_for("Gone")))
  end)

  it("prunes entries whose owning Neovim is dead", function()
    vim.fn.mkdir(registry.dir(), "p")
    local stale = registry.dir() .. "/999998-Ghost.json"
    vim.fn.writefile({ vim.fn.json_encode({
      agent = "Ghost", nvim_pid = 999998, job_pid = 999997,
    }) }, stale)

    local entries = registry.read_all({ derive = false })

    assert.equals(0, #entries)
    assert.equals(0, vim.fn.filereadable(stale))
  end)

  it("prunes entries whose agent process is dead", function()
    vim.fn.mkdir(registry.dir(), "p")
    local dead = registry.dir() .. "/" .. vim.fn.getpid() .. "-Dead.json"
    vim.fn.writefile({ vim.fn.json_encode({
      agent = "Dead", nvim_pid = vim.fn.getpid(), job_pid = 999997,
    }) }, dead)

    assert.equals(0, #registry.read_all({ derive = false }))
    assert.equals(0, vim.fn.filereadable(dead))
  end)

  it("set_task overrides the label and an empty task clears it", function()
    local job = fake_agent("Task")
    aiagent.set_task("rewrite the parser", "Task")
    assert.equals("rewrite the parser", aiagent.agents["Task"].task)
    assert.equals("rewrite the parser", registry.read_all({ derive = false })[1].label)

    aiagent.set_task("", "Task")
    assert.is_nil(aiagent.agents["Task"].task)
    assert.is_nil(registry.read_all({ derive = false })[1].label)
    vim.fn.jobstop(job)
  end)

  it("render marks the local current agent and pads columns", function()
    local lines, hls = registry.render({
      { agent = "Alpha", color = "red", current = true, is_local = true,
        status = "busy", branch = "agent/a", cwd = "/tmp/a", label = "one" },
      { agent = "B",     color = "blue", status = "idle", status_age = 240,
        branch = "agent/b", cwd = "/tmp/b", label = "two" },
    })

    assert.equals(2, #lines)
    assert.is_truthy(lines[1]:match("^ ▶ Alpha"))
    assert.is_truthy(lines[2]:match("^   B"))
    assert.is_truthy(lines[1]:match("busy"))
    assert.is_truthy(lines[2]:match("idle 4m"))

    -- Columns line up on screen.  Byte offsets do NOT match: the ▶ marker is
    -- three bytes wide but one cell, so display width is what must be compared.
    local function col_of(line, text)
      return vim.fn.strdisplaywidth(line:sub(1, line:find(text) - 1))
    end
    assert.equals(col_of(lines[1], "agent/a"), col_of(lines[2], "agent/b"))
    assert.equals(col_of(lines[1], "one"), col_of(lines[2], "two"))

    -- Highlight ranges are byte offsets, and must land exactly on the name.
    local name_hl
    for _, h in ipairs(hls) do
      if h.line == 0 and h.group == "AIAgentListName_red" then name_hl = h end
    end
    assert.is_truthy(name_hl)
    assert.equals("Alpha", lines[1]:sub(name_hl.col + 1, name_hl.end_col))
  end)

  it("focus_cmd prefers a multiplexer, then the emulator, else nil", function()
    assert.same({ "tmux", "switch-client", "-t", "%3" },
      registry.focus_cmd({ term = { tmux = "%3", iterm = "GUID" } }))

    local iterm = registry.focus_cmd({ term = { iterm = "GUID-1" } })
    assert.equals("osascript", iterm[1])
    assert.is_truthy(iterm[3]:match('iTerm2'))
    assert.is_truthy(iterm[3]:match('GUID%-1'))

    assert.is_nil(registry.focus_cmd({ term = {} }))
    assert.is_nil(registry.focus_cmd({}))
  end)

  it("focus_cmd honours the config.focus_cmd override", function()
    aiagent.setup({ focus_cmd = function(entry) return { "raise", entry.agent } end })
    assert.same({ "raise", "X" },
      registry.focus_cmd({ agent = "X", term = { tmux = "%3" } }))
  end)

  it("focus switches locally, or drives the owning instance remotely", function()
    -- A local entry is just a switch in this instance; nothing is spawned.
    local opened
    local orig_open = aiagent.open
    aiagent.open = function(name) opened = name end

    registry.focus({ agent = "Mine", is_local = true })
    assert.equals("Mine", opened)

    -- A remote entry with no known terminal must warn rather than error, and
    -- must not touch this instance.
    opened = nil
    local level
    local orig_notify = vim.notify
    vim.notify = function(_, lvl) level = lvl end

    registry.focus({ agent = "Theirs", is_local = false, nvim_pid = 999998,
                     cwd = "/tmp/x", term = {} })

    vim.notify = orig_notify
    aiagent.open = orig_open
    assert.is_nil(opened)
    assert.equals(vim.log.levels.WARN, level)
  end)

  it("focus warns instead of throwing on a non-executable focus command", function()
    -- jobstart() raises E475 on a bad argv[0]; a hand-written focus_cmd or a
    -- missing multiplexer binary must degrade to a warning, not an error.
    aiagent.config.focus_cmd = function() return { "aiagent-no-such-binary", "x" } end

    local level
    local orig_notify = vim.notify
    vim.notify = function(_, lvl) level = lvl end

    local ok = pcall(registry.focus, { agent = "T", is_local = false,
                                       nvim_pid = 999998, term = { tmux = "%1" } })

    vim.notify = orig_notify
    assert.is_true(ok)
    assert.equals(vim.log.levels.WARN, level)
  end)

  it("human_text ignores tool results and strips injected envelopes", function()
    local human_text = registry._human_text

    assert.equals("plain prompt", human_text({ content = "plain prompt" }))
    assert.equals("typed text", human_text({
      content = { { type = "text", text = "typed text" } },
    }))
    -- a tool result is not a human turn
    assert.is_nil(human_text({ content = { { type = "tool_result", content = "x" } } }))
    -- slash-command echoes and reminders are stripped, leaving the real prompt
    assert.equals("the real prompt", human_text({
      content = "<command-name>/color</command-name>\n<system-reminder>noise</system-reminder>\nthe real prompt",
    }))
    assert.is_nil(human_text({ content = "" }))
    assert.is_nil(human_text(nil))
  end)

  it("last_prompt returns the newest human prompt from a transcript", function()
    local home = vim.fn.tempname()
    local orig_home = vim.env.HOME
    vim.env.HOME = home

    local cwd = "/work/proj"
    local session = "sess-1"
    local dir = home .. "/.claude/projects/" .. cwd:gsub("[^%w%-]", "-")
    vim.fn.mkdir(dir, "p")
    vim.fn.writefile({
      vim.fn.json_encode({ type = "user", message = { content = "first prompt" } }),
      vim.fn.json_encode({ type = "assistant", message = { content = "reply" } }),
      vim.fn.json_encode({ type = "user", message = { content = "second prompt" } }),
      -- newest entry is a tool result, which must be skipped
      vim.fn.json_encode({ type = "user",
        message = { content = { { type = "tool_result", content = "output" } } } }),
    }, dir .. "/" .. session .. ".jsonl")

    assert.equals("second prompt", registry.last_prompt(session, cwd))
    assert.is_nil(registry.last_prompt("missing", cwd))
    assert.is_nil(registry.last_prompt(nil, cwd))

    vim.env.HOME = orig_home
    vim.fn.delete(home, "rf")
  end)
end)
