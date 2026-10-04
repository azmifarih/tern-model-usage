-- model-usage — live omp model usage in Tern's status line.
--
-- Polls `omp usage --json` (coding-plan quota windows) and renders a status-line
-- segment: "usage codex 30% · cc 12%", tinted warn/error as a window fills.
-- Click the segment to see the full per-window breakdown; the "Model Usage" palette commands refresh,
-- show the per-window breakdown, hide the segment, or show the status line.

local POLL_MS = 180000 -- quota windows move slowly, and omp caches reports ~5 min

local PROVIDER_LABELS = {
	["openai-codex"] = "codex",
	["opencode-go"] = "opencode",
	["commandcode"] = "cc",
	["anthropic"] = "claude",
	["google-gemini-cli"] = "gemini-cli",
	["google-antigravity"] = "antigravity",
}

local state = { text = nil, tone = nil, detail = nil, err = nil, raw = nil, canvasPane = nil }
local enabled = true
local polling = false
local lastPoll = nil

local function providerLabel(id)
	return PROVIDER_LABELS[id] or id
end

-- User config lives in the plugin's data directory (next to kv.json), so it
-- survives reinstalling the plugin: <data>/config.json. Missing keys fall back
-- to the defaults below; a missing file is written with those defaults, and a
-- malformed one keeps the last good config and logs a warning.
local SHOW_VALUES = { one = true, all = true }
local PICK_VALUES = { max = true, min = true, first = true }

local function defaultConfig()
	return {
		show = "one", -- one | all — one picked window per provider, or every matching window
		pick = "max", -- max | min | first — how to pick when show = "one"
		windows = {}, -- allowlist in display order; empty means every window omp reports
		label = true, -- include the window id (5h, 7d, monthly) in the segment
		exclude = {}, -- provider ids to leave out entirely
		providers = {}, -- per-provider overrides of the keys above
	}
end

local CONFIG_PATH = nil
local config = defaultConfig()

local function configPath()
	if not CONFIG_PATH then
		CONFIG_PATH = tern.plugin.data .. "/config.json"
	end
	return CONFIG_PATH
end

