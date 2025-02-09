-- GLOBALS -> LOCAL
local _G = getfenv(0)
local InFlight, self = InFlight, InFlight
local GetNumRoutes, GetTaxiMapID, GetTime, NumTaxiNodes, TaxiGetNodeSlot, TaxiNodeGetType, TaxiNodeName, UnitOnTaxi
	= GetNumRoutes, GetTaxiMapID, GetTime, NumTaxiNodes, TaxiGetNodeSlot, TaxiNodeGetType, TaxiNodeName, UnitOnTaxi
local abs, floor, format, gsub, ipairs, pairs, print, strjoin
	= abs, floor, format, gsub, ipairs, pairs, print, strjoin
local gtt = GameTooltip
local oldTakeTaxiNode
InFlight.debug = false

-- LIBRARIES
local smed = LibStub("LibSharedMedia-3.0")

-- LOCAL VARIABLES
local debug = InFlight.debug
local Print, PrintD = InFlight.Print, InFlight.PrintD
local vars, db												-- addon databases
local taxiSrc, taxiSrcName, taxiDst, taxiDstName, endTime	-- location data
local porttaken, takeoff, inworld, outworld, ontaxi			-- flags
local ratio, endText = 0, "??"								-- cache variables
local sb, spark, timeText, locText, bord					-- frame elements
local totalTime, startTime, elapsed, throt = 0, 0, 0, 0		-- throttle vars

-- LOCALIZATION
local L = LibStub("AceLocale-3.0"):GetLocale("InFlight", not debug)
local FL = LibStub("AceLocale-3.0"):GetLocale("InFlightLoc", not debug)
InFlight.L = L

-- LOCAL FUNCTIONS
local function FormatTime(secs)  -- simple time format
	if not secs then
		return "??"
	end

	return format(TIMER_MINUTES_DISPLAY, secs / 60, secs % 60)
end

local function ShortenName(name)  -- shorten name to lighten saved vars and display
	return gsub(name, L["DestParse"], "")
end

local function SetPoints(f, lp, lrt, lrp, lx, ly, rp, rrt, rrp, rx, ry)
	f:ClearAllPoints()
	f:SetPoint(lp, lrt, lrp, lx, ly)
	if rp then
		f:SetPoint(rp, rrt, rrp, rx, ry)
	end
end

local function SetToUnknown()  -- setup bar for flights with unknown time
	sb:SetMinMaxValues(0, 1)
	sb:SetValue(1)
	sb:SetStatusBarColor(db.unknowncolor.r, db.unknowncolor.g, db.unknowncolor.b, db.unknowncolor.a)
	spark:Hide()
end

