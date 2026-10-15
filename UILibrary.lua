--[[
    UI Library (improved)

    Changes vs. original:
      * Every connection/instance is tracked and cleaned up -> Window:Destroy()
      * Single window-level drag + outside-click handlers (no per-component global listeners)
      * Window drags by the bottom bar only (UIDragDetector made sliders/pickers drag the window)
      * Only one popup (dropdown / colorpicker) open at a time; popups close on drag, tab switch, scroll
      * Touch support in sliders and colorpicker
      * Theme bindings are declarative (Themed) instead of hand-written update functions
      * Working config system (Save / Load / List) + live theme editor in the Configuration tab
      * Keybind: Callback = key pressed, OnChanged = key rebound, Escape clears
      * New: Label, Section, Window:Notify, Window:Destroy, Library:Unload, Numeric textbox
      * Toggle has a real checkmark; Toggle:Colorpicker returns the picker object
      * Fixed: Create() sets Parent last, deprecated TextService removed, duplicate-flag warnings,
        dropdown returns a copy of its selection, SetValue(val, silent) everywhere
]]

local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local CoreGui = game:GetService("CoreGui")
local TweenService = game:GetService("TweenService")
local HttpService = game:GetService("HttpService")

local LocalPlayer = Players.LocalPlayer

local Theme = {
	Body = Color3.fromRGB(20, 20, 26),
	Sidebar = Color3.fromRGB(26, 26, 34),
	Main = Color3.fromRGB(30, 30, 40),
	Search = Color3.fromRGB(35, 35, 45),
	TextPrimary = Color3.fromRGB(240, 240, 245),
	TextSecondary = Color3.fromRGB(130, 130, 145),
	Accent = Color3.fromRGB(225, 225, 245),
	Border = Color3.fromRGB(45, 45, 58),
	Font = Enum.Font.GothamMedium,
}

local Icons = {
	Placeholder = "rbxassetid://11419709766",
	Save = "rbxassetid://11419703493",
	Search = "rbxassetid://11293977875",
	Keyboard = "rbxassetid://12974370712",
	ChevronDown = "rbxassetid://11421095840",
	Pipette = "rbxassetid://11419718822",
	Checkmark = "rbxassetid://10709790644",
}

