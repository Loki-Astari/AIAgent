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
