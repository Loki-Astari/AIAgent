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

describe("aiagent.history", function()
  local history = require("aiagent.history")
  local tmp

  -- A transcript shaped like a real one: three turns, then a rewind to before
  -- turn 2 that forks a second branch off turn 1.
  local function write_transcript(leaf)
    tmp = vim.fn.tempname() .. ".jsonl"
    local function turn(uuid, parent, prompt, reply, reply_uuid, tool)
      local lines = {
        vim.json.encode({
          type = "user", uuid = uuid, parentUuid = parent, isSidechain = false,
          origin = { kind = "human" }, timestamp = "2026-09-01T18:34:12.051Z",
          message = { role = "user", content = { { type = "text", text = prompt } } },
        }),
        vim.json.encode({
          type = "assistant", uuid = reply_uuid, parentUuid = uuid,
          timestamp = "2026-09-01T18:34:20.000Z",
          message = { role = "assistant", content = tool
            and { { type = "tool_use", name = "Edit", input = { file_path = "/repo/init.lua" } } }
            or { { type = "text", text = reply } } },
        }),
      }
      return lines
    end
    local out = {}
    vim.list_extend(out, turn("u1", vim.NIL, "first prompt", "alpha", "a1"))
    vim.list_extend(out, turn("u2", "a1", "second prompt", "beta", "a2"))
    vim.list_extend(out, turn("u3", "a2", "third prompt", "gamma", "a3"))
    -- The fork: a turn whose parent is turn 1's reply, not the newest entry.
    vim.list_extend(out, turn("u4", "a1", "branched prompt", nil, "a4", true))
    table.insert(out, vim.json.encode({
      type = "last-prompt", lastPrompt = "x", leafUuid = leaf, sessionId = "s1" }))
    vim.fn.writefile(out, tmp)
    return tmp
  end

  after_each(function()
    if tmp then vim.fn.delete(tmp) end
  end)

  it("builds a tree with a real fork and marks the active path", function()
    local tree = history.build(history.parse(write_transcript("a3")))

    assert.equals(4, #tree.turns)
    -- Turn 1 has two children: the original line and the rewound branch.
    assert.equals(2, #tree.children["u1"])
    -- The pointer names turn 3's reply, so 1-2-3 are active and the fork is not.
    assert.is_true(tree.active["u1"])
    assert.is_true(tree.active["u3"])
    assert.is_nil(tree.active["u4"])
    -- A turn's jump target is the end of its own reply, not the prompt entry.
    assert.equals("a2", tree.meta["u2"].leaf)
    -- "Where you are" is the turn OWNING the recorded leaf.
    assert.equals("u3", tree.current)
    -- Tool traffic is summarised onto the turn.
    assert.equals(1, tree.meta["u4"].tools)
    assert.same({ "init.lua" }, tree.meta["u4"].files)
  end)

  it("follows the leaf pointer onto the other branch", function()
    local tree = history.build(history.parse(write_transcript("a4")))
    assert.is_true(tree.active["u4"])
    assert.is_nil(tree.active["u2"])
    assert.is_nil(tree.active["u3"])
  end)

  it("renders the trunk in a fixed gutter and only indents forks", function()
    local tree = history.build(history.parse(write_transcript("a3")))
    local lines, hls, rows = history.render(tree, { width = 80 })

    local function row_for(uuid)
      for i, r in ipairs(rows) do if r.uuid == uuid then return i end end
    end
    -- Trunk turns all start at column 0 however deep they are: depth must not
    -- indent, or a long linear session walks off the right edge.
    for _, uuid in ipairs({ "u1", "u2", "u3" }) do
      -- Match the whole marker, not a character class: Lua patterns are byte
      -- based, so "[●▶]" is a set of the five bytes those two glyphs are made
      -- of and would match one byte of either.
      local mark = lines[row_for(uuid)]:match("^(%S+) ")
      assert.is_true(mark == "●" or mark == "▶")
    end
    -- The rewound branch is indented and drawn with the off-path marker.
    assert.is_truthy(lines[row_for("u4")]:match("^│ ○ "))
    -- Current position marker sits on the active leaf turn.
    assert.is_truthy(lines[row_for("u3")]:match("^▶ "))
    -- Rows that are graph connectors map to no turn.
    assert.is_nil(rows[row_for("u4") - 1].uuid)
    -- Highlights are byte offsets and land on the marker.
    local hit
    for _, h in ipairs(hls) do
      if h.line == row_for("u3") - 1 and h.group == "AIAgentTreeHere" then hit = h end
    end
    assert.is_truthy(hit)
    assert.equals("▶", lines[row_for("u3")]:sub(hit.col + 1, hit.end_col))
  end)

  it("plans a no-op for the current position and a jump for anything else", function()
    local tree = history.build(history.parse(write_transcript("a3")))

    assert.equals("noop", history.plan(tree, "u3").kind)

    local back = history.plan(tree, "u2")
    assert.equals("jump", back.kind)
    assert.equals("a2", back.leaf)
    assert.is_true(back.on_path)

    local across = history.plan(tree, "u4")
    assert.equals("jump", across.kind)
    assert.equals("a4", across.leaf)
    assert.is_false(across.on_path)

    assert.equals("none", history.plan(tree, "nope").kind)
  end)

  it("treats the turn owning the pointer as the current one, mid-turn or not", function()
    -- Claude Code writes the pointer when a prompt is SUBMITTED, so it names an
    -- entry part-way through the turn, never the turn's last entry.  Selecting
    -- the current node must still be a no-op rather than a pointless restart.
    local tree = history.build(history.parse(write_transcript("u3")))
    assert.equals("u3", tree.current)
    assert.equals("noop", history.plan(tree, "u3").kind)

    -- And the marker follows the same rule, even when the current turn still
    -- has children (which is exactly the state right after a jump).
    local jumped = history.build(history.parse(write_transcript("a1")))
    assert.equals("u1", jumped.current)
    assert.equals("noop", history.plan(jumped, "u1").kind)
    local lines, _, rows = history.render(jumped, { width = 80 })
    for i, r in ipairs(rows) do
      if r.uuid == "u1" then assert.is_truthy(lines[i]:match("^▶ ")) end
    end
  end)

  it("set_leaf appends a pointer that build() then follows", function()
    local path = write_transcript("a3")
    -- a4 is a leaf (the fork's tip), so the pointer can name it directly.
    assert.is_true(history.set_leaf(path, "s1", "a4", "branched prompt"))

    local tree = history.build(history.parse(path))
    assert.is_true(tree.active["u4"])
    assert.is_nil(tree.active["u3"])

    -- The original entries are untouched: moving never rewrites history.
    local raw = table.concat(vim.fn.readfile(path), "\n")
    assert.is_truthy(raw:match('"uuid":"u3"'))

    -- No anchor was needed, so nothing but the pointer was appended.
    local last = vim.fn.readfile(path)
    assert.is_truthy(last[#last]:match('"type":"last%-prompt"'))
    assert.is_truthy(last[#last]:match('"leafUuid":"a4"'))
  end)

  it("prefers the newest entry when the pointer has gone stale", function()
    -- A resumed session does not necessarily write a `last-prompt` of its own,
    -- so after a jump the newest pointer stays the one WE wrote at the branch
    -- point.  Trusting it would mark the branch point as "here" and render the
    -- turns just added as an abandoned branch.
    local path = write_transcript("a1")

    -- Two turns appended after the pointer, branching from turn 1.
    local extra_lines = {}
    local function add(uuid, parent, prompt, reply)
      table.insert(extra_lines, vim.json.encode({
        type = "user", uuid = uuid, parentUuid = parent, isSidechain = false,
        origin = { kind = "human" }, timestamp = "2026-09-03T09:00:00.000Z",
        message = { role = "user", content = { { type = "text", text = prompt } } },
      }))
      table.insert(extra_lines, vim.json.encode({
        type = "assistant", uuid = reply, parentUuid = uuid,
        timestamp = "2026-09-03T09:00:05.000Z",
        message = { role = "assistant", content = { { type = "text", text = "ok" } } },
      }))
    end
    add("u5", "a1", "new branch first", "a5")
    add("u6", "a5", "new branch second", "a6")
    vim.fn.writefile(extra_lines, path, "a")

    local tree = history.build(history.parse(path))
    assert.equals("u6", tree.current)
    assert.is_true(tree.active["u5"])
    assert.is_true(tree.active["u1"])
    -- The branch that was rewound away stays off the path.
    assert.is_nil(tree.active["u2"])
    assert.is_nil(tree.active["u3"])
    -- And selecting the tip is the no-op, not the branch point.
    assert.equals("noop", history.plan(tree, "u6").kind)
    assert.equals("jump", history.plan(tree, "u1").kind)
  end)

  it("head() trusts the pointer only while it is the newest thing written", function()
    local path = write_transcript("a2")
    local parsed = history.parse(path)
    -- Pointer is the last line in the file, so it names the position.
    assert.equals("a2", history.head(parsed))

    -- One entry appended after it and the pointer is stale, so the newest entry
    -- wins.  This is what a fork relies on to capture (and restore) a source
    -- session's position without stopping it.
    vim.fn.writefile({ vim.json.encode({
      type = "assistant", uuid = "a9", parentUuid = "a3",
      message = { role = "assistant", content = { { type = "text", text = "later" } } },
    }) }, path, "a")
    assert.equals("a9", history.head(history.parse(path)))
  end)

  it("anchors a rewind so the pointer names a real leaf", function()
    -- Resume only honours a pointer that names a LEAF; at a node with children
    -- it silently resumes the newest leaf instead.  Every rewind targets such a
    -- node, so set_leaf must give it a synthetic child to point at.
    local path = write_transcript("a3")
    assert.is_true(history.set_leaf(path, "s1", "a1", "first prompt"))

    local parsed = history.parse(path)
    -- The anchor is a child of the target, and the pointer names the anchor.
    local anchor
    for uuid, entry in pairs(parsed.nodes) do
      if entry.parentUuid == "a1" and entry.type == "system" then anchor = uuid end
    end
    assert.is_truthy(anchor)
    assert.equals(anchor, parsed.leaf)

    -- The anchor is a leaf, so a resumed session will accept the pointer.
    local children = 0
    for _, entry in pairs(parsed.nodes) do
      if entry.parentUuid == anchor then children = children + 1 end
    end
    assert.equals(0, children)

    -- The target turn is now where we are, and both old branches survive.
    local tree = history.build(parsed)
    assert.equals("u1", tree.current)
    assert.is_nil(tree.active["u2"])
    assert.equals(2, #tree.children["u1"])
  end)

end)