local function applyConfig(base, data)
	local show = data.show
	if show ~= nil then
		if type(show) == "string" and SHOW_VALUES[show] then
			base.show = show
		else
			tern.log.warn(string.format("model-usage: config.show = %s is not one|all", tostring(show)))
		end
	end
	local pick = data.pick
	if pick ~= nil then
		if type(pick) == "string" and PICK_VALUES[pick] then
			base.pick = pick
		else
			tern.log.warn(string.format("model-usage: config.pick = %s is not max|min|first", tostring(pick)))
		end
	end
	if type(data.label) == "boolean" then
		base.label = data.label
	end
	for _, key in ipairs({ "windows", "exclude" }) do
		if type(data[key]) == "table" then
			local list = {}
			for _, item in ipairs(data[key]) do
				if type(item) == "string" then
					list[#list + 1] = item
				end
			end
			base[key] = list
		end
	end
	if type(data.providers) == "table" then
		base.providers = data.providers
	end
	return base
end

local function loadConfig()
	local path = configPath()
	if not tern.fs.exists(path) then
		pcall(tern.fs.write, path, tern.json.encode(defaultConfig(), true) .. "\n")
		return defaultConfig(), nil
	end
	local okRead, text = pcall(tern.fs.read, path)
	if not okRead then
		return nil, "config.json is unreadable"
	end
	local okDecode, data = pcall(tern.json.decode, text)
	if not okDecode or type(data) ~= "table" then
		return nil, "config.json is not a JSON object"
	end
	return applyConfig(defaultConfig(), data), nil
end

-- The effective keys for one provider: the global ones, overridden by its entry.
local function providerConfig(provider)
	local view = { show = config.show, pick = config.pick, windows = config.windows, label = config.label }
	local override = config.providers[provider]
	if type(override) == "table" then
		applyConfig(view, override)
	end
	return view
end

local function inWindows(id, allow)
	if #allow == 0 then
		return true
	end
	if type(id) ~= "string" then
		return false
	end
	local lower = id:lower()
	for _, item in ipairs(allow) do
		if item:lower() == lower then
			return true
		end
	end
	return false
end

-- Candidates in the config's window order when an allowlist is set, else as reported.
local function ordered(cands, allow)
	if #allow == 0 then
		return cands
	end
	local out = {}
	for _, want in ipairs(allow) do
		for _, cand in ipairs(cands) do
			if cand.id and cand.id:lower() == want:lower() then
				out[#out + 1] = cand
			end
		end
	end
	return out
end

local function pickOne(cands, pick)
	local best = cands[1]
	for _, cand in ipairs(cands) do
		if pick == "min" and cand.used < best.used then
			best = cand
		elseif pick == "max" and cand.used > best.used then
			best = cand
		end
	end
	return best
end

local function kvGet(key)
	local ok, value = pcall(tern.kv.get, key)
	return ok and value or nil
end

local function kvSet(key, value)
	pcall(tern.kv.set, key, value)
end

local function formatReset(resetsAt, nowMs)
	if type(resetsAt) ~= "number" or type(nowMs) ~= "number" then
		return ""
	end
	local mins = math.floor((resetsAt - nowMs) / 60000)
	if mins < 0 then
		return ""
	end
	if mins >= 1440 then
		return string.format(", resets in %dd %dh", math.floor(mins / 1440), math.floor(mins % 1440 / 60))
	end
	if mins >= 60 then
		return string.format(", resets in %dh %dm", math.floor(mins / 60), mins % 60)
	end
	return string.format(", resets in %dm", mins)
end

-- omp's UsageReport[] -> one status line plus a detail list. The most constrained
-- window per provider wins; providers are deduplicated across credentials.
local function summarize(text)
	local ok, data = pcall(tern.json.decode, text)
	if not ok or type(data) ~= "table" then
		return nil
	end
	local nowMs = data.generatedAt
	local seen, order = {}, {}
	local worst = 0
	for _, report in ipairs(data.reports or {}) do
		local provider = report.provider or "?"
		local best
		for _, limit in ipairs(report.limits or {}) do
			local amount = limit.amount or {}
			local used = amount.usedFraction
			if type(used) ~= "number" then
				used = (type(amount.used) == "number" and type(amount.limit) == "number" and amount.limit > 0)
						and amount.used / amount.limit
					or 0
			end
			if not best or used > best.used then
				best = {
					used = used,
					id = limit.window and limit.window.id,
					window = (limit.window and limit.window.label) or limit.label or "window",
					resetsAt = limit.window and limit.window.resetsAt,
					status = limit.status,
				}
			end
		end
		if best then
			local entry = seen[provider]
			if not entry then
				entry = { best = best }
				seen[provider] = entry
				order[#order + 1] = provider
			end
			if best.used > entry.best.used then
				entry.best = best
			end
		end
	end
	if #order == 0 then
		return nil
	end
	local parts, details = {}, {}
	for _, provider in ipairs(order) do
		local best = seen[provider].best
		local pct = math.floor(best.used * 100 + 0.5)
		parts[#parts + 1] = best.id and string.format("%s %s %d%%", providerLabel(provider), best.id, pct)
			or string.format("%s %d%%", providerLabel(provider), pct)
		if best.used > worst then
			worst = best.used
		end
		details[#details + 1] = string.format(
			"%s: %s %d%% used%s%s",
			provider,
			best.window,
			pct,
			formatReset(best.resetsAt, nowMs),
			best.status and best.status ~= "ok" and (" [" .. best.status .. "]") or ""
		)
	end
	local tone
	if worst >= 0.9 then
		tone = "error"
	elseif worst >= 0.75 then
		tone = "warn"
	end
	return table.concat(parts, " · "), tone, table.concat(details, " · ")
end

-- The last good report is cached in the plugin's data directory, trimmed to the
-- fields the plugin renders (report metadata carries account ids and an email,
-- which have no business in a status line cache). A fresh window — or a plugin
-- reload — paints the segment and opens the details pane from this instead of
-- going blank until omp answers again.
local CACHE_PATH = nil

local function cachePath()
	if not CACHE_PATH then
		CACHE_PATH = tern.plugin.data .. "/usage.json"
	end
	return CACHE_PATH
end

local function trimReport(text)
	local ok, data = pcall(tern.json.decode, text)
	if not ok or type(data) ~= "table" then
		return nil
	end
	local reports = {}
	for _, report in ipairs(data.reports or {}) do
		local limits = {}
		for _, limit in ipairs(report.limits or {}) do
			local amount = limit.amount or {}
			local window = limit.window
			limits[#limits + 1] = {
				label = limit.label,
				window = window and { id = window.id, label = window.label, resetsAt = window.resetsAt },
				amount = {
					used = amount.used,
					limit = amount.limit,
					usedFraction = amount.usedFraction,
				},
				status = limit.status,
			}
		end
		reports[#reports + 1] = { provider = report.provider, limits = limits }
	end
	return tern.json.encode({ generatedAt = data.generatedAt, reports = reports }, true)
end

local function saveCache(raw)
	local trimmed = trimReport(raw)
	if trimmed then
		pcall(tern.fs.write, cachePath(), trimmed .. "\n")
	end
end

-- Restores the segment and the detail list from the cache. `tern.now()` is a
-- monotonic clock, not wall time, so the cache cannot be aged against the
-- report's epoch stamp; instead the stamp stays part of the data, which keeps
-- every "resets in …" string correct, and any live window replaces the restored
-- numbers within one poll.
local function restoreCache()
	local okRead, text = pcall(tern.fs.read, cachePath())
	if not okRead or type(text) ~= "string" or text == "" then
		return false
	end
	local okDecode, data = pcall(tern.json.decode, text)
	if not okDecode or type(data) ~= "table" or type(data.generatedAt) ~= "number" then
		return false
	end
	local seg, tone, detail = summarize(text)
	if not seg then
		return false
	end
	state.raw, state.text, state.tone, state.detail = text, seg, tone, detail
	return true
end

-- Candidate invocations, most reliable first: a bun interpreter beats an omp
-- shim whose `#!/usr/bin/env bun` needs bun on PATH, which Tern's own env may lack.
local function ompCommands()
	local home = tern.getenv("HOME") or ""
	local cmds = {}
	local function file(path)
		return tern.fs.exists(path)
	end
	if home ~= "" then
		local bun = home .. "/.bun/bin/bun"
		if file(bun) then
			for _, cli in ipairs({
				home .. "/node_modules/@oh-my-pi/pi-coding-agent/dist/cli.js",
				home .. "/.bun/install/global/node_modules/@oh-my-pi/pi-coding-agent/dist/cli.js",
			}) do
				if file(cli) then
					cmds[#cmds + 1] = { bun, cli, "usage", "--json" }
				end
			end
		end
		for _, bin in ipairs({ home .. "/.bun/bin/omp", home .. "/.local/bin/omp" }) do
			if file(bin) then
				cmds[#cmds + 1] = { bin, "usage", "--json" }
			end
		end
	end
	cmds[#cmds + 1] = { "omp", "usage", "--json" }
	cmds[#cmds + 1] = { "sh", "-lc", "omp usage --json" }
	return cmds
end

-- Polls omp, falling through to the next candidate when a spawn fails or the
-- command itself cannot be found (126/127).
local function fetchUsage(cb)
	local cmds = ompCommands()
	local index = 0
	local function attempt()
		index = index + 1
		local argv = cmds[index]
		if not argv then
			cb(nil, "omp not found")
			return
		end
		local ok, awaitable = pcall(tern.process.run, argv, { timeout_ms = 60000 })
		if not ok then
			attempt()
			return
		end
		awaitable:next(function(result, err, cx)
			if err or not result then
				attempt()
				return
			end
			if result.status == 126 or result.status == 127 then
				attempt()
				return
			end
			if result.status ~= 0 or result.stdout == "" then
				local why = (result.stderr or ""):match("^[^\n]*") or ""
				cb(nil, string.format("%s usage failed (exit %s%s)", argv[1], tostring(result.status), why ~= "" and (": " .. why) or ""))
				return
			end
			cb(result.stdout, nil, cx)
		end)
	end
	attempt()
end

-- Full multi-line usage breakdown: every window for every provider.
local function fullUsageText(text)
	local ok, data = pcall(tern.json.decode, text)
	if not ok or type(data) ~= "table" then
		return nil
	end
	local nowMs = data.generatedAt
	local seen, order = {}, {}
	for _, report in ipairs(data.reports or {}) do
		local provider = report.provider or "?"
		if not seen[provider] then
			seen[provider] = true
			order[#order + 1] = provider
		end
	end
	local lines = {}
	for _, provider in ipairs(order) do
		lines[#lines + 1] = providerLabel(provider) .. ":"
		for _, report in ipairs(data.reports or {}) do
			if report.provider == provider then
				for _, limit in ipairs(report.limits or {}) do
					local amount = limit.amount or {}
					local used = amount.usedFraction
					if type(used) ~= "number" then
						used = (type(amount.used) == "number" and type(amount.limit) == "number" and amount.limit > 0)
							and amount.used / amount.limit
						or 0
					end
					local pct = math.floor(used * 100 + 0.5)
					local label = (limit.window and limit.window.label) or limit.label or "window"
					local reset = formatReset(limit.window and limit.window.resetsAt or nil, nowMs)
					local status = limit.status and limit.status ~= "ok" and (" [" .. limit.status .. "]") or ""
					lines[#lines + 1] = string.format("  %s: %d%% used%s%s", label, pct, reset, status)
				end
			end
		end
		lines[#lines + 1] = ""
	end
	return table.concat(lines, "\n")
end

-- Collects (provider, window, used, resetsAt, status) rows from the raw report,
-- deduplicated per provider in report order.
local function usageRows(data)
	local seen, order, byProvider = {}, {}, {}
	for _, report in ipairs(data.reports or {}) do
		local provider = report.provider or "?"
		if not seen[provider] then
			seen[provider] = true
			order[#order + 1] = provider
			byProvider[provider] = {}
		end
		for _, limit in ipairs(report.limits or {}) do
			local amount = limit.amount or {}
			local used = amount.usedFraction
			if type(used) ~= "number" then
				used = (type(amount.used) == "number" and type(amount.limit) == "number" and amount.limit > 0)
						and amount.used / amount.limit
					or 0
			end
			byProvider[provider][#byProvider[provider] + 1] = {
				label = (limit.window and limit.window.label) or limit.label or "window",
				id = limit.window and limit.window.id,
				used = used,
				resetsAt = limit.window and limit.window.resetsAt,
				status = limit.status,
			}
		end
	end
	return order, byProvider
end

-- A rich, persistent canvas view: one card per provider with a table row per
-- quota window (bar, percent, reset, status). Returns nil when unsupported.
local function buildUsageView(text)
	local ui = tern.ui
	if not ui then
		return nil
	end
	local ok, data = pcall(tern.json.decode, text)
	if not ok or type(data) ~= "table" then
		return nil
	end
	local nowMs = data.generatedAt
	local order, byProvider = usageRows(data)
	if #order == 0 then
		return nil
	end
	-- Plain `ui.text` lines instead of `ui.table`: with the table node, every
	-- card after the first laid out its frame but painted nothing — no header
	-- row, no cells — while the view itself held every row. Text lines avoid
	-- that node entirely.
	local cards = {}
	for _, provider in ipairs(order) do
		local lines = {}
		for _, w in ipairs(byProvider[provider]) do
			local pct = math.floor(w.used * 100 + 0.5)
			local name = w.id and string.format("%s (%s)", w.label, w.id) or w.label
			local reset = formatReset(w.resetsAt, nowMs)
			reset = (reset:gsub("^, ", ""))
			local status = w.status or "ok"
			-- Same thresholds the status line uses: warn at 75%, error at 90%.
			local pctTone
			if w.used >= 0.9 then
				pctTone = "error"
			elseif w.used >= 0.75 then
				pctTone = "warn"
			end
			local bar = math.min(10, math.max(0, math.floor(w.used * 10 + 0.5)))
			lines[#lines + 1] = ui.text({
				ui.span(name, "strong"),
				ui.span(string.format("  %d%%  ", pct), pctTone),
				ui.span(string.rep("█", bar) .. string.rep("·", 10 - bar), pctTone or "muted"),
				ui.span(reset ~= "" and ("  " .. reset) or "", "muted"),
				ui.span("  " .. status, (w.status and w.status ~= "ok") and "error" or "muted"),
			})
		end
		cards[#cards + 1] = ui.card(providerLabel(provider), { ui.col(lines) })
	end
	return ui.col({
		ui.text({ ui.span("omp model usage", "strong"), ui.span(string.format(" · %d provider(s)", #order), "muted") }),
		ui.col(cards),
	})
end

-- What the pane shows while there is nothing to tabulate: the first poll is
-- still running, or it failed. Kept as a view so the pane opens on the click
-- and fills itself in when the poll lands, instead of showing nothing.
local function noticeView(message)
	return tern.ui.col({
		tern.ui.text({ tern.ui.span("omp model usage", "strong") }),
		tern.ui.text({ tern.ui.span(message, "muted") }),
	})
end

-- The current pane view: the tables once a report is in, otherwise a notice.
local function paneView()
	if state.raw then
		return buildUsageView(state.raw)
	end
	return noticeView(state.err and ("no usage: " .. state.err) or "reading quota windows from omp…")
end

-- The canvas pane showing this plugin's usage, reused across reloads.
local function findCanvas(cx)
	if not cx or not cx.canvas then
		return nil
	end
	if state.canvasPane and cx.canvas:get(state.canvasPane) then
		return state.canvasPane
	end
		state.canvasPane = nil
	local ok, list = pcall(function()
		return cx.canvas:list()
	end)
	if ok and type(list) == "table" then
		for _, info in ipairs(list) do
			local owner = tostring(info.owner or "")
			if info.title == "Model Usage" and (owner == "model-usage" or owner == "plugin:model-usage") then
				state.canvasPane = info.pane
				return info.pane
			end
		end
	end
	return nil
end

-- Opens or refreshes the canvas with the current view. `open` forces a new pane
-- when none exists; returns the pane id, or nil when the host has no canvas.
local function showUsage(cx)
	if not cx or not cx.canvas then
		return nil
	end
	local view = paneView()
	if not view then
		return nil
	end
	local pane = findCanvas(cx)
	if pane then
		local ok = pcall(function()
			cx.canvas:set(pane, { view = view })
		end)
		if ok then
			return pane
		end
		state.canvasPane = nil
	end
	local opened, err = cx.canvas:open({
		title = "Model Usage",
		about = "Live omp coding-plan usage: one row per quota window, read-only.",
		view = view,
		how = "below",
	})
	if opened then
		state.canvasPane = opened
		return opened
	end
	if err then
		tern.log.warn("model-usage: canvas open failed: " .. tostring(err))
	end
	return nil
end

-- `force` skips the gap check: a click on an empty segment must not wait out a
-- poll that already started before the click.
local function poll(cx, force)
	if polling then
		return
	end
	-- window_start and module load can both ask for a first poll within the same
	-- process; one spawn is enough.
	if not force and lastPoll and tern.now() - lastPoll < 30000 then
		return
	end
	lastPoll = tern.now()
	polling = true
	fetchUsage(function(out, err, cx)
		polling = false
		if out then
			local text, tone, detail = summarize(out)
			if text then
				state.text, state.tone, state.detail, state.err = text, tone, detail, nil
				state.raw = out
				saveCache(out)
			else
				state.err = "no usage reported"
			end
		else
			state.err = err or "omp usage failed"
		end
		-- Keep an open canvas in sync without reopening one unprompted: a pane
		-- opened while the first poll was still running shows the report as soon
		-- as it lands, and a failed poll leaves the reason in the pane.
		if state.canvasPane and cx and cx.canvas then
			local pane = state.canvasPane
			pcall(function()
				if cx.canvas:get(pane) then
					local view = paneView()
					if view then
						cx.canvas:set(pane, { view = view })
					end
				else
					state.canvasPane = nil
				end
			end)
		end
		tern.chrome.refresh()
		if state.err then
			tern.log.warn("model-usage: " .. tostring(state.err))
		else
			tern.log.info("model-usage: " .. tostring(state.text))
		end
	end)
end

-- Registration and polling run at module scope: Tern loads a plugin's window entry
-- into an already-running window, where window_start never fires again.
if kvGet("enabled") == false then
	enabled = false
end

tern.chrome.status(function(_pane)
	if not enabled or not state.text then
		return nil
	end
	return {
		{
			text = "usage " .. state.text,
			tone = state.tone,
			command = "plugin.model-usage.details",
		},
	}
end)

tern.command({
	id = "refresh",
	title = "Model Usage: Refresh",
	group = "Model Usage",
	run = function(cx)
		cx:toast("info", "Model usage", "Refreshing…")
		poll(cx, true)
	end,
})

tern.command({
	id = "details",
	title = "Model Usage: Details",
	group = "Model Usage",
	-- Never gated: before the first poll the pane still opens and fills itself.
	run = function(cx)
		local pane = showUsage(cx)
		if pane then
			-- Nothing to draw yet: the poll that fills it may have started before
			-- the click, so ask for one now unless one is already in flight.
			if not state.raw then
				poll(cx, true)
			end
			return
		end
		local detail = state.raw and fullUsageText(state.raw) or state.detail
		if not detail or detail == "" then
			detail = state.err and ("no usage: " .. state.err) or "no usage yet"
		end
		cx:toast("info", "Model usage", detail)
	end,
})

tern.command({
	id = "toggle",
	title = "Model Usage: Toggle",
	group = "Model Usage",
	run = function(cx)
		enabled = not enabled
		kvSet("enabled", enabled)
		tern.chrome.refresh()
		cx:toast("info", enabled and "Model usage segment shown" or "Model usage segment hidden")
	end,
})

tern.command({
	id = "status-line",
	title = "Model Usage: Show Status Line",
	group = "Model Usage",
	run = function(cx)
		cx.settings:set("status_bar", true)
		tern.chrome.refresh()
		cx:toast("info", "Status line enabled")
	end,
})

-- Fires only when a window starts with the plugin already installed.
tern.on("window_start", function(cx)
	local ok, shown = pcall(function()
		return cx.settings:get("status_bar")
	end)
	if ok and shown ~= true then
		pcall(function()
			cx.settings:set("status_bar", true)
		end)
	end
	poll(cx)
end)

local function loop()
	tern.timer(POLL_MS, function(cx)
		if enabled then
			poll(cx)
		end
		loop()
	end)
end

-- Paint from the cache first: a window that starts, or a reload, shows the last
-- known windows instead of a blank segment until this process's first poll.
if restoreCache() then
	tern.chrome.refresh()
end

poll()
loop()

tern.log.info("model-usage: ready")
