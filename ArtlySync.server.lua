--[[
	Artly Sync Plugin
	Two-way file sync between Artly and Roblox Studio (Rojo-style developer tool).

	PRIMARY path — local auto-link: when the Artly desktop app is running it serves
	the sync protocol on a loopback port, and this plugin discovers it and connects
	automatically with no code and no URL (see tryLocalConnect / probeLocalInfo).
	FALLBACK path — remote: web users without the desktop app can still paste a
	one-time connect code under "Connect to a server manually". Either way tree
	sync itself is purely declarative (create / update / delete instances and
	properties, exactly like Rojo). On top of that the connected Artly agent can
	issue two explicit code commands for THIS session: "luau" (the escape hatch —
	run a chunk once at edit-time, like the command bar) and "playtest"
	(compile-check every script, then Run the place to capture runtime errors).
	Both run at plugin identity and only ever touch the local Studio session.
]]

local HttpService = game:GetService("HttpService")
local RunService = game:GetService("RunService")

---------------------------------------------------------------------------
-- Config
---------------------------------------------------------------------------
-- Baked production origin (the remote fallback for web users without the desktop
-- app). The PRIMARY path is local auto-discovery below — no URL, no code.
local DEFAULT_SERVER_URL = "https://artlyrblx.com"
local BATCH_INTERVAL = 0.2

-- Local auto-link: the Artly desktop app runs the SAME sync protocol on a
-- loopback port. We probe a small fixed window of ports and connect to the first
-- whose /info reports app == "artly-desktop" — zero input, like Rojo. Keep
-- LOCAL_PORT_COUNT in sync with SYNC_PORT_RANGE in the desktop's syncServer.ts.
local LOCAL_HOST = "http://127.0.0.1:"
local LOCAL_BASE_PORT = 48653
local LOCAL_PORT_COUNT = 5
local LOCAL_APP_ID = "artly-desktop"

-- Artly logo asset id (a Decal/Image uploaded to Roblox). Set this to your
-- uploaded logo's id (digits only) to show the real logo in the toolbar + panel
-- header; until then a clean "A" monogram tile is drawn as a fallback.
local ARTLY_LOGO_ASSET_ID = 128261725346695

-- Bump on every published update (shown in the panel footer).
local PLUGIN_VERSION = "1.3.0"