local TweenFast = TweenInfo.new(0.15, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local TweenSmooth = TweenInfo.new(0.25, Enum.EasingStyle.Quart, Enum.EasingDirection.Out)
local TweenDrag = TweenInfo.new(0.08, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local DarkIcon = Color3.fromRGB(17, 17, 17)

---------------------------------------------------------------------------
-- Utilities
---------------------------------------------------------------------------

local function Create(Class, Props)
	local Inst = Instance.new(Class)
	local Parent = Props.Parent
	for Key, Value in Props do
		if Key ~= "Parent" then Inst[Key] = Value end
	end
	if Parent then Inst.Parent = Parent end
	return Inst
end

local function Corner(Parent, Radius)
	return Create("UICorner", {CornerRadius = UDim.new(0, Radius), Parent = Parent})
end

local function Tween(Inst, Info, Props)
	local Tw = TweenService:Create(Inst, Info, Props)
	Tw:Play()
	return Tw
end

-- Tween, or apply instantly
local function Set(Inst, Props, Instant, Info)
	if Instant then
		for Key, Value in Props do Inst[Key] = Value end
	else
		Tween(Inst, Info or TweenFast, Props)
	end
end

local function IsPress(Input)
	return Input.UserInputType == Enum.UserInputType.MouseButton1 or Input.UserInputType == Enum.UserInputType.Touch
end

local function IsMove(Input)
	return Input.UserInputType == Enum.UserInputType.MouseMovement or Input.UserInputType == Enum.UserInputType.Touch
end

local function Inside(Gui, Pos)
	local A, S = Gui.AbsolutePosition, Gui.AbsoluteSize
	return Pos.X >= A.X and Pos.X <= A.X + S.X and Pos.Y >= A.Y and Pos.Y <= A.Y + S.Y
end

local function FormatKeyName(Key)
	if not Key then return "None" end
	local Name = Key.Name
	if Name == "MouseButton1" then return "MB1" end
	if Name == "MouseButton2" then return "MB2" end
	if Name == "MouseButton3" then return "MB3" end
	return Name
end

local function Noop() end

-- Connection / instance bookkeeping
local Maid = {}
Maid.__index = Maid
function Maid.new() return setmetatable({Tasks = {}}, Maid) end
function Maid:Give(Task) table.insert(self.Tasks, Task); return Task end
function Maid:Clean()
	for _, Task in self.Tasks do
		local Kind = typeof(Task)
		if Kind == "RBXScriptConnection" then Task:Disconnect()
		elseif Kind == "Instance" then Task:Destroy()
		elseif Kind == "function" then pcall(Task) end
	end
	table.clear(self.Tasks)
end

-- Theme hooks (functions re-run when the theme changes)
local ThemeHooks = {}
local function AddThemeHook(Fn)
	table.insert(ThemeHooks, Fn)
	return function()
		local I = table.find(ThemeHooks, Fn)
		if I then table.remove(ThemeHooks, I) end
	end
end

local Library = {
	ToggleKey = nil,
	Flags = {},
	Windows = {},
	ConfigFolder = "UILibrary",
}

function Library:SetWindowKeybind(KeyEnum) self.ToggleKey = KeyEnum end
function Library:GetTheme() return Theme end

function Library:SetTheme(NewTheme)
	for Key, Value in NewTheme do
		if Theme[Key] ~= nil then Theme[Key] = Value end
	end
	for _, Fn in table.clone(ThemeHooks) do pcall(Fn) end
end

---------------------------------------------------------------------------
-- Config (needs an executor/environment with file functions; otherwise returns false)
---------------------------------------------------------------------------

local function HasFiles()
	return typeof(writefile) == "function" and typeof(readfile) == "function"
		and typeof(isfile) == "function" and typeof(makefolder) == "function" and typeof(isfolder) == "function"
end

function Library:Serialize()
	local Out = {}
	for Flag, Obj in self.Flags do
		if string.sub(Flag, 1, 1) == "_" then continue end
		local Kind = Obj:GetComponentType()
		if Kind == "Button" then continue end
		local Value = Obj:GetValue()
		if Kind == "Colorpicker" then
			Out[Flag] = {Color = Value:ToHex(), Alpha = Obj:GetTransparency()}
		elseif Kind == "Keybind" then
			Out[Flag] = Value and {Type = tostring(Value.EnumType), Name = Value.Name} or false
		else
			Out[Flag] = Value
		end
	end
	return HttpService:JSONEncode(Out)
end

function Library:Deserialize(Json)
	local Ok, Data = pcall(function() return HttpService:JSONDecode(Json) end)
	if not Ok or type(Data) ~= "table" then return false end
	for Flag, Value in Data do
		local Obj = self.Flags[Flag]
		if not Obj then continue end
		pcall(function()
			local Kind = Obj:GetComponentType()
			if Kind == "Colorpicker" then
				Obj:SetValue(Color3.fromHex(Value.Color))
				Obj:SetTransparency(Value.Alpha)
			elseif Kind == "Keybind" then
				Obj:SetValue(Value and Enum[Value.Type][Value.Name] or nil)
			elseif Kind ~= "Button" then
				Obj:SetValue(Value)
			end
		end)
	end
	return true
end

function Library:SaveConfig(Name)
	if not HasFiles() then return false, "File API not available" end
	if not isfolder(self.ConfigFolder) then makefolder(self.ConfigFolder) end
	Name = string.gsub(Name or "default", "[^%w_%- ]", "")
	if Name == "" then return false, "Invalid name" end
	writefile(`{self.ConfigFolder}/{Name}.json`, self:Serialize())
	return true
end

function Library:LoadConfig(Name)
	if not HasFiles() then return false, "File API not available" end
	local Path = `{self.ConfigFolder}/{Name}.json`
	if not isfile(Path) then return false, "Config not found" end
	return self:Deserialize(readfile(Path))
end

function Library:ListConfigs()
	local Out = {}
	if HasFiles() and typeof(listfiles) == "function" and isfolder(self.ConfigFolder) then
		for _, Path in listfiles(self.ConfigFolder) do
			local Name = string.match(Path, "([^/\\]+)%.json$")
			if Name then table.insert(Out, Name) end
		end
	end
	return Out
end

function Library:Unload()
	for _, Win in table.clone(self.Windows) do Win:Destroy() end
end

---------------------------------------------------------------------------
-- Window
---------------------------------------------------------------------------

function Library:Window(Options)
	Options = Options or {}
	local SubTitle = Options.SubTitle or "v1.0.0"
	local Janitor = Maid.new()
	local FlagNames = {}

	if Options.ToggleKey then Library.ToggleKey = Options.ToggleKey end

	local ScreenGui = Create("ScreenGui", {
		Name = Options.Name or "UILibrary",
		ResetOnSpawn = false,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
		DisplayOrder = 100,
	})
	if not pcall(function() ScreenGui.Parent = CoreGui end) then
		ScreenGui.Parent = LocalPlayer:WaitForChild("PlayerGui")
	end
	Janitor:Give(ScreenGui)

	-- Bind instance properties to theme keys: Themed(label, {TextColor3 = "TextPrimary"})
	local function Themed(Inst, Map)
		local function Apply()
			for Prop, Key in Map do Inst[Prop] = Theme[Key] end
		end
		Apply()
		Janitor:Give(AddThemeHook(Apply))
	end
	local function OnTheme(Fn) Janitor:Give(AddThemeHook(Fn)) end

	local function Register(Flag, Obj)
		if Library.Flags[Flag] and not FlagNames[Flag] then
			warn(`[UILibrary] Duplicate flag "{Flag}" - give one of them a unique Flag option`)
		end
		Library.Flags[Flag] = Obj
		FlagNames[Flag] = true
	end

	local Screen = ScreenGui.AbsoluteSize
	local WinW = Screen.X > 0 and math.min(Options.Width or 850, Screen.X - 20) or (Options.Width or 850)
	local WinH = Screen.Y > 0 and math.min(Options.Height or 550, Screen.Y - 20) or (Options.Height or 550)

	local MainFrame = Create("CanvasGroup", {
		Size = UDim2.fromOffset(WinW, WinH),
		Position = UDim2.fromOffset(math.max((Screen.X - WinW) / 2, 0), math.max((Screen.Y - WinH) / 2, 0)),
		BackgroundColor3 = Theme.Body, BorderSizePixel = 0, GroupTransparency = 0, Parent = ScreenGui,
	})
	Corner(MainFrame, 8)
	Themed(MainFrame, {BackgroundColor3 = "Body"})

	local BottomBar = Create("Frame", {Size = UDim2.new(1, 0, 0, 64), Position = UDim2.new(0, 0, 1, -64), BackgroundColor3 = Theme.Sidebar, BorderSizePixel = 0, Parent = MainFrame})
	Themed(BottomBar, {BackgroundColor3 = "Sidebar"})

	-- Profile
	local ProfileFrame = Create("Frame", {Size = UDim2.new(0, 200, 1, 0), Position = UDim2.new(0, 20, 0, 0), BackgroundTransparency = 1, Parent = BottomBar})
	local Avatar = Create("ImageLabel", {Size = UDim2.fromOffset(40, 40), Position = UDim2.new(0, 0, 0.5, -20), BackgroundColor3 = Theme.Search, Parent = ProfileFrame})
	Corner(Avatar, 20)
	Themed(Avatar, {BackgroundColor3 = "Search"})
	task.spawn(function()
		local Ok, Thumb = pcall(function()
			return Players:GetUserThumbnailAsync(LocalPlayer.UserId, Enum.ThumbnailType.HeadShot, Enum.ThumbnailSize.Size48x48)
		end)
		if Ok and Avatar.Parent then Avatar.Image = Thumb end
	end)
	local ProfileName = Create("TextLabel", {Size = UDim2.new(1, -52, 0, 20), Position = UDim2.new(0, 52, 0.5, -18), BackgroundTransparency = 1, Text = LocalPlayer.DisplayName or "User", TextColor3 = Theme.TextPrimary, Font = Theme.Font, TextSize = 15, TextXAlignment = Enum.TextXAlignment.Left, TextTruncate = Enum.TextTruncate.AtEnd, Parent = ProfileFrame})
	local ProfileSub = Create("TextLabel", {Size = UDim2.new(1, -52, 0, 16), Position = UDim2.new(0, 52, 0.5, 2), BackgroundTransparency = 1, Text = SubTitle, TextColor3 = Theme.TextSecondary, Font = Theme.Font, TextSize = 12, TextXAlignment = Enum.TextXAlignment.Left, Parent = ProfileFrame})
	Themed(ProfileName, {TextColor3 = "TextPrimary", Font = "Font"})
	Themed(ProfileSub, {TextColor3 = "TextSecondary", Font = "Font"})

	-- Tab nav (grows with the number of tabs)
	local TabNav = Create("Frame", {Size = UDim2.new(0, 0, 1, 0), AutomaticSize = Enum.AutomaticSize.X, Position = UDim2.fromScale(0.5, 0), AnchorPoint = Vector2.new(0.5, 0), BackgroundTransparency = 1, Parent = BottomBar})
	Create("UIListLayout", {FillDirection = Enum.FillDirection.Horizontal, VerticalAlignment = Enum.VerticalAlignment.Center, Padding = UDim.new(0, 12), Parent = TabNav})

	-- Actions (save + search)
	local ActionContainer = Create("Frame", {Size = UDim2.new(0, 250, 1, 0), Position = UDim2.new(1, -270, 0, 0), BackgroundTransparency = 1, Parent = BottomBar})
	Create("UIListLayout", {FillDirection = Enum.FillDirection.Horizontal, HorizontalAlignment = Enum.HorizontalAlignment.Right, VerticalAlignment = Enum.VerticalAlignment.Center, SortOrder = Enum.SortOrder.LayoutOrder, Padding = UDim.new(0, 12), Parent = ActionContainer})

	local SaveBtn = Create("TextButton", {Size = UDim2.fromOffset(40, 40), BackgroundColor3 = Theme.Search, Text = "", AutoButtonColor = false, LayoutOrder = 2, Parent = ActionContainer})
	Corner(SaveBtn, 8)
	local SaveIcon = Create("ImageLabel", {Size = UDim2.fromOffset(20, 20), Position = UDim2.fromScale(0.5, 0.5), AnchorPoint = Vector2.new(0.5, 0.5), BackgroundTransparency = 1, Image = Icons.Save, ImageColor3 = Theme.TextSecondary, Parent = SaveBtn})

	local SearchBar = Create("Frame", {Size = UDim2.fromOffset(160, 40), BackgroundColor3 = Theme.Search, LayoutOrder = 1, Parent = ActionContainer})
	Corner(SearchBar, 8)
	Themed(SearchBar, {BackgroundColor3 = "Search"})
	local SearchIcon = Create("ImageLabel", {Size = UDim2.fromOffset(16, 16), Position = UDim2.new(0, 12, 0.5, -8), BackgroundTransparency = 1, Image = Icons.Search, ImageColor3 = Theme.TextSecondary, Parent = SearchBar})
	Themed(SearchIcon, {ImageColor3 = "TextSecondary"})
	local SearchBox = Create("TextBox", {Size = UDim2.new(1, -40, 1, 0), Position = UDim2.new(0, 36, 0, 0), BackgroundTransparency = 1, Text = "", PlaceholderText = "Search...", ClearTextOnFocus = false, TextColor3 = Theme.TextPrimary, PlaceholderColor3 = Theme.TextSecondary, Font = Theme.Font, TextSize = 13, TextXAlignment = Enum.TextXAlignment.Left, Parent = SearchBar})
	Themed(SearchBox, {TextColor3 = "TextPrimary", PlaceholderColor3 = "TextSecondary", Font = "Font"})

	-- Content
	local ContentArea = Create("Frame", {Size = UDim2.new(1, 0, 1, -64), BackgroundTransparency = 1, Parent = MainFrame})
	local TabContainer = Create("Frame", {Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1, Parent = ContentArea})

	local SearchContent = Create("ScrollingFrame", {Size = UDim2.new(1, -40, 1, -40), Position = UDim2.fromOffset(20, 20), BackgroundTransparency = 1, BorderSizePixel = 0, ScrollBarThickness = 4, ScrollBarImageColor3 = Theme.Accent, CanvasSize = UDim2.new(), AutomaticCanvasSize = Enum.AutomaticSize.Y, Visible = false, Parent = TabContainer})
	Themed(SearchContent, {ScrollBarImageColor3 = "Accent"})
	Create("UIListLayout", {SortOrder = Enum.SortOrder.LayoutOrder, Parent = SearchContent})

	local NoResults = Create("TextLabel", {Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1, Text = "No results found", TextColor3 = Theme.TextSecondary, Font = Theme.Font, TextSize = 16, Visible = false, Parent = TabContainer})
	Themed(NoResults, {TextColor3 = "TextSecondary", Font = "Font"})

	local WindowObj = {
		ScreenGui = ScreenGui,
		Tabs = {},
		AllRows = {},
		CurrentTab = nil,
		Watermarks = {},
		ActivePopup = nil,
		Binding = false,
		Visible = true,
	}

	-----------------------------------------------------------------------
	-- Popups (only one open at a time)
	-----------------------------------------------------------------------
	function WindowObj:OpenPopup(Popup)
		if self.ActivePopup and self.ActivePopup ~= Popup then self.ActivePopup.Close() end
		self.ActivePopup = Popup
	end
	function WindowObj:ClosePopup()
		local P = self.ActivePopup
		self.ActivePopup = nil
		if P then P.Close() end
	end

	Janitor:Give(UserInputService.InputBegan:Connect(function(Input)
		local P = WindowObj.ActivePopup
		if not P or not IsPress(Input) then return end
		for _, Frame in P.Frames do
			if Inside(Frame, Input.Position) then return end
		end
		WindowObj:ClosePopup()
	end))

	-----------------------------------------------------------------------
	-- Single shared drag handler (window drag, sliders, color picker)
	-----------------------------------------------------------------------
	local ActiveDrag = nil
	local function BeginDrag(Fn) ActiveDrag = Fn end
	Janitor:Give(UserInputService.InputChanged:Connect(function(Input)
		if ActiveDrag and IsMove(Input) then ActiveDrag(Input) end
	end))
	Janitor:Give(UserInputService.InputEnded:Connect(function(Input)
		if ActiveDrag and IsPress(Input) then ActiveDrag = nil end
	end))

	Janitor:Give(BottomBar.InputBegan:Connect(function(Input)
		if not IsPress(Input) then return end
		WindowObj:ClosePopup()
		local StartMouse = Vector2.new(Input.Position.X, Input.Position.Y)
		local StartX, StartY = MainFrame.Position.X.Offset, MainFrame.Position.Y.Offset
		BeginDrag(function(Move)
			local Bounds, Size = ScreenGui.AbsoluteSize, MainFrame.AbsoluteSize
			local X = math.clamp(StartX + Move.Position.X - StartMouse.X, 0, math.max(Bounds.X - Size.X, 0))
			local Y = math.clamp(StartY + Move.Position.Y - StartMouse.Y, 0, math.max(Bounds.Y - Size.Y, 0))
			MainFrame.Position = UDim2.fromOffset(X, Y)
		end)
	end))

	-----------------------------------------------------------------------
	-- Visibility
	-----------------------------------------------------------------------
	function WindowObj:SetVisible(State)
		if self.Visible == State then return end
		self.Visible = State
		if State then
			MainFrame.Visible = true
			Tween(MainFrame, TweenSmooth, {GroupTransparency = 0})
		else
			self:ClosePopup()
			local Tw = Tween(MainFrame, TweenSmooth, {GroupTransparency = 1})
			Tw.Completed:Once(function()
				if not self.Visible then MainFrame.Visible = false end
			end)
		end
		for _, Wm in self.Watermarks do Wm:UpdatePosition() end
	end
	function WindowObj:ToggleVisibility() self:SetVisible(not self.Visible) end

	Janitor:Give(UserInputService.InputBegan:Connect(function(Input, Processed)
		if Processed or WindowObj.Binding then return end
		if Library.ToggleKey and Input.KeyCode == Library.ToggleKey then WindowObj:ToggleVisibility() end
	end))

	-----------------------------------------------------------------------
	-- Watermark
	-----------------------------------------------------------------------
	local function WatermarkReposition()
		for _, Wm in WindowObj.Watermarks do Wm:UpdatePosition() end
	end
	Janitor:Give(MainFrame:GetPropertyChangedSignal("AbsolutePosition"):Connect(WatermarkReposition))
	Janitor:Give(MainFrame:GetPropertyChangedSignal("AbsoluteSize"):Connect(WatermarkReposition))

	function WindowObj:Watermark(InitialText)
		local Frame = Create("Frame", {BackgroundColor3 = Theme.Sidebar, Size = UDim2.fromOffset(0, 26), AutomaticSize = Enum.AutomaticSize.X, ClipsDescendants = true, ZIndex = 5000, Parent = ScreenGui})
		Corner(Frame, 6)
		Create("UIPadding", {PaddingLeft = UDim.new(0, 12), PaddingRight = UDim.new(0, 12), Parent = Frame})
		local Stroke = Create("UIStroke", {Color = Theme.Border, Thickness = 1, Parent = Frame})
		local TopAccent = Create("Frame", {BackgroundColor3 = Theme.Accent, BorderSizePixel = 0, Size = UDim2.new(1, 0, 0, 1), ZIndex = 5001, Parent = Frame})
		Create("UIGradient", {Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 1), NumberSequenceKeypoint.new(0.15, 0),
			NumberSequenceKeypoint.new(0.85, 0), NumberSequenceKeypoint.new(1, 1),
		}), Parent = TopAccent})
		local Text = Create("TextLabel", {BackgroundTransparency = 1, Size = UDim2.new(0, 0, 1, 0), AutomaticSize = Enum.AutomaticSize.X, Text = InitialText or "", RichText = true, TextColor3 = Theme.TextPrimary, Font = Enum.Font.Code, TextSize = 13, ZIndex = 5001, Parent = Frame})
		Themed(Frame, {BackgroundColor3 = "Sidebar"})
		Themed(Stroke, {Color = "Border"})
		Themed(TopAccent, {BackgroundColor3 = "Accent"})
		Themed(Text, {TextColor3 = "TextPrimary"})

		local Wm = {Frame = Frame, Position = "TopLeft"}

		function Wm:SetText(NewText) Text.Text = NewText end
		function Wm:SetVisible(State) Frame.Visible = State end
		function Wm:UpdatePosition()
			local Right = string.find(self.Position, "Right") ~= nil
			local Bottom = string.find(self.Position, "Bottom") ~= nil
			if WindowObj.Visible then
				local P, S, W = MainFrame.AbsolutePosition, MainFrame.AbsoluteSize, Frame.AbsoluteSize
				local X = P.X + (Right and S.X or 0)
				local Y = Bottom and (P.Y + S.Y + 8) or (P.Y - W.Y - 8)
				Frame.AnchorPoint = Vector2.new(Right and 1 or 0, 0)
				Frame.Position = UDim2.fromOffset(X, Y)
			else
				Frame.AnchorPoint = Vector2.new(Right and 1 or 0, Bottom and 1 or 0)
				Frame.Position = UDim2.new(Right and 1 or 0, Right and -15 or 15, Bottom and 1 or 0, Bottom and -15 or 15)
			end
		end
		function Wm:SetPosition(Pos) self.Position = Pos; self:UpdatePosition() end

		Janitor:Give(Frame:GetPropertyChangedSignal("AbsoluteSize"):Connect(function() Wm:UpdatePosition() end))
		table.insert(WindowObj.Watermarks, Wm)
		task.defer(function() Wm:UpdatePosition() end)
		return Wm
	end

	-----------------------------------------------------------------------
	-- Notifications
	-----------------------------------------------------------------------
	local NotifyHolder = Create("Frame", {Size = UDim2.new(0, 280, 1, -20), Position = UDim2.new(1, -290, 0, 10), BackgroundTransparency = 1, ZIndex = 6000, Parent = ScreenGui})
	Create("UIListLayout", {VerticalAlignment = Enum.VerticalAlignment.Bottom, HorizontalAlignment = Enum.HorizontalAlignment.Right, SortOrder = Enum.SortOrder.LayoutOrder, Padding = UDim.new(0, 6), Parent = NotifyHolder})

	function WindowObj:Notify(Opts)
		Opts = type(Opts) == "string" and {Content = Opts} or Opts
		local Card = Create("CanvasGroup", {Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, BackgroundColor3 = Theme.Main, GroupTransparency = 1, ZIndex = 6001, Parent = NotifyHolder})
		Corner(Card, 6)
		Create("UIStroke", {Color = Theme.Border, Thickness = 1, Parent = Card})
		Create("UIPadding", {PaddingLeft = UDim.new(0, 12), PaddingRight = UDim.new(0, 12), PaddingTop = UDim.new(0, 10), PaddingBottom = UDim.new(0, 10), Parent = Card})
		Create("UIListLayout", {SortOrder = Enum.SortOrder.LayoutOrder, Padding = UDim.new(0, 3), Parent = Card})
		if Opts.Title then
			Create("TextLabel", {Size = UDim2.new(1, 0, 0, 16), AutomaticSize = Enum.AutomaticSize.Y, BackgroundTransparency = 1, Text = Opts.Title, TextColor3 = Theme.Accent, Font = Theme.Font, TextSize = 13, TextWrapped = true, TextXAlignment = Enum.TextXAlignment.Left, LayoutOrder = 1, Parent = Card})
		end
		if Opts.Content then
			Create("TextLabel", {Size = UDim2.new(1, 0, 0, 14), AutomaticSize = Enum.AutomaticSize.Y, BackgroundTransparency = 1, Text = Opts.Content, TextColor3 = Theme.TextPrimary, Font = Theme.Font, TextSize = 12, TextWrapped = true, TextXAlignment = Enum.TextXAlignment.Left, LayoutOrder = 2, Parent = Card})
		end
		Tween(Card, TweenSmooth, {GroupTransparency = 0})
		task.delay(Opts.Duration or 4, function()
			if not Card.Parent then return end
			local Tw = Tween(Card, TweenSmooth, {GroupTransparency = 1})
			Tw.Completed:Once(function() Card:Destroy() end)
		end)
	end

	-----------------------------------------------------------------------
	-- Search
	-----------------------------------------------------------------------
	Janitor:Give(SearchBox:GetPropertyChangedSignal("Text"):Connect(function()
		local Query = string.lower(SearchBox.Text)
		for _, Comp in WindowObj.AllRows do Comp.Row.Parent = Comp.OriginalParent end

		if Query == "" then
			SearchContent.Visible = false
			NoResults.Visible = false
			if WindowObj.CurrentTab then WindowObj.CurrentTab.Canvas.Visible = true end
			return
		end

		if WindowObj.CurrentTab then WindowObj.CurrentTab.Canvas.Visible = false end
		SearchContent.Visible = true
		local Found = 0
		for _, Comp in WindowObj.AllRows do
			local Haystack = string.lower(Comp.Title .. " " .. (Comp.Keywords or ""))
			if string.find(Haystack, Query, 1, true) then
				Comp.Row.Parent = SearchContent
				Found += 1
			end
		end
		NoResults.Visible = Found == 0
	end))

	-----------------------------------------------------------------------
	-- Tabs
	-----------------------------------------------------------------------
	function WindowObj:Tab(Opts)
		local TabTitle = Opts.Title or "Tab"
		local TabIcon = Opts.Icon or Icons.Placeholder
		local IsConfig = Opts.IsConfig or false

		local TabBtn = Create("TextButton", {Name = TabTitle, Size = UDim2.fromOffset(40, 40), BackgroundTransparency = 1, BackgroundColor3 = Theme.Search, Text = "", AutoButtonColor = false})
		if not IsConfig then TabBtn.Parent = TabNav end
		Janitor:Give(TabBtn)
		Corner(TabBtn, 8)
		local TabIconImage = Create("ImageLabel", {Size = UDim2.fromOffset(20, 20), Position = UDim2.fromScale(0.5, 0.5), AnchorPoint = Vector2.new(0.5, 0.5), BackgroundTransparency = 1, Image = TabIcon, ImageColor3 = Theme.TextSecondary, Parent = TabBtn})

		local TabCanvas = Create("CanvasGroup", {Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1, GroupTransparency = 1, Visible = false, Parent = TabContainer})
		local TabContent = Create("ScrollingFrame", {Size = UDim2.new(1, -40, 1, -40), Position = UDim2.fromOffset(20, 20), BackgroundTransparency = 1, BorderSizePixel = 0, ScrollBarThickness = 4, ScrollBarImageColor3 = Theme.Accent, CanvasSize = UDim2.new(), AutomaticCanvasSize = Enum.AutomaticSize.Y, Parent = TabCanvas})
		Themed(TabContent, {ScrollBarImageColor3 = "Accent"})
		Create("UIListLayout", {SortOrder = Enum.SortOrder.LayoutOrder, Padding = UDim.new(0, 4), Parent = TabContent})
		-- popups are positioned in screen space, so close them when the page scrolls
		Janitor:Give(TabContent:GetPropertyChangedSignal("CanvasPosition"):Connect(function() WindowObj:ClosePopup() end))

		local TabObj = {Canvas = TabCanvas, Container = TabContent, TabButton = TabBtn, Title = TabTitle, Icon = TabIcon, IsConfig = IsConfig, LayoutOrder = 0}
		table.insert(WindowObj.Tabs, TabObj)

		function TabObj.SetActive(Active, Instant)
			if IsConfig then
				Set(SaveBtn, {BackgroundColor3 = Active and Theme.Accent or Theme.Search}, Instant)
				Set(SaveIcon, {ImageColor3 = Active and DarkIcon or Theme.TextSecondary}, Instant)
			else
				Set(TabBtn, {BackgroundTransparency = Active and 0 or 1, BackgroundColor3 = Theme.Search}, Instant)
				Set(TabIconImage, {ImageColor3 = Active and Theme.Accent or Theme.TextSecondary}, Instant)
			end
		end
		OnTheme(function() TabObj.SetActive(WindowObj.CurrentTab == TabObj, true) end)

		local function ActivateTab()
			if WindowObj.CurrentTab == TabObj then return end
			if SearchBox.Text ~= "" then SearchBox.Text = "" end
			WindowObj:ClosePopup()

			local Prev = WindowObj.CurrentTab
			if Prev then
				Prev.Canvas.Visible = false
				Prev.SetActive(false)
			end
			TabCanvas.GroupTransparency = Prev and 1 or 0
			TabCanvas.Visible = true
			Tween(TabCanvas, TweenSmooth, {GroupTransparency = 0})
			TabObj.SetActive(true)
			WindowObj.CurrentTab = TabObj
		end
		function TabObj:Activate() ActivateTab() end

		if not IsConfig then
			Janitor:Give(TabBtn.MouseButton1Click:Connect(ActivateTab))
			local Count = 0
			for _, T in WindowObj.Tabs do if not T.IsConfig then Count += 1 end end
			if Count == 1 then ActivateTab() end
		end

		-------------------------------------------------------------------
		-- Row helpers
		-------------------------------------------------------------------
		local function CreateRow(Title, Height, NoSeparator, Keywords)
			TabObj.LayoutOrder += 1
			local Row = Create("Frame", {Size = UDim2.new(1, 0, 0, Height or 40), BackgroundTransparency = 1, LayoutOrder = TabObj.LayoutOrder, Parent = TabContent})
			if not NoSeparator then
				local Sep = Create("Frame", {Size = UDim2.new(1, -16, 0, 1), Position = UDim2.new(0, 8, 1, -1), BackgroundColor3 = Theme.Border, BackgroundTransparency = 0.5, BorderSizePixel = 0, Parent = Row})
				Themed(Sep, {BackgroundColor3 = "Border"})
			end
			table.insert(WindowObj.AllRows, {Row = Row, OriginalParent = TabContent, Title = Title or "", Keywords = Keywords})
			return Row
		end

		local function RowTitle(Row, Title, Reserve)
			local L = Create("TextLabel", {Size = UDim2.new(1, -(Reserve or 200), 1, 0), Position = UDim2.fromOffset(8, 0), BackgroundTransparency = 1, Text = Title, TextColor3 = Theme.TextPrimary, Font = Theme.Font, TextSize = 13, TextXAlignment = Enum.TextXAlignment.Left, TextTruncate = Enum.TextTruncate.AtEnd, Parent = Row})
			Themed(L, {TextColor3 = "TextPrimary", Font = "Font"})
			return L
		end

		local function FlagFor(Opts2, Kind, Title)
			return Opts2.Flag or string.format("%s/%s/%s", TabTitle, Kind, Title)
		end

		-------------------------------------------------------------------
		-- Label / Section
		-------------------------------------------------------------------
		function TabObj:Label(Text)
			local Row = CreateRow(Text, 28, true)
			local L = Create("TextLabel", {Size = UDim2.new(1, -16, 1, 0), Position = UDim2.fromOffset(8, 0), BackgroundTransparency = 1, Text = Text, TextColor3 = Theme.TextSecondary, Font = Theme.Font, TextSize = 12, TextWrapped = true, TextXAlignment = Enum.TextXAlignment.Left, Parent = Row})
			Themed(L, {TextColor3 = "TextSecondary", Font = "Font"})
			local Obj = {Row = Row}
			function Obj:SetText(T) L.Text = T end
			return Obj
		end

		function TabObj:Section(Title)
			local Row = CreateRow("", 30, true)
			Row.Visible = true
			local L = Create("TextLabel", {Size = UDim2.new(1, -16, 1, 0), Position = UDim2.fromOffset(8, 4), BackgroundTransparency = 1, Text = string.upper(Title), TextColor3 = Theme.Accent, Font = Theme.Font, TextSize = 11, TextXAlignment = Enum.TextXAlignment.Left, Parent = Row})
			Themed(L, {TextColor3 = "Accent", Font = "Font"})
			-- sections are not searchable
			WindowObj.AllRows[#WindowObj.AllRows].Title = "\0never-matches"
			return {Row = Row}
		end

		-------------------------------------------------------------------
		-- Color picker (shared by Colorpicker and Toggle:Colorpicker)
		-------------------------------------------------------------------
		local function AttachColorPicker(TargetRow, CompTitle, P, RightOffset)
			P = P or {}
			local Callback = P.Callback or Noop
			local Flag = FlagFor(P, "Colorpicker", CompTitle)
			local Color = P.Default or Color3.new(1, 1, 1)
			local Alpha = (P.Transparency or 100) / 100
			local H, S, V = Color:ToHSV()

			local Holder = Create("Frame", {Size = UDim2.new(0, 250, 1, 0), Position = UDim2.new(1, -RightOffset, 0, 0), AnchorPoint = Vector2.new(1, 0), BackgroundTransparency = 1, ZIndex = 10, Parent = TargetRow})
			Create("UIListLayout", {FillDirection = Enum.FillDirection.Horizontal, HorizontalAlignment = Enum.HorizontalAlignment.Right, VerticalAlignment = Enum.VerticalAlignment.Center, SortOrder = Enum.SortOrder.LayoutOrder, Padding = UDim.new(0, 12), Parent = Holder})

			local CopyBtn = Create("TextButton", {Size = UDim2.fromOffset(16, 16), BackgroundTransparency = 1, Text = "", AutoButtonColor = false, LayoutOrder = 1, ZIndex = 10, Visible = typeof(setclipboard) == "function", Parent = Holder})
			local CopyIcon = Create("ImageLabel", {Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1, Image = Icons.Pipette, ImageColor3 = Theme.TextSecondary, ZIndex = 10, Parent = CopyBtn})
			Themed(CopyIcon, {ImageColor3 = "TextSecondary"})

			local ColorBtn = Create("TextButton", {Size = UDim2.fromOffset(18, 18), BackgroundColor3 = Color, Text = "", AutoButtonColor = false, LayoutOrder = 2, ZIndex = 10, Parent = Holder})
			Corner(ColorBtn, 4)
			local HexBox = Create("TextBox", {Size = UDim2.new(0, 0, 0, 20), AutomaticSize = Enum.AutomaticSize.X, BackgroundTransparency = 1, Text = "", TextColor3 = Theme.TextPrimary, Font = Theme.Font, TextSize = 13, ClearTextOnFocus = false, LayoutOrder = 3, ZIndex = 10, Parent = Holder})
			local AlphaLabel = Create("TextLabel", {Size = UDim2.new(0, 0, 0, 20), AutomaticSize = Enum.AutomaticSize.X, BackgroundTransparency = 1, Text = "", TextColor3 = Theme.TextSecondary, Font = Theme.Font, TextSize = 13, TextXAlignment = Enum.TextXAlignment.Right, LayoutOrder = 4, ZIndex = 10, Parent = Holder})
			Themed(HexBox, {TextColor3 = "TextPrimary", Font = "Font"})
			Themed(AlphaLabel, {TextColor3 = "TextSecondary", Font = "Font"})

			local Picker = Create("Frame", {BackgroundColor3 = Theme.Main, BorderSizePixel = 0, Size = UDim2.fromOffset(220, 0), Visible = false, ClipsDescendants = true, ZIndex = 3000, Parent = ScreenGui})
			Corner(Picker, 6)
			local PickerStroke = Create("UIStroke", {Color = Theme.Border, Thickness = 1, Parent = Picker})
			Create("UIPadding", {PaddingLeft = UDim.new(0, 10), PaddingRight = UDim.new(0, 10), PaddingTop = UDim.new(0, 10), PaddingBottom = UDim.new(0, 10), Parent = Picker})
			Create("UIListLayout", {SortOrder = Enum.SortOrder.LayoutOrder, Padding = UDim.new(0, 5), Parent = Picker})
			Themed(Picker, {BackgroundColor3 = "Main"})
			Themed(PickerStroke, {Color = "Border"})

			local ColorMap = Create("TextButton", {Size = UDim2.new(1, 0, 0, 120), BackgroundColor3 = Color3.fromHSV(H, 1, 1), AutoButtonColor = false, Text = "", LayoutOrder = 1, ZIndex = 3001, Parent = Picker})
			Corner(ColorMap, 4)
			local SatOverlay = Create("Frame", {Size = UDim2.fromScale(1, 1), BackgroundColor3 = Color3.new(1, 1, 1), BorderSizePixel = 0, ZIndex = 3002, Parent = ColorMap})
			Create("UIGradient", {Transparency = NumberSequence.new({NumberSequenceKeypoint.new(0, 0), NumberSequenceKeypoint.new(1, 1)}), Parent = SatOverlay})
			Corner(SatOverlay, 4)
			local ValOverlay = Create("Frame", {Size = UDim2.fromScale(1, 1), BackgroundColor3 = Color3.new(0, 0, 0), BorderSizePixel = 0, ZIndex = 3003, Parent = ColorMap})
			Create("UIGradient", {Rotation = 90, Transparency = NumberSequence.new({NumberSequenceKeypoint.new(0, 1), NumberSequenceKeypoint.new(1, 0)}), Parent = ValOverlay})
			Corner(ValOverlay, 4)
			local Marker = Create("Frame", {Size = UDim2.fromOffset(12, 12), BackgroundTransparency = 1, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(S, 1 - V), ZIndex = 3004, Parent = ColorMap})
			Corner(Marker, 6)
			Create("UIStroke", {Color = Color3.new(1, 1, 1), Thickness = 2, Parent = Marker})

			local function PickerSlider(Name, Order)
				local Frame = Create("Frame", {BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 35), LayoutOrder = Order, ZIndex = 3001, Parent = Picker})
				local TitleLab = Create("TextLabel", {Text = Name, Size = UDim2.new(1, -40, 0, 15), BackgroundTransparency = 1, Font = Theme.Font, TextSize = 12, TextColor3 = Theme.TextSecondary, TextXAlignment = Enum.TextXAlignment.Left, ZIndex = 3001, Parent = Frame})
				local ValLab = Create("TextLabel", {Text = "0", Size = UDim2.new(0, 40, 0, 15), Position = UDim2.new(1, -40, 0, 0), BackgroundTransparency = 1, Font = Theme.Font, TextSize = 12, TextColor3 = Theme.TextPrimary, TextXAlignment = Enum.TextXAlignment.Right, ZIndex = 3001, Parent = Frame})
				local Track = Create("TextButton", {BackgroundColor3 = Theme.Search, BorderSizePixel = 0, Position = UDim2.fromOffset(0, 22), Size = UDim2.new(1, 0, 0, 4), Text = "", AutoButtonColor = false, ZIndex = 3001, Parent = Frame})
				Corner(Track, 2)
				local Fill = Create("Frame", {BorderSizePixel = 0, Size = UDim2.fromScale(0, 1), BackgroundColor3 = Theme.Accent, ZIndex = 3002, Parent = Track})
				Corner(Fill, 2)
				Themed(TitleLab, {TextColor3 = "TextSecondary", Font = "Font"})
				Themed(ValLab, {TextColor3 = "TextPrimary", Font = "Font"})
				Themed(Track, {BackgroundColor3 = "Search"})
				Themed(Fill, {BackgroundColor3 = "Accent"})
				return {Track = Track, Fill = Fill, Label = ValLab}
			end
			local HueSlider = PickerSlider("Hue", 2)
			local AlphaSlider = PickerSlider("Transparency", 3)

			local function Render(Fire)
				Color = Color3.fromHSV(H, S, V)
				ColorBtn.BackgroundColor3 = Color
				HexBox.Text = string.upper(Color:ToHex())
				AlphaLabel.Text = math.floor(Alpha * 100) .. "%"
				ColorMap.BackgroundColor3 = Color3.fromHSV(H, 1, 1)
				Marker.Position = UDim2.fromScale(S, 1 - V)
				HueSlider.Fill.Size = UDim2.fromScale(H, 1)
				HueSlider.Label.Text = tostring(math.floor(H * 360))
				AlphaSlider.Fill.Size = UDim2.fromScale(Alpha, 1)
				AlphaSlider.Label.Text = math.floor(Alpha * 100) .. "%"
				if Fire then Callback(Color, Alpha) end
			end

			Janitor:Give(HexBox.FocusLost:Connect(function()
				local Ok, Parsed = pcall(Color3.fromHex, HexBox.Text)
				if Ok then
					H, S, V = Parsed:ToHSV()
					Render(true)
				else
					HexBox.Text = string.upper(Color:ToHex())
				end
			end))

			Janitor:Give(CopyBtn.MouseButton1Click:Connect(function()
				if typeof(setclipboard) == "function" then
					setclipboard("#" .. string.upper(Color:ToHex()))
					WindowObj:Notify({Content = "Copied #" .. string.upper(Color:ToHex()), Duration = 2})
				end
			end))

			local function Hook(Gui, Kind)
				Janitor:Give(Gui.InputBegan:Connect(function(Input)
					if not IsPress(Input) then return end
					local function Update(In)
						local Size, Pos = Gui.AbsoluteSize, Gui.AbsolutePosition
						local X = math.clamp((In.Position.X - Pos.X) / math.max(Size.X, 1), 0, 1)
						local Y = math.clamp((In.Position.Y - Pos.Y) / math.max(Size.Y, 1), 0, 1)
						if Kind == "Map" then S, V = X, 1 - Y
						elseif Kind == "Hue" then H = X
						else Alpha = X end
						Render(true)
					end
					Update(Input)
					BeginDrag(Update)
				end))
			end
			Hook(ColorMap, "Map"); Hook(HueSlider.Track, "Hue"); Hook(AlphaSlider.Track, "Alpha")

			local IsOpen = false
			local function Close()
				if not IsOpen then return end
				IsOpen = false
				local Tw = Tween(Picker, TweenSmooth, {Size = UDim2.fromOffset(220, 0)})
				Tw.Completed:Once(function() if not IsOpen then Picker.Visible = false end end)
			end
			local Popup = {Close = Close, Frames = {Picker, ColorBtn}}

			Janitor:Give(ColorBtn.MouseButton1Click:Connect(function()
				if IsOpen then WindowObj:ClosePopup(); Close(); return end
				WindowObj:OpenPopup(Popup)
				local Pos, Size, Bounds = ColorBtn.AbsolutePosition, ColorBtn.AbsoluteSize, ScreenGui.AbsoluteSize
				local X = Pos.X - 230
				if X < 0 then X = Pos.X + Size.X + 10 end
				X = math.clamp(X, 0, math.max(Bounds.X - 220, 0))
				local Y = math.clamp(Pos.Y + Size.Y + 6, 0, math.max(Bounds.Y - 220, 0))
				Picker.Position = UDim2.fromOffset(X, Y)
				Picker.Visible = true
				IsOpen = true
				Tween(Picker, TweenSmooth, {Size = UDim2.fromOffset(220, 220)})
			end))

			Render(false)

			local Obj = {}
			function Obj:GetComponentType() return "Colorpicker" end
			function Obj:GetValue() return Color end
			function Obj:GetTransparency() return Alpha * 100 end
			function Obj:SetValue(NewColor, Silent) H, S, V = NewColor:ToHSV(); Render(not Silent) end
			function Obj:SetTransparency(Trans, Silent) Alpha = math.clamp(Trans, 0, 100) / 100; Render(not Silent) end
			Register(Flag, Obj)
			return Obj
		end

		function TabObj:Colorpicker(O)
			local Title = O.Title or "Colorpicker"
			local Row = CreateRow(Title, 40)
			RowTitle(Row, Title, 250)
			local Obj = AttachColorPicker(Row, Title, O, 8)
			Obj.Row = Row
			return Obj
		end

		-------------------------------------------------------------------
		-- Button
		-------------------------------------------------------------------
		function TabObj:Button(O)
			local Title = O.Title or "Button"
			local Callback = O.Callback or Noop
			local Row = CreateRow(Title, 40)
			RowTitle(Row, Title, 200)

			local Btn = Create("TextButton", {Size = UDim2.new(0, 0, 0, 26), Position = UDim2.new(1, -8, 0.5, 0), AnchorPoint = Vector2.new(1, 0.5), AutomaticSize = Enum.AutomaticSize.X, BackgroundColor3 = Theme.Search, Text = O.Action or "Click", TextColor3 = Theme.TextPrimary, Font = Theme.Font, TextSize = 12, AutoButtonColor = false, Parent = Row})
			Corner(Btn, 4)
			Create("UIPadding", {PaddingLeft = UDim.new(0, 16), PaddingRight = UDim.new(0, 16), Parent = Btn})
			Themed(Btn, {BackgroundColor3 = "Search", TextColor3 = "TextPrimary", Font = "Font"})

			Janitor:Give(Btn.MouseEnter:Connect(function() Tween(Btn, TweenFast, {BackgroundColor3 = Theme.Border}) end))
			Janitor:Give(Btn.MouseLeave:Connect(function() Tween(Btn, TweenFast, {BackgroundColor3 = Theme.Search}) end))
			Janitor:Give(Btn.MouseButton1Click:Connect(Callback))

			local Obj = {Row = Row}
			function Obj:GetComponentType() return "Button" end
			function Obj:Fire() Callback() end
			Register(FlagFor(O, "Button", Title), Obj)
			return Obj
		end

		-------------------------------------------------------------------
		-- Textbox
		-------------------------------------------------------------------
		function TabObj:Textbox(O)
			local Title = O.Title or "Textbox"
			local Callback = O.Callback or Noop
			local Row = CreateRow(Title, 40)
			RowTitle(Row, Title, 200)

			local Input = Create("TextBox", {Size = UDim2.fromOffset(100, 26), Position = UDim2.new(1, -8, 0.5, 0), AnchorPoint = Vector2.new(1, 0.5), BackgroundColor3 = Theme.Search, Text = O.Default or "", PlaceholderText = O.Placeholder or "Type here", TextColor3 = Theme.TextPrimary, PlaceholderColor3 = Theme.TextSecondary, Font = Enum.Font.Code, TextSize = 12, TextXAlignment = Enum.TextXAlignment.Left, AutomaticSize = Enum.AutomaticSize.X, ClearTextOnFocus = false, ClipsDescendants = true, Parent = Row})
			Corner(Input, 4)
			local Stroke = Create("UIStroke", {Color = Theme.Border, Thickness = 1, ApplyStrokeMode = Enum.ApplyStrokeMode.Border, Parent = Input})
			Create("UIPadding", {PaddingLeft = UDim.new(0, 10), PaddingRight = UDim.new(0, 10), Parent = Input})
			Create("UISizeConstraint", {MinSize = Vector2.new(100, 26), MaxSize = Vector2.new(300, 26), Parent = Input})
			Themed(Input, {BackgroundColor3 = "Search", TextColor3 = "TextPrimary", PlaceholderColor3 = "TextSecondary"})
			Themed(Stroke, {Color = "Border"})

			if O.Numeric then
				Janitor:Give(Input:GetPropertyChangedSignal("Text"):Connect(function()
					local Clean = string.gsub(Input.Text, "[^%d%.%-]", "")
					if Clean ~= Input.Text then Input.Text = Clean end
				end))
			end

			local Value = O.Default or ""
			Janitor:Give(Input.Focused:Connect(function() Tween(Stroke, TweenFast, {Color = Theme.Accent}) end))
			Janitor:Give(Input.FocusLost:Connect(function()
				Tween(Stroke, TweenFast, {Color = Theme.Border})
				Value = Input.Text
				Callback(Value)
			end))

			local Obj = {Row = Row}
			function Obj:GetComponentType() return "Textbox" end
			function Obj:GetValue() return Value end
			function Obj:SetValue(Val, Silent)
				Value = tostring(Val)
				Input.Text = Value
				if not Silent then Callback(Value) end
			end
			Register(FlagFor(O, "Textbox", Title), Obj)
			return Obj
		end

		-------------------------------------------------------------------
		-- Keybind  (Callback = pressed, OnChanged = rebound)
		-------------------------------------------------------------------
		function TabObj:Keybind(O)
			local Title = O.Title or "Keybind"
			local Callback = O.Callback or Noop
			local OnChanged = O.OnChanged or Noop
			local Key = O.Default
			local Binding, BindConn = false, nil

			local Row = CreateRow(Title, 40)
			RowTitle(Row, Title, 200)

			local Container = Create("TextButton", {Size = UDim2.new(0, 150, 1, 0), Position = UDim2.new(1, -8, 0.5, 0), AnchorPoint = Vector2.new(1, 0.5), BackgroundTransparency = 1, Text = "", AutoButtonColor = false, Parent = Row})
			Create("UIListLayout", {FillDirection = Enum.FillDirection.Horizontal, HorizontalAlignment = Enum.HorizontalAlignment.Right, VerticalAlignment = Enum.VerticalAlignment.Center, SortOrder = Enum.SortOrder.LayoutOrder, Padding = UDim.new(0, 8), Parent = Container})
			local KeyText = Create("TextLabel", {Size = UDim2.new(0, 0, 0, 20), AutomaticSize = Enum.AutomaticSize.X, BackgroundTransparency = 1, Text = FormatKeyName(Key), TextColor3 = Theme.TextPrimary, Font = Theme.Font, TextSize = 13, LayoutOrder = 2, Parent = Container})
			local IconHolder = Create("Frame", {Size = UDim2.fromOffset(24, 18), BackgroundTransparency = 1, LayoutOrder = 1, Parent = Container})
			local Icon = Create("ImageLabel", {Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1, Image = Icons.Keyboard, ImageColor3 = Theme.TextPrimary, Parent = IconHolder})

			local function Refresh(Instant)
				KeyText.Text = Binding and "..." or FormatKeyName(Key)
				local Col = Binding and Theme.Accent or Theme.TextPrimary
				Set(KeyText, {TextColor3 = Col}, Instant)
				Set(Icon, {ImageColor3 = Col}, Instant)
			end
			OnTheme(function() Refresh(true); KeyText.Font = Theme.Font end)

			Janitor:Give(Container.MouseButton1Click:Connect(function()
				if Binding then return end
				Binding = true
				WindowObj.Binding = true
				Refresh()
				BindConn = UserInputService.InputBegan:Connect(function(Input)
					local New
					if Input.UserInputType == Enum.UserInputType.Keyboard then
						New = Input.KeyCode ~= Enum.KeyCode.Escape and Input.KeyCode or false
					elseif string.find(Input.UserInputType.Name, "MouseButton") then
						New = Input.UserInputType
					else
						return
					end
					BindConn:Disconnect(); BindConn = nil
					Binding = false
					task.defer(function() WindowObj.Binding = false end) -- swallow this press
					Key = New or nil
					Refresh()
					OnChanged(Key)
				end)
			end))
			Janitor:Give(function() if BindConn then BindConn:Disconnect() end end)

			Janitor:Give(UserInputService.InputBegan:Connect(function(Input, Processed)
				if Processed or WindowObj.Binding or not Key then return end
				if Input.KeyCode == Key or Input.UserInputType == Key then Callback(Key) end
			end))

			local Obj = {Row = Row}
			function Obj:GetComponentType() return "Keybind" end
			function Obj:GetValue() return Key end
			function Obj:SetValue(Val, Silent)
				Key = Val
				Refresh()
				if not Silent then OnChanged(Key) end
			end
			Register(FlagFor(O, "Keybind", Title), Obj)
			return Obj
		end

		-------------------------------------------------------------------
		-- Slider
		-------------------------------------------------------------------
		function TabObj:Slider(O)
			local Title = O.Title or "Slider"
			local Min, Max = O.Min or 0, O.Max or 100
			local Range = math.max(Max - Min, 1e-9)
			local Decimal = O.Decimal or 0
			local Prefix, Suffix = O.Prefix or "", O.Suffix or ""
			local Dual = O.Dual or false
			local Callback = O.Callback or Noop
			local ZeroAlpha = math.clamp(((O.ZeroNumber or Min) - Min) / Range, 0, 1)

			local Current
			if Dual then
				local D = type(O.Default) == "table" and O.Default or {}
				Current = {math.clamp(D[1] or Min, Min, Max), math.clamp(D[2] or Max, Min, Max)}
			else
				Current = math.clamp(O.Default or Min, Min, Max)
			end

			local Row = CreateRow(Title, 52)
			local TitleLabel = Create("TextLabel", {Size = UDim2.fromOffset(200, 20), Position = UDim2.fromOffset(8, 8), BackgroundTransparency = 1, Text = Title, TextColor3 = Theme.TextPrimary, Font = Theme.Font, TextSize = 13, TextXAlignment = Enum.TextXAlignment.Left, Parent = Row})
			local ValueLabel = Create("TextLabel", {Size = UDim2.fromOffset(150, 20), Position = UDim2.new(1, -158, 0, 8), BackgroundTransparency = 1, Text = "", TextColor3 = Theme.TextPrimary, Font = Theme.Font, TextSize = 12, TextXAlignment = Enum.TextXAlignment.Right, Parent = Row})
			Themed(TitleLabel, {TextColor3 = "TextPrimary", Font = "Font"})
			Themed(ValueLabel, {TextColor3 = "TextPrimary", Font = "Font"})

			local TrackBtn = Create("TextButton", {Size = UDim2.new(1, -16, 0, 20), Position = UDim2.fromOffset(8, 28), BackgroundTransparency = 1, Text = "", AutoButtonColor = false, Parent = Row})
			local Track = Create("Frame", {Size = UDim2.new(1, 0, 0, 4), Position = UDim2.new(0, 0, 0.5, -2), BackgroundColor3 = Theme.Search, Parent = TrackBtn})
			Corner(Track, 2)
			local Fill = Create("Frame", {Size = UDim2.fromScale(0, 1), BackgroundColor3 = Theme.Accent, Parent = Track})
			Corner(Fill, 2)
			local Handle1 = Create("Frame", {Size = UDim2.fromOffset(12, 12), Position = UDim2.fromScale(Dual and 0 or 1, 0.5), AnchorPoint = Vector2.new(0.5, 0.5), BackgroundColor3 = Theme.TextPrimary, Parent = Fill})
			Corner(Handle1, 6)
			local Handle2
			if Dual then
				Handle2 = Create("Frame", {Size = UDim2.fromOffset(12, 12), Position = UDim2.fromScale(1, 0.5), AnchorPoint = Vector2.new(0.5, 0.5), BackgroundColor3 = Theme.TextPrimary, Parent = Fill})
				Corner(Handle2, 6)
			end
			Themed(Track, {BackgroundColor3 = "Search"})
			Themed(Fill, {BackgroundColor3 = "Accent"})
			Themed(Handle1, {BackgroundColor3 = "TextPrimary"})
			if Handle2 then Themed(Handle2, {BackgroundColor3 = "TextPrimary"}) end

			local function Fmt(Val) return Prefix .. string.format("%." .. Decimal .. "f", Val) .. Suffix end

			local function Render(Instant)
				if Dual then
					local A1, A2 = (Current[1] - Min) / Range, (Current[2] - Min) / Range
					Set(Fill, {Position = UDim2.fromScale(A1, 0), Size = UDim2.new(A2 - A1, 0, 1, 0)}, Instant, TweenDrag)
					ValueLabel.Text = string.format("( %s, %s )", Fmt(Current[1]), Fmt(Current[2]))
				else
					local A = (Current - Min) / Range
					Set(Fill, {Position = UDim2.fromScale(math.min(A, ZeroAlpha), 0), Size = UDim2.new(math.abs(A - ZeroAlpha), 0, 1, 0)}, Instant, TweenDrag)
					Handle1.Position = UDim2.fromScale(A < ZeroAlpha and 0 or 1, 0.5)
					ValueLabel.Text = string.format("( %s )", Fmt(Current))
				end
			end

			local function SetValue(Value, Fire)
				if Dual then
					local V = type(Value) == "table" and Value or {Min, Max}
					local A, B = math.clamp(V[1] or Min, Min, Max), math.clamp(V[2] or Max, Min, Max)
					if A > B then A, B = B, A end
					if Current[1] == A and Current[2] == B and Fire then return end
					Current = {A, B}
				else
					local N = math.clamp(tonumber(Value) or Min, Min, Max)
					if Current == N and Fire then return end
					Current = N
				end
				Render(false)
				if Fire then Callback(Dual and table.clone(Current) or Current) end
			end

			local function AlphaOf(Input)
				return math.clamp((Input.Position.X - Track.AbsolutePosition.X) / math.max(Track.AbsoluteSize.X, 1), 0, 1)
			end
			local function Snap(Alpha)
				local Mult = 10 ^ Decimal
				return math.clamp(math.round((Min + Range * Alpha) * Mult) / Mult, Min, Max)
			end

			Janitor:Give(TrackBtn.InputBegan:Connect(function(Input)
				if not IsPress(Input) then return end
				local Handle = 1
				if Dual then
					local A = AlphaOf(Input)
					local D1, D2 = math.abs(A - (Current[1] - Min) / Range), math.abs(A - (Current[2] - Min) / Range)
					Handle = (D1 == D2) and (A > (Current[1] - Min) / Range and 2 or 1) or (D1 < D2 and 1 or 2)
				end
				local function Apply(In)
					local Value = Snap(AlphaOf(In))
					if Dual then
						local New = {Current[1], Current[2]}
						New[Handle] = Value
						SetValue(New, true)
					else
						SetValue(Value, true)
					end
				end
				Apply(Input)
				BeginDrag(Apply)
			end))

			Render(true)
			local Obj = {Row = Row}
			function Obj:GetComponentType() return "Slider" end
			function Obj:GetValue() return Dual and table.clone(Current) or Current end
			function Obj:SetValue(Val, Silent) SetValue(Val, not Silent) if Silent then Render(false) end end
			Register(FlagFor(O, "Slider", Title), Obj)
			return Obj
		end

		-------------------------------------------------------------------
		-- Toggle
		-------------------------------------------------------------------
		function TabObj:Toggle(O)
			local Title = O.Title or "Toggle"
			local Callback = O.Callback or Noop
			local State = O.Default or false

			local Row = CreateRow(Title, 40)
			RowTitle(Row, Title, 60)

			local Box = Create("Frame", {Size = UDim2.fromOffset(18, 18), Position = UDim2.new(1, -8, 0.5, 0), AnchorPoint = Vector2.new(1, 0.5), BackgroundColor3 = State and Theme.Accent or Theme.Search, Parent = Row})
			Corner(Box, 4)
			local Check = Create("ImageLabel", {Size = UDim2.fromOffset(12, 12), Position = UDim2.fromScale(0.5, 0.5), AnchorPoint = Vector2.new(0.5, 0.5), BackgroundTransparency = 1, Image = Icons.Checkmark, ImageColor3 = DarkIcon, ImageTransparency = State and 0 or 1, Parent = Box})

			local function Render(Instant)
				Set(Box, {BackgroundColor3 = State and Theme.Accent or Theme.Search}, Instant)
				Set(Check, {ImageTransparency = State and 0 or 1}, Instant)
			end
			OnTheme(function() Render(true) end)

			local function SetState(New, Fire)
				State = New and true or false
				Render(false)
				if Fire then Callback(State) end
			end

			local Click = Create("TextButton", {Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1, Text = "", ZIndex = 5, Parent = Row})
			Janitor:Give(Click.MouseButton1Click:Connect(function() SetState(not State, true) end))

			local Obj = {Row = Row, Pickers = {}}
			function Obj:GetComponentType() return "Toggle" end
			function Obj:GetValue() return State end
			function Obj:SetValue(Val, Silent) SetState(Val, not Silent) end
			function Obj:Colorpicker(Props)
				local Picker = AttachColorPicker(Row, Title, Props, 36)
				table.insert(self.Pickers, Picker)
				return Picker
			end
			Register(FlagFor(O, "Toggle", Title), Obj)
			return Obj
		end

		-------------------------------------------------------------------
		-- Dropdown
		-------------------------------------------------------------------
		function TabObj:Dropdown(O)
			local Title = O.Title or "Dropdown"
			local OptionsList = O.Options or {}
			local Multi = O.Multi or false
			local Callback = O.Callback or Noop
			local MaxHeight = O.MaxHeight or 160
			local Selected = {}

			local function Normalize(Val)
				local Out = {}
				if Multi then
					if type(Val) == "table" then for _, V in Val do table.insert(Out, V) end end
				else
					if type(Val) == "string" and Val ~= "" then table.insert(Out, Val)
					elseif type(Val) == "table" and #Val > 0 then table.insert(Out, Val[1]) end
				end
				return Out
			end
			Selected = Normalize(O.Default)

			local Row = CreateRow(Title, 40)
			RowTitle(Row, Title, 200)

			local DropBtn = Create("TextButton", {Size = UDim2.fromOffset(160, 26), Position = UDim2.new(1, -8, 0.5, 0), AnchorPoint = Vector2.new(1, 0.5), BackgroundColor3 = Theme.Search, Text = "", AutoButtonColor = false, Parent = Row})
			Corner(DropBtn, 4)
			local DropText = Create("TextLabel", {Size = UDim2.new(1, -30, 1, 0), Position = UDim2.fromOffset(10, 0), BackgroundTransparency = 1, Text = "", TextColor3 = Theme.TextPrimary, Font = Theme.Font, TextSize = 12, TextXAlignment = Enum.TextXAlignment.Left, TextTruncate = Enum.TextTruncate.AtEnd, Parent = DropBtn})
			local Chevron = Create("ImageLabel", {Size = UDim2.fromOffset(16, 16), Position = UDim2.new(1, -20, 0.5, -8), BackgroundTransparency = 1, Image = Icons.ChevronDown, ImageColor3 = Theme.TextSecondary, Parent = DropBtn})
			Themed(DropBtn, {BackgroundColor3 = "Search"})
			Themed(DropText, {TextColor3 = "TextPrimary", Font = "Font"})
			Themed(Chevron, {ImageColor3 = "TextSecondary"})

			local Menu = Create("ScrollingFrame", {Size = UDim2.fromOffset(160, 0), BackgroundColor3 = Theme.Main, Visible = false, ClipsDescendants = true, ZIndex = 10, BorderSizePixel = 0, ScrollBarThickness = 2, ScrollBarImageColor3 = Theme.Border, CanvasSize = UDim2.new(), AutomaticCanvasSize = Enum.AutomaticSize.Y, Parent = ScreenGui})
			Corner(Menu, 6)
			local MenuStroke = Create("UIStroke", {Color = Theme.Border, Thickness = 1, Parent = Menu})
			Create("UIPadding", {PaddingTop = UDim.new(0, 4), PaddingBottom = UDim.new(0, 4), Parent = Menu})
			local Layout = Create("UIListLayout", {SortOrder = Enum.SortOrder.LayoutOrder, Parent = Menu})
			Themed(Menu, {BackgroundColor3 = "Main", ScrollBarImageColor3 = "Border"})
			Themed(MenuStroke, {Color = "Border"})

			local Buttons, IsOpen = {}, false

			local function UpdateText()
				DropText.Text = #Selected > 0 and table.concat(Selected, ", ") or "None"
			end

			local function Close()
				if not IsOpen then return end
				IsOpen = false
				Tween(Chevron, TweenSmooth, {Rotation = 0})
				local Tw = Tween(Menu, TweenSmooth, {Size = UDim2.fromOffset(160, 0)})
				Tw.Completed:Once(function() if not IsOpen then Menu.Visible = false end end)
			end
			local Popup = {Close = Close, Frames = {Menu, DropBtn}}

			local function Paint(Instant)
				for Option, Btn in Buttons do
					Set(Btn, {TextColor3 = table.find(Selected, Option) and Theme.Accent or Theme.TextSecondary}, Instant)
				end
			end
			OnTheme(function() Paint(true) end)

			local function SetValue(Val, Fire)
				Selected = Normalize(Val)
				Paint(false)
				UpdateText()
				if Fire then Callback(Multi and table.clone(Selected) or Selected[1]) end
			end

			local function Rebuild(NewOptions)
				OptionsList = type(NewOptions) == "table" and NewOptions or {}
				for _, Btn in Buttons do Btn:Destroy() end
				table.clear(Buttons)
				local Keep = {}
				for _, Item in Selected do if table.find(OptionsList, Item) then table.insert(Keep, Item) end end
				Selected = Keep

				for Index, Option in OptionsList do
					local Btn = Create("TextButton", {Size = UDim2.new(1, 0, 0, 28), BackgroundTransparency = 1, Text = Option, TextColor3 = table.find(Selected, Option) and Theme.Accent or Theme.TextSecondary, Font = Theme.Font, TextSize = 12, TextXAlignment = Enum.TextXAlignment.Left, LayoutOrder = Index, ZIndex = 11, Parent = Menu})
					Create("UIPadding", {PaddingLeft = UDim.new(0, 10), Parent = Btn})
					Buttons[Option] = Btn
					Btn.MouseButton1Click:Connect(function()
						if Multi then
							local New = table.clone(Selected)
							local I = table.find(New, Option)
							if I then table.remove(New, I) else table.insert(New, Option) end
							SetValue(New, true)
						else
							SetValue(Option, true)
							WindowObj:ClosePopup(); Close()
						end
					end)
				end
				UpdateText()
			end
			Rebuild(OptionsList)

			Janitor:Give(DropBtn.MouseButton1Click:Connect(function()
				if IsOpen then WindowObj:ClosePopup(); Close(); return end
				WindowObj:OpenPopup(Popup)
				local Pos, Size, Bounds = DropBtn.AbsolutePosition, DropBtn.AbsoluteSize, ScreenGui.AbsoluteSize
				local Height = math.min(Layout.AbsoluteContentSize.Y + 8, MaxHeight)
				local Y = Pos.Y + Size.Y + 6
				if Y + Height > Bounds.Y then Y = Pos.Y - Height - 6 end
				Menu.Position = UDim2.fromOffset(Pos.X, Y)
				Menu.Visible = true
				IsOpen = true
				Tween(Chevron, TweenSmooth, {Rotation = 180})
				Tween(Menu, TweenSmooth, {Size = UDim2.fromOffset(160, Height)})
			end))

			local Obj = {Row = Row}
			function Obj:GetComponentType() return "Dropdown" end
			function Obj:GetValue() return Multi and table.clone(Selected) or Selected[1] end
			function Obj:SetValue(Val, Silent) SetValue(Val, not Silent) end
			function Obj:SetOptions(New) Rebuild(New) end
			function Obj:GetOptions() return OptionsList end
			Register(FlagFor(O, "Dropdown", Title), Obj)
			return Obj
		end

		return TabObj
	end

	-----------------------------------------------------------------------
	-- Destroy
	-----------------------------------------------------------------------
	function WindowObj:Destroy()
		Janitor:Clean()
		for Flag in FlagNames do Library.Flags[Flag] = nil end
		local I = table.find(Library.Windows, WindowObj)
		if I then table.remove(Library.Windows, I) end
	end
	table.insert(Library.Windows, WindowObj)

	-----------------------------------------------------------------------
	-- Configuration tab (config files + live theme editor)
	-----------------------------------------------------------------------
	local Config = WindowObj:Tab({Title = "Configuration", Icon = Icons.Save, IsConfig = true})
	WindowObj.ConfigTab = Config
	Janitor:Give(SaveBtn.MouseButton1Click:Connect(function() Config:Activate() end))
	Config.SetActive(false, true)

	Config:Section("Configs")
	local NameBox = Config:Textbox({Title = "Config name", Default = "default", Flag = "_Config/Name"})
	local ConfigList = Config:Dropdown({Title = "Saved configs", Options = Library:ListConfigs(), Flag = "_Config/List"})
	Config:Button({Title = "Save config", Action = "Save", Flag = "_Config/Save", Callback = function()
		local Ok, Err = Library:SaveConfig(NameBox:GetValue())
		WindowObj:Notify({Title = "Config", Content = Ok and "Saved." or ("Save failed: " .. tostring(Err))})
		ConfigList:SetOptions(Library:ListConfigs())
	end})
	Config:Button({Title = "Load selected", Action = "Load", Flag = "_Config/Load", Callback = function()
		local Name = ConfigList:GetValue()
		if not Name then WindowObj:Notify({Title = "Config", Content = "Select a config first."}) return end
		local Ok, Err = Library:LoadConfig(Name)
		WindowObj:Notify({Title = "Config", Content = Ok and ("Loaded " .. Name) or ("Load failed: " .. tostring(Err))})
	end})
	Config:Button({Title = "Refresh list", Action = "Refresh", Flag = "_Config/Refresh", Callback = function()
		ConfigList:SetOptions(Library:ListConfigs())
	end})

	Config:Section("Theme")
	for _, Key in {"Accent", "Body", "Sidebar", "Main", "Search", "TextPrimary", "TextSecondary", "Border"} do
		Config:Colorpicker({Title = Key, Default = Theme[Key], Flag = "Theme/" .. Key, Callback = function(Col)
			Library:SetTheme({[Key] = Col})
		end})
	end

	return WindowObj
end

return Library