local function GetEstimatedTime(slot)  -- estimates flight times based on edges
	local numRoutes = GetNumRoutes(slot)
	if numRoutes < 2 then
		return
	end

	local taxiNodes = {[1] = taxiSrc, [numRoutes + 1] = L[ShortenName(TaxiNodeName(slot))]}
	for edge = 2, numRoutes, 1 do
		taxiNodes[edge] = L[ShortenName(TaxiNodeName(TaxiGetNodeSlot(slot, edge, true)))]
	end

	local etimes = { 0 }
	local prevNode = {}
	local nextNode = {}
	local srcNode = 1
	local dstNode = #taxiNodes - 1
	PrintD("|cff208020New Route:|r", taxiSrc, "-->", taxiNodes[#taxiNodes], "-", #taxiNodes, "nodes")
	while srcNode and srcNode < #taxiNodes do
		while dstNode and dstNode > srcNode do
			PrintD("|cff208020Node:|r", taxiNodes[srcNode], "-->", taxiNodes[dstNode])
			if vars[taxiNodes[srcNode]] then
				if not etimes[dstNode] and vars[taxiNodes[srcNode]][taxiNodes[dstNode]] then
					etimes[dstNode] = etimes[srcNode] + vars[taxiNodes[srcNode]][taxiNodes[dstNode]]
					PrintD(taxiNodes[dstNode], "time:", FormatTime(etimes[srcNode]), "+", FormatTime(vars[taxiNodes[srcNode]][taxiNodes[dstNode]]), "=", FormatTime(etimes[dstNode]))
					nextNode[srcNode] = dstNode - 1
					prevNode[dstNode] = srcNode
					srcNode = dstNode
					dstNode = #taxiNodes
				else
					dstNode = dstNode - 1
				end
			else
				srcNode = prevNode[srcNode]
				dstNode = nextNode[srcNode]
			end
		end

		if not etimes[#taxiNodes] then
			PrintD("<<")
			srcNode = prevNode[srcNode]
			dstNode = nextNode[srcNode]
		end
	end

	PrintD(".")
	return etimes[#taxiNodes]
end

local function addDuration(flightTime, estimated)
	if flightTime > 0 then
		gtt:AddLine(L["Duration"]..(estimated and "~" or "")..FormatTime(flightTime), 1, 1, 1)
	else
		gtt:AddLine(L["Duration"].."-:--", 0.8, 0.8, 0.8)
	end

	gtt:Show()
end

local function postTaxiNodeOnButtonEnter(button) -- adds duration info to taxi node tooltips
	local id = button:GetID()
	if TaxiNodeGetType(id) ~= "REACHABLE" then
		return
	end

	local duration = vars[taxiSrc] and vars[taxiSrc][L[ShortenName(TaxiNodeName(id))]]
	if duration then
		addDuration(duration)
	else
		addDuration(GetEstimatedTime(id) or 0, true)
	end
end

----------------------------
function InFlight.Print(...)  -- prefix chat messages
----------------------------
	print("|cff0040ffIn|r|cff00aaffFlight|r:", ...)
end
Print = InFlight.Print

-----------------------------
function InFlight.PrintD(...)  -- debug print
-----------------------------
	if debug then
		print("|cff00ff40In|r|cff00aaffFlight|r:", ...)
	end
end
PrintD = InFlight.PrintD

----------------------------------
function InFlight:GetDestination()
----------------------------------
	return taxiDstName
end

---------------------------------
function InFlight:GetFlightTime()
---------------------------------
	return endTime
end

----------------------------
function InFlight:LoadBulk()  -- called from InFlight_Load
----------------------------
	InFlightDB = InFlightDB or {}

	-- Convert old saved variables
	if not InFlightDB.version then
		InFlightDB.perchar = nil
		InFlightDB.dbinit = nil
		InFlightDB.upload = nil
		local tempDB = InFlightDB
		InFlightDB = { profiles = { Default = tempDB }}
	end

	-- Check that this is the right version of the client
	if select(4, GetBuildInfo()) > 20000 then
		Print(L["AddonDisabled"])
		DisableAddOn("InFlight")
		return
	end

	-- Check that this is the right version of the database to avoid corruption
	if InFlightDB.version ~= "classic_era" then
		InFlightDB.global = nil
		InFlightDB.version = "classic_era"
	end

	-- Update default data
	-- This number only needs to be changed if corrupted data has been
	-- introduced into the player save data from a bug in the game or this
	-- addon, and therefore the player save data needs to be reset.
	-- Duplicates of updated default data will be automatically removed from the player save data
	-- by the metatable
	if InFlightDB.dbinit ~= 1150 or debug then
		InFlightDB.dbinit = 1150
		InFlightDB.upload = nil
		Print(L["DefaultsUpdated"])

		if debug then
			for faction, t in pairs(self.defaults.global) do
				local count = 0
				for src, dt in pairs(t) do
					for dst, dtime in pairs(dt) do
						count = count + 1
					end
				end

				PrintD(faction, "|cff208020-|r", count, "|cff208020flights|r")
			end
		else
			InFlightDB.global = nil
		end
	end

	-- Set up flight point translations
	for key, value in pairs(FL) do
		L[value] = key
	end

	-- Sanitise data
	if InFlightDB.global then
		local defaults = self.defaults.global
		local global = {}
		for faction, t in pairs(InFlightDB.global) do
			global[faction] = {}
			for src, dt in pairs(t) do
				local lsrc = L[ShortenName(src)]
				if lsrc ~= src and FL[lsrc] ~= L[src] then
					src = lsrc
				end

				global[faction][src] = {}
				for dst, dtime in pairs(dt) do
					local ldst = L[ShortenName(dst)]
					if ldst ~= dst and FL[ldst] ~= L[dst] then
						dst = ldst
					end

					if defaults[faction][src] and defaults[faction][src][dst]
							and abs(dtime - defaults[faction][src][dst]) < (debug and 2 or 5) then
						global[faction][src][dst] = defaults[faction][src][dst]
					else
						global[faction][src][dst] = dtime
					end
				end
			end
		end

		InFlightDB.global = global
	end

	FL = nil

	-- Check every 2 weeks if there are new flight times that could be uploaded
	if not InFlightDB.upload or InFlightDB.upload < time() then
		if InFlightDB.global then
			local defaults = self.defaults.global
			for faction, t in pairs(InFlightDB.global) do
				local found = 0
				for src, dt in pairs(t) do
					for dst, dtime in pairs(dt) do
						if not defaults[faction][src] or not defaults[faction][src][dst] then
							found = found + 1
							PrintD(faction, "|cff208020-|r", src, "-->", dst, "|cff00ff40added:|r", FormatTime(dtime))
						elseif abs(dtime - defaults[faction][src][dst]) >= (debug and 2 or 5) then
							found = found + 1
							PrintD(faction, "|cff208020-|r", src, "-->", dst, "|cff00aaffupdated:|r", FormatTime(defaults[faction][src][dst]), "-->", FormatTime(dtime))
						end
					end
				end

				if found > 0 then
					Print(faction, format("|cff208020- "..L["FlightTimeContribute"].."|r", "|r"..found.."|cff208020"))
				end
			end
		end

		InFlightDB.upload = time() + 1209600	-- 2 weeks in seconds (60 * 60 * 24 * 14)
	end

	-- Create profile and flight time databases
	local faction = UnitFactionGroup("player")
	if not debug then
		InFlight.defaults.global[faction == "Alliance" and "Horde" or "Alliance"] = nil
	end
	self.db = LibStub("AceDB-3.0"):New("InFlightDB", self.defaults, true)
	db = self.db.profile
	vars = self.db.global[faction]

	oldTakeTaxiNode = TakeTaxiNode
	TakeTaxiNode = function(slot)
		if TaxiNodeGetType(slot) ~= "REACHABLE" then
			return
		end

		-- Attempt to get source flight point if another addon auto-takes the taxi
		-- which can cause this function to run before the TAXIMAP_OPENED function
		if not taxiSrc then
			for i = 1, NumTaxiNodes(), 1 do
				if TaxiNodeGetType(i) == "CURRENT" then
					taxiSrcName = ShortenName(TaxiNodeName(i))
					taxiSrc = L[taxiSrcName]
					break
				end
			end

			if not taxiSrc then
				oldTakeTaxiNode(slot)
				return
			end
		end

		taxiDstName = ShortenName(TaxiNodeName(slot))
		taxiDst = L[taxiDstName]
		local t = vars[taxiSrc]
		if t and t[taxiDst] and t[taxiDst] > 0 then  -- saved variables lookup
			endTime = t[taxiDst]
			endText = FormatTime(endTime)
		else
			endTime = GetEstimatedTime(slot)
			endText = (endTime and "~" or "")..FormatTime(endTime)
		end

		if db.confirmflight then  -- confirm flight
			StaticPopupDialogs.INFLIGHTCONFIRM = StaticPopupDialogs.INFLIGHTCONFIRM or {
				button1 = OKAY, button2 = CANCEL,
				OnAccept = function(this, data) InFlight:StartTimer(data) end,
				timeout = 0, exclusive = 1, hideOnEscape = 1,
			}
			StaticPopupDialogs.INFLIGHTCONFIRM.text = format(L["ConfirmPopup"], "|cffffff00"..taxiDstName..(endTime and " ("..endText..")" or "").."|r")

			local dialog = StaticPopup_Show("INFLIGHTCONFIRM")
			if dialog then
				dialog.data = slot
			end
		else  -- just take the flight
			self:StartTimer(slot)
		end
	end

	-- function hooks to detect if a user took a summon
	hooksecurefunc("TaxiRequestEarlyLanding", function()
		porttaken = true
		PrintD("|cffff8080Taxi Early|cff208020, porttaken -|r", porttaken)
	end)

	hooksecurefunc("AcceptBattlefieldPort", function(index, accept)
		porttaken = accept and true
		PrintD("|cffff8080Battlefield port|cff208020, porttaken -|r", porttaken)
	end)

	hooksecurefunc(C_SummonInfo, "ConfirmSummon", function()
		porttaken = true
		PrintD("|cffff8080Summon|cff208020, porttaken -|r", porttaken)
	end)

	self:Hide()
	self.LoadBulk = nil
end

---------------------------------------
function InFlight:InitSource(isTaxiMap)  -- cache source location and hook tooltips
---------------------------------------
	taxiSrcName = nil
	taxiSrc = nil

	for i = 1, NumTaxiNodes(), 1 do
		local tb = _G["TaxiButton"..i]
		if tb and not tb.inflighted then
			tb:HookScript("OnEnter", postTaxiNodeOnButtonEnter)
			tb.inflighted = true
		end

--		PrintD(L[ShortenName(TaxiNodeName(i))], ShortenName(TaxiNodeName(i)))
		if TaxiNodeGetType(i) == "CURRENT" then
			taxiSrcName = ShortenName(TaxiNodeName(i))
			taxiSrc = L[taxiSrcName]
		end
	end
end

----------------------------------
function InFlight:StartTimer(slot)  -- lift off
----------------------------------
	Dismount()

	-- create the timer bar
	if not sb then
		self:CreateBar()
	end

	-- start the timers and setup statusbar
	if endTime then
		sb:SetMinMaxValues(0, endTime)
		sb:SetValue(db.fill and 0 or endTime)
		spark:SetPoint("CENTER", sb, "LEFT", db.fill and 0 or db.width, 0)
	else
		SetToUnknown()
	end

	InFlight:UpdateLook()
	timeText:SetFormattedText("%s / %s", FormatTime(0), endText)
	sb:Show()
	self:Show()

	porttaken = nil
	elapsed, totalTime, startTime = 0, 0, GetTime()
	takeoff, inworld = true, true
	throt = min(0.2, (endTime or 50) / (db.width or 1))  -- increases updates for short flights

	self:RegisterEvent("PLAYER_CONTROL_GAINED")
	self:RegisterEvent("PLAYER_ENTERING_WORLD")
	self:RegisterEvent("PLAYER_LEAVING_WORLD")

	if slot then
		oldTakeTaxiNode(slot)
	end
end

-------------------------------------------
function InFlight:StartMiscFlight(src, dst)  -- called from InFlight_Load for special flights
-------------------------------------------
	taxiSrcName = L[src]
	taxiSrc = src
	taxiDstName = L[dst]
	taxiDst = dst
	endTime = vars[src] and vars[src][dst]
	endText = FormatTime(endTime)
	self:StartTimer()
end

do  -- timer bar
	local bdrop = { edgeSize = 16, insets = {}, }
	local bdi = bdrop.insets
	-----------------------------
	function InFlight:CreateBar()
	-----------------------------
		sb = CreateFrame("StatusBar", "InFlightBar", UIParent)
		sb:Hide()
		sb:SetPoint(db.p, UIParent, db.rp, db.x, db.y)
		sb:SetMovable(true)
		sb:EnableMouse(true)
		sb:SetClampedToScreen(true)
		sb:SetScript("OnMouseUp", function(this, a1)
			if a1 == "RightButton" then
				InFlight:ShowOptions()
			elseif a1 == "LeftButton" and IsControlKeyDown() then
				ontaxi, porttaken = nil, true
			end
		end)
		sb:RegisterForDrag("LeftButton")
		sb:SetScript("OnDragStart", function(this)
			if IsShiftKeyDown() then
				this:StartMoving()
			end
		end)
		sb:SetScript("OnDragStop", function(this)
			this:StopMovingOrSizing()
			local a,b,c,d,e = this:GetPoint()
			db.p, db.rp, db.x, db.y = a, c, floor(d + 0.5), floor(e + 0.5)
		end)
		sb:SetScript("OnEnter", function(this)
			gtt:SetOwner(this, "ANCHOR_RIGHT")
			gtt:SetText("InFlight", 1, 1, 1)
			gtt:AddLine(L["TooltipOption1"], 0, 1, 0)
			gtt:AddLine(L["TooltipOption2"], 0, 1, 0)
			gtt:AddLine(L["TooltipOption3"], 0, 1, 0)
			gtt:Show()
		end)
		sb:SetScript("OnLeave", function() gtt:Hide() end)

		timeText = sb:CreateFontString(nil, "OVERLAY")
		locText = sb:CreateFontString(nil, "OVERLAY")

		spark = sb:CreateTexture(nil, "OVERLAY")
		spark:Hide()
		spark:SetTexture("Interface\\CastingBar\\UI-CastingBar-Spark")
		spark:SetWidth(16)
		spark:SetBlendMode("ADD")

		bord = CreateFrame("Frame", nil, sb, BackdropTemplateMixin and "BackdropTemplate")  -- border/background
		SetPoints(bord, "TOPLEFT", sb, "TOPLEFT", -5, 5, "BOTTOMRIGHT", sb, "BOTTOMRIGHT", 5, -5)
		bord:SetFrameStrata("LOW")

		local function onupdate(this, a1)
			elapsed = elapsed + a1
			if elapsed < throt then
				return
			end

			totalTime = GetTime() - startTime
			elapsed = 0

			if takeoff then  -- check if actually in flight after take off (doesn't happen immediately)
				if UnitOnTaxi("player") then
					takeoff, ontaxi = nil, true
					elapsed, totalTime, startTime = throt - 0.01, 0, GetTime()
				elseif totalTime > 5 then
					sb:Hide()
					this:Hide()
				end

				return
			end

			if ontaxi and not inworld then
				return
			end

			if not UnitOnTaxi("player") then  -- event bug fix
				ontaxi = nil
			end

			if not ontaxi then  -- flight ended
				PrintD("|cff208020porttaken -|r", porttaken)
				if not porttaken and taxiSrc then
					vars[taxiSrc] = vars[taxiSrc] or {}
					local oldTime = vars[taxiSrc][taxiDst]
					local newTime = floor(totalTime + 0.5)
					local msg = strjoin(" ", taxiSrcName, db.totext, taxiDstName, "|cff208020")
					if not oldTime then
						msg = msg..L["FlightTimeAdded"].."|r "..FormatTime(newTime)
					elseif abs(newTime - oldTime) >= 5 then
						msg = msg..L["FlightTimeUpdated"].."|r "..FormatTime(oldTime).." |cff208020"..db.totext.."|r "..FormatTime(newTime)
					else
						if debug then
							if abs(newTime - oldTime) >= 2 then
								PrintD(msg.."|r|cff00aaff"..L["FlightTimeUpdated"].."|r "..FormatTime(oldTime).." |cff208020"..db.totext.."|r "..FormatTime(newTime))
							else
								PrintD(msg.."|r|cff00ff40"..L["Duration"].."|r "..FormatTime(newTime))
							end
						end

						if not debug or abs(newTime - oldTime) < 2 then
							newTime = oldTime
						end

						msg = nil
					end

					vars[taxiSrc][taxiDst] = newTime
					if msg and db.chatlog then
						Print(msg)
					end
				end

				taxiSrcName = nil
				taxiSrc = nil
				taxiDstName = nil
				taxiDst = nil
				endTime = nil
				endText = FormatTime(endTime)
				sb:Hide()
				this:Hide()

				return
			end

			if endTime then  -- update statusbar if destination time is known
				if totalTime - 2 > endTime then   -- in case the flight is longer than expected
					SetToUnknown()
					endTime = nil
					endText = FormatTime(endTime)
				else
					local curTime = totalTime
					if curTime > endTime then
						curTime = endTime
					elseif curTime < 0 then
						curTime = 0
					end

					local value = db.fill and curTime or (endTime - curTime)
					sb:SetValue(value)
					spark:SetPoint("CENTER", sb, "LEFT", value * ratio, 0)

					value = db.countup and curTime or (endTime - curTime)
					timeText:SetFormattedText("%s / %s", FormatTime(value), endText)
				end
			else  -- destination time is unknown, so show that it's timing
				timeText:SetFormattedText("%s / %s", FormatTime(totalTime), endText)
			end
		end

		function self:PLAYER_LEAVING_WORLD()
			PrintD('PLAYER_LEAVING_WORLD')
			inworld = nil
			outworld = GetTime()
		end

		function self:PLAYER_ENTERING_WORLD()
			PrintD('PLAYER_ENTERING_WORLD')
			inworld = true
			if outworld then
				startTime = startTime - (outworld - GetTime())
			end

			outworld = nil
		end

		function self:PLAYER_CONTROL_GAINED()
			PrintD('PLAYER_CONTROL_GAINED')
			if not inworld then
				return
			end

			if self:IsShown() then
				ontaxi = nil
				onupdate(self, 3)
			end

			self:UnregisterEvent("PLAYER_ENTERING_WORLD")
			self:UnregisterEvent("PLAYER_LEAVING_WORLD")
			self:UnregisterEvent("PLAYER_CONTROL_GAINED")
		end

		self:SetScript("OnUpdate", onupdate)
		self.CreateBar = nil
	end

	------------------------------
	function InFlight:UpdateLook()
	------------------------------
		if not sb then
			return
		end

		sb:SetWidth(db.width)
		sb:SetHeight(db.height)

		local texture = smed:Fetch("statusbar", db.texture)
		local inset = (db.border=="Textured" and 2) or 4
		bdrop.bgFile = texture
		bdrop.edgeFile = smed:Fetch("border", db.border)
		bdi.left, bdi.right, bdi.top, bdi.bottom = inset, inset, inset, inset
		bord:SetBackdrop(bdrop)
		bord:SetBackdropColor(db.backcolor.r, db.backcolor.g, db.backcolor.b, db.backcolor.a)
		bord:SetBackdropBorderColor(db.bordercolor.r, db.bordercolor.g, db.bordercolor.b, db.bordercolor.a)
		sb:SetStatusBarTexture(texture)
		if sb:GetStatusBarTexture() then
			sb:GetStatusBarTexture():SetHorizTile(false)
			sb:GetStatusBarTexture():SetVertTile(false)
		end

		spark:SetHeight(db.height * 2.4)
		if endTime then  -- in case we're in flight
			ratio = db.width / endTime
			sb:SetStatusBarColor(db.barcolor.r, db.barcolor.g, db.barcolor.b, db.barcolor.a)
			if db.spark then
				spark:Show()
			else
				spark:Hide()
			end
		else
			SetToUnknown()
		end

		locText:SetFont(smed:Fetch("font", db.font), db.fontsize, db.outline and "OUTLINE" or nil)
		locText:SetShadowColor(0, 0, 0, db.fontcolor.a)
		locText:SetShadowOffset(1, -1)
		locText:SetTextColor(db.fontcolor.r, db.fontcolor.g, db.fontcolor.b, db.fontcolor.a)

		timeText:SetFont(smed:Fetch("font", db.font), db.fontsize, db.outlinetime and "OUTLINE" or nil)
		timeText:SetShadowColor(0, 0, 0, db.fontcolor.a)
		timeText:SetShadowOffset(1, -1)
		timeText:SetTextColor(db.fontcolor.r, db.fontcolor.g, db.fontcolor.b, db.fontcolor.a)

		if db.inline then
			timeText:SetJustifyH("CENTER")
			timeText:SetJustifyV("MIDDLE")
			SetPoints(timeText, "RIGHT", sb, "RIGHT", -4, 0)
			locText:SetJustifyH("LEFT")
			locText:SetJustifyV("MIDDLE")
			SetPoints(locText, "LEFT", sb, "LEFT", 4, 0, "RIGHT", timeText, "LEFT", -2, 0)
			locText:SetText(taxiDstName or "??")
		elseif db.twolines then
			timeText:SetJustifyH("CENTER")
			timeText:SetJustifyV("MIDDLE")
			SetPoints(timeText, "MIDDLE", sb, "CENTER", 0, 0)
			locText:SetJustifyH("CENTER")
			locText:SetJustifyV("bottom")
			SetPoints(locText, "TOPLEFT", sb, "TOPLEFT", -24, db.fontsize*2.5, "BOTTOMRIGHT", sb, "TOPRIGHT", 24, (db.border=="None" and 1) or 3)
			locText:SetFormattedText("%s %s\n%s", taxiSrcName or "??", db.totext, taxiDstName or "??")
		else
			timeText:SetJustifyH("CENTER")
			timeText:SetJustifyV("MIDDLE")
			SetPoints(timeText, "CENTER", sb, "CENTER", 0, 0)
			locText:SetJustifyH("CENTER")
			locText:SetJustifyV("BOTTOM")
			SetPoints(locText, "TOPLEFT", sb, "TOPLEFT", -24, db.fontsize*2.5, "BOTTOMRIGHT", sb, "TOPRIGHT", 24, (db.border=="None" and 1) or 3)
			locText:SetFormattedText("%s %s %s", taxiSrcName or "??", db.totext, taxiDstName or "??")
		end
	end
end

---------------------------------
function InFlight:SetLayout(this)  -- setups the options in the default interface options
---------------------------------
	local t1 = this:CreateFontString(nil, "ARTWORK")
	t1:SetFontObject(GameFontNormalLarge)
	t1:SetJustifyH("LEFT")
	t1:SetJustifyV("TOP")
	t1:SetPoint("TOPLEFT", 16, -16)
	t1:SetText("|cff0040ffIn|cff00aaffFlight|r")
	this.tl = t1

	local t2 = this:CreateFontString(nil, "ARTWORK")
	t2:SetFontObject(GameFontHighlight)
	t2:SetJustifyH("LEFT")
	t2:SetJustifyV("TOP")
	SetPoints(t2, "TOPLEFT", t1, "BOTTOMLEFT", 0, -8, "RIGHT", this, "RIGHT", -32, 0)
	t2:SetNonSpaceWrap(true)
	local function GetInfo(field)
		return GetAddOnMetadata("InFlight", field) or "N/A"
	end

	t2:SetFormattedText("|cff00aaffAuthor:|r %s\n|cff00aaffVersion:|r %s\n\n%s|r", GetInfo("Author"), GetInfo("Version"), GetInfo("Notes"))

	local b = CreateFrame("Button", nil, this, "UIPanelButtonTemplate")
	b:SetText(_G.GAMEOPTIONS_MENU)
	b:SetWidth(max(120, b:GetTextWidth() + 20))
	b:SetScript("OnClick", InFlight.ShowOptions)
	b:SetPoint("TOPLEFT", t2, "BOTTOMLEFT", -2, -8)

	this:SetScript("OnShow", nil)

	self.SetLayout = nil
end

-- options table
smed:Register("border", "Textured", "\\Interface\\None")  -- dummy border
local InFlightDD, offsetvalue, offsetcount, lastb
local info = { }
-------------------------------
function InFlight.ShowOptions()
-------------------------------
	if not InFlightDD then
		InFlightDD = CreateFrame("Frame", "InFlightDD", InFlight)
		InFlightDD.displayMode = "MENU"

		hooksecurefunc("ToggleDropDownMenu", function(...) lastb = select(8, ...) end)
		local function Exec(b, k, value)
			if k == "totext" then
				StaticPopupDialogs["InFlightToText"] = StaticPopupDialogs["InFlightToText"] or {
					text = L["Enter your 'to' text."],
					button1 = ACCEPT, button2 = CANCEL,
					hasEditBox = 1, maxLetters = 12,
					OnAccept = function(self)
						db.totext = strtrim(self.editBox:GetText())
						InFlight:UpdateLook()
					end,

					OnShow = function(self)
						self.editBox:SetText(db.totext)
						self.editBox:SetFocus()
					end,

					OnHide = function(self)
						self.editBox:SetText("")
					end,

					EditBoxOnEnterPressed = function(self)
						local parent = self:GetParent()
						db.totext = strtrim(parent.editBox:GetText())
						parent:Hide()
						InFlight:UpdateLook()
					end,

					EditBoxOnEscapePressed = function(self)
						self:GetParent():Hide()
					end,

					timeout = 0, exclusive = 1, whileDead = 1, hideOnEscape = 1,
				}
				StaticPopup_Show("InFlightToText")
			elseif (k == "less" or k == "more") and lastb then
				local off = (k == "less" and -8) or 8
				if offsetvalue == value then
					offsetcount = offsetcount + off
				else
					offsetvalue, offsetcount = value, off
				end

				local tb = _G[gsub(lastb:GetName(), "ExpandArrow", "")]
				CloseDropDownMenus(b:GetParent():GetID())
				ToggleDropDownMenu(b:GetParent():GetID(), tb.value, nil, nil, nil, nil, tb.menuList, tb)
			elseif k == "resetoptions" then
				self.db:ResetProfile()
				if self.db:GetCurrentProfile() ~= "Default" then
					db.perchar = true
				end
			elseif k == "resettimes" then
				InFlightDB.dbinit = nil
				InFlightDB.global = {}
				ReloadUI()
			end
		end

		local function Set(b, k)
			if not k then
				return
			end

			db[k] = not db[k]
			if k == "perchar" then
				local charKey = UnitName("player").." - "..GetRealmName()
				if db[k] then
					db[k] = false
					self.db:SetProfile(charKey)
					self.db:CopyProfile("Default")
					db = self.db.profile
					db[k] = true
				else
					self.db:SetProfile("Default")
					db = self.db.profile
					self.db:DeleteProfile(charKey)
				end
			end

			InFlight:UpdateLook()
		end

		local function SetSelect(b, a1)
			db[a1] = tonumber(b.value) or b.value
			local level, num = strmatch(b:GetName(), "DropDownList(%d+)Button(%d+)")
			level, num = tonumber(level) or 0, tonumber(num) or 0
			for i = 1, UIDROPDOWNMENU_MAXBUTTONS, 1 do
				local b = _G["DropDownList"..level.."Button"..i.."Check"]
				if b then
					b[i == num and "Show" or "Hide"](b)
				end
			end

			InFlight:UpdateLook()
		end

		local function SetColor(a1)
			local dbc = db[UIDROPDOWNMENU_MENU_VALUE]
			if not dbc then
				return
			end

			if a1 then
				local pv = ColorPickerFrame.previousValues
				dbc.r, dbc.g, dbc.b, dbc.a = pv.r, pv.g, pv.b, 1 - pv.opacity
			else
				dbc.r, dbc.g, dbc.b = ColorPickerFrame:GetColorRGB()
				dbc.a = 1 - OpacitySliderFrame:GetValue()
			end

			InFlight:UpdateLook()
		end

		local function AddButton(lvl, text, keepshown)
			info.text = text
			info.keepShownOnClick = keepshown
			UIDropDownMenu_AddButton(info, lvl)
			wipe(info)
		end

		local function AddToggle(lvl, text, value)
			info.arg1 = value
			info.func = Set
			info.checked = db[value]
			info.isNotRadio = true
			AddButton(lvl, text, true)
		end

		local function AddExecute(lvl, text, arg1, arg2)
			info.arg1 = arg1
			info.arg2 = arg2
			info.func = Exec
			info.notCheckable = 1
			AddButton(lvl, text, true)
		end

		local function AddColor(lvl, text, value)
			local dbc = db[value]
			if not dbc then
				return
			end

			info.hasColorSwatch = true
			info.padding = 5
			info.hasOpacity = 1
			info.r, info.g, info.b, info.opacity = dbc.r, dbc.g, dbc.b, 1 - dbc.a
			info.swatchFunc, info.opacityFunc, info.cancelFunc = SetColor, SetColor, SetColor
			info.value = value
			info.notCheckable = 1
			info.func = UIDropDownMenuButton_OpenColorPicker
			AddButton(lvl, text)
		end

		local function AddList(lvl, text, value)
			info.value = value
			info.hasArrow = true
			info.notCheckable = 1
			AddButton(lvl, text, true)
		end

		local function AddSelect(lvl, text, arg1, value)
			info.arg1 = arg1
			info.func = SetSelect
			info.value = value
			if tonumber(value) and tonumber(db[arg1] or "blah") then
				if floor(100 * tonumber(value)) == floor(100 * tonumber(db[arg1])) then
					info.checked = true
				end
			else
				info.checked = (db[arg1] == value)
			end

			AddButton(lvl, text, true)
		end

		local function AddFakeSlider(lvl, value, minv, maxv, step, tbl)
			local cvalue = 0
			local dbv = db[value]
			if type(dbv) == "string" and tbl then
				for i, v in ipairs(tbl) do
					if dbv == v then
						cvalue = i
						break
					end
				end
			else
				cvalue = dbv or ((maxv - minv) / 2)
			end

			local adj = (offsetvalue == value and offsetcount) or 0
			local starti = max(minv, cvalue - (7 - adj) * step)
			local endi = min(maxv, cvalue + (8 + adj) * step)
			if starti == minv then
				endi = min(maxv, starti + 16 * step)
			elseif endi == maxv then
				starti = max(minv, endi - 16 * step)
			end

			if starti > minv then
				AddExecute(lvl, "--", "less", value)
			end

			if tbl then
				for i = starti, endi, step do
					AddSelect(lvl, tbl[i], value, tbl[i])
				end
			else
				local fstring = (step >= 1 and "%d") or (step >= 0.1 and "%.1f") or "%.2f"
				for i = starti, endi, step do
					AddSelect(lvl, format(fstring, i), value, i)
				end
			end

			if endi < maxv then
				AddExecute(lvl, "++", "more", value)
			end
		end

		InFlightDD.initialize = function(self, lvl)
			if lvl == 1 then
				info.isTitle = true
				info.notCheckable = 1
				AddButton(lvl, "|cff0040ffIn|cff00aaffFlight|r")
				AddList(lvl, L["BarOptions"], "frame")
				AddList(lvl, L["TextOptions"], "text")
				AddList(lvl, _G.OTHER, "other")
			elseif lvl == 2 then
				local sub = UIDROPDOWNMENU_MENU_VALUE
				if sub == "frame" then
					AddToggle(lvl, L["CountUp"], "countup")
					AddToggle(lvl, L["FillUp"], "fill")
					AddToggle(lvl, L["ShowSpark"], "spark")
					AddList(lvl, L["Height"], "height")
					AddList(lvl, L["Width"], "width")
					AddList(lvl, L["Texture"], "texture")
					AddList(lvl, L["Border"], "border")
					AddColor(lvl, L["BackgroundColor"], "backcolor")
					AddColor(lvl, L["BarColor"], "barcolor")
					AddColor(lvl, L["UnknownColor"], "unknowncolor")
					AddColor(lvl, L["BorderColor"], "bordercolor")
				elseif sub == "text" then
					AddToggle(lvl, L["CompactMode"], "inline")
					AddToggle(lvl, L["TwoLines"], "twolines")
					AddExecute(lvl, L["ToText"], "totext")
					AddList(lvl, L["Font"], "font")
					AddList(lvl, _G.FONT_SIZE, "fontsize")
					AddColor(lvl, L["FontColor"], "fontcolor")
					AddToggle(lvl, L["OutlineInfo"], "outline")
					AddToggle(lvl, L["OutlineTime"], "outlinetime")
				elseif sub == "other" then
					AddToggle(lvl, L["ShowChat"], "chatlog")
					AddToggle(lvl, L["ConfirmFlight"], "confirmflight")
					AddToggle(lvl, L["PerCharOptions"], "perchar")
					AddExecute(lvl, L["ResetOptions"], "resetoptions")
					AddExecute(lvl, L["ResetFlightTimes"], "resettimes")
				end
			elseif lvl == 3 then
				local sub = UIDROPDOWNMENU_MENU_VALUE
				if sub == "texture" or sub == "border" or sub == "font" then
					local t = smed:List(sub == "texture" and "statusbar" or sub)
					AddFakeSlider(lvl, sub, 1, #t, 1, t)
				elseif sub == "width" then
					AddFakeSlider(lvl, sub, 40, 500, 5)
				elseif sub == "height" then
					AddFakeSlider(lvl, sub, 4, 100, 1)
				elseif sub == "fontsize" then
					AddFakeSlider(lvl, sub, 4, 30, 1)
				end
			end
		end
	end

	ToggleDropDownMenu(1, nil, InFlightDD, "cursor")
end

if debug then

-- /run inflightupdate(false)
-- Set updateExistingTimes to true to update and add new times (for updates based
--   on the current default db)
-- Set updateExistingTimes to false to only add new unknown times (use for updates
--   not based on current default db to avoid re-adding old/incorrect times)
-- Set updateExistingTimes to nil to update and add new times from your own data
function inflightupdate(updateExistingTimes)
	local updates = {}
	local ownData = false
	if #updates == 0 then
		updates[1] = InFlightDB.global
		ownData = true
	end
	local defaults = self.defaults.global
	for _, flightPaths in ipairs(updates) do
		if updateExistingTimes == nil then
			updateExistingTimes = ownData
		end

		for faction, t in pairs(flightPaths) do
			if faction == "Horde" or faction == "Alliance" then
				local found = false
				local updated, added = 0, 0
				for src, dt in pairs(t) do
					if not defaults[faction][src] then
						defaults[faction][src] = {}
						PrintD(faction, "|cff208020New flightpoint:|r", src)
					end

					for dst, utime in pairs(dt) do
						if src ~= dst and type(utime) == "number" then
							local vtime = defaults[faction][src][dst]
							if utime >= 5 and (not vtime or ownData or abs(vtime - utime) >= 5) then
								if vtime then
									if updateExistingTimes and defaults[faction][src][dst] ~= utime then
										defaults[faction][src][dst] = utime
										found = true
										updated = updated + 1
										PrintD(faction, "|cff00aaffupdated:|r", src, "|cff208020-->|r", dst, "|cff208020- old:|r", vtime, "|cff208020new:|r", utime)
									end
								else
									defaults[faction][src][dst] = utime
									found = true
									added = added + 1
									PrintD(faction, "|cff00ff40   added:|r", src, "|cff208020-->|r", dst, "|cff208020- new:|r", utime)
								end
							end
						end
					end
				end

				if found then
					PrintD(faction, "|cff208020-|r", updated, "|cff00aaffupdated times.|r")
					PrintD(faction, "|cff208020-|r", added, "|cff00ff40new times.|r")
				else
					PrintD(faction, "|cff208020-|r No time updates found.")
				end
			else
				defaults[faction] = nil
				PrintD("Unknown faction removed:", faction)
			end
		end

		InFlightDB.defaults = defaults
	end
end

end -- debug