---------------------------------------------------------------------------
-- State
---------------------------------------------------------------------------
local connected = false
local uploading = false -- true while the initial existing-game upload is streaming
-- When the desktop is in on-demand mode it reads the hierarchy live, so we must
-- NOT bulk-upload the whole place (that's the freeze) — only scripts + the folders
-- that home them. Set from /info (info.scriptsOnly).
local scriptsOnly = false
local sessionId = nil
local cursor = 0
local rootInstanceId = nil
local projectToken = nil     -- project-scoped token (always set after login)
local projectName = ""
local selectedProjectId = nil
local selectedProjectName = nil
local lastSyncTime = 0
local syncCount = 0
local instanceCount = 0

-- Connect-flow state.
local autoPairing = false
local localMode = false          -- true while connected to the local desktop app
local connecting = false         -- guards against overlapping connect attempts
local localAutoEnabled = true    -- keep auto-discovering the local app while disconnected
local localAutoLoopRunning = false

local serverUrl = plugin:GetSetting("ArtlyServerUrl") or DEFAULT_SERVER_URL
local savedToken = plugin:GetSetting("ArtlyToken") or ""

local idToInstance = {}
local instanceToId = {}
local pendingChanges = {}
local pendingAdds = {}      -- id -> { instance, parentId }
local pendingRemoves = {}   -- list of ids
local pausedInstances = {}
local changeConnections = {}
local treeConnections = {}  -- service -> { added, removing }
local batchAccumulator = 0
local handledExec = {} -- execIds already handled (commands are at-least-once)

local WATCHED_SERVICES = {
	-- Order matters: smaller, edit-critical services first (scripts, GUIs, data)
	-- so they always sync even on a giant game; Workspace LAST since it's usually
	-- by far the largest (map geometry) and shouldn't block everything else.
	"ServerScriptService", "ReplicatedStorage", "StarterGui", "StarterPlayer",
	"ServerStorage", "ReplicatedFirst", "StarterPack", "Lighting",
	"SoundService", "Chat", "Teams", "MaterialService",
	"Workspace",
}

-- Forward declarations
local finishConnect
local disconnect
local softReconnect
local startAutoPair
local stopAutoPair
local tryLocalConnect
local startLocalAutoConnect

---------------------------------------------------------------------------
-- Toolbar
---------------------------------------------------------------------------
local toolbar = plugin:CreateToolbar("Artly Sync")

local TOOLBAR_ICON = (ARTLY_LOGO_ASSET_ID and ARTLY_LOGO_ASSET_ID > 0)
	and ("rbxassetid://" .. tostring(ARTLY_LOGO_ASSET_ID))
	or "rbxassetid://6031075938"

local connectButton = toolbar:CreateButton(
	"Artly Sync",
	"Open Artly Sync panel",
	TOOLBAR_ICON,
	"Artly Sync"
)

---------------------------------------------------------------------------
-- Theme — a dark "frosted glass" palette matching the Artly web app
---------------------------------------------------------------------------
-- Greys taken straight from the website: #1a1a1a panel, #2a2a2a cards, with
-- white/15 borders.
local PANEL_BG    = Color3.fromRGB(26, 26, 26)   -- #1a1a1a
local CARD        = Color3.fromRGB(42, 42, 42)   -- #2a2a2a
local INPUT_BG    = Color3.fromRGB(20, 20, 20)
local TRACK_BG    = Color3.fromRGB(33, 33, 33)   -- usage-bar track (~zinc-800)
local STROKE      = Color3.fromRGB(255, 255, 255)
local STROKE_TRANS = 0.85                         -- ~white/15
local CORNER      = 4                              -- corner radius everywhere
local TEXT        = Color3.fromRGB(236, 237, 241)
local TEXT_DIM    = Color3.fromRGB(150, 153, 161)
local TEXT_FAINT  = Color3.fromRGB(110, 113, 122)
local ACCENT      = Color3.fromRGB(73, 176, 255)  -- Artly blue (#49b0ff)
local LOGO_BLUE   = Color3.fromRGB(37, 99, 235)   -- Artly mark (#2563EB)
local CREDIT_A    = Color3.fromRGB(47, 127, 214)  -- credits bar gradient (#2f7fd6)
local CREDIT_B    = Color3.fromRGB(73, 176, 255)  -- (#49b0ff)
local FREE_A      = Color3.fromRGB(8, 145, 178)   -- free bar gradient (#0891b2)
local FREE_B      = Color3.fromRGB(34, 211, 238)  -- (#22d3ee)
local OK          = Color3.fromRGB(78, 201, 132)
local DANGER      = Color3.fromRGB(232, 90, 96)

local FONT_REG  = Font.fromEnum(Enum.Font.Gotham)
local FONT_MED  = Font.fromEnum(Enum.Font.GothamMedium)
local FONT_BOLD = Font.fromEnum(Enum.Font.GothamBold)
local FONT_BLACK = Font.fromEnum(Enum.Font.GothamBlack)

---------------------------------------------------------------------------
-- Status Widget
---------------------------------------------------------------------------
local statusWidgetInfo = DockWidgetPluginGuiInfo.new(
	Enum.InitialDockState.Right,
	false,
	false,
	320,
	520,
	280,
	380
)

local statusWidget = plugin:CreateDockWidgetPluginGui("ArtlySyncPanel", statusWidgetInfo)
statusWidget.Title = "Artly Sync"

local mainFrame = Instance.new("Frame")
mainFrame.Size = UDim2.new(1, 0, 1, 0)
mainFrame.BackgroundColor3 = PANEL_BG
mainFrame.BorderSizePixel = 0
mainFrame.Parent = statusWidget

local mainPadding = Instance.new("UIPadding")
mainPadding.PaddingTop = UDim.new(0, 14)
mainPadding.PaddingBottom = UDim.new(0, 14)
mainPadding.PaddingLeft = UDim.new(0, 14)
mainPadding.PaddingRight = UDim.new(0, 14)
mainPadding.Parent = mainFrame

local mainLayout = Instance.new("UIListLayout")
mainLayout.Padding = UDim.new(0, 12)
mainLayout.SortOrder = Enum.SortOrder.LayoutOrder
mainLayout.Parent = mainFrame

---------------------------------------------------------------------------
-- UI Helpers
---------------------------------------------------------------------------
local function addCorner(inst, radius)
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, radius or CORNER)
	c.Parent = inst
	return c
end

local function addStroke(inst, color, transparency, thickness)
	local s = Instance.new("UIStroke")
	s.Color = color or STROKE
	s.Transparency = transparency or STROKE_TRANS
	s.Thickness = thickness or 1
	s.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	s.Parent = inst
	return s
end

local function addPadding(inst, top, right, bottom, left)
	local p = Instance.new("UIPadding")
	p.PaddingTop = UDim.new(0, top)
	p.PaddingRight = UDim.new(0, right)
	p.PaddingBottom = UDim.new(0, bottom)
	p.PaddingLeft = UDim.new(0, left)
	p.Parent = inst
	return p
end

-- A rounded grey card matching the website's #2a2a2a panels (white/15 border).
local function makeCard(parent, order)
	local card = Instance.new("Frame")
	card.Size = UDim2.new(1, 0, 0, 0)
	card.AutomaticSize = Enum.AutomaticSize.Y
	card.BackgroundColor3 = CARD
	card.BackgroundTransparency = 0
	card.BorderSizePixel = 0
	card.LayoutOrder = order
	card.Parent = parent
	addCorner(card)
	addStroke(card)
	return card
end

local function makeLabel(parent, text, order, size, color)
	local label = Instance.new("TextLabel")
	label.Size = UDim2.new(1, 0, 0, size or 16)
	label.Text = text
	label.TextColor3 = color or TEXT_DIM
	label.BackgroundTransparency = 1
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.TextSize = 13
	label.FontFace = FONT_MED
	label.LayoutOrder = order
	label.Parent = parent
	return label
end

local function makeInput(parent, placeholder, order, defaultText)
	local box = Instance.new("TextBox")
	box.Size = UDim2.new(1, 0, 0, 34)
	box.Text = defaultText or ""
	box.PlaceholderText = placeholder
	box.BackgroundColor3 = INPUT_BG
	box.BackgroundTransparency = 0
	box.TextColor3 = TEXT
	box.PlaceholderColor3 = TEXT_FAINT
	box.BorderSizePixel = 0
	box.TextSize = 13
	box.ClearTextOnFocus = false
	box.TextXAlignment = Enum.TextXAlignment.Left
	box.FontFace = FONT_MED
	-- Keep long values (the connect code is ~46 chars) inside the box: clip to the
	-- rounded bounds and truncate with an ellipsis instead of bleeding past the border.
	box.ClipsDescendants = true
	box.TextTruncate = Enum.TextTruncate.AtEnd
	box.LayoutOrder = order
	box.Parent = parent

	addCorner(box)
	local stroke = addStroke(box, STROKE, STROKE_TRANS, 1)
	addPadding(box, 0, 11, 0, 11)

	-- Accent the border while focused (a small premium touch).
	box.Focused:Connect(function()
		stroke.Color = ACCENT
		stroke.Transparency = 0.35
	end)
	box.FocusLost:Connect(function()
		stroke.Color = STROKE
		stroke.Transparency = STROKE_TRANS
	end)

	return box
end

local function makeButton(parent, text, order, bgColor)
	local btn = Instance.new("TextButton")
	btn.Size = UDim2.new(1, 0, 0, 36)
	btn.Text = text
	btn.BackgroundColor3 = bgColor or ACCENT
	btn.TextColor3 = Color3.fromRGB(255, 255, 255)
	btn.BorderSizePixel = 0
	btn.TextSize = 14
	btn.FontFace = FONT_BOLD
	btn.LayoutOrder = order
	btn.AutoButtonColor = true
	btn.Parent = parent

	addCorner(btn)
	return btn
end

-- A labelled usage bar (matches the website's sidebar bars): a header row
-- ("title  value") above a rounded track with a gradient fill. Returns setters.
local function makeUsageBar(parent, order, title, titleColor, fillA, fillB)
	local wrap = Instance.new("Frame")
	wrap.Size = UDim2.new(1, 0, 0, 0)
	wrap.AutomaticSize = Enum.AutomaticSize.Y
	wrap.BackgroundTransparency = 1
	wrap.LayoutOrder = order
	wrap.Parent = parent

	local row = Instance.new("Frame")
	row.Size = UDim2.new(1, 0, 0, 16)
	row.BackgroundTransparency = 1
	row.LayoutOrder = 1
	row.Parent = wrap

	local titleLabel = Instance.new("TextLabel")
	titleLabel.Size = UDim2.new(0.6, 0, 1, 0)
	titleLabel.BackgroundTransparency = 1
	titleLabel.Text = title
	titleLabel.TextColor3 = titleColor
	titleLabel.TextXAlignment = Enum.TextXAlignment.Left
	titleLabel.TextSize = 12
	titleLabel.FontFace = FONT_BOLD
	titleLabel.Parent = row

	local valueLabel = Instance.new("TextLabel")
	valueLabel.Size = UDim2.new(0.4, 0, 1, 0)
	valueLabel.Position = UDim2.new(0.6, 0, 0, 0)
	valueLabel.BackgroundTransparency = 1
	valueLabel.Text = "—"
	valueLabel.TextColor3 = TEXT
	valueLabel.TextXAlignment = Enum.TextXAlignment.Right
	valueLabel.TextSize = 12
	valueLabel.FontFace = FONT_BOLD
	valueLabel.Parent = row

	local track = Instance.new("Frame")
	track.Size = UDim2.new(1, 0, 0, 8)
	track.BackgroundColor3 = TRACK_BG
	track.BorderSizePixel = 0
	track.LayoutOrder = 2
	track.Parent = wrap
	addCorner(track, 999)

	local fill = Instance.new("Frame")
	fill.Size = UDim2.new(0, 0, 1, 0)
	fill.BackgroundColor3 = fillB
	fill.BorderSizePixel = 0
	fill.Parent = track
	addCorner(fill, 999)
	local fillGrad = Instance.new("UIGradient")
	fillGrad.Color = ColorSequence.new(fillA, fillB)
	fillGrad.Parent = fill

	local barWrapLayout = Instance.new("UIListLayout")
	barWrapLayout.Padding = UDim.new(0, 5)
	barWrapLayout.SortOrder = Enum.SortOrder.LayoutOrder
	barWrapLayout.Parent = wrap

	return {
		setValue = function(text) valueLabel.Text = text end,
		setPct = function(pct)
			fill.Size = UDim2.new(math.clamp(pct, 0, 1), 0, 1, 0)
		end,
		setVisible = function(v) wrap.Visible = v end,
	}
end

local function makeDivider(parent, order)
	local div = Instance.new("Frame")
	div.Size = UDim2.new(1, 0, 0, 1)
	div.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
	div.BackgroundTransparency = 0.9
	div.BorderSizePixel = 0
	div.LayoutOrder = order
	div.Parent = parent
	return div
end

---------------------------------------------------------------------------
-- Header — Artly logo + wordmark
---------------------------------------------------------------------------
local header = Instance.new("Frame")
header.Size = UDim2.new(1, 0, 0, 38)
header.BackgroundTransparency = 1
header.LayoutOrder = 0
header.Parent = mainFrame

-- The real Artly logo renders only when ARTLY_LOGO_ASSET_ID is set to an uploaded
-- image asset id. With no id we show NO placeholder mark (just the wordmark) —
-- never a made-up logo. textX is where the wordmark starts (after the logo, or 0).
local hasLogo = ARTLY_LOGO_ASSET_ID and ARTLY_LOGO_ASSET_ID > 0
local textX = 0
if hasLogo then
	local logo = Instance.new("ImageLabel")
	logo.Image = "rbxassetid://" .. tostring(ARTLY_LOGO_ASSET_ID)
	logo.BackgroundTransparency = 1
	logo.ScaleType = Enum.ScaleType.Fit
	logo.Size = UDim2.new(0, 32, 0, 32)
	logo.Position = UDim2.new(0, 0, 0.5, 0)
	logo.AnchorPoint = Vector2.new(0, 0.5)
	logo.Parent = header
	textX = 42
end

local wordmark = Instance.new("TextLabel")
wordmark.Size = UDim2.new(1, -textX, 0, 18)
wordmark.Position = UDim2.new(0, textX, 0, 1)
wordmark.BackgroundTransparency = 1
wordmark.Text = "Artly"
wordmark.TextColor3 = TEXT
wordmark.TextXAlignment = Enum.TextXAlignment.Left
wordmark.FontFace = FONT_BOLD
wordmark.TextSize = 17
wordmark.Parent = header

local wordmarkSub = Instance.new("TextLabel")
wordmarkSub.Size = UDim2.new(1, -textX, 0, 13)
wordmarkSub.Position = UDim2.new(0, textX, 0, 20)
wordmarkSub.BackgroundTransparency = 1
wordmarkSub.Text = "Studio Sync"
wordmarkSub.TextColor3 = TEXT_FAINT
wordmarkSub.TextXAlignment = Enum.TextXAlignment.Left
wordmarkSub.FontFace = FONT_MED
wordmarkSub.TextSize = 11
wordmarkSub.Parent = header

---------------------------------------------------------------------------
-- Status indicator
---------------------------------------------------------------------------
local statusRow = makeCard(mainFrame, 1)
statusRow.LayoutOrder = 1
-- Fixed height (its dot/label are absolutely positioned, so AutomaticSize would
-- collapse it to 0).
statusRow.AutomaticSize = Enum.AutomaticSize.None
statusRow.Size = UDim2.new(1, 0, 0, 36)
addPadding(statusRow, 0, 12, 0, 12)

local statusDot = Instance.new("Frame")
statusDot.Size = UDim2.new(0, 9, 0, 9)
statusDot.Position = UDim2.new(0, 0, 0.5, 0)
statusDot.AnchorPoint = Vector2.new(0, 0.5)
statusDot.BackgroundColor3 = Color3.fromRGB(120, 120, 120)
statusDot.BorderSizePixel = 0
statusDot.Parent = statusRow

local dotCorner = Instance.new("UICorner")
dotCorner.CornerRadius = UDim.new(1, 0)
dotCorner.Parent = statusDot

local statusText = Instance.new("TextLabel")
statusText.Size = UDim2.new(1, -20, 0, 16)
statusText.Position = UDim2.new(0, 18, 0.5, 0)
statusText.AnchorPoint = Vector2.new(0, 0.5)
statusText.Text = "Disconnected"
statusText.TextColor3 = TEXT_DIM
statusText.BackgroundTransparency = 1
statusText.TextXAlignment = Enum.TextXAlignment.Left
statusText.TextSize = 13
statusText.FontFace = FONT_BOLD
statusText.Parent = statusRow

---------------------------------------------------------------------------
-- Info section (visible when connected)
---------------------------------------------------------------------------
local infoFrame = makeCard(mainFrame, 3)
infoFrame.LayoutOrder = 3
infoFrame.Visible = false
addPadding(infoFrame, 12, 14, 12, 14)

local infoLayout = Instance.new("UIListLayout")
infoLayout.Padding = UDim.new(0, 5)
infoLayout.SortOrder = Enum.SortOrder.LayoutOrder
infoLayout.Parent = infoFrame

makeLabel(infoFrame, "WORKSPACE", 0, 13, TEXT_FAINT)
local projectLabel = makeLabel(infoFrame, "Project: --", 1, 18, TEXT)
projectLabel.FontFace = FONT_BOLD
projectLabel.TextSize = 14
local instancesLabel = makeLabel(infoFrame, "Instances: 0", 2)
local lastSyncLabel = makeLabel(infoFrame, "Last sync: never", 3)
local syncCountLabel = makeLabel(infoFrame, "Changes synced: 0", 4)

-- Usage bars (the website's two sidebar bars): credits + daily free-model.
local usageDivider = makeDivider(infoFrame, 5)
usageDivider.BackgroundTransparency = 0.85
local usageSpacer = Instance.new("Frame")
usageSpacer.Size = UDim2.new(1, 0, 0, 2)
usageSpacer.BackgroundTransparency = 1
usageSpacer.LayoutOrder = 6
usageSpacer.Parent = infoFrame
local creditsBar = makeUsageBar(infoFrame, 7, "Credits", TEXT, CREDIT_A, CREDIT_B)
local freeBar = makeUsageBar(infoFrame, 8, "Free Model", FREE_B, FREE_A, FREE_B)

---------------------------------------------------------------------------
-- Login section (visible when disconnected)
---------------------------------------------------------------------------
local loginFrame = makeCard(mainFrame, 4)
loginFrame.LayoutOrder = 4
addPadding(loginFrame, 14, 14, 14, 14)

local loginLayout = Instance.new("UIListLayout")
loginLayout.Padding = UDim.new(0, 9)
loginLayout.SortOrder = Enum.SortOrder.LayoutOrder
loginLayout.Parent = loginFrame

local autoPairTitle = makeLabel(loginFrame, "Artly Studio Sync", 1, 20, TEXT)
autoPairTitle.FontFace = FONT_BOLD
autoPairTitle.TextSize = 16
autoPairTitle.TextWrapped = true
autoPairTitle.AutomaticSize = Enum.AutomaticSize.Y

local autoPairHint = makeLabel(
	loginFrame,
	"Open the Artly desktop app and this plugin links automatically — no code needed. Make sure Game Settings → Security → Allow HTTP Requests is on.",
	2, 56, TEXT_DIM
)
autoPairHint.TextWrapped = true
autoPairHint.TextSize = 12

-- Connect-code entry — the primary path (matches the website's "Connect plugin"
-- popup, which hands you a one-time code).
local manualFrame = Instance.new("Frame")
manualFrame.Size = UDim2.new(1, 0, 0, 0)
manualFrame.AutomaticSize = Enum.AutomaticSize.Y
manualFrame.BackgroundTransparency = 1
manualFrame.LayoutOrder = 5
-- Hidden by default: the primary path is automatic local discovery. Revealed by
-- the "Connect to a server manually" toggle (remoteToggle) for remote/web users.
manualFrame.Visible = false
manualFrame.Parent = loginFrame

local manualLayout = Instance.new("UIListLayout")
manualLayout.Padding = UDim.new(0, 8)
manualLayout.SortOrder = Enum.SortOrder.LayoutOrder
manualLayout.Parent = manualFrame

makeLabel(manualFrame, "CONNECT CODE", 1, 13, TEXT_FAINT)
local tokenInput = makeInput(manualFrame, "Paste your code…", 2, savedToken)
local connectBtn = makeButton(manualFrame, "Connect", 3, ACCENT)
local cancelBtn  = makeButton(manualFrame, "Cancel", 3, Color3.fromRGB(60, 60, 60))
cancelBtn.Visible = false

local function setConnecting(isConnecting)
	connectBtn.Visible  = not isConnecting
	cancelBtn.Visible   = isConnecting
	tokenInput.TextEditable = not isConnecting
end

-- Advanced (server URL) — collapsed by default; the prod URL is baked in.
local advancedBtn = Instance.new("TextButton")
advancedBtn.Size = UDim2.new(1, 0, 0, 16)
advancedBtn.BackgroundTransparency = 1
advancedBtn.Text = "Advanced settings"
advancedBtn.TextColor3 = TEXT_FAINT
advancedBtn.TextXAlignment = Enum.TextXAlignment.Left
advancedBtn.TextSize = 12
advancedBtn.FontFace = FONT_MED
advancedBtn.LayoutOrder = 4
advancedBtn.AutoButtonColor = false
advancedBtn.Parent = manualFrame

local advancedFrame = Instance.new("Frame")
advancedFrame.Size = UDim2.new(1, 0, 0, 0)
advancedFrame.AutomaticSize = Enum.AutomaticSize.Y
advancedFrame.BackgroundTransparency = 1
advancedFrame.Visible = false
advancedFrame.LayoutOrder = 5
advancedFrame.Parent = manualFrame

local advancedLayout = Instance.new("UIListLayout")
advancedLayout.Padding = UDim.new(0, 6)
advancedLayout.SortOrder = Enum.SortOrder.LayoutOrder
advancedLayout.Parent = advancedFrame

makeDivider(advancedFrame, 1)
makeLabel(advancedFrame, "SERVER URL", 2, 13, TEXT_FAINT)
local urlInput = makeInput(advancedFrame, "https://artlyrblx.com", 3, serverUrl)

advancedBtn.MouseButton1Click:Connect(function()
	advancedFrame.Visible = not advancedFrame.Visible
	advancedBtn.Text = advancedFrame.Visible and "Hide advanced" or "Advanced settings"
end)

-- Reveal the manual code/URL form (remote / web fallback). LayoutOrder 4 sits
-- between the hint (2) and the hidden manualFrame (5), so the form expands right
-- beneath this toggle.
local remoteToggle = Instance.new("TextButton")
remoteToggle.Size = UDim2.new(1, 0, 0, 16)
remoteToggle.BackgroundTransparency = 1
remoteToggle.Text = "Connect to a server manually"
remoteToggle.TextColor3 = TEXT_FAINT
remoteToggle.TextXAlignment = Enum.TextXAlignment.Left
remoteToggle.TextSize = 12
remoteToggle.FontFace = FONT_MED
remoteToggle.LayoutOrder = 4
remoteToggle.AutoButtonColor = false
remoteToggle.Parent = loginFrame

remoteToggle.MouseButton1Click:Connect(function()
	manualFrame.Visible = not manualFrame.Visible
	remoteToggle.Text = manualFrame.Visible and "Hide manual connection" or "Connect to a server manually"
end)

-- Auto-pair confirm code (shown only when the website's account-link flow is on).
-- Height 0 + AutomaticSize so it takes no space when empty (no dead gap).
local autoPairCodeLabel = makeLabel(loginFrame, "", 6, 0, ACCENT)
autoPairCodeLabel.FontFace = FONT_BOLD
autoPairCodeLabel.TextWrapped = true
autoPairCodeLabel.AutomaticSize = Enum.AutomaticSize.Y

local loginStatus = makeLabel(loginFrame, "", 7, 0, DANGER)
loginStatus.TextWrapped = true
loginStatus.AutomaticSize = Enum.AutomaticSize.Y

-- Update the auto-pair status block. `code` shows the visual confirm code;
-- `err` shows a problem (e.g. not signed in) in red.
local function setAutoPairStatus(title, code, err)
	if title then autoPairTitle.Text = title end
	autoPairCodeLabel.Text = code and ("Confirm code on the website: " .. code) or ""
	loginStatus.Text = err or ""
end

---------------------------------------------------------------------------
-- Action buttons (visible when connected)
---------------------------------------------------------------------------
local actionsFrame = Instance.new("Frame")
actionsFrame.Size = UDim2.new(1, 0, 0, 0)
actionsFrame.AutomaticSize = Enum.AutomaticSize.Y
actionsFrame.BackgroundTransparency = 1
actionsFrame.LayoutOrder = 5
actionsFrame.Visible = false
actionsFrame.Parent = mainFrame

local actionsLayout = Instance.new("UIListLayout")
actionsLayout.Padding = UDim.new(0, 6)
actionsLayout.SortOrder = Enum.SortOrder.LayoutOrder
actionsLayout.Parent = actionsFrame

local disconnectBtn = makeButton(actionsFrame, "Disconnect", 1, DANGER)

---------------------------------------------------------------------------
-- Footer — version
---------------------------------------------------------------------------
local footer = Instance.new("TextLabel")
footer.Size = UDim2.new(1, 0, 0, 14)
footer.BackgroundTransparency = 1
footer.Text = "Artly Sync v" .. PLUGIN_VERSION
footer.TextColor3 = TEXT_FAINT
footer.TextXAlignment = Enum.TextXAlignment.Center
footer.TextSize = 11
footer.FontFace = FONT_MED
footer.LayoutOrder = 20
footer.Parent = mainFrame

---------------------------------------------------------------------------
-- UI update functions
---------------------------------------------------------------------------
local function formatTime(t)
	if t == 0 then return "never" end
	local elapsed = os.time() - t
	if elapsed < 5 then return "just now" end
	if elapsed < 60 then return elapsed .. "s ago" end
	if elapsed < 3600 then return math.floor(elapsed / 60) .. "m ago" end
	return math.floor(elapsed / 3600) .. "h ago"
end

local function updateStatusUI()
	if connected then
		statusDot.BackgroundColor3 = Color3.fromRGB(50, 200, 80)
		statusText.Text = "Connected"
		statusText.TextColor3 = Color3.fromRGB(50, 200, 80)

		projectLabel.Text = "Project: " .. (selectedProjectName or projectName)
		instancesLabel.Text = "Instances: " .. tostring(instanceCount)
		lastSyncLabel.Text = "Last sync: " .. formatTime(lastSyncTime)
		syncCountLabel.Text = "Changes synced: " .. tostring(syncCount)

		infoFrame.Visible = true
		loginFrame.Visible = false
		actionsFrame.Visible = true
	else
		statusDot.BackgroundColor3 = Color3.fromRGB(120, 120, 120)
		statusText.Text = "Disconnected"
		statusText.TextColor3 = Color3.fromRGB(180, 180, 180)

		infoFrame.Visible = false
		loginFrame.Visible = true
		actionsFrame.Visible = false
	end
end

task.spawn(function()
	while true do
		if connected and lastSyncTime > 0 then
			lastSyncLabel.Text = "Last sync: " .. formatTime(lastSyncTime)
		end
		task.wait(5)
	end
end)

local function markSynced()
	lastSyncTime = os.time()
	syncCount = syncCount + 1
	updateStatusUI()
end

-- "Searching" status shown while the local auto-connect loop probes for the
-- desktop app (soft blue, distinct from the grey "Disconnected" idle state).
local function setSearchingStatus()
	if connected then return end
	statusDot.BackgroundColor3 = ACCENT
	statusText.Text = "Looking for Artly Studio…"
	statusText.TextColor3 = ACCENT
end

---------------------------------------------------------------------------
-- HTTP helpers
---------------------------------------------------------------------------
-- Per-place routing: tell the server which Roblox place this is so each place
-- gets its own workspace. PlaceId is 0 for an unpublished place (the server
-- treats that as the default project). Name is sanitized to safe header chars.
local function withPlaceHeaders(headers)
	headers["X-Place-Id"] = tostring(game.PlaceId)
	headers["X-Place-Name"] = string.sub((tostring(game.Name):gsub("[^%w%s%-_]", "")), 1, 64)
	-- Announce the running plugin version on every request so the desktop app can
	-- tell when Studio has an older plugin loaded than the one it bundles (and
	-- prompt for a Studio restart to pick up the update). See syncServer.ts.
	headers["X-Plugin-Version"] = PLUGIN_VERSION
	return headers
end

local function httpGet(path)
	local url = serverUrl .. "/api/code/sync" .. path
	local ok, result = pcall(function()
		return HttpService:RequestAsync({
			Url = url,
			Method = "GET",
			Headers = withPlaceHeaders({ Authorization = "Bearer " .. (projectToken or "") }),
		})
	end)
	if not ok then return nil, result end
	if result.StatusCode ~= 200 then
		return nil, "HTTP " .. tostring(result.StatusCode)
	end
	return HttpService:JSONDecode(result.Body), nil
end

local function httpPost(path, body)
	local url = serverUrl .. "/api/code/sync" .. path
	local json = HttpService:JSONEncode(body)
	local ok, result = pcall(function()
		return HttpService:RequestAsync({
			Url = url,
			Method = "POST",
			Headers = withPlaceHeaders({
				["Content-Type"] = "application/json",
				Authorization = "Bearer " .. (projectToken or ""),
			}),
			Body = json,
		})
	end)
	if not ok then return nil, result end
	if result.StatusCode ~= 200 then
		return nil, "HTTP " .. tostring(result.StatusCode)
	end
	return HttpService:JSONDecode(result.Body), nil
end

---------------------------------------------------------------------------
-- Usage bars (credits + daily free-model allowance) — GET /sync/usage
---------------------------------------------------------------------------
local function formatCount(n)
	n = math.floor(tonumber(n) or 0)
	if n >= 1000000 then return string.format("%.1fM", n / 1000000) end
	if n >= 1000 then return string.format("%.1fk", n / 1000) end
	return tostring(n)
end

local function refreshUsage()
	if not projectToken or projectToken == "" then return end
	local data, err = httpGet("/usage")
	if not data then
		-- Don't fail silently: a broken /usage call (auth, redirect, 5xx, bad
		-- body) used to just leave both bars stuck on their "—" placeholder,
		-- which is indistinguishable from "no usage yet". Log the real reason so
		-- it shows in Studio Output, and mark the bars as unavailable.
		warn("[Artly Sync] usage fetch failed: " .. tostring(err))
		creditsBar.setValue("unavailable")
		freeBar.setValue("unavailable")
		return
	end

	local c = data.credits
	if c then
		if c.unlimited then
			creditsBar.setValue("Unlimited")
			creditsBar.setPct(1)
		else
			local rem = tonumber(c.remaining) or 0
			local quota = tonumber(c.quota) or 0
			creditsBar.setValue(formatCount(rem) .. " / " .. formatCount(quota))
			creditsBar.setPct(quota > 0 and rem / quota or 0)
		end
		creditsBar.setVisible(true)
	else
		creditsBar.setVisible(false)
	end

	local f = data.freeUsage
	if f then
		local limit = tonumber(f.limit) or 0
		local used = tonumber(f.used) or 0
		local rem = math.max(0, limit - used)
		freeBar.setValue(rem .. " / " .. limit)
		freeBar.setPct(limit > 0 and rem / limit or 0)
		freeBar.setVisible(true)
	else
		freeBar.setVisible(false)
	end
end

-- Refresh the bars while connected (the website refreshes the same data live).
task.spawn(function()
	while true do
		if connected then
			pcall(refreshUsage)
		end
		task.wait(15)
	end
end)

---------------------------------------------------------------------------
-- Instance mapping
---------------------------------------------------------------------------
local function registerInstance(id, instance)
	idToInstance[id] = instance
	instanceToId[instance] = id
end

local function unregisterInstance(instance)
	local id = instanceToId[instance]
	if id then
		idToInstance[id] = nil
		instanceToId[instance] = nil
	end
	local conns = changeConnections[instance]
	if conns then
		for _, c in ipairs(conns) do pcall(function() c:Disconnect() end) end
		changeConnections[instance] = nil
	end
end

local function unregisterTree(instance)
	for _, child in ipairs(instance:GetChildren()) do
		unregisterTree(child)
	end
	unregisterInstance(instance)
end

---------------------------------------------------------------------------
-- Properties
---------------------------------------------------------------------------
local SCRIPT_CLASSES = { Script = true, LocalScript = true, ModuleScript = true }

local CollectionService = game:GetService("CollectionService")

local function decodeProperty(prop)
	if type(prop) ~= "table" or prop.type == nil then
		return prop
	end
	local t = prop.type
	local v = prop.value
	if t == "String" or t == "Content" or t == "Bool" or t == "Number" then
		return v
	elseif t == "Vector3" and type(v) == "table" then
		return Vector3.new(v[1] or 0, v[2] or 0, v[3] or 0)
	elseif t == "Vector2" and type(v) == "table" then
		return Vector2.new(v[1] or 0, v[2] or 0)
	elseif t == "Color3" and type(v) == "table" then
		return Color3.new(v[1] or 0, v[2] or 0, v[3] or 0)
	elseif t == "UDim" and type(v) == "table" then
		return UDim.new(v[1] or 0, v[2] or 0)
	elseif t == "UDim2" and type(v) == "table" then
		return UDim2.new(v[1] or 0, v[2] or 0, v[3] or 0, v[4] or 0)
	elseif t == "CFrame" and type(v) == "table" then
		if #v >= 12 then
			return CFrame.new(v[1], v[2], v[3], v[4], v[5], v[6], v[7], v[8], v[9], v[10], v[11], v[12])
		else
			return CFrame.new(v[1] or 0, v[2] or 0, v[3] or 0)
		end
	elseif t == "BrickColor" and type(v) == "string" then
		return BrickColor.new(v)
	elseif t == "EnumItem" and type(v) == "table" and v.enumType and v.name then
		local ok, enumGroup = pcall(function() return (Enum :: any)[v.enumType] end)
		if ok and enumGroup then
			local ok2, item = pcall(function() return enumGroup[v.name] end)
			if ok2 then return item end
		end
		return nil
	elseif t == "Rect" and type(v) == "table" then
		return Rect.new(v[1] or 0, v[2] or 0, v[3] or 0, v[4] or 0)
	elseif t == "NumberRange" and type(v) == "table" then
		return NumberRange.new(v[1] or 0, v[2] or 1)
	elseif t == "NumberSequence" and type(v) == "table" then
		local keypoints = {}
		for _, kp in ipairs(v) do
			table.insert(keypoints, NumberSequenceKeypoint.new(kp.time or 0, kp.value or 0, kp.envelope or 0))
		end
		if #keypoints >= 2 then return NumberSequence.new(keypoints) end
		return nil
	elseif t == "ColorSequence" and type(v) == "table" then
		local keypoints = {}
		for _, kp in ipairs(v) do
			local c = kp.color or {1, 1, 1}
			table.insert(keypoints, ColorSequenceKeypoint.new(kp.time or 0, Color3.new(c[1] or 1, c[2] or 1, c[3] or 1)))
		end
		if #keypoints >= 2 then return ColorSequence.new(keypoints) end
		return nil
	elseif t == "Font" and type(v) == "table" then
		local family = v.family or "rbxasset://fonts/families/SourceSansPro.json"
		local weight = Enum.FontWeight[v.weight or "Regular"] or Enum.FontWeight.Regular
		local style = Enum.FontStyle[v.style or "Normal"] or Enum.FontStyle.Normal
		return Font.new(family, weight, style)
	elseif t == "Instance" then
		-- Instance reference by full path. The target may not exist yet (same
		-- batch), so we return a sentinel and resolve it in setInstanceProperty /
		-- resolvePendingInstanceRefs once the whole batch has been created.
		-- value == false means "explicit nil reference" (clear the property).
		if type(v) == "string" and v ~= "" then
			return { __artlyRef = v }
		end
		return { __artlyRef = false }
	elseif t == "Vector3int16" and type(v) == "table" then
		return Vector3int16.new(v[1] or 0, v[2] or 0, v[3] or 0)
	elseif t == "Vector2int16" and type(v) == "table" then
		return Vector2int16.new(v[1] or 0, v[2] or 0)
	elseif t == "Color3uint8" and type(v) == "table" then
		return Color3.fromRGB(v[1] or 0, v[2] or 0, v[3] or 0)
	elseif t == "PhysicalProperties" then
		if type(v) == "table" and #v >= 5 then
			return PhysicalProperties.new(v[1], v[2], v[3], v[4], v[5])
		end
		return nil
	elseif t == "Axes" and type(v) == "table" then
		local items = {}
		for _, name in ipairs(v) do
			local ok2, item = pcall(function() return Enum.Axis[name] end)
			if ok2 and item then table.insert(items, item) end
		end
		return Axes.new(table.unpack(items))
	elseif t == "Faces" and type(v) == "table" then
		local items = {}
		for _, name in ipairs(v) do
			local ok2, item = pcall(function() return Enum.NormalId[name] end)
			if ok2 and item then table.insert(items, item) end
		end
		return Faces.new(table.unpack(items))
	elseif t == "Ray" and type(v) == "table" then
		local o = v.origin or { 0, 0, 0 }
		local d = v.direction or { 0, 0, 0 }
		return Ray.new(
			Vector3.new(o[1] or 0, o[2] or 0, o[3] or 0),
			Vector3.new(d[1] or 0, d[2] or 0, d[3] or 0)
		)
	elseif t == "Region3" and type(v) == "table" then
		local mn = v.min or { 0, 0, 0 }
		local mx = v.max or { 0, 0, 0 }
		return Region3.new(
			Vector3.new(mn[1] or 0, mn[2] or 0, mn[3] or 0),
			Vector3.new(mx[1] or 0, mx[2] or 0, mx[3] or 0)
		)
	end
	return v
end

local function serializeProperty(instance, propName)
	local ok, value = pcall(function() return (instance :: any)[propName] end)
	if not ok then return nil end
	if value == nil then return nil end
	local t = typeof(value)
	if t == "string" then return { type = "String", value = value }
	elseif t == "boolean" then return { type = "Bool", value = value }
	elseif t == "number" then return { type = "Number", value = value }
	elseif t == "Vector3" then return { type = "Vector3", value = {value.X, value.Y, value.Z} }
	elseif t == "Vector2" then return { type = "Vector2", value = {value.X, value.Y} }
	elseif t == "Color3" then return { type = "Color3", value = {value.R, value.G, value.B} }
	elseif t == "UDim" then return { type = "UDim", value = {value.Scale, value.Offset} }
	elseif t == "UDim2" then return { type = "UDim2", value = {value.X.Scale, value.X.Offset, value.Y.Scale, value.Y.Offset} }
	elseif t == "CFrame" then
		local c = {value:GetComponents()}
		return { type = "CFrame", value = c }
	elseif t == "BrickColor" then return { type = "BrickColor", value = value.Name }
	elseif t == "EnumItem" then return { type = "EnumItem", value = { enumType = tostring(value.EnumType), name = value.Name } }
	elseif t == "Rect" then return { type = "Rect", value = {value.Min.X, value.Min.Y, value.Max.X, value.Max.Y} }
	elseif t == "NumberRange" then return { type = "NumberRange", value = {value.Min, value.Max} }
	elseif t == "Font" then return { type = "Font", value = { family = value.Family, weight = value.Weight.Name, style = value.Style.Name } }
	elseif t == "Instance" then return { type = "Instance", value = value:GetFullName() }
	elseif t == "Vector3int16" then return { type = "Vector3int16", value = { value.X, value.Y, value.Z } }
	elseif t == "Vector2int16" then return { type = "Vector2int16", value = { value.X, value.Y } }
	elseif t == "PhysicalProperties" then return { type = "PhysicalProperties", value = { value.Density, value.Friction, value.Elasticity, value.FrictionWeight, value.ElasticityWeight } }
	elseif t == "Axes" then
		local names = {}
		for _, axisName in ipairs({ "X", "Y", "Z" }) do
			if (value :: any)[axisName] then table.insert(names, axisName) end
		end
		return { type = "Axes", value = names }
	elseif t == "Faces" then
		local names = {}
		for _, faceName in ipairs({ "Top", "Bottom", "Left", "Right", "Front", "Back" }) do
			if (value :: any)[faceName] then table.insert(names, faceName) end
		end
		return { type = "Faces", value = names }
	elseif t == "Ray" then
		return { type = "Ray", value = {
			origin = { value.Origin.X, value.Origin.Y, value.Origin.Z },
			direction = { value.Direction.X, value.Direction.Y, value.Direction.Z },
		} }
	elseif t == "Region3" then
		local c = value.CFrame.Position
		local h = value.Size / 2
		return { type = "Region3", value = {
			min = { c.X - h.X, c.Y - h.Y, c.Z - h.Z },
			max = { c.X + h.X, c.Y + h.Y, c.Z + h.Z },
		} }
	elseif t == "NumberSequence" then
		local kps = {}
		for _, kp in ipairs(value.Keypoints) do
			table.insert(kps, { time = kp.Time, value = kp.Value, envelope = kp.Envelope })
		end
		return { type = "NumberSequence", value = kps }
	elseif t == "ColorSequence" then
		local kps = {}
		for _, kp in ipairs(value.Keypoints) do
			table.insert(kps, { time = kp.Time, color = { kp.Value.R, kp.Value.G, kp.Value.B } })
		end
		return { type = "ColorSequence", value = kps }
	else return nil -- unrepresentable type (signal, userdata…) — skip, don't junk it
	end
end

-- Instance references arrive from decodeProperty as a { __artlyRef = path }
-- sentinel. The target may not exist yet while a batch is mid-apply, so
-- unresolved refs are queued and retried by resolvePendingInstanceRefs() once
-- the whole batch is in place.
local pendingInstanceRefs = {}

local function resolveInstancePath(path)
	if type(path) ~= "string" or path == "" then return nil end
	-- Accept "game.Workspace.X", "Workspace.X", "/Workspace/X", "Workspace/X".
	local clean = path:gsub("^[Gg]ame[%.%/]", "")
	local current = game
	for segment in string.gmatch(clean, "[^%./]+") do
		if current == game then
			local ok, svc = pcall(game.GetService, game, segment)
			current = (ok and svc) or game:FindFirstChild(segment)
		else
			current = current:FindFirstChild(segment)
		end
		if not current then return nil end
	end
	if current == game then return nil end
	return current
end

local function setInstanceProperty(instance, propName, propValue)
	local value = decodeProperty(propValue)
	if value == nil then return end
	-- Instance-reference sentinel: resolve the target path to a live Instance
	-- (e.g. Weld.Part0, Model.PrimaryPart). Defer if the target isn't built yet.
	if type(value) == "table" and value.__artlyRef ~= nil then
		local target = nil
		if value.__artlyRef ~= false then
			target = resolveInstancePath(value.__artlyRef)
			if not target then
				table.insert(pendingInstanceRefs, { instance = instance, propName = propName, path = value.__artlyRef })
				return
			end
		end
		pcall(function() (instance :: any)[propName] = target end)
		return
	end
	-- The legacy `Font` property is an Enum.Font; a Font *object* belongs on
	-- `FontFace`. Redirect so payloads carrying a Font under "Font" don't fail
	-- with "EnumItem, number, or string expected, got Font".
	if propName == "Font" and typeof(value) == "Font" then
		propName = "FontFace"
	end
	-- Skip properties that don't exist on this instance (e.g. an AI-invented
	-- prop like "Bounce" on a Part) instead of spamming sync warnings.
	if not pcall(function() return (instance :: any)[propName] end) then
		return
	end
	local ok, err = pcall(function() (instance :: any)[propName] = value end)
	if not ok then
		-- Read-only / derived properties (e.g. Camera.ViewportSize, GuiObject
		-- AbsoluteSize) are readable but can't be assigned. They may linger in a
		-- tree captured by an older build — skip them silently rather than warn.
		local msg = string.lower(tostring(err))
		if string.find(msg, "read only", 1, true) or string.find(msg, "read-only", 1, true) then
			return
		end
		warn("[Artly Sync] Failed to set " .. propName .. " on " .. instance:GetFullName() .. ": " .. tostring(err))
	end
end

-- Retry any instance references whose targets didn't exist mid-batch. Called at
-- the end of applyPatch / initialSync, once every instance in the batch is built.
local function resolvePendingInstanceRefs()
	if #pendingInstanceRefs == 0 then return end
	local refs = pendingInstanceRefs
	pendingInstanceRefs = {}
	for _, ref in ipairs(refs) do
		if ref.instance and ref.instance.Parent then
			local target = resolveInstancePath(ref.path)
			if target then
				-- Pause so the now-all-properties change listener doesn't echo this
				-- server-driven write back as if the user made it.
				pausedInstances[ref.instance] = true
				pcall(function() (ref.instance :: any)[ref.propName] = target end)
				pausedInstances[ref.instance] = nil
			end
		end
	end
end

local function applyAttributes(instance, attributes)
	if type(attributes) ~= "table" then return end
	for key, value in pairs(attributes) do
		pcall(function() instance:SetAttribute(key, value) end)
	end
end

local function applyTags(instance, tags)
	if type(tags) ~= "table" then return end
	for _, tag in ipairs(tags.value or tags) do
		if type(tag) == "string" then
			pcall(function() CollectionService:AddTag(instance, tag) end)
		end
	end
end

---------------------------------------------------------------------------
-- Change tracking (Studio -> Server)
---------------------------------------------------------------------------
local function onInstanceChanged(instance, propertyName)
	if pausedInstances[instance] then return end
	if RunService:IsRunning() then return end
	table.insert(pendingChanges, { instance = instance, property = propertyName })
end

local function connectChangeListener(instance)
	if changeConnections[instance] then return end
	local conns = {}
	-- Watch EVERY property: Instance.Changed fires with the property name for any
	-- property change, so edits to Size/Color/Material/Text/anchored/etc. in
	-- Studio sync back to the agent — not just Name. (Parent moves are caught by
	-- the DescendantAdded/Removing tree listeners.)
	local ok, conn = pcall(function()
		return instance.Changed:Connect(function(prop)
			onInstanceChanged(instance, prop)
		end)
	end)
	if ok and conn then table.insert(conns, conn) end
	-- Scripts: Changed doesn't fire for Source (security), so watch it explicitly.
	if SCRIPT_CLASSES[instance.ClassName] then
		local ok2, conn2 = pcall(function()
			return instance:GetPropertyChangedSignal("Source"):Connect(function()
				onInstanceChanged(instance, "Source")
			end)
		end)
		if ok2 and conn2 then table.insert(conns, conn2) end
	end
	-- ValueBase (.Changed fires with the new VALUE, not "Value") — watch Value so
	-- IntValue/StringValue/ObjectValue/etc. edits still sync.
	local isValue = pcall(function() return instance:IsA("ValueBase") end) and instance:IsA("ValueBase")
	if isValue then
		local ok3, conn3 = pcall(function()
			return instance:GetPropertyChangedSignal("Value"):Connect(function()
				onInstanceChanged(instance, "Value")
			end)
		end)
		if ok3 and conn3 then table.insert(conns, conn3) end
	end
	changeConnections[instance] = conns
end

-- Properties worth capturing when an instance is uploaded, so the agent sees
-- real geometry/appearance (size, position, color, material…) instead of just a
-- name + class. A plugin can't enumerate an instance's non-default properties,
-- so we try a curated union of the properties that matter for building — a read
-- that doesn't apply to the class is pcall-skipped, and only value-typed results
-- are kept. serializeProperty types each one correctly (e.g. "Size" is a Vector3
-- on a Part, a UDim2 on a Frame).
local CAPTURE_PROPS = {
	-- transform / geometry (BasePart uses Vector3/CFrame; GuiObject uses UDim2)
	"Size", "Position", "CFrame", "Rotation", "Orientation", "AnchorPoint", "AutomaticSize",
	-- BasePart appearance + physics
	"Anchored", "CanCollide", "CanTouch", "CanQuery", "Massless", "Locked",
	"Transparency", "Reflectance", "Color", "BrickColor", "Material", "CastShadow",
	"Shape", "CollisionGroup",
	-- GuiObject appearance
	"BackgroundColor3", "BackgroundTransparency", "BorderColor3", "BorderSizePixel",
	"Visible", "ZIndex", "ClipsDescendants", "LayoutOrder", "Active", "Selectable",
	-- Image
	"Image", "ImageColor3", "ImageTransparency", "ScaleType",
	-- ScrollingFrame
	"CanvasSize", "ScrollBarThickness", "AutomaticCanvasSize", "ScrollingDirection",
	-- Text
	"Text", "TextColor3", "TextSize", "TextScaled", "TextWrapped", "TextTransparency",
	"Font", "FontFace", "RichText", "TextXAlignment", "TextYAlignment",
	"TextStrokeColor3", "TextStrokeTransparency", "LineHeight",
	"PlaceholderText", "PlaceholderColor3", "ClearTextOnFocus", "MultiLine",
	"AutoButtonColor", "Modal",
	-- UI constraints / layout
	"CornerRadius", "Padding", "PaddingTop", "PaddingBottom", "PaddingLeft",
	"PaddingRight", "FillDirection", "HorizontalAlignment", "VerticalAlignment",
	"SortOrder", "Wraps", "Thickness", "ApplyStrokeMode", "LineJoinMode",
	"AspectRatio", "AspectType", "DominantAxis", "MaxSize", "MinSize",
	-- value objects + config
	"Value",
	-- lights
	"Brightness", "Range", "Shadows", "Angle", "Face",
	-- sound
	"SoundId", "Volume", "Looped", "Playing", "PlaybackSpeed", "RollOffMaxDistance",
	-- decal / texture
	"Texture", "StudsPerTileU", "StudsPerTileV",
	-- spawn / team / misc gameplay
	"TeamColor", "Neutral", "Duration", "Enabled", "ResetOnSpawn", "DisplayOrder",
	-- ProximityPrompt / ClickDetector
	"ActionText", "ObjectText", "HoldDuration", "MaxActivationDistance",
	"RequiresLineOfSight", "KeyboardKeyCode", "GamepadKeyCode", "ClickablePrompt",
	"Exclusivity", "UIOffset", "Style", "CursorIcon",
	-- mesh (MeshPart / SpecialMesh)
	"MeshId", "TextureID", "TextureId", "MeshType", "Scale", "VertexColor",
	"RenderFidelity", "DoubleSided", "Offset",
	-- physics extras
	"CustomPhysicalProperties", "EnableFluidForces", "RootPriority", "MaterialVariant",
	"AssemblyLinearVelocity", "AssemblyAngularVelocity",
	-- Attachment
	"Axis", "SecondaryAxis", "WorldPosition", "WorldAxis",
	-- Constraints / welds / motors (Part0/Part1/Attachment0/1 are Instance refs)
	"Part0", "Part1", "Attachment0", "Attachment1", "C0", "C1",
	"CurrentAngle", "DesiredAngle", "MaxVelocity", "Length", "Radius", "Restitution",
	"Stiffness", "Damping", "FreeLength", "MaxForce", "MaxTorque", "Responsiveness",
	"RigidityEnabled", "LimitsEnabled", "UpperAngle", "LowerAngle", "MotorMaxTorque",
	"AngularVelocity", "ActuatorType", "LinearVelocity", "VectorVelocity",
	-- Model
	"PrimaryPart", "ModelStreamingMode", "LevelOfDetail", "WorldPivot", "PivotOffset",
	-- ScreenGui / LayerCollector
	"IgnoreGuiInset", "ZIndexBehavior", "ClipToDeviceSafeArea",
	-- ScrollingFrame extras
	"CanvasPosition", "ScrollBarImageColor3", "ScrollBarImageTransparency",
	"ScrollingEnabled", "ElasticBehavior", "TopImage", "MidImage", "BottomImage",
	-- Image extras
	"SliceCenter", "SliceScale", "TileSize", "ResampleMode", "ImageRectOffset",
	"ImageRectSize", "HoverImage", "PressedImage",
	-- Text extras
	"TextTruncate", "MaxVisibleGraphemes", "TextEditable",
	-- UI layout extras
	"HorizontalFlex", "VerticalFlex", "ItemLineAlignment", "CellSize", "CellPadding",
	"StartCorner", "FillDirectionMaxCells", "MaxTextSize", "MinTextSize",
	"Color", "Transparency", "Rotation",
	-- Lighting / Atmosphere / Sky / post-process
	"Ambient", "OutdoorAmbient", "ColorShift_Top", "ColorShift_Bottom", "ClockTime",
	"GeographicLatitude", "ExposureCompensation", "EnvironmentDiffuseScale",
	"EnvironmentSpecularScale", "GlobalShadows", "FogColor", "FogEnd", "FogStart",
	"Density", "Glare", "Haze", "Decay", "StarCount", "SunTextureId", "MoonTextureId",
	"CelestialBodiesShown", "Saturation", "Contrast", "TintColor", "Intensity",
	"Threshold", "Blur",
	-- Sound extras
	"RollOffMinDistance", "RollOffMode", "TimePosition", "PlayOnRemove",
	-- ParticleEmitter / Beam / Trail / Fire / Smoke
	"Rate", "Lifetime", "Speed", "SpreadAngle", "RotSpeed", "Acceleration", "Drag",
	"LockedToPart", "EmissionDirection", "ZOffset", "LightEmission", "LightInfluence",
	"Squash", "FlipbookLayout", "Width0", "Width1", "FaceCamera", "Segments",
	"CurveSize0", "CurveSize1", "TextureLength", "TextureMode", "TextureSpeed",
	"MinLength", "MaxLength", "WidthScale", "Heat", "SecondaryColor",
	-- Humanoid
	"Health", "MaxHealth", "WalkSpeed", "JumpPower", "JumpHeight", "UseJumpPower",
	"HipHeight", "AutoRotate", "DisplayDistanceType", "HealthDisplayType",
	"HealthDisplayDistance", "NameDisplayDistance", "DisplayName", "RigType",
	"AutoJumpEnabled", "BreakJointsOnDeath", "MaxSlopeAngle",
	-- Tool
	"CanBeDropped", "Grip", "GripForward", "GripPos", "GripRight", "GripUp",
	"ManualActivationOnly", "RequiresHandle", "ToolTip",
	-- Camera
	"FieldOfView", "CameraType", "CameraSubject", "FieldOfViewMode", "DiagonalFieldOfView",
	-- team / spawn + generic refs
	"AllowTeamChangeOnTouch", "Adornee", "Archivable",
}

-- Deep-equal for serialized property values ({type, value} where value is a
-- primitive, an array, or a small keyed table). Used to skip default-valued props.
local function deepEqual(a, b)
	if a == b then return true end
	if type(a) ~= "table" or type(b) ~= "table" then return false end
	for k, v in pairs(a) do
		if not deepEqual(v, b[k]) then return false end
	end
	for k in pairs(b) do
		if a[k] == nil then return false end
	end
	return true
end

-- Per-ClassName capture plan, computed ONCE from a throwaway default instance:
-- which of the ~250 CAPTURE_PROPS actually EXIST on the class, plus each one's
-- DEFAULT serialized value. This is the big perf lever on large games — instead
-- of probing all 250 props on every instance, we iterate only the class's real
-- props (~40 for a Part) and skip the ones still at their default (smaller
-- payload, less work to apply server-side).
local classCapturePlan = {}

local function getCapturePlan(instance)
	local cn = instance.ClassName
	local plan = classCapturePlan[cn]
	if plan then return plan end
	plan = {}
	local okNew, defInst = pcall(Instance.new, cn)
	if not okNew then defInst = nil end
	local probe = defInst or instance
	for _, name in ipairs(CAPTURE_PROPS) do
		-- Existence = a plain read doesn't error (true even for nil-default props
		-- like Model.PrimaryPart, which serializeProperty would report as nil).
		local exists = pcall(function() return (probe :: any)[name] end)
		if exists then
			plan[#plan + 1] = { name = name, default = defInst and serializeProperty(defInst, name) or nil }
		end
	end
	if defInst then pcall(function() defInst:Destroy() end) end
	classCapturePlan[cn] = plan
	return plan
end

local function captureProperties(instance)
	local props = {}
	-- Script source is the most important thing for the agent to read/edit.
	if SCRIPT_CLASSES[instance.ClassName] then
		local ok, source = pcall(function() return (instance :: any).Source end)
		if ok and source then props.Source = { type = "String", value = source } end
	end
	-- Iterate only this class's real props (cached) and keep the ones that differ
	-- from the class default. serializeProperty stays the single source of truth
	-- for representability (returns nil for anything we can't round-trip).
	for _, entry in ipairs(getCapturePlan(instance)) do
		local serialized = serializeProperty(instance, entry.name)
		if serialized ~= nil and (entry.default == nil or not deepEqual(serialized, entry.default)) then
			props[entry.name] = serialized
		end
	end
	return props
end

local function captureAttributes(instance)
	local ok, attrs = pcall(function() return instance:GetAttributes() end)
	if not ok or not attrs then return nil end
	local out = nil
	for key, value in pairs(attrs) do
		local vt = type(value)
		if vt == "string" or vt == "number" or vt == "boolean" then
			out = out or {}
			out[key] = value
		end
	end
	return out
end

-- Full property capture (NO default-stripping) for the Properties panel's
-- on-demand "describe" request — one instance, only when it's selected, so the
-- extra cost is fine. captureProperties (the always-on sync path) stays lean.
local function captureAllProperties(instance)
	local props = {}
	if SCRIPT_CLASSES[instance.ClassName] then
		local ok, source = pcall(function() return (instance :: any).Source end)
		if ok and source then props.Source = { type = "String", value = source } end
	end
	for _, entry in ipairs(getCapturePlan(instance)) do
		local serialized = serializeProperty(instance, entry.name)
		if serialized ~= nil then props[entry.name] = serialized end
	end
	local tags = CollectionService:GetTags(instance)
	if tags and #tags > 0 then props.Tags = { type = "Tags", value = tags } end
	return props
end

-- Answer a server "describe" command: read ONE instance's full live property set
-- and POST it back for the Properties panel. This is the ONLY command we honour —
-- we still never loadstring or execute server-supplied code.
local function handleDescribe(execId, instanceId, path)
	-- Resolve by mirror GUID (mirror mode) OR by live path (on-demand mode, which
	-- has no GUID for data instances).
	local inst = instanceId and idToInstance[instanceId] or nil
	if not inst and path then inst = resolveInstancePath(path) end
	if not inst then
		pcall(function()
			httpPost("/exec-result", { execId = execId, ok = false, output = "not found", sessionId = sessionId })
		end)
		return
	end
	local parent = inst.Parent
	local payload = {
		id = instanceId or inst:GetFullName(),
		name = inst.Name,
		className = inst.ClassName,
		parentName = parent and parent.Name or nil,
		properties = captureAllProperties(inst),
		attributes = captureAttributes(inst) or {},
	}
	pcall(function()
		httpPost("/exec-result", {
			execId = execId,
			ok = true,
			output = HttpService:JSONEncode(payload),
			sessionId = sessionId,
		})
	end)
end

-- Answer a server "structure" command: walk the LIVE game tree at rootPath up to
-- maxDepth and POST back Name/ClassName/Path nodes only (no properties). This is
-- the on-demand hierarchy read that lets the desktop stop mirroring data instances
-- to disk. Bounded (depth + node caps) and cooperatively yielded so a giant place
-- never blocks Studio's main thread. Still purely declarative — no code execution.
local MAX_STRUCTURE_DEPTH = 10
local MAX_STRUCTURE_NODES = 1000
local STRUCTURE_YIELD_EVERY = 1000

local function handleStructure(execId, rootPath, maxDepth)
	maxDepth = math.min(math.max(tonumber(maxDepth) or 1, 1), MAX_STRUCTURE_DEPTH)
	local nodes = {}
	local truncated = false
	local visited = 0

	-- Roots to enumerate: the children of an explicit rootPath, else the watched
	-- top-level services (NOT all of game — skips Players, etc.).
	local roots = {}
	local resolvedRootPath
	if type(rootPath) == "string" and rootPath ~= "" then
		local root = resolveInstancePath(rootPath)
		if root then
			resolvedRootPath = root:GetFullName()
			roots = root:GetChildren()
		end
	else
		resolvedRootPath = "game"
		for _, name in ipairs(WATCHED_SERVICES) do
			local ok, svc = pcall(game.GetService, game, name)
			if ok and svc then roots[#roots + 1] = svc end
		end
	end

	local function walk(inst, depth)
		if #nodes >= MAX_STRUCTURE_NODES then truncated = true; return end
		visited = visited + 1
		if visited % STRUCTURE_YIELD_EVERY == 0 then task.wait() end
		local children = inst:GetChildren()
		nodes[#nodes + 1] = {
			path = inst:GetFullName(),
			name = inst.Name,
			className = inst.ClassName,
			depth = depth,
			childCount = #children,
		}
		if depth < maxDepth then
			for _, child in ipairs(children) do
				if #nodes >= MAX_STRUCTURE_NODES then truncated = true; break end
				walk(child, depth + 1)
			end
		elseif #children > 0 then
			truncated = true -- more exists below the depth cap
		end
	end

	for _, root in ipairs(roots) do
		walk(root, 1)
	end

	local payload = { rootPath = resolvedRootPath or "game", nodes = nodes, truncated = truncated }
	pcall(function()
		httpPost("/exec-result", {
			execId = execId,
			ok = true,
			output = HttpService:JSONEncode(payload),
			sessionId = sessionId,
		})
	end)
end

-- Everything for the luau escape-hatch + the two playtest modes lives on this ONE
-- table. Luau caps a function scope at 200 locals and the plugin's main chunk runs
-- near that ceiling, so we deliberately use a single `local Playtest` instead of a
-- dozen module-level locals/functions (which overflowed the limit and stopped the
-- whole plugin from loading). Fields are assigned below; nothing here runs at load.
local Playtest = {
	TAG = "_ArtlyPlaytest",
	REMOTE = "_ArtlyPlaytestRemote",
	MAX_LOGS = 400,
	active = false, -- an injected play session is (about to be) live
	runStarted = false, -- we've actually observed Play running (gates cleanup)
	prevHttp = nil, -- HttpService.HttpEnabled before we forced it on
	-- Services scanned for scripts during a compile-check (everywhere a place keeps
	-- runnable code; data-only services excluded).
	SCAN_SERVICES = {
		"ServerScriptService", "ReplicatedStorage", "StarterPlayer", "StarterGui",
		"StarterPack", "ServerStorage", "ReplicatedFirst", "Workspace", "Lighting",
	},
}

-- Answer a server "luau" command: compile + run an agent-supplied Luau chunk once
-- in the live edit session and POST back its return value. This is the escape hatch
-- the agent uses for anything the declarative property model can't express (bulk
-- edits, reading otherwise-invisible state, calling any edit-time API). The chunk is
-- first-party (it originates from the user's own Artly agent acting on their place),
-- runs at plugin identity exactly like Studio's command bar, and only ever touches
-- THIS Studio session. Mirrors the request/response contract of handleDescribe.
function Playtest.handleLuau(execId, source)
	if type(source) ~= "string" or source == "" then
		pcall(function()
			httpPost("/exec-result", { execId = execId, ok = false, output = "no source", sessionId = sessionId })
		end)
		return
	end
	local fn, compileErr = loadstring(source, "=artly-exec")
	if not fn then
		pcall(function()
			httpPost("/exec-result", { execId = execId, ok = false, output = "compile error: " .. tostring(compileErr), sessionId = sessionId })
		end)
		return
	end
	local ok, ret = pcall(fn)
	if not ok then
		pcall(function()
			httpPost("/exec-result", { execId = execId, ok = false, output = tostring(ret), sessionId = sessionId })
		end)
		return
	end
	-- A table comes back as JSON; anything else as a string; nil as "".
	local output
	if type(ret) == "table" then
		local encoded, encErr = pcall(function() return HttpService:JSONEncode(ret) end)
		output = encoded and encErr or tostring(ret)
	elseif ret == nil then
		output = ""
	else
		output = tostring(ret)
	end
	pcall(function()
		httpPost("/exec-result", { execId = execId, ok = true, output = output, sessionId = sessionId })
	end)
end

-- Compile-check every script in the place by loadstring()ing its Source (syntax/
-- load errors only). Returns (compileErrors[], scriptsChecked). Shared by both
-- playtest modes.
function Playtest.compileCheck()
	local compileErrors = {}
	local scriptsChecked = 0
	for _, svcName in ipairs(Playtest.SCAN_SERVICES) do
		local okSvc, svc = pcall(game.GetService, game, svcName)
		if okSvc and svc then
			for _, d in ipairs(svc:GetDescendants()) do
				if d:IsA("LuaSourceContainer") then
					scriptsChecked = scriptsChecked + 1
					local src
					local okSrc = pcall(function() src = d.Source end)
					if okSrc and type(src) == "string" and src ~= "" then
						local fn, err = loadstring(src, "=" .. d:GetFullName())
						if not fn then
							compileErrors[#compileErrors + 1] = { path = d:GetFullName(), error = tostring(err) }
						end
					end
				end
			end
			task.wait() -- yield so a huge place doesn't stall Studio
		end
	end
	return compileErrors, scriptsChecked
end

---------------------------------------------------------------------------
-- Play-Solo orchestrator (Tier 2): a REAL playtest with a character + client.
--
-- A plugin can't press Play and doesn't run inside the Play-Solo VMs, so instead
-- we INJECT two scripts (paused → never synced) that get cloned into the play
-- session and drive it from the inside:
--   • a server Script   — the HTTP bridge: fetches the step list from the desktop,
--                          runs server steps, relays client steps over a
--                          RemoteFunction, captures logs/errors, POSTs the report.
--   • a client LocalScript — executes client steps: run client Luau and drive the
--                          character (Humanoid:Move/Jump) to autonomously play.
-- The desktop presses F5 once injection is acked, and Shift+F5 when the report
-- lands. Injected scripts run as ordinary game scripts (no plugin security); HTTP
-- is force-enabled for the run (and restored) so the orchestrator can phone home.
---------------------------------------------------------------------------
Playtest.SERVER_ORCH = [==[
local HttpService = game:GetService("HttpService")
local LogService = game:GetService("LogService")
local ScriptContext = game:GetService("ScriptContext")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

local baseUrl = script:GetAttribute("ServerUrl")
local token = script:GetAttribute("Token") or ""
local sessionId = script:GetAttribute("SessionId")
local playtestId = script:GetAttribute("PlaytestId")

local function http(method, path, body)
	local ok, res = pcall(function()
		return HttpService:RequestAsync({
			Url = baseUrl .. "/api/code/sync" .. path,
			Method = method,
			Headers = { ["Content-Type"] = "application/json", Authorization = "Bearer " .. token },
			Body = body and HttpService:JSONEncode(body) or nil,
		})
	end)
	if not ok or not res or not res.Success then return nil end
	if res.Body and #res.Body > 0 then
		local okD, dec = pcall(function() return HttpService:JSONDecode(res.Body) end)
		if okD then return dec end
	end
	return {}
end

local logs, errors = {}, {}
-- Studio-environment noise that is NOT a bug in the user's game — filtered out of
-- runtimeErrors so a clean playtest reports ok=true (otherwise the agent thinks it
-- failed and re-runs forever). Still kept in `logs` for transparency.
local function isBenign(m)
	m = tostring(m)
	return string.find(m, "StudioAccessToApisNotAllowed", 1, true) ~= nil
		or string.find(m, "Studio access to APIs is not allowed", 1, true) ~= nil
		or string.find(m, "Http requests are not enabled", 1, true) ~= nil
		or string.find(m, "HttpService is not allowed", 1, true) ~= nil
end
LogService.MessageOut:Connect(function(message, msgType)
	if #logs < 400 then logs[#logs + 1] = { message = message, type = msgType.Name } end
	if msgType == Enum.MessageType.MessageError and not isBenign(message) and #errors < 100 then
		errors[#errors + 1] = message
	end
end)
ScriptContext.Error:Connect(function(message, stack)
	if not isBenign(message) and #errors < 100 then errors[#errors + 1] = tostring(message) .. " | " .. tostring(stack) end
end)

local cfg = http("GET", "/playtest-config?playtestId=" .. playtestId) or {}
local steps = cfg.steps or {}
local duration = tonumber(cfg.duration) or 8

local remote = ReplicatedStorage:WaitForChild(script:GetAttribute("RemoteName") or "_ArtlyPlaytestRemote", 10)

-- Wait for the Play-Solo player + character to exist before exercising anything.
local player = Players:GetPlayers()[1]
local t0 = os.clock()
while not player and os.clock() - t0 < 10 do player = Players:GetPlayers()[1]; task.wait(0.1) end
if player and not player.Character then pcall(function() player.CharacterAdded:Wait() end) end
task.wait(1)
local playClock = os.clock() -- start counting play time once the character is ready

local function runServer(code)
	-- loadstring is disabled in play sessions and THROWS ("loadstring() is not
	-- available"); pcall it so a code step degrades to an error instead of killing
	-- the orchestrator before it can report.
	local okLoad, fn, err = pcall(loadstring, code or "")
	if not okLoad then return { ok = false, error = "loadstring unavailable in play (use an edit-time exec instead)" } end
	if not fn then return { ok = false, error = "compile: " .. tostring(err) } end
	local ok, ret = pcall(fn)
	if not ok then return { ok = false, error = tostring(ret) } end
	return { ok = true, result = ret ~= nil and tostring(ret) or "" }
end

local stepResults = {}
-- Whole loop is protected: a single bad step must NEVER stop us from POSTing the
-- report (a missing report is what made playtests "time out").
pcall(function()
	for i, step in ipairs(steps) do
		local st = step.type
		local r
		local okStep, stepErr = pcall(function()
			if st == "server" then
				r = runServer(step.code)
			elseif st == "wait" then
				task.wait(tonumber(step.seconds) or 1)
				r = { ok = true }
			elseif st == "walkto" or st == "jump" or st == "client" or st == "click" or st == "key" or st == "fireserver" or st == "setprop" or st == "getprop" then
				if remote and player then
					local ok, res = pcall(function() return remote:InvokeClient(player, step) end)
					r = (ok and type(res) == "table") and res or { ok = false, error = "client: " .. tostring(res) }
				else
					r = { ok = false, error = "no client/remote available" }
				end
			else
				r = { ok = false, error = "unknown step type: " .. tostring(st) }
			end
		end)
		if not okStep then r = { ok = false, error = "step crashed: " .. tostring(stepErr) } end
		r.index, r.type = i, st
		stepResults[#stepResults + 1] = r
	end
end)

-- Always make the session last (about) the requested duration. After any explicit
-- steps, let the game keep running for whatever time is left — so instant steps like
-- fireserver/setprop don't end the playtest ~1s after it starts, and errors that take
-- a moment to surface still get captured. We do NOT auto-walk the character (driving
-- a walking avatar from a script is unreliable); the character just stands and the
-- game runs while we watch for errors.
local remaining = duration - (os.clock() - playClock)
if remaining > 1 then
	task.wait(remaining)
end

http("POST", "/playtest-report", {
	playtestId = playtestId,
	sessionId = sessionId,
	report = { ran = true, mode = "play", durationSeconds = duration, steps = stepResults, logs = logs, runtimeErrors = errors },
})
]==]

-- LIVE orchestrator: instead of running a fixed list of steps and reporting once,
-- this keeps the Play-Solo session alive and runs ONE command at a time, pulled
-- live from the desktop — so the AI can look at the result (state + a fresh
-- screenshot), then decide the next command, reacting to what actually happened
-- (a brittle pre-baked script breaks the moment one thing differs; this doesn't).
Playtest.LIVE_ORCH = [==[
local HttpService = game:GetService("HttpService")
local LogService = game:GetService("LogService")
local ScriptContext = game:GetService("ScriptContext")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")

local baseUrl = script:GetAttribute("ServerUrl")
local token = script:GetAttribute("Token") or ""
local sessionId = script:GetAttribute("SessionId")
local playtestId = script:GetAttribute("PlaytestId")

local function http(method, path, body)
	local ok, res = pcall(function()
		return HttpService:RequestAsync({
			Url = baseUrl .. "/api/code/sync" .. path,
			Method = method,
			Headers = { ["Content-Type"] = "application/json", Authorization = "Bearer " .. token },
			Body = body and HttpService:JSONEncode(body) or nil,
		})
	end)
	if not ok or not res or not res.Success then return nil end
	if res.Body and #res.Body > 0 then
		local okD, dec = pcall(function() return HttpService:JSONDecode(res.Body) end)
		if okD then return dec end
	end
	return {}
end

-- Capture runtime errors as they happen so each command result can report only the
-- errors NEW since the previous command (errCursor) — that's how the AI sees "what
-- my last action broke" live.
local logs, errors = {}, {}
local errCursor = 0
local function isBenign(m)
	m = tostring(m)
	return string.find(m, "StudioAccessToApisNotAllowed", 1, true) ~= nil
		or string.find(m, "Studio access to APIs is not allowed", 1, true) ~= nil
		or string.find(m, "Http requests are not enabled", 1, true) ~= nil
		or string.find(m, "HttpService is not allowed", 1, true) ~= nil
end
LogService.MessageOut:Connect(function(message, msgType)
	if #logs < 600 then logs[#logs + 1] = { message = message, type = msgType.Name } end
	if msgType == Enum.MessageType.MessageError and not isBenign(message) and #errors < 200 then
		errors[#errors + 1] = tostring(message)
	end
end)
ScriptContext.Error:Connect(function(message, stack)
	if not isBenign(message) and #errors < 200 then errors[#errors + 1] = tostring(message) end
end)

local remote = ReplicatedStorage:WaitForChild(script:GetAttribute("RemoteName") or "_ArtlyPlaytestRemote", 10)

-- Wait for the Play-Solo player + character before accepting commands.
local player = Players:GetPlayers()[1]
local t0 = os.clock()
while not player and os.clock() - t0 < 12 do player = Players:GetPlayers()[1]; task.wait(0.1) end
if player and not player.Character then pcall(function() player.CharacterAdded:Wait() end) end
task.wait(0.5)

-- Snapshot of the character so every result carries live state (where am I, am I alive).
local function charState()
	local c = player and player.Character
	if not c then return nil end
	local hrp = c:FindFirstChild("HumanoidRootPart")
	local hum = c:FindFirstChildOfClass("Humanoid")
	return {
		position = hrp and { math.floor(hrp.Position.X * 10) / 10, math.floor(hrp.Position.Y * 10) / 10, math.floor(hrp.Position.Z * 10) / 10 } or nil,
		health = hum and hum.Health or nil,
		maxHealth = hum and hum.MaxHealth or nil,
		walkSpeed = hum and hum.WalkSpeed or nil,
		state = hum and hum:GetState().Name or nil,
	}
end

local function newErrors()
	local out = {}
	for i = errCursor + 1, #errors do out[#out + 1] = errors[i] end
	errCursor = #errors
	return out
end

local function posOf(inst)
	if inst:IsA("BasePart") then return inst.Position end
	if inst:IsA("Model") then local okP, cf = pcall(function() return inst:GetPivot() end); return okP and cf.Position or nil end
	if inst:IsA("Attachment") then return inst.WorldPosition end
	return nil
end

-- find: search the LIVE tree for instances by name substring and/or className, so
-- the AI can DISCOVER what to interact with (and its real position) instead of
-- guessing a path that may have changed — the core of not being brittle.
local function doFind(cmd)
	local nameQ = cmd.name and string.lower(tostring(cmd.name)) or nil
	local classQ = cmd.class and tostring(cmd.class) or nil
	local root = Workspace
	if cmd.under then
		local cur = game
		for seg in string.gmatch(tostring(cmd.under), "[^%.]+") do
			if seg == "game" then cur = game elseif cur then cur = cur:FindFirstChild(seg) end
			if not cur then break end
		end
		if cur then root = cur end
	end
	local limit = math.clamp(tonumber(cmd.limit) or 12, 1, 40)
	local matches = {}
	local okScan = pcall(function()
		for _, d in ipairs(root:GetDescendants()) do
			if #matches >= limit then break end
			local nameOk = (not nameQ) or string.find(string.lower(d.Name), nameQ, 1, true) ~= nil
			local classOk = (not classQ) or d:IsA(classQ)
			if nameOk and classOk then
				local p = posOf(d)
				matches[#matches + 1] = {
					path = d:GetFullName(),
					name = d.Name,
					className = d.ClassName,
					position = p and { math.floor(p.X * 10) / 10, math.floor(p.Y * 10) / 10, math.floor(p.Z * 10) / 10 } or nil,
				}
			end
		end
	end)
	return { ok = okScan and true or false, matches = matches }
end

-- Run one command. find/state/wait are handled server-side here; everything that
-- needs the character/PlayerGui (walkto, jump, getprop, setprop, fireserver,
-- jump) is delegated to the CLIENT orchestrator via the RemoteFunction.
local function runCommand(cmd)
	local t = cmd.type
	if t == "find" then
		return doFind(cmd)
	elseif t == "state" then
		return { ok = true, result = "ok" }
	elseif t == "wait" then
		task.wait(math.clamp(tonumber(cmd.seconds) or 1, 0, 15))
		return { ok = true, result = "waited" }
	else
		if remote and player then
			local ok, res = pcall(function() return remote:InvokeClient(player, cmd) end)
			return (ok and type(res) == "table") and res or { ok = false, error = "client: " .. tostring(res) }
		end
		return { ok = false, error = "no client/remote available" }
	end
end

-- Command loop: pull → run → post result (with live state + new errors). The
-- desktop adds the screenshot. Bail on a stop signal or the hard lifetime cap.
local sessionStart = os.clock()
local MAX_LIFE = 1200 -- 20 min absolute safety; the desktop also idle-stops us
while os.clock() - sessionStart < MAX_LIFE do
	local poll = http("GET", "/playtest-cmd?playtestId=" .. playtestId)
	if poll == nil then
		task.wait(0.4) -- transient http failure; keep going
	elseif poll.stop then
		break
	elseif poll.cmd then
		local cmd = poll.cmd
		local r
		local ok, err = pcall(function() r = runCommand(cmd) end)
		if not ok then r = { ok = false, error = "command crashed: " .. tostring(err) } end
		r = r or { ok = false, error = "no result" }
		http("POST", "/playtest-cmd-result", {
			playtestId = playtestId,
			sessionId = sessionId,
			cmdId = poll.cmdId,
			result = r,
			character = charState(),
			newErrors = newErrors(),
		})
	else
		task.wait(0.3) -- idle: no command queued
	end
end
pcall(function() http("POST", "/playtest-cmd-result", { playtestId = playtestId, sessionId = sessionId, stopped = true }) end)
]==]

Playtest.CLIENT_ORCH = [==[
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local player = Players.LocalPlayer
local remote = ReplicatedStorage:WaitForChild("_ArtlyPlaytestRemote", 20)
if not remote then return end

-- Resolve a dotted instance path ("game.ReplicatedStorage.Sprint",
-- "game.Players.LocalPlayer.Character.Humanoid") to a live instance.
local function resolvePath(path)
	local cur = game
	for seg in string.gmatch(tostring(path), "[^%.]+") do
		if seg == "game" then
			cur = game
		elseif seg == "LocalPlayer" or seg == "Player" then
			cur = player
		elseif seg == "Character" then
			cur = player.Character
		elseif cur then
			cur = cur:FindFirstChild(seg)
		end
		if not cur then return nil end
	end
	return cur
end

remote.OnClientInvoke = function(step)
	local st = step.type
	if st == "client" then
		local okLoad, fn, err = pcall(loadstring, step.code or "")
		if not okLoad then return { ok = false, error = "loadstring unavailable in play (use an edit-time exec instead)" } end
		if not fn then return { ok = false, error = "compile: " .. tostring(err) } end
		local ok, ret = pcall(fn)
		if not ok then return { ok = false, error = tostring(ret) } end
		return { ok = true, result = ret ~= nil and tostring(ret) or "" }
	elseif st == "walkto" then
		-- Move the character to a target instance (or x/y/z point) so proximity-triggered
		-- features fire and you can look at it. TELEPORTS directly (driving a walking
		-- character from a script is unreliable) — lands the character just short of the
		-- target, facing it, so it ends up NEXT to the thing, not inside it.
		local char = player.Character
		if not char then
			local okC, c = pcall(function() return player.CharacterAdded:Wait() end)
			char = okC and c or nil
		end
		local hrp = char and char:FindFirstChild("HumanoidRootPart")
		if not char or not hrp then return { ok = false, error = "no character to move" } end
		local targetPos
		if step.x ~= nil and step.y ~= nil and step.z ~= nil then
			targetPos = Vector3.new(tonumber(step.x), tonumber(step.y), tonumber(step.z))
		else
			local inst = resolvePath(step.target)
			if not inst then return { ok = false, error = "target not found: " .. tostring(step.target) } end
			if inst:IsA("BasePart") then
				targetPos = inst.Position
			elseif inst:IsA("Model") then
				local okP, cf = pcall(function() return inst:GetPivot() end)
				targetPos = okP and cf.Position or nil
			elseif inst:IsA("Attachment") then
				targetPos = inst.WorldPosition
			end
			if not targetPos then return { ok = false, error = "target has no position: " .. tostring(step.target) } end
		end
		local reach = math.clamp(tonumber(step.reach) or 4, 1, 50)
		local from = hrp.Position
		local flat = Vector3.new(targetPos.X - from.X, 0, targetPos.Z - from.Z)
		local landing
		if flat.Magnitude > 0.1 then
			landing = targetPos - flat.Unit * math.max(reach - 1, 1) + Vector3.new(0, 3.5, 0)
		else
			landing = targetPos + Vector3.new(0, 3.5, 0)
		end
		pcall(function() char:PivotTo(CFrame.lookAt(landing, Vector3.new(targetPos.X, landing.Y, targetPos.Z))) end)
		task.wait(0.3)
		local d = (Vector3.new(targetPos.X, 0, targetPos.Z) - Vector3.new(hrp.Position.X, 0, hrp.Position.Z)).Magnitude
		return {
			ok = true,
			result = "teleported next to " .. tostring(step.target or "point") .. string.format(" (%.1f studs away)", d),
			arrived = d <= reach + 2,
			teleported = true,
		}
	elseif st == "jump" then
		-- Make the character jump once (e.g. to test a height meter or a jump pad).
		local char = player.Character
		local hum = char and char:FindFirstChildOfClass("Humanoid")
		if not hum then return { ok = false, error = "no Humanoid to jump" } end
		pcall(function() hum.Jump = true end)
		task.wait(0.4)
		return { ok = true, result = "jumped" }
	elseif st == "fireserver" then
		-- Trigger a server-driven ability by firing its RemoteEvent from the client
		-- (no keystroke needed) — e.g. a sprint the client signals to the server.
		local ev = resolvePath(step.remote)
		if not ev then return { ok = false, error = "remote not found: " .. tostring(step.remote) } end
		local args = step.args
		if type(args) ~= "table" then args = (args == nil) and {} or { args } end
		local ok, err = pcall(function() ev:FireServer(table.unpack(args)) end)
		if not ok then return { ok = false, error = "FireServer failed: " .. tostring(err) } end
		return { ok = true, result = "fired " .. tostring(step.remote) }
	elseif st == "setprop" then
		-- Trigger/observe an effect by setting a property directly (no keystroke) —
		-- e.g. set the local Humanoid's WalkSpeed to mimic a sprint speed boost.
		local inst = resolvePath(step.target)
		if not inst then return { ok = false, error = "target not found: " .. tostring(step.target) } end
		local ok, err = pcall(function() inst[step.property] = step.value end)
		if not ok then return { ok = false, error = "set " .. tostring(step.property) .. " failed: " .. tostring(err) } end
		return { ok = true, result = tostring(step.property) .. " = " .. tostring(step.value) }
	elseif st == "getprop" then
		-- READ a property/value so you can VERIFY behaviour (e.g. read a height-bar
		-- number before vs after jumping). Returns the value as a string.
		local inst = resolvePath(step.target)
		if not inst then return { ok = false, error = "target not found: " .. tostring(step.target) } end
		local ok, val = pcall(function() return inst[step.property] end)
		if not ok then return { ok = false, error = "read " .. tostring(step.property) .. " failed: " .. tostring(val) } end
		return { ok = true, result = tostring(step.property) .. " = " .. tostring(val) }
	elseif st == "click" or st == "key" then
		-- Real mouse/keyboard synthesis needs VirtualInputManager, which is
		-- RobloxScript-only and unavailable from an injected game script. Surface a
		-- clear, actionable error rather than crash: trigger the behaviour via a
		-- "fireserver"/"setprop" step (the ability's RemoteEvent / a property) instead.
		return {
			ok = false,
			error = "input simulation (" .. tostring(st) .. ") isn't available from the playtest sandbox (VirtualInputManager is RobloxScript-only). Trigger the behaviour with a 'fireserver' or 'setprop' step instead.",
		}
	end
	return { ok = false, error = "unknown step type" }
end
]==]

-- Remove any leftover injected playtest instances (and restore HttpEnabled).
-- Safe to call any time we're in edit mode; tagged instances are paused/untracked
-- so destroying them never emits sync patches.
function Playtest.cleanup()
	for _, svcName in ipairs({ "ServerScriptService", "ReplicatedStorage", "StarterPlayer" }) do
		local okSvc, svc = pcall(game.GetService, game, svcName)
		if okSvc and svc then
			for _, d in ipairs(svc:GetDescendants()) do
				local okA, tagged = pcall(function() return d:GetAttribute(Playtest.TAG) end)
				if okA and tagged then
					pausedInstances[d] = true
					pcall(function() d:Destroy() end)
				end
			end
		end
	end
	if Playtest.prevHttp ~= nil then
		pcall(function() HttpService.HttpEnabled = Playtest.prevHttp end)
		Playtest.prevHttp = nil
	end
	Playtest.active = false
	Playtest.runStarted = false
end

-- Inject the orchestrator scripts so the next Play Solo run is driven from inside.
-- `live` chooses the LIVE command-loop orchestrator (AI drives it one command at a
-- time) over the one-shot scripted SERVER_ORCH.
function Playtest.inject(playtestId, live)
	Playtest.cleanup() -- clear any stale leftovers first

	local ServerScriptService = game:GetService("ServerScriptService")
	local ReplicatedStorage = game:GetService("ReplicatedStorage")
	local StarterPlayer = game:GetService("StarterPlayer")

	-- The orchestrator runs as a normal game script in Play Solo, so it needs HTTP
	-- enabled to reach the desktop (plugins bypass this, in-game scripts don't).
	-- NOTE: we deliberately do NOT touch loadstring — ServerScriptService no longer
	-- exposes a settable LoadStringEnabled (reading it throws "not a valid member"
	-- on current Studio). server/client CODE steps therefore rely on the place
	-- already permitting loadstring and degrade to a clear per-step error if not;
	-- play / click / key / error-capture never need it.
	pcall(function() Playtest.prevHttp = HttpService.HttpEnabled end)
	pcall(function() HttpService.HttpEnabled = true end)

	local remote = Instance.new("RemoteFunction")
	remote.Name = Playtest.REMOTE
	pausedInstances[remote] = true
	remote:SetAttribute(Playtest.TAG, true)
	remote.Parent = ReplicatedStorage

	local serverScript = Instance.new("Script")
	serverScript.Name = "_ArtlyPlaytestServer"
	serverScript.Source = live and Playtest.LIVE_ORCH or Playtest.SERVER_ORCH
	pausedInstances[serverScript] = true
	serverScript:SetAttribute(Playtest.TAG, true)
	serverScript:SetAttribute("ServerUrl", serverUrl)
	serverScript:SetAttribute("Token", projectToken or "")
	serverScript:SetAttribute("SessionId", sessionId or "")
	serverScript:SetAttribute("PlaytestId", playtestId)
	serverScript:SetAttribute("RemoteName", Playtest.REMOTE)
	serverScript.Parent = ServerScriptService

	local sps = StarterPlayer:FindFirstChildOfClass("StarterPlayerScripts")
	if sps then
		local clientScript = Instance.new("LocalScript")
		clientScript.Name = "_ArtlyPlaytestClient"
		clientScript.Source = Playtest.CLIENT_ORCH
		pausedInstances[clientScript] = true
		clientScript:SetAttribute(Playtest.TAG, true)
		clientScript.Parent = sps
	end

	Playtest.active = true
end

-- Answer a server "playtest" command. Two modes:
--   "run"  (default) — self-contained: compile-check, then drive Run mode for
--                      `duration`s capturing logs/errors. Server-only, no avatar.
--   "play"           — real Play Solo: compile-check, then inject the orchestrator
--                      and ack "injected" so the desktop presses F5. The injected
--                      server script POSTs the report; the desktop writes the
--                      result file. There IS a character + client + input sim.
function Playtest.handlePlaytest(execId, duration, mode, playtestId)
	-- "play" = one-shot scripted Play Solo; "live" = persistent Play Solo the AI
	-- drives one command at a time; anything else = headless Run-mode capture.
	if mode ~= "play" and mode ~= "live" then mode = "run" end
	duration = math.min(math.max(tonumber(duration) or 8, 1), 30)

	local compileErrors, scriptsChecked = Playtest.compileCheck()

	if mode == "play" or mode == "live" then
		if #compileErrors > 0 then
			-- Don't launch a playtest on code that won't even load.
			local report = { phase = "compile", ran = false, mode = mode, scriptsChecked = scriptsChecked, compileErrors = compileErrors }
			pcall(function()
				httpPost("/exec-result", { execId = execId, ok = false, output = HttpService:JSONEncode(report), sessionId = sessionId })
			end)
			return
		end
		local okInject, injErr = pcall(Playtest.inject, playtestId, mode == "live")
		if not okInject then
			Playtest.cleanup()
			pcall(function()
				httpPost("/exec-result", { execId = execId, ok = false, output = "inject failed: " .. tostring(injErr), sessionId = sessionId })
			end)
			return
		end
		-- "injected" tells the desktop to press Play (F5); the report arrives
		-- separately from the in-session orchestrator.
		pcall(function()
			httpPost("/exec-result", { execId = execId, ok = true, output = "injected", sessionId = sessionId })
		end)
		return
	end

	-- mode "run": capture runtime output across a Run-mode simulation.
	local LogService = game:GetService("LogService")
	local logs = {}
	local logConn = LogService.MessageOut:Connect(function(message, msgType)
		if #logs < Playtest.MAX_LOGS then
			logs[#logs + 1] = { message = message, type = msgType.Name }
		end
	end)
	local runOk, runErr = pcall(function() RunService:Run() end)
	if runOk then
		task.wait(duration)
		pcall(function() RunService:Stop() end)
		task.wait(0.25) -- let Stop settle and final messages flush before we disconnect
	end
	logConn:Disconnect()

	local runtimeErrors = {}
	for _, l in ipairs(logs) do
		if l.type == "MessageError" then
			runtimeErrors[#runtimeErrors + 1] = l.message
		end
	end
	local report = {
		scriptsChecked = scriptsChecked,
		compileErrors = compileErrors,
		ran = runOk,
		runError = (not runOk) and tostring(runErr) or nil,
		durationSeconds = runOk and duration or 0,
		runtimeErrors = runtimeErrors,
		logs = logs,
		mode = "run",
	}
	local clean = (#compileErrors == 0) and runOk and (#runtimeErrors == 0)
	pcall(function()
		httpPost("/exec-result", {
			execId = execId,
			ok = clean,
			output = HttpService:JSONEncode(report),
			sessionId = sessionId,
		})
	end)
end

local function serializeForAdd(instance, parentId)
	local props = captureProperties(instance)
	local tags = CollectionService:GetTags(instance)
	if tags and #tags > 0 then
		props.Tags = { type = "Tags", value = tags }
	end
	local result = {
		name = instance.Name,
		className = instance.ClassName,
		parent = parentId,
		properties = props,
	}
	local attrs = captureAttributes(instance)
	if attrs then result.attributes = attrs end
	return result
end

local function flushChanges()
	if not connected then return end
	if RunService:IsRunning() then return end -- HTTP is blocked while running/playing
	if #pendingChanges == 0 and next(pendingAdds) == nil and #pendingRemoves == 0 then return end

	-- Snapshot + clear up front so change listeners firing during the yields below
	-- queue into fresh tables (never mutate what we're iterating), and a re-entrant
	-- flush (Heartbeat fires again mid-yield) sees nothing to do.
	local pc, pa, pr = pendingChanges, pendingAdds, pendingRemoves
	pendingChanges = {}
	pendingAdds = {}
	pendingRemoves = {}

	local updated = {}
	local seen = {}
	local work = 0

	for _, change in ipairs(pc) do
		local id = instanceToId[change.instance]
		if not id then continue end
		if pa[id] then continue end -- new instances go in `added`, not `updated`
		if not seen[id] then
			seen[id] = { id = id, changedProperties = {} }
			table.insert(updated, seen[id])
		end
		local serialized = serializeProperty(change.instance, change.property)
		if serialized ~= nil then
			seen[id].changedProperties[change.property] = serialized
		end
		work = work + 1
		if work % 200 == 0 then task.wait() end -- keep Studio responsive on big batches
	end

	local added = {}
	for id, entry in pairs(pa) do
		if entry.instance and entry.instance.Parent then
			-- Re-resolve parent id in case parent registered after queueing
			local parentId = entry.parentId or instanceToId[entry.instance.Parent]
			if parentId then
				added[id] = serializeForAdd(entry.instance, parentId)
			end
		end
		-- serializeForAdd captures the full property set (heavy) — yield often.
		work = work + 1
		if work % 50 == 0 then task.wait() end
	end

	local removed = {}
	for _, id in ipairs(pr) do table.insert(removed, id) end

	if #updated == 0 and next(added) == nil and #removed == 0 then return end

	task.spawn(function()
		local _, err = httpPost("/write", {
			sessionId = sessionId,
			added = added,
			updated = updated,
			removed = removed,
		})
		if not err then markSynced() end
	end)
end

---------------------------------------------------------------------------
-- Reconciler
---------------------------------------------------------------------------
local function resolveRobloxParent(className)
	local services = {
		ServerScriptService = game:GetService("ServerScriptService"),
		ReplicatedStorage = game:GetService("ReplicatedStorage"),
		StarterPlayer = game:GetService("StarterPlayer"),
		StarterGui = game:GetService("StarterGui"),
		StarterPack = game:GetService("StarterPack"),
		Workspace = game:GetService("Workspace"),
		Lighting = game:GetService("Lighting"),
		ServerStorage = game:GetService("ServerStorage"),
		ReplicatedFirst = game:GetService("ReplicatedFirst"),
		SoundService = game:GetService("SoundService"),
		Chat = game:GetService("Chat"),
		Teams = game:GetService("Teams"),
		TestService = game:GetService("TestService"),
		MaterialService = game:GetService("MaterialService"),
		StarterCharacterScripts = game:GetService("StarterPlayer"):FindFirstChild("StarterCharacterScripts"),
		StarterPlayerScripts = game:GetService("StarterPlayer"):FindFirstChild("StarterPlayerScripts"),
	}
	-- Fallback: try to resolve any service name via GetService
	if not services[className] then
		local ok, svc = pcall(game.GetService, game, className)
		if ok and svc then return svc end
	end
	return services[className]
end

local function createInstance(id, data)
	local parent = idToInstance[data.parent]

	if not parent then
		local service = resolveRobloxParent(data.className) or resolveRobloxParent(data.name)
		if service then
			registerInstance(id, service)
			return service
		end
		return nil
	end

	for _, child in ipairs(parent:GetChildren()) do
		if child.Name == data.name and child.ClassName == data.className then
			registerInstance(id, child)
			pausedInstances[child] = true
			for propName, propValue in pairs(data.properties or {}) do
				if propName == "Tags" then applyTags(child, propValue)
				else setInstanceProperty(child, propName, propValue) end
			end
			applyAttributes(child, data.attributes)
			pausedInstances[child] = nil
			connectChangeListener(child)
			return child
		end
	end

	local ok, instance = pcall(Instance.new, data.className)
	if not ok then
		warn("[Artly Sync] Cannot create: " .. tostring(data.className))
		return nil
	end

	pausedInstances[instance] = true
	pcall(function() instance.Name = data.name end)
	for propName, propValue in pairs(data.properties or {}) do
		if propName == "Tags" then applyTags(instance, propValue)
		else setInstanceProperty(instance, propName, propValue) end
	end
	applyAttributes(instance, data.attributes)
	local parentOk, parentErr = pcall(function() instance.Parent = parent end)
	pausedInstances[instance] = nil

	if not parentOk then
		warn("[Artly Sync] Failed to parent " .. tostring(data.className) ..
			" '" .. tostring(data.name) .. "' under " .. tostring(parent.ClassName) ..
			": " .. tostring(parentErr))
		pcall(function() instance:Destroy() end)
		return nil
	end

	registerInstance(id, instance)
	connectChangeListener(instance)
	return instance
end

local function applyPatch(patch)
	local changed = false

	for _, id in ipairs(patch.removed or {}) do
		local instance = idToInstance[id]
		if instance then
			unregisterTree(instance)
			-- Don't Destroy() game services (DataStoreService, SerializationService,
			-- etc.) — their Parent is locked by the engine and Destroy() spams
			-- "Parent property locked" warnings even inside pcall.
			if instance.Parent ~= game then
				pcall(function() instance:Destroy() end)
			end
			changed = true
		end
	end

	-- Create instances in parent-first order. Mirrors initialSync: build an
	-- array, then repeatedly drain entries whose parent is ready.
	local sorted = {}
	for id, data in pairs(patch.added or {}) do
		table.insert(sorted, { id = id, data = data })
	end
	for _ = 1, 32 do
		local remaining = {}
		local created = 0
		for _, entry in ipairs(sorted) do
			local parentReady = (entry.data.parent == nil)
				or (idToInstance[entry.data.parent] ~= nil)
				or (resolveRobloxParent(entry.data.className) ~= nil)
			if parentReady then
				local ok, result = pcall(createInstance, entry.id, entry.data)
				if not ok then
					warn("[Artly Sync] createInstance crashed: " .. tostring(result))
				elseif result then
					changed = true
				end
				created = created + 1
			else
				table.insert(remaining, entry)
			end
		end
		sorted = remaining
		if #sorted == 0 or created == 0 then break end
	end
	-- Any leftovers whose parents never materialized
	for _, entry in ipairs(sorted) do
		local ok, result = pcall(createInstance, entry.id, entry.data)
		if ok and result then changed = true end
		if not ok then
			warn("[Artly Sync] leftover createInstance crashed: " .. tostring(result))
		end
	end

	for _, update in ipairs(patch.updated or {}) do
		local instance = idToInstance[update.id]
		if not instance then continue end

		-- Skip instances that are no longer in the data model (destroyed during play
		-- mode). game:IsAncestorOf returns false for destroyed/unparented instances,
		-- preventing "Parent property locked" engine warnings from pcall'd assignments.
		if instance ~= game and instance.Parent ~= game and not game:IsAncestorOf(instance) then
			unregisterInstance(instance)
			continue
		end

		pausedInstances[instance] = true

		if update.changedClassName then
			local parent = instance.Parent
			local name = update.changedName or instance.Name
			local props = update.changedProperties or {}

			-- Snapshot existing children so they survive the className swap.
			-- Roblox can't change className on an existing instance, so we must
			-- create a new one — but we reparent children instead of destroying them.
			local existingChildren = instance:GetChildren()

			local ok, newInstance = pcall(Instance.new, update.changedClassName)
			if ok then
				newInstance.Name = name
				for propName, propValue in pairs(props) do
					setInstanceProperty(newInstance, propName, propValue)
				end
				newInstance.Parent = parent
				for _, child in ipairs(existingChildren) do
					pcall(function() child.Parent = newInstance end)
				end
				-- Swap registration without unregistering subtree (children kept their ids)
				idToInstance[update.id] = newInstance
				instanceToId[newInstance] = update.id
				instanceToId[instance] = nil
				local oldConns = changeConnections[instance]
				if oldConns then
					for _, c in ipairs(oldConns) do pcall(function() c:Disconnect() end) end
					changeConnections[instance] = nil
				end
				pcall(function() instance:Destroy() end)
				connectChangeListener(newInstance)
			end
			changed = true
			continue
		end

		if update.changedName then
			instance.Name = update.changedName
			changed = true
		end

		if update.changedParent then
			local newParent = idToInstance[update.changedParent]
			if newParent then
				pcall(function() instance.Parent = newParent end)
				changed = true
			end
		end

		for propName, propValue in pairs(update.changedProperties or {}) do
			setInstanceProperty(instance, propName, propValue)
			changed = true
		end

		pausedInstances[instance] = nil
	end

	-- Targets for any deferred instance references now all exist — wire them up.
	resolvePendingInstanceRefs()

	if changed then
		instanceCount = 0
		for _ in pairs(idToInstance) do instanceCount = instanceCount + 1 end
		markSynced()
	end
end

---------------------------------------------------------------------------
-- Initial sync
---------------------------------------------------------------------------
local function initialSync()
	statusText.Text = "Syncing..."
	statusText.TextColor3 = Color3.fromRGB(255, 200, 50)
	statusDot.BackgroundColor3 = Color3.fromRGB(255, 200, 50)

	local data, err = httpGet("/full")
	if not data then
		warn("[Artly Sync] Failed to get full tree: " .. tostring(err))
		return false
	end

	sessionId = data.sessionId
	cursor = data.cursor or 0
	local instances = data.instances or {}

	for id, inst in pairs(instances) do
		if inst.className == "DataModel" then
			registerInstance(id, game)
			rootInstanceId = id
		else
			local service = resolveRobloxParent(inst.className) or resolveRobloxParent(inst.name)
			if service then registerInstance(id, service) end
		end
	end

	local sorted = {}
	for id, inst in pairs(instances) do
		if not idToInstance[id] then
			table.insert(sorted, { id = id, data = inst })
		end
	end

	local built = 0
	for _ = 1, 20 do
		local remaining = {}
		local created = 0
		for _, entry in ipairs(sorted) do
			if entry.data.parent == nil or idToInstance[entry.data.parent] ~= nil then
				createInstance(entry.id, entry.data)
				created = created + 1
				built = built + 1
				-- Yield periodically so pulling a large tree doesn't freeze Studio.
				if built % 100 == 0 then task.wait() end
			else
				table.insert(remaining, entry)
			end
		end
		sorted = remaining
		if #sorted == 0 or created == 0 then break end
	end

	-- Whole tree built — resolve any instance references that were deferred.
	resolvePendingInstanceRefs()

	instanceCount = 0
	for _ in pairs(idToInstance) do instanceCount = instanceCount + 1 end
	lastSyncTime = os.time()

	return true
end

---------------------------------------------------------------------------
-- Upload the EXISTING game (Studio -> Server) on connect
---------------------------------------------------------------------------
-- initialSync() only PULLS the server's tree into Studio. A game that already
-- had content before connecting (Parts, GUIs, Scripts the user built) was never
-- sent up, so the agent's workspace looked empty and it told the user "your game
-- is empty" even though it isn't. Walk each watched service top-down and queue
-- every instance the server doesn't already know as an add. Top-down guarantees
-- each parent is registered (and has an id) before its children are queued, so
-- the server can rebuild the hierarchy.
local UPLOAD_CHUNK = 150 -- instances per /write; keeps each POST body well under
                         -- the request-body limit (Roblox HttpService + the Vercel
                         -- proxy reject large bodies — a single huge upload silently
                         -- failed, leaving the agent's workspace empty).

local function uploadExistingTree()
	if not connected then return end
	uploading = true
	-- Collect newly-seen instances in PARENT-FIRST order (the walk is top-down), so
	-- chunks can be sent in that order and the server always has a child's parent
	-- before the child.
	local order = {}
	local walked = 0

	-- Queue `inst` and any un-registered ancestors up to its service, parent-first.
	-- Used by scripts-only mode so a script's parent path exists on disk; non-script
	-- ancestors go up as lightweight FOLDERS (just to home the script — the real
	-- instance is read live on demand, never mirrored).
	local function ensureQueued(inst)
		if inst == game or instanceToId[inst] then return end
		local parent = inst.Parent
		if parent and parent ~= game then ensureQueued(parent) end
		local parentId = instanceToId[parent]
		if not parentId then return end
		local id = HttpService:GenerateGUID(false)
		registerInstance(id, inst)
		local asFolder = not SCRIPT_CLASSES[inst.ClassName]
		if not asFolder then connectChangeListener(inst) end -- only watch real scripts
		order[#order + 1] = { id = id, instance = inst, parentId = parentId, asFolder = asFolder }
	end

	local function walk(parent)
		local parentId = instanceToId[parent]
		-- Mirror mode can't register a child without a registered parent, so it stops
		-- here. Scripts-only mode must keep descending (scripts can live deep under
		-- unregistered data instances) — ensureQueued registers the chain lazily.
		if not scriptsOnly and not parentId then return end
		for _, child in ipairs(parent:GetChildren()) do
			walked = walked + 1
			-- Yield every ~1000 nodes (the proven cadence) so a giant place doesn't
			-- block Studio's main thread while we walk it.
			if walked % 1000 == 0 then task.wait() end
			if scriptsOnly then
				-- On-demand desktop: upload ONLY scripts (+ their folder ancestors),
				-- not the whole place — this is what kills the upload freeze.
				if SCRIPT_CLASSES[child.ClassName] then ensureQueued(child) end
			elseif not instanceToId[child] then
				local id = HttpService:GenerateGUID(false)
				registerInstance(id, child)
				connectChangeListener(child)
				order[#order + 1] = { id = id, instance = child, parentId = parentId }
			end
			walk(child)
		end
	end
	for _, serviceName in ipairs(WATCHED_SERVICES) do
		local ok, service = pcall(game.GetService, game, serviceName)
		if ok and service then walk(service) end
	end

	-- Send in ordered, AWAITED chunks (synchronous httpPost, not task.spawn) so a
	-- huge game uploads as many small bodies that fit the size limit, in parent-
	-- first order. Retry a failed chunk a couple of times (e.g. transient close).
	local i = 1
	while i <= #order and connected do
		if RunService:IsRunning() then task.wait(0.5) -- HTTP blocked while running
		else
			local added = {}
			local n = 0
			while n < UPLOAD_CHUNK and i <= #order do
				local e = order[i]
				i = i + 1
				if e.instance and e.instance.Parent then
					local parentId = e.parentId or instanceToId[e.instance.Parent]
					if parentId then
						if e.asFolder then
							-- Lightweight container so the script's path exists on disk;
							-- no properties (the real instance is queried on demand).
							added[e.id] = { name = e.instance.Name, className = "Folder", parent = parentId, properties = {} }
						else
							added[e.id] = serializeForAdd(e.instance, parentId)
						end
					end
				end
				n = n + 1
			end
			if next(added) ~= nil then
				local ok = false
				for attempt = 1, 3 do
					local _, err = httpPost("/write", { sessionId = sessionId, added = added, updated = {}, removed = {} })
					if not err then ok = true; break end
					warn("[Artly Sync] upload chunk failed (try " .. attempt .. "): " .. tostring(err))
					task.wait(attempt)
				end
				if ok then
					-- Reflect real progress in the panel (not the initial service count).
					instanceCount = 0
					for _ in pairs(idToInstance) do instanceCount = instanceCount + 1 end
					markSynced()
				end
			end
			task.wait() -- yield between chunks so Studio stays responsive
		end
	end
	uploading = false
	print("[Artly Sync] Uploaded " .. tostring(#order) .. " instances")
end

---------------------------------------------------------------------------
-- Poll loop
---------------------------------------------------------------------------
local function startPolling()
	task.spawn(function()
		local failCount = 0
		while connected do
			-- While Studio is in Run/Play mode, HttpService is blocked in that
			-- context ("Http requests can only be executed by game server"). Pause
			-- polling until the run/test stops, then resume cleanly — don't burn
			-- failCount or spam errors. (A plugin playtest also trips this.)
			if RunService:IsRunning() then
				-- Mark that the injected play run actually started, so we only clean
				-- up AFTER it ends (not in the gap between "injected" and F5).
				if Playtest.active then Playtest.runStarted = true end
				task.wait(0.5)
				continue
			end
			-- Just came out of a Play-Solo playtest we injected → tear the injected
			-- orchestrator scripts back out and restore HttpEnabled.
			-- (The desktop also sends a cleanup as a fallback.)
			if Playtest.active and Playtest.runStarted then
				Playtest.cleanup()
			end
			local data, err = httpGet("/subscribe?cursor=" .. tostring(cursor))
			if not connected then break end

			if data then
				failCount = 0
				if data.sessionId ~= sessionId then
					-- The server session changed (it restarted, or its workspace was
					-- reset). Auto re-handshake with the SAME token so the live game
					-- is re-uploaded — no manual disconnect/reconnect needed.
					print("[Artly Sync] Server session changed — re-syncing automatically…")
					task.spawn(softReconnect)
					break
				end
				cursor = data.cursor or cursor
				-- Apply declarative tree changes (create / update / delete
				-- instances and properties), exactly like Rojo. Any `commands`
				-- field is handled separately below.
				for _, patch in ipairs(data.patches or {}) do
					applyPatch(patch)
				end
				-- Edit-time commands. "describe"/"structure" are declarative reads;
				-- "luau"/"playtest" run agent-supplied code in THIS Studio session (the
				-- escape hatch + real playtest). Each is deduped by execId and run off
				-- the poll loop so a long playtest never blocks polling.
				for _, cmd in ipairs(data.commands or {}) do
					if cmd.kind == "describe" and cmd.execId and not handledExec[cmd.execId] then
						handledExec[cmd.execId] = true
						local iid, ipath = cmd.instanceId, cmd.path
						task.spawn(function() handleDescribe(cmd.execId, iid, ipath) end)
					elseif cmd.kind == "structure" and cmd.execId and not handledExec[cmd.execId] then
						handledExec[cmd.execId] = true
						local rp, md = cmd.rootPath, cmd.maxDepth
						task.spawn(function() handleStructure(cmd.execId, rp, md) end)
					elseif cmd.kind == "luau" and cmd.execId and not handledExec[cmd.execId] then
						handledExec[cmd.execId] = true
						local src = cmd.source
						task.spawn(function() Playtest.handleLuau(cmd.execId, src) end)
					elseif cmd.kind == "playtest" and cmd.execId and not handledExec[cmd.execId] then
						handledExec[cmd.execId] = true
						local dur, md, pid = cmd.duration, cmd.mode, cmd.playtestId
						task.spawn(function() Playtest.handlePlaytest(cmd.execId, dur, md, pid) end)
					end
				end
			else
				failCount = failCount + 1
				-- While the initial upload is streaming, the server is busy writing
				-- files and the long-poll often times out — DON'T treat that as a
				-- lost connection (a re-handshake here would reset the upload and it
				-- would never finish). Just keep polling; the upload uses its own
				-- requests and completes independently.
				-- Otherwise, after a stretch of real failures, re-handshake (the
				-- server may have come back on a new session).
				if failCount > 8 and not uploading then
					print("[Artly Sync] Lost contact — attempting automatic re-sync…")
					task.spawn(softReconnect)
					break
				end
				task.wait(math.min(2 * failCount, 10))
			end

			task.wait(0.1)
		end
	end)
end

---------------------------------------------------------------------------
-- Batch loop
---------------------------------------------------------------------------
local batchConnection = nil

local function startBatchLoop()
	batchConnection = RunService.Heartbeat:Connect(function(dt)
		if not connected then return end
		if RunService:IsRunning() then return end -- no HTTP while running/playing
		batchAccumulator = batchAccumulator + dt
		if batchAccumulator >= BATCH_INTERVAL then
			batchAccumulator = 0
			flushChanges()
		end
	end)
end

---------------------------------------------------------------------------
-- Tree listeners (auto-detect adds/removes from Studio)
---------------------------------------------------------------------------
local function onDescendantAdded(instance)
	if not connected then return end
	if RunService:IsRunning() then return end
	if pausedInstances[instance] then return end
	if instanceToId[instance] then return end

	local parent = instance.Parent
	if not parent then return end
	local parentId = instanceToId[parent]
	if not parentId then return end

	local id = HttpService:GenerateGUID(false)
	registerInstance(id, instance)
	connectChangeListener(instance)
	pendingAdds[id] = { instance = instance, parentId = parentId }
end

local function onDescendantRemoving(instance)
	if not connected then return end
	local id = instanceToId[instance]
	if not id then return end

	-- Always unregister immediately so idToInstance stays clean. Without this,
	-- instances destroyed by game scripts during play mode leave stale dead
	-- references that cause "Parent property locked" engine warnings when the
	-- server later tries to patch them.
	unregisterInstance(instance)

	if RunService:IsRunning() then return end -- don't push removes during play mode

	if pendingAdds[id] then
		-- Added and removed before flush: cancel the add, no server trip
		pendingAdds[id] = nil
	else
		table.insert(pendingRemoves, id)
	end
end

local function attachTreeListeners()
	for _, serviceName in ipairs(WATCHED_SERVICES) do
		local ok, service = pcall(game.GetService, game, serviceName)
		if ok and service and not treeConnections[service] then
			treeConnections[service] = {
				added = service.DescendantAdded:Connect(onDescendantAdded),
				removing = service.DescendantRemoving:Connect(onDescendantRemoving),
			}
		end
	end
end

local function detachTreeListeners()
	for _, conns in pairs(treeConnections) do
		if conns.added then conns.added:Disconnect() end
		if conns.removing then conns.removing:Disconnect() end
	end
	treeConnections = {}
end

---------------------------------------------------------------------------
-- Selection tracking
---------------------------------------------------------------------------
local Selection = game:GetService("Selection")
local selectionConnection = nil

local function getInstancePath(instance)
	local parts = {}
	local current = instance
	while current and current ~= game do
		table.insert(parts, 1, current.Name)
		current = current.Parent
	end
	return table.concat(parts, ".")
end

local function pushSelection()
	if not connected or not projectToken then return end
	local selected = Selection:Get()
	local selectionData = {}
	for _, inst in ipairs(selected) do
		table.insert(selectionData, {
			id = instanceToId[inst] or "",
			name = inst.Name,
			className = inst.ClassName,
			path = getInstancePath(inst),
		})
	end
	pcall(function()
		HttpService:RequestAsync({
			Url = serverUrl .. "/api/code/sync/selection",
			Method = "POST",
			Headers = withPlaceHeaders({
				["Content-Type"] = "application/json",
				Authorization = "Bearer " .. (projectToken or ""),
			}),
			Body = HttpService:JSONEncode({ selection = selectionData }),
		})
	end)
end

local function attachSelectionListener()
	if selectionConnection then selectionConnection:Disconnect() end
	selectionConnection = Selection.SelectionChanged:Connect(function()
		task.delay(0.15, pushSelection)
	end)
	task.delay(0.25, pushSelection)
end

local function detachSelectionListener()
	if selectionConnection then
		selectionConnection:Disconnect()
		selectionConnection = nil
	end
end

---------------------------------------------------------------------------
-- Connect / Disconnect
---------------------------------------------------------------------------
-- HttpService requests are blocked unless the place has "Allow HTTP Requests" on
-- (Game Settings → Security). Without it, NOTHING syncs — so detect it up front
-- and tell the user exactly what to flip, instead of a vague "can't connect".
local function httpRequestsDisabled()
	local ok, enabled = pcall(function() return HttpService.HttpEnabled end)
	return ok and enabled == false -- only treat as disabled when we can read a definite false
end

local function looksLikeHttpDisabled(err)
	local m = string.lower(tostring(err or ""))
	return string.find(m, "not enabled", 1, true) ~= nil
		or (string.find(m, "http", 1, true) ~= nil and string.find(m, "enable", 1, true) ~= nil)
end

local function showHttpDisabled()
	statusText.Text = "HTTP is OFF"
	statusText.TextColor3 = Color3.fromRGB(255, 80, 80)
	statusDot.BackgroundColor3 = Color3.fromRGB(255, 80, 80)
	loginStatus.Text = "Enable Game Settings → Security → Allow HTTP Requests, then reconnect"
	loginStatus.TextColor3 = Color3.fromRGB(255, 170, 80)
	warn("[Artly Sync] HTTP requests are disabled — enable 'Allow HTTP Requests' in Game Settings → Security.")
end

finishConnect = function()
	statusText.Text = "Connecting..."
	statusText.TextColor3 = Color3.fromRGB(255, 200, 50)
	statusDot.BackgroundColor3 = Color3.fromRGB(255, 200, 50)

	-- Fail fast with a clear, actionable message if HTTP is off.
	if httpRequestsDisabled() then
		showHttpDisabled()
		return
	end

	local info, err = httpGet("/info")
	if not info then
		if looksLikeHttpDisabled(err) or httpRequestsDisabled() then
			showHttpDisabled()
			return
		end
		statusText.Text = "Failed to connect"
		statusText.TextColor3 = Color3.fromRGB(255, 80, 80)
		statusDot.BackgroundColor3 = Color3.fromRGB(255, 80, 80)
		loginStatus.Text = "Cannot reach server"
		loginStatus.TextColor3 = Color3.fromRGB(255, 100, 100)
		warn("[Artly Sync] Cannot reach server: " .. tostring(err))
		return
	end

	projectName = info.projectName
	sessionId = info.sessionId
	rootInstanceId = info.rootInstanceId
	scriptsOnly = info.scriptsOnly == true
	connected = true

	local ok = initialSync()
	if not ok then
		connected = false
		statusText.Text = "Sync failed"
		statusText.TextColor3 = Color3.fromRGB(255, 80, 80)
		statusDot.BackgroundColor3 = Color3.fromRGB(255, 80, 80)
		return
	end

	-- Start polling + listeners FIRST so they're never blocked by the upload, then
	-- push the user's pre-existing game up in the BACKGROUND. On a big game the
	-- upload streams over many chunks (and pauses while the game is running, since
	-- HTTP is blocked then) — backgrounding keeps the connection live and lets the
	-- upload resume + finish on its own once you're back in Edit mode.
	startPolling()
	startBatchLoop()
	attachTreeListeners()
	attachSelectionListener()
	task.spawn(uploadExistingTree)

	syncCount = 0
	updateStatusUI()
	connectButton:SetActive(true)
	task.spawn(refreshUsage) -- populate the usage bars right away
	print("[Artly Sync] Connected to " .. (selectedProjectName or projectName))
end

-- ── Local desktop-app discovery ──────────────────────────────────────────────
-- Probe one loopback port for the Artly desktop app's sync server. Returns the
-- /info table only if it positively identifies as the app (never some other
-- local service). Connection-refused (nothing listening) just returns nil.
local function probeLocalInfo(port)
	local ok, result = pcall(function()
		return HttpService:RequestAsync({
			Url = LOCAL_HOST .. tostring(port) .. "/api/code/sync/info",
			Method = "GET",
			Headers = { Accept = "application/json" },
		})
	end)
	if not ok or type(result) ~= "table" or result.StatusCode ~= 200 then return nil end
	local decoded
	local decodeOk = pcall(function() decoded = HttpService:JSONDecode(result.Body) end)
	if not decodeOk or type(decoded) ~= "table" or decoded.app ~= LOCAL_APP_ID then return nil end
	return decoded
end

-- Scan the loopback port window for the desktop app; if found, connect with no
-- code/URL (the localhost server ignores auth). Returns whether we connected.
tryLocalConnect = function()
	if connected or connecting then return false end
	connecting = true

	local foundPort
	for i = 0, LOCAL_PORT_COUNT - 1 do
		if probeLocalInfo(LOCAL_BASE_PORT + i) then
			foundPort = LOCAL_BASE_PORT + i
			break
		end
	end
	if not foundPort then
		connecting = false
		return false
	end

	-- Found it. Point the existing sync machinery at the local server and run the
	-- normal handshake. projectToken is a non-empty sentinel so the token-guarded
	-- calls (selection/usage) still fire; the local server ignores its value.
	serverUrl = LOCAL_HOST .. tostring(foundPort)
	localMode = true
	projectToken = "local"
	local connectOk = pcall(finishConnect)
	connecting = false
	if not connectOk then return false end
	return connected
end

-- Background loop: while disconnected and local auto is enabled, keep probing so
-- the plugin links the moment the desktop app comes up (and re-links if it
-- restarts on another port). HTTP-disabled is surfaced once, not spammed.
startLocalAutoConnect = function()
	if localAutoLoopRunning then return end
	localAutoLoopRunning = true
	task.spawn(function()
		local warnedHttp = false
		while localAutoLoopRunning do
			if localAutoEnabled and not connected and not connecting then
				if RunService:IsRunning() then
					-- HTTP is blocked during a playtest; wait it out, don't probe.
				elseif httpRequestsDisabled() then
					if not warnedHttp then showHttpDisabled(); warnedHttp = true end
				else
					warnedHttp = false
					setSearchingStatus()
					tryLocalConnect()
				end
			end
			task.wait(connected and 5 or 3)
		end
	end)
end

local function login()
	if connected or connecting then return end
	stopAutoPair() -- manual connect takes over from the auto-pair loop

	local url = urlInput.Text
	local token = tokenInput.Text

	-- Strip a trailing slash so "<url>/api/code/sync" stays well-formed.
	url = (url:gsub("/+$", ""))

	if url == "" or token == "" then
		loginStatus.Text = "Server URL and token required"
		loginStatus.TextColor3 = Color3.fromRGB(255, 100, 100)
		return
	end

	-- Explicit manual connect → this is the remote path; pause local auto-discovery
	-- so the two don't race for the connection.
	localMode = false
	localAutoEnabled = false
	connecting = true

	serverUrl = url
	savedToken = token
	projectToken = token
	plugin:SetSetting("ArtlyServerUrl", url)
	plugin:SetSetting("ArtlyToken", token)

	loginStatus.Text = ""
	setConnecting(true)

	task.spawn(function()
		-- The token IS the project credential; /info validates it and returns the
		-- session. finishConnect surfaces any failure in loginStatus.
		pcall(finishConnect)
		if not connected then
			projectToken = nil
			loginStatus.Text = "Connection failed — check the URL and token"
			loginStatus.TextColor3 = Color3.fromRGB(255, 100, 100)
		end
		connecting = false
		setConnecting(false)
	end)
end

disconnect = function()
	stopAutoPair()
	-- Notify server before cleaning up
	if projectToken then
		pcall(function()
			HttpService:RequestAsync({
				Url = serverUrl .. "/api/code/sync/disconnect",
				Method = "POST",
				-- Include the place headers so the server tears down the SAME
				-- per-place session (not the token's default project).
				Headers = withPlaceHeaders({
					["Content-Type"] = "application/json",
					Authorization = "Bearer " .. (projectToken or ""),
				}),
				Body = HttpService:JSONEncode({}),
			})
		end)
	end

	connected = false
	uploading = false
	projectToken = nil

	if batchConnection then
		batchConnection:Disconnect()
		batchConnection = nil
	end

	detachTreeListeners()
	detachSelectionListener()
	for _, conns in pairs(changeConnections) do
		for _, c in ipairs(conns) do pcall(function() c:Disconnect() end) end
	end
	changeConnections = {}
	idToInstance = {}
	instanceToId = {}
	pausedInstances = {}
	pendingChanges = {}
	pendingAdds = {}
	pendingRemoves = {}
	sessionId = nil
	cursor = 0
	syncCount = 0
	lastSyncTime = 0
	instanceCount = 0

	connectButton:SetActive(false)
	updateStatusUI()
	print("[Artly Sync] Disconnected")
end

-- Auto-heal: re-handshake with the SAME token after the server session changed
-- or contact dropped (server restart, workspace reset, brief outage). KEEPS
-- projectToken/serverUrl (unlike disconnect, which clears them) and re-runs the
-- full handshake — so the live game is re-uploaded with NO manual reconnect.
softReconnect = function()
	connected = false
	uploading = false
	if batchConnection then
		batchConnection:Disconnect()
		batchConnection = nil
	end
	detachTreeListeners()
	detachSelectionListener()
	for _, conns in pairs(changeConnections) do
		for _, c in ipairs(conns) do pcall(function() c:Disconnect() end) end
	end
	changeConnections = {}
	idToInstance = {}
	instanceToId = {}
	pausedInstances = {}
	pendingChanges = {}
	pendingAdds = {}
	pendingRemoves = {}
	sessionId = nil
	cursor = 0
	syncCount = 0

	statusText.Text = "Reconnecting…"
	statusText.TextColor3 = Color3.fromRGB(255, 200, 50)
	statusDot.BackgroundColor3 = Color3.fromRGB(255, 200, 50)
	setConnecting(true)

	-- Retry up to 8 times (~45 s total). If all attempts fail, give up and
	-- restore the login form so the user can reconnect manually when ready.
	local succeeded = false
	for attempt = 1, 8 do
		if connected then succeeded = true; break end
		task.wait(math.min(attempt * 2, 8))
		if connected then succeeded = true; break end
		if localMode then
			-- Re-probe the loopback window (the app may have restarted on another port).
			pcall(tryLocalConnect)
		else
			if not projectToken or projectToken == "" then break end
			pcall(finishConnect)
		end
		if connected then succeeded = true; break end
	end

	if succeeded then
		setConnecting(false)
	elseif localMode then
		-- Don't fall back to "paste a code" in local mode — just resume searching;
		-- the background auto-connect loop keeps probing until the app returns.
		connected = false
		setConnecting(false)
		updateStatusUI()
		setSearchingStatus()
	else
		connected = false
		projectToken = nil
		setConnecting(false)
		updateStatusUI()
		loginStatus.Text = "Lost connection — paste a new code to reconnect"
		loginStatus.TextColor3 = Color3.fromRGB(255, 100, 100)
	end
end

---------------------------------------------------------------------------
-- Connect entry
---------------------------------------------------------------------------
-- Local mode (primary): the plugin probes loopback for the Artly desktop app and
-- links automatically — no code, no URL. The only host it ever contacts is
-- 127.0.0.1, or (remote fallback) whatever the developer types under "Connect to
-- a server manually". It never beacons or sends the Roblox user id unprompted.
stopAutoPair = function()
	autoPairing = false
end

-- Show the disconnected/searching panel (the manual form stays hidden behind its
-- toggle). Kept under the old name so existing call sites stay simple.
startAutoPair = function()
	autoPairing = false
	manualFrame.Visible = false
	setAutoPairStatus("Artly Studio Sync", nil, nil)
	setSearchingStatus()
end

-- On load we don't paste anything or contact a remote server. We start the local
-- auto-connect loop: the moment the Artly desktop app is open on this machine the
-- plugin links automatically — no code, no URL. The manual/remote form stays
-- tucked behind the "Connect to a server manually" toggle for web users.
local function showInitialState()
	if serverUrl == nil or serverUrl == "" then
		serverUrl = DEFAULT_SERVER_URL
	end
	manualFrame.Visible = false
	setAutoPairStatus("Artly Studio Sync", nil, nil)
	setSearchingStatus()
	localAutoEnabled = true
	startLocalAutoConnect()
end

---------------------------------------------------------------------------
-- Wire up buttons
---------------------------------------------------------------------------
connectButton.Click:Connect(function()
	statusWidget.Enabled = not statusWidget.Enabled
	-- Reopening the panel while disconnected resumes local auto-discovery and kicks
	-- an immediate probe (handy right after an explicit Disconnect).
	if statusWidget.Enabled and not connected and not connecting then
		localAutoEnabled = true
		setSearchingStatus()
		startLocalAutoConnect()
		task.spawn(tryLocalConnect)
	end
end)

connectBtn.MouseButton1Click:Connect(function()
	login()
end)

cancelBtn.MouseButton1Click:Connect(function()
	-- Abort any in-progress connect or softReconnect loop.
	connected  = false
	connecting = false
	projectToken = nil
	setConnecting(false)
	loginStatus.Text = "Cancelled"
	loginStatus.TextColor3 = TEXT_DIM
	updateStatusUI()
end)

disconnectBtn.MouseButton1Click:Connect(function()
	-- Explicit Disconnect: tear down AND stop auto-reconnect so it stays down.
	-- Reopen the panel from the toolbar to start linking again.
	localAutoEnabled = false
	localMode = false
	disconnect()
	manualFrame.Visible = false
	setAutoPairStatus("Artly Studio Sync", nil, nil)
	autoPairHint.Text = "Disconnected. Reopen this panel from the toolbar to reconnect."
end)

---------------------------------------------------------------------------
-- Cleanup
---------------------------------------------------------------------------
plugin.Unloading:Connect(function()
	disconnect()
end)

-- Initial state — nothing connects or uploads until the user clicks Connect.
updateStatusUI()
showInitialState()
print("[Artly Sync] Plugin loaded — auto-linking to the Artly desktop app if it's running.")
