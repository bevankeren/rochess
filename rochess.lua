--!nocheck
--[[
	BeverlyHub v1.5.1 — RoChess!
	Hybrid Chess Engine (Stockfish 19 VPS + Cloud + Independent Offline Luau Engine)
	Board Arrow Overlay, Live Analysis, Dynamic Auto-Adapt Strength & Safe Auto Play
]]

if not game:IsLoaded() then
	pcall(function()
		game.Loaded:Wait()
	end)
end

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local GuiService = game:GetService("GuiService")
local TweenService = game:GetService("TweenService")
local HttpService = game:GetService("HttpService")
local AssetService = game:GetService("AssetService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CoreGui = game:GetService("CoreGui")

local LocalPlayer = Players.LocalPlayer or Players.PlayerAdded:Wait()

-- Clean up previous instance on re-execution
local globalEnv = (type(getgenv) == "function" and getgenv()) or _G
if type(globalEnv.__RoChessHubCleanup) == "function" then
	pcall(globalEnv.__RoChessHubCleanup)
end

local LIB_BASE = "https://raw.githubusercontent.com/bevankeren/BeverlyLIB/main/"
local REMOTE_SCRIPT_URL = "https://raw.githubusercontent.com/bevankeren/rochess/main/rochess.lua"
local HUB_VERSION = "1.5.1"

-- ============================================================================
-- 1. CONFIGURATION & RUNTIME STATE
-- ============================================================================
local CONFIG = {
	Enabled = true,
	EngineMode = "Hybrid", -- "Hybrid" | "Stockfish" | "Luau" | "LocalWS"
	PlayStyle = "GM", -- "Full" | "SuperGM" | "GM" | "Master"
	AutoAdapt = true, -- Dynamic Auto-Adapt Strength against strong/engine opponents or worse evals
	StockfishDepth = 15, -- 8..18 (VPS SF19 supports up to 18; stockfish.online clamps to 15)
	LuauMaxDepth = 6, -- 3..8
	LuauTimeBudget = 0.55, -- seconds
	VpsApiUrl = "https://recipes-est-bowl-ones.trycloudflare.com",
	VpsApiKey = "bh_sf19_rochess_7c9a4e2f",
	LocalWsUrl = "ws://127.0.0.1:8765",
	ShowArrows = true,
	ShowPonder = true,
	ShowHighlights = true,
	ShowEvalBar = true,
	ShowEngineBadge = true,
	ArrowColor = Color3.fromRGB(56, 217, 169),
	OnlyMyTurn = true,
	PuzzleHelper = true,
	AntiEngineTurbo = true, -- Auto-detect engine opponent + ponder prefetch + fast mode
	AutoPlay = false, -- OFF by default
	AutoDelayMin = 1.0, -- seconds (middlegame base min)
	AutoDelayMax = 5.0, -- seconds (middlegame base max)
	SmartDelay = true, -- Fast opening & endgame, complexity middlegame, clock-aware cap
	FastOpeningMoves = 5, -- First N full moves play fast
	EndgamePieces = 10, -- Speed up when total pieces on board <= N
	MaxClockLead = 30, -- Max seconds ahead of opponent clock before naturally slowing down (0 = off)
	AutoFindMatch = false, -- OFF by default
	AutoFindTc = "Selected", -- "Selected" or TC id ("1+0", "3+2", etc.)
	AutoReloadOnTeleport = true, -- Re-queue loader automatically on cross-server match teleports
}

local STATE = {
	Alive = true,
	Connections = {},
	App = nil,
	Board = nil,
	LastSessionRef = nil,
	LastSessionId = nil,
	SessionStartedAt = 0,
	LastPageSwitchAt = 0,
	LastKey = "",
	TerminalKey = "",
	SearchGen = 0,
	Searching = false,
	SearchStartedAt = 0,
	ActiveStage = nil, -- "vps" | "cloud" | "luau" | "ws" | nil
	MissingResultSince = 0,
	ActiveEngine = "Ready",
	ActiveEngineKind = "idle", -- "idle" | "thinking" | "vpssf" | "gm" | "stockfish" | "localws" | "luau" | "fallback" | "book" | "puzzle" | "turbo"
	CurrentResult = nil, -- { best, ponder, evalCp, mate, depth, source, ms, pv, san, fromSq, toSq, promo }
	LastMyTurnResult = nil,
	LastEvalCp = nil,
	LastEvalFlip = nil,
	EvalWhiteCp = 0,
	EvalMate = nil,
	LastArrowSig = "",
	LastAutoKey = "",
	AutoGen = 0,
	AutoPending = false,
	AutoPendingAt = 0,
	AutoExpectedWait = 0,
	AutoRetryAfter = 0,
	LastAutoClickAt = 0,
	WindowFocused = true,
	MenuAutoHiddenNotified = false,
	TeleportQueued = false,
	-- Stockfish API health / circuit breakers (independent for VPS & Public Cloud)
	VpsFailStreak = 0,
	VpsCooldownUntil = 0,
	SfFailStreak = 0,
	SfCooldownUntil = 0,
	-- Speculative Ponder Prefetch
	PrefetchKey = "",
	PrefetchFen4 = "",
	PrefetchGen = 0,
	PrefetchDone = nil, -- { done = false, res = nil, fen4 = "", cacheKey = "", gen = 0 }
	-- Opponent Engine Detector, Clock Pressure & Dynamic Auto-Adapt state
	Opp = {
		gameId = nil,
		lastPly = -1,
		oppTurnStartAt = 0,
		baseMs = nil,
		incMs = 0,
		expectedByPly = {}, -- [ply] = { uci, myUci, myCapture, myToSq, oppFen, source }
		checked = 0,
		hits = 0,
		streak = 0,
		maxStreak = 0,
		fastHits = 0,
		blunders = 0,
		blunderPenalty = 0,
		lastEvalForMe = nil,
		lastEvalSource = nil,
		times = {},
		suspicion = 0,
		suspect = false,
		engineDetected = false,
		clockPressure = false,
		turboActive = false,
		turboReason = nil,
		notified = false,
		adaptTier = nil,
		lastAdaptPly = -1,
	},
	-- Auto Find Match state
	AutoFindOverAt = 0,
	AutoFindLastQueueAt = 0,
	Cache = {},
	CacheOrder = {},
	CacheMax = 384,
	WsConn = nil,
}

local function trackConn(conn)
	table.insert(STATE.Connections, conn)
	return conn
end

local httpRequest = request or http_request or (syn and syn.request) or (http and http.request)
local wsLibrary = WebSocket or (syn and syn.websocket)
local queueOnTeleport = queue_on_teleport or queueonteleport or (syn and syn.queue_on_teleport) or (fluxus and fluxus.queue_on_teleport)

local function getTeleportLoaderSource()
	if type(globalEnv.__RoChessLoader) == "string" and globalEnv.__RoChessLoader ~= "" then
		return globalEnv.__RoChessLoader
	end
	if type(isfile) == "function" then
		local okF, exists = pcall(isfile, "BeverlyHub/rochess.lua")
		if okF and exists then
			return 'loadstring(readfile("BeverlyHub/rochess.lua"))()'
		end
	end
	return 'loadstring(game:HttpGet("' .. REMOTE_SCRIPT_URL .. '"))()'
end

-- ============================================================================
-- 2. INDEPENDENT PURE LUAU CHESS ENGINE (ZERO DEPENDENCY ON GAME'S Chess.Bot)
-- ============================================================================
local PureChess = {}
do
	local band = bit32.band
	local bxor = bit32.bxor
	local extract = bit32.extract
	local abs = math.abs
	local floor = math.floor

	local EMPTY, PAWN, KNIGHT, BISHOP, ROOK, QUEEN, KING, OFF = 0, 1, 2, 3, 4, 5, 6, 7
	local F_NONE, F_DOUBLE, F_EP, F_OO, F_OOO = 0, 1, 2, 3, 4
	local MATE = 30000
	local INF = 32000

	local KNIGHT_DIRS = { -21, -19, -12, -8, 8, 12, 19, 21 }
	local BISHOP_DIRS = { -11, -9, 9, 11 }
	local ROOK_DIRS = { -10, -1, 1, 10 }
	local KING_DIRS = { -11, -10, -9, -1, 1, 9, 10, 11 }
	local FILES = { "a", "b", "c", "d", "e", "f", "g", "h" }
	local PIECE_LOWER = { "p", "n", "b", "r", "q", "k" }
	local SAN_LETTER = { "", "N", "B", "R", "Q", "K" }
	local CHAR_TO_PIECE = { p = 1, n = 2, b = 3, r = 4, q = 5, k = 6 }

	local SQUARES = table.create(64, 0)
	local SQ64 = table.create(120, 0)
	local PST_IDX_W = table.create(120, 1)
	local PST_IDX_B = table.create(120, 1)
	for rank = 0, 7 do
		for file = 0, 7 do
			local idx64 = rank * 8 + file + 1
			local sq = 22 + file + rank * 10
			SQUARES[idx64] = sq
			SQ64[sq] = idx64
			PST_IDX_W[sq] = (7 - rank) * 8 + file + 1
			PST_IDX_B[sq] = rank * 8 + file + 1
		end
	end

	local CASTLE_MASK = table.create(120, 15)
	CASTLE_MASK[22] = 13 -- a1
	CASTLE_MASK[26] = 12 -- e1
	CASTLE_MASK[29] = 14 -- h1
	CASTLE_MASK[92] = 7 -- a8
	CASTLE_MASK[96] = 3 -- e8
	CASTLE_MASK[99] = 11 -- h8

	-- Zobrist Keys (deterministic)
	local zRng = Random.new(20261125)
	local Z_PC1 = table.create(13 * 120, 0)
	local Z_PC2 = table.create(13 * 120, 0)
	for p = -6, 6 do
		for sq = 1, 120 do
			local k = (p + 6) * 120 + sq
			Z_PC1[k] = zRng:NextInteger(0, 2147483647)
			Z_PC2[k] = zRng:NextInteger(0, 2147483647)
		end
	end
	local Z_SIDE1 = zRng:NextInteger(0, 2147483647)
	local Z_SIDE2 = zRng:NextInteger(0, 2147483647)
	local Z_CASTLE1, Z_CASTLE2 = {}, {}
	for c = 0, 15 do
		Z_CASTLE1[c] = zRng:NextInteger(0, 2147483647)
		Z_CASTLE2[c] = zRng:NextInteger(0, 2147483647)
	end
	local Z_EP1, Z_EP2 = {}, {}
	for f = 0, 7 do
		Z_EP1[f] = zRng:NextInteger(0, 2147483647)
		Z_EP2[f] = zRng:NextInteger(0, 2147483647)
	end

	-- PeSTO Tapered Evaluation Tables (MG & EG, a8=1 .. h1=64)
	local MG_VAL = { 82, 337, 365, 477, 1025, 0 }
	local EG_VAL = { 94, 281, 297, 512, 936, 0 }
	local PHASE_W = { 0, 1, 1, 2, 4, 0 }
	local MVV_VAL = { 100, 320, 330, 500, 900, 20000 }

	local MG_PST = {
		{ -- Pawn
			0,0,0,0,0,0,0,0, 98,134,61,95,68,126,34,-11, -6,7,26,31,65,56,25,-20, -14,13,6,21,23,12,17,-23,
			-27,-2,-5,12,17,6,10,-25, -26,-4,-4,-10,3,3,33,-12, -35,-1,-20,-23,-15,24,38,-22, 0,0,0,0,0,0,0,0,
		},
		{ -- Knight
			-167,-89,-34,-49,61,-97,-15,-107, -73,-41,72,36,23,62,7,-17, -47,60,37,65,84,129,73,44, -9,17,19,53,37,69,18,22,
			-13,4,16,13,28,19,21,-8, -23,-9,12,10,19,17,25,-16, -29,-53,-12,-3,-1,18,-14,-19, -105,-21,-58,-33,-17,-28,-19,-23,
		},
		{ -- Bishop
			-29,4,-82,-37,-25,-42,7,-8, -26,16,-18,-13,30,59,18,-47, -16,37,43,40,35,50,37,-2, -4,5,19,50,37,37,7,-2,
			-6,13,13,26,34,12,10,4, 0,15,15,15,14,27,18,10, 4,15,16,0,7,21,33,1, -33,-3,-14,-21,-13,-12,-39,-21,
		},
		{ -- Rook
			32,42,32,51,63,9,31,43, 27,32,58,62,80,67,26,44, -5,19,26,36,17,45,61,16, -24,-11,7,26,24,35,-8,-20,
			-36,-26,-12,-1,9,-7,6,-23, -45,-25,-16,-17,3,0,-5,-33, -44,-16,-20,-9,-1,11,-6,-71, -19,-13,1,17,16,7,-37,-26,
		},
		{ -- Queen
			-28,0,29,12,59,44,43,45, -24,-39,-5,1,-16,57,28,54, -13,-17,7,8,29,56,47,57, -27,-27,-16,-16,-1,17,-2,1,
			-9,-26,-9,-10,-2,-4,3,-3, -14,2,-11,-2,-5,2,14,5, -35,-8,11,2,8,15,-3,1, -1,-18,-9,10,-15,-25,-31,-50,
		},
		{ -- King
			-65,23,16,-15,-56,-34,2,13, 29,-1,-20,-7,-8,-4,-38,-29, -9,24,2,-16,-20,6,22,-22, -17,-20,-12,-27,-30,-25,-14,-36,
			-49,-1,-27,-39,-46,-44,-33,-51, -14,-14,-22,-46,-44,-30,-15,-27, 1,7,-8,-64,-43,-16,9,8, -15,36,12,-54,8,-28,24,14,
		},
	}

	local EG_PST = {
		{ -- Pawn
			0,0,0,0,0,0,0,0, 178,173,158,134,147,132,165,187, 94,100,85,67,56,53,82,84, 32,24,13,5,-2,4,17,17,
			13,9,-3,-7,-7,-8,3,-1, 4,7,-6,1,0,-5,-1,-8, 13,8,8,10,13,0,2,-7, 0,0,0,0,0,0,0,0,
		},
		{ -- Knight
			-58,-38,-13,-28,-31,-27,-63,-99, -25,-8,-25,-2,-9,-25,-24,-52, -24,-20,10,9,-1,-9,-19,-41, -17,3,22,22,22,11,8,-18,
			-18,-6,16,25,16,17,4,-18, -23,-3,-1,15,10,-3,-20,-22, -42,-20,-10,-5,-2,-20,-23,-44, -29,-51,-23,-15,-22,-18,-50,-64,
		},
		{ -- Bishop
			-14,-21,-11,-8,-7,-9,-17,-24, -8,-4,7,-12,-3,-13,-4,-14, 2,-8,0,-1,-2,6,0,4, -3,9,12,9,14,10,3,2,
			-6,3,13,19,7,10,-3,-9, -12,-3,8,10,13,3,-7,-15, -14,-18,-7,-1,4,-9,-15,-27, -23,-9,-23,-5,-9,-16,-5,-17,
		},
		{ -- Rook
			13,10,18,15,12,12,8,5, 11,13,13,11,-3,3,8,3, 7,7,7,5,4,-3,-5,-3, 4,3,13,1,2,1,-1,2,
			3,5,8,4,-5,-6,-8,-11, -4,0,-5,-1,-7,-12,-8,-16, -6,-6,0,2,-9,-9,-11,-3, -9,2,3,-1,-5,-13,4,-20,
		},
		{ -- Queen
			-9,22,22,27,27,19,10,20, -17,20,32,41,58,25,30,0, -20,6,9,49,47,35,19,9, 3,22,24,45,57,40,57,36,
			-18,28,19,47,31,34,39,23, -16,-27,15,6,9,17,10,5, -22,-23,-30,-16,-16,-23,-36,-32, -33,-28,-22,-43,-5,-32,-20,-41,
		},
		{ -- King
			-74,-35,-18,-18,-11,15,4,-17, -12,17,14,17,17,38,23,11, 10,17,23,15,20,45,44,13, -8,22,24,27,26,33,26,3,
			-18,-4,21,24,27,23,9,-11, -19,-3,11,21,23,16,7,-9, -27,-11,4,13,14,4,-5,-17, -53,-34,-21,-11,-28,-14,-24,-43,
		},
	}

	-- Compact Opening Book (4-field FEN -> { uci, ... })
	local BOOK = {
		["rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq -"] = { "e2e4", "d2d4", "g1f3", "c2c4" },
		["rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq -"] = { "e7e5", "c7c5", "e7e6", "c7c6" },
		["rnbqkbnr/pppppppp/8/8/3P4/8/PPP1PPPP/RNBQKBNR b KQkq -"] = { "d7d5", "g8f6", "e7e6" },
		["rnbqkbnr/pppp1ppp/8/4p3/4P3/8/PPPP1PPP/RNBQKBNR w KQkq -"] = { "g1f3" },
		["rnbqkbnr/pppp1ppp/8/4p3/4P3/5N2/PPPP1PPP/RNBQKB1R b KQkq -"] = { "b8c6", "g8f6" },
		["r1bqkbnr/pppp1ppp/2n5/4p3/4P3/5N2/PPPP1PPP/RNBQKB1R w KQkq -"] = { "f1b5", "f1c4", "d2d4" },
		["r1bqkbnr/pppp1ppp/2n5/1B2p3/4P3/5N2/PPPP1PPP/RNBQK2R b KQkq -"] = { "a7a6", "g8f6" },
		["r1bqkbnr/pppp1ppp/2n5/4p3/2B1P3/5N2/PPPP1PPP/RNBQK2R b KQkq -"] = { "f8c5", "g8f6" },
		["rnbqkbnr/pp1ppppp/8/2p5/4P3/8/PPPP1PPP/RNBQKBNR w KQkq -"] = { "g1f3", "b1c3" },
		["rnbqkbnr/pp1ppppp/8/2p5/4P3/5N2/PPPP1PPP/RNBQKB1R b KQkq -"] = { "d7d6", "b8c6", "e7e6" },
		["rnbqkbnr/ppp1pppp/8/3p4/3P4/8/PPP1PPPP/RNBQKBNR w KQkq -"] = { "c2c4", "g1f3", "c1f4" },
		["rnbqkbnr/ppp1pppp/8/3p4/2PP4/8/PP2PPPP/RNBQKBNR b KQkq -"] = { "e7e6", "c7c6" },
		["rnbqkb1r/pppppppp/5n2/8/3P4/8/PPP1PPPP/RNBQKBNR w KQkq -"] = { "c2c4", "g1f3", "c1f4" },
		["rnbqkbnr/pppp1ppp/4p3/8/4P3/8/PPPP1PPP/RNBQKBNR w KQkq -"] = { "d2d4" },
		["rnbqkbnr/pp1ppppp/2p5/8/4P3/8/PPPP1PPP/RNBQKBNR w KQkq -"] = { "d2d4" },
	}

	local function encodeMove(fromSq, toSq, promo, flag)
		return fromSq + toSq * 128 + promo * 16384 + flag * 131072
	end

	function PureChess.sqToAlg(sq)
		return FILES[(sq - 2) % 10 + 1] .. tostring((sq - 22) // 10 + 1)
	end

	function PureChess.algToSq(alg)
		if type(alg) ~= "string" or #alg ~= 2 then
			return nil
		end
		local f = string.byte(alg, 1) - 97
		local r = string.byte(alg, 2) - 49
		if f < 0 or f > 7 or r < 0 or r > 7 then
			return nil
		end
		return 22 + f + r * 10
	end

	function PureChess.algToIndex64(alg)
		local sq = PureChess.algToSq(alg)
		return sq and SQ64[sq] or nil
	end

	function PureChess.index64ToAlg(idx64)
		local sq = SQUARES[idx64]
		return sq and PureChess.sqToAlg(sq) or nil
	end

	function PureChess.moveToUci(m)
		local fromSq = band(m, 127)
		local toSq = extract(m, 7, 7)
		local promo = extract(m, 14, 3)
		local s = PureChess.sqToAlg(fromSq) .. PureChess.sqToAlg(toSq)
		if promo ~= 0 then
			s = s .. PIECE_LOWER[promo]
		end
		return s
	end

	local Board = {}
	Board.__index = Board

	function PureChess.new(fen)
		local self = setmetatable({
			board = table.create(120, OFF),
			kingSq = { [1] = 26, [-1] = 96 },
			side = 1,
			castling = 0,
			ep = 0,
			halfmove = 0,
			fullmove = 1,
			ply = 0,
			h1 = 0,
			h2 = 0,
			uMove = {},
			uCap = {},
			uCastle = {},
			uEp = {},
			uHalf = {},
			uH1 = {},
			uH2 = {},
			posH1 = {},
			posH2 = {},
		}, Board)
		self:loadFen(fen or "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1")
		return self
	end

	function Board:computeHash()
		local h1, h2 = 0, 0
		local b = self.board
		for i = 1, 64 do
			local sq = SQUARES[i]
			local pc = b[sq]
			if pc ~= 0 then
				local k = (pc + 6) * 120 + sq
				h1 = bxor(h1, Z_PC1[k])
				h2 = bxor(h2, Z_PC2[k])
			end
		end
		if self.side == -1 then
			h1 = bxor(h1, Z_SIDE1)
			h2 = bxor(h2, Z_SIDE2)
		end
		h1 = bxor(h1, Z_CASTLE1[self.castling])
		h2 = bxor(h2, Z_CASTLE2[self.castling])
		if self.ep ~= 0 then
			local f = (self.ep - 2) % 10
			h1 = bxor(h1, Z_EP1[f])
			h2 = bxor(h2, Z_EP2[f])
		end
		self.h1 = h1
		self.h2 = h2
	end

	function Board:loadFen(fen)
		local parts = {}
		for tok in string.gmatch(fen, "%S+") do
			parts[#parts + 1] = tok
		end
		local b = self.board
		for i = 1, 120 do
			b[i] = OFF
		end
		for i = 1, 64 do
			b[SQUARES[i]] = EMPTY
		end
		self.kingSq[1] = 0
		self.kingSq[-1] = 0

		local rank, file = 7, 0
		local placement = parts[1] or ""
		for i = 1, #placement do
			local ch = string.sub(placement, i, i)
			if ch == "/" then
				rank -= 1
				file = 0
			else
				local n = tonumber(ch)
				if n then
					file += n
				else
					local low = string.lower(ch)
					local pt = CHAR_TO_PIECE[low]
					if pt and rank >= 0 and file <= 7 then
						local col = (ch ~= low) and 1 or -1
						local sq = 22 + file + rank * 10
						b[sq] = pt * col
						if pt == KING then
							self.kingSq[col] = sq
						end
					end
					file += 1
				end
			end
		end

		self.side = (parts[2] == "b") and -1 or 1
		local cs = parts[3] or "-"
		local cm = 0
		if string.find(cs, "K", 1, true) and b[26] == KING and b[29] == ROOK then cm += 1 end
		if string.find(cs, "Q", 1, true) and b[26] == KING and b[22] == ROOK then cm += 2 end
		if string.find(cs, "k", 1, true) and b[96] == -KING and b[99] == -ROOK then cm += 4 end
		if string.find(cs, "q", 1, true) and b[96] == -KING and b[92] == -ROOK then cm += 8 end
		self.castling = cm

		local epStr = parts[4]
		self.ep = (epStr and epStr ~= "-") and (PureChess.algToSq(epStr) or 0) or 0
		self.halfmove = tonumber(parts[5]) or 0
		self.fullmove = tonumber(parts[6]) or 1
		self.ply = 0
		self:computeHash()
		self.posH1[0] = self.h1
		self.posH2[0] = self.h2
	end

	function Board:getFen()
		local b = self.board
		local ranks = {}
		for r = 7, 0, -1 do
			local row = ""
			local emp = 0
			for f = 0, 7 do
				local pc = b[22 + f + r * 10]
				if pc == EMPTY then
					emp += 1
				else
					if emp > 0 then
						row ..= tostring(emp)
						emp = 0
					end
					local ch = PIECE_LOWER[abs(pc)]
					row ..= (pc > 0) and string.upper(ch) or ch
				end
			end
			if emp > 0 then
				row ..= tostring(emp)
			end
			ranks[#ranks + 1] = row
		end
		local cs = ""
		if band(self.castling, 1) ~= 0 then cs ..= "K" end
		if band(self.castling, 2) ~= 0 then cs ..= "Q" end
		if band(self.castling, 4) ~= 0 then cs ..= "k" end
		if band(self.castling, 8) ~= 0 then cs ..= "q" end
		if cs == "" then cs = "-" end
		local epStr = (self.ep ~= 0) and PureChess.sqToAlg(self.ep) or "-"
		return table.concat(ranks, "/")
			.. " " .. (self.side == 1 and "w" or "b")
			.. " " .. cs
			.. " " .. epStr
			.. " " .. tostring(self.halfmove)
			.. " " .. tostring(self.fullmove)
	end

	function Board:isAttacked(sq, bySide)
		local b = self.board
		-- Pawns
		if bySide == 1 then
			if b[sq - 9] == 1 or b[sq - 11] == 1 then return true end
		else
			if b[sq + 9] == -1 or b[sq + 11] == -1 then return true end
		end
		-- Knights
		local kn = 2 * bySide
		for i = 1, 8 do
			if b[sq + KNIGHT_DIRS[i]] == kn then return true end
		end
		-- Bishops / Queens
		local bi, qu = 3 * bySide, 5 * bySide
		for i = 1, 4 do
			local dir = BISHOP_DIRS[i]
			local cur = sq + dir
			while true do
				local pc = b[cur]
				if pc ~= 0 then
					if pc == bi or pc == qu then return true end
					break
				end
				cur += dir
			end
		end
		-- Rooks / Queens
		local rk = 4 * bySide
		for i = 1, 4 do
			local dir = ROOK_DIRS[i]
			local cur = sq + dir
			while true do
				local pc = b[cur]
				if pc ~= 0 then
					if pc == rk or pc == qu then return true end
					break
				end
				cur += dir
			end
		end
		-- King
		local kg = 6 * bySide
		for i = 1, 8 do
			if b[sq + KING_DIRS[i]] == kg then return true end
		end
		return false
	end

	function Board:inCheck()
		local ksq = self.kingSq[self.side]
		return ksq ~= 0 and self:isAttacked(ksq, -self.side)
	end

	function Board:genPseudo(out, capturesOnly)
		local n = 0
		local b = self.board
		local side = self.side
		local ep = self.ep

		for i = 1, 64 do
			local sq = SQUARES[i]
			local pc = b[sq]
			if pc ~= 0 and (pc > 0) == (side > 0) then
				local pt = abs(pc)
				if pt == PAWN then
					local dir = side * 10
					local rank = (sq - 22) // 10
					local promoRank = (side == 1) and 6 or 1
					local startRank = (side == 1) and 1 or 6

					-- Captures & EP
					for _, off in { dir - 1, dir + 1 } do
						local toSq = sq + off
						local cap = b[toSq]
						if cap ~= OFF and cap ~= 0 and (cap > 0) ~= (side > 0) then
							if rank == promoRank then
								n += 1; out[n] = encodeMove(sq, toSq, QUEEN, F_NONE)
								n += 1; out[n] = encodeMove(sq, toSq, KNIGHT, F_NONE)
								n += 1; out[n] = encodeMove(sq, toSq, ROOK, F_NONE)
								n += 1; out[n] = encodeMove(sq, toSq, BISHOP, F_NONE)
							else
								n += 1; out[n] = encodeMove(sq, toSq, 0, F_NONE)
							end
						elseif toSq == ep and ep ~= 0 then
							n += 1; out[n] = encodeMove(sq, toSq, 0, F_EP)
						end
					end

					-- Quiet pushes & quiet promotions
					local one = sq + dir
					if b[one] == EMPTY then
						if rank == promoRank then
							n += 1; out[n] = encodeMove(sq, one, QUEEN, F_NONE)
							if not capturesOnly then
								n += 1; out[n] = encodeMove(sq, one, KNIGHT, F_NONE)
								n += 1; out[n] = encodeMove(sq, one, ROOK, F_NONE)
								n += 1; out[n] = encodeMove(sq, one, BISHOP, F_NONE)
							end
						elseif not capturesOnly then
							n += 1; out[n] = encodeMove(sq, one, 0, F_NONE)
							if rank == startRank then
								local two = sq + dir * 2
								if b[two] == EMPTY then
									n += 1; out[n] = encodeMove(sq, two, 0, F_DOUBLE)
								end
							end
						end
					end
				elseif pt == KNIGHT then
					for d = 1, 8 do
						local toSq = sq + KNIGHT_DIRS[d]
						local cap = b[toSq]
						if cap ~= OFF then
							if cap == EMPTY then
								if not capturesOnly then
									n += 1; out[n] = encodeMove(sq, toSq, 0, F_NONE)
								end
							elseif (cap > 0) ~= (side > 0) then
								n += 1; out[n] = encodeMove(sq, toSq, 0, F_NONE)
							end
						end
					end
				elseif pt == KING then
					for d = 1, 8 do
						local toSq = sq + KING_DIRS[d]
						local cap = b[toSq]
						if cap ~= OFF then
							if cap == EMPTY then
								if not capturesOnly then
									n += 1; out[n] = encodeMove(sq, toSq, 0, F_NONE)
								end
							elseif (cap > 0) ~= (side > 0) then
								n += 1; out[n] = encodeMove(sq, toSq, 0, F_NONE)
							end
						end
					end
					-- Castling
					if not capturesOnly then
						local cs = self.castling
						if side == 1 and sq == 26 then
							if band(cs, 1) ~= 0 and b[27] == EMPTY and b[28] == EMPTY and b[29] == ROOK then
								if not self:isAttacked(26, -1) and not self:isAttacked(27, -1) and not self:isAttacked(28, -1) then
									n += 1; out[n] = encodeMove(26, 28, 0, F_OO)
								end
							end
							if band(cs, 2) ~= 0 and b[25] == EMPTY and b[24] == EMPTY and b[23] == EMPTY and b[22] == ROOK then
								if not self:isAttacked(26, -1) and not self:isAttacked(25, -1) and not self:isAttacked(24, -1) then
									n += 1; out[n] = encodeMove(26, 24, 0, F_OOO)
								end
							end
						elseif side == -1 and sq == 96 then
							if band(cs, 4) ~= 0 and b[97] == EMPTY and b[98] == EMPTY and b[99] == -ROOK then
								if not self:isAttacked(96, 1) and not self:isAttacked(97, 1) and not self:isAttacked(98, 1) then
									n += 1; out[n] = encodeMove(96, 98, 0, F_OO)
								end
							end
							if band(cs, 8) ~= 0 and b[95] == EMPTY and b[94] == EMPTY and b[93] == EMPTY and b[92] == -ROOK then
								if not self:isAttacked(96, 1) and not self:isAttacked(95, 1) and not self:isAttacked(94, 1) then
									n += 1; out[n] = encodeMove(96, 94, 0, F_OOO)
								end
							end
						end
					end
				else
					-- Sliders: Bishop (3), Rook (4), Queen (5)
					if pt == BISHOP or pt == QUEEN then
						for d = 1, 4 do
							local dir = BISHOP_DIRS[d]
							local toSq = sq + dir
							while true do
								local cap = b[toSq]
								if cap == EMPTY then
									if not capturesOnly then
										n += 1; out[n] = encodeMove(sq, toSq, 0, F_NONE)
									end
								else
									if cap ~= OFF and (cap > 0) ~= (side > 0) then
										n += 1; out[n] = encodeMove(sq, toSq, 0, F_NONE)
									end
									break
								end
								toSq += dir
							end
						end
					end
					if pt == ROOK or pt == QUEEN then
						for d = 1, 4 do
							local dir = ROOK_DIRS[d]
							local toSq = sq + dir
							while true do
								local cap = b[toSq]
								if cap == EMPTY then
									if not capturesOnly then
										n += 1; out[n] = encodeMove(sq, toSq, 0, F_NONE)
									end
								else
									if cap ~= OFF and (cap > 0) ~= (side > 0) then
										n += 1; out[n] = encodeMove(sq, toSq, 0, F_NONE)
									end
									break
								end
								toSq += dir
							end
						end
					end
				end
			end
		end
		return n
	end

	function Board:makeMove(m)
		local b = self.board
		local side = self.side
		local fromSq = band(m, 127)
		local toSq = extract(m, 7, 7)
		local promo = extract(m, 14, 3)
		local flag = extract(m, 17, 3)

		local ply = self.ply + 1
		self.ply = ply
		self.uMove[ply] = m
		local cap = b[toSq]
		self.uCap[ply] = cap
		self.uCastle[ply] = self.castling
		self.uEp[ply] = self.ep
		self.uHalf[ply] = self.halfmove
		self.uH1[ply] = self.h1
		self.uH2[ply] = self.h2

		local h1, h2 = self.h1, self.h2
		if self.ep ~= 0 then
			local f = (self.ep - 2) % 10
			h1 = bxor(h1, Z_EP1[f])
			h2 = bxor(h2, Z_EP2[f])
			self.ep = 0
		end
		h1 = bxor(h1, Z_CASTLE1[self.castling])
		h2 = bxor(h2, Z_CASTLE2[self.castling])

		local pc = b[fromSq]
		local kFrom = (pc + 6) * 120 + fromSq
		h1 = bxor(h1, Z_PC1[kFrom])
		h2 = bxor(h2, Z_PC2[kFrom])
		b[fromSq] = EMPTY

		if cap ~= EMPTY then
			local kCap = (cap + 6) * 120 + toSq
			h1 = bxor(h1, Z_PC1[kCap])
			h2 = bxor(h2, Z_PC2[kCap])
		end

		local placed = (promo ~= 0) and (promo * side) or pc
		b[toSq] = placed
		local kTo = (placed + 6) * 120 + toSq
		h1 = bxor(h1, Z_PC1[kTo])
		h2 = bxor(h2, Z_PC2[kTo])

		if abs(pc) == KING then
			self.kingSq[side] = toSq
		end

		if flag == F_EP then
			local capSq = toSq - side * 10
			local epPc = b[capSq]
			b[capSq] = EMPTY
			local kEp = (epPc + 6) * 120 + capSq
			h1 = bxor(h1, Z_PC1[kEp])
			h2 = bxor(h2, Z_PC2[kEp])
		elseif flag == F_DOUBLE then
			self.ep = fromSq + side * 10
			local f = (self.ep - 2) % 10
			h1 = bxor(h1, Z_EP1[f])
			h2 = bxor(h2, Z_EP2[f])
		elseif flag == F_OO then
			local rFrom = (side == 1) and 29 or 99
			local rTo = (side == 1) and 27 or 97
			local rk = b[rFrom]
			b[rFrom] = EMPTY
			b[rTo] = rk
			local k1 = (rk + 6) * 120 + rFrom
			local k2 = (rk + 6) * 120 + rTo
			h1 = bxor(h1, bxor(Z_PC1[k1], Z_PC1[k2]))
			h2 = bxor(h2, bxor(Z_PC2[k1], Z_PC2[k2]))
		elseif flag == F_OOO then
			local rFrom = (side == 1) and 22 or 92
			local rTo = (side == 1) and 25 or 95
			local rk = b[rFrom]
			b[rFrom] = EMPTY
			b[rTo] = rk
			local k1 = (rk + 6) * 120 + rFrom
			local k2 = (rk + 6) * 120 + rTo
			h1 = bxor(h1, bxor(Z_PC1[k1], Z_PC1[k2]))
			h2 = bxor(h2, bxor(Z_PC2[k1], Z_PC2[k2]))
		end

		self.castling = band(self.castling, band(CASTLE_MASK[fromSq], CASTLE_MASK[toSq]))
		h1 = bxor(h1, Z_CASTLE1[self.castling])
		h2 = bxor(h2, Z_CASTLE2[self.castling])

		if abs(pc) == PAWN or cap ~= EMPTY or flag == F_EP then
			self.halfmove = 0
		else
			self.halfmove += 1
		end
		if side == -1 then
			self.fullmove += 1
		end

		self.side = -side
		self.h1 = bxor(h1, Z_SIDE1)
		self.h2 = bxor(h2, Z_SIDE2)
		self.posH1[ply] = self.h1
		self.posH2[ply] = self.h2
	end

	function Board:undoMove()
		local ply = self.ply
		self.ply = ply - 1
		local side = -self.side
		self.side = side

		local m = self.uMove[ply]
		local fromSq = band(m, 127)
		local toSq = extract(m, 7, 7)
		local promo = extract(m, 14, 3)
		local flag = extract(m, 17, 3)

		local b = self.board
		local moved = (promo ~= 0) and (PAWN * side) or b[toSq]
		b[fromSq] = moved
		b[toSq] = self.uCap[ply]

		if abs(moved) == KING then
			self.kingSq[side] = fromSq
		end

		if flag == F_EP then
			b[toSq - side * 10] = -side
		elseif flag == F_OO then
			local rFrom = (side == 1) and 29 or 99
			local rTo = (side == 1) and 27 or 97
			b[rFrom] = b[rTo]
			b[rTo] = EMPTY
		elseif flag == F_OOO then
			local rFrom = (side == 1) and 22 or 92
			local rTo = (side == 1) and 25 or 95
			b[rFrom] = b[rTo]
			b[rTo] = EMPTY
		end

		self.castling = self.uCastle[ply]
		self.ep = self.uEp[ply]
		self.halfmove = self.uHalf[ply]
		self.h1 = self.uH1[ply]
		self.h2 = self.uH2[ply]
		if side == -1 then
			self.fullmove -= 1
		end
	end

	function Board:makeNull()
		local ply = self.ply + 1
		self.ply = ply
		self.uMove[ply] = 0
		self.uCap[ply] = 0
		self.uCastle[ply] = self.castling
		self.uEp[ply] = self.ep
		self.uHalf[ply] = self.halfmove
		self.uH1[ply] = self.h1
		self.uH2[ply] = self.h2
		if self.ep ~= 0 then
			local f = (self.ep - 2) % 10
			self.h1 = bxor(self.h1, Z_EP1[f])
			self.h2 = bxor(self.h2, Z_EP2[f])
			self.ep = 0
		end
		self.side = -self.side
		self.h1 = bxor(self.h1, Z_SIDE1)
		self.h2 = bxor(self.h2, Z_SIDE2)
		self.posH1[ply] = self.h1
		self.posH2[ply] = self.h2
	end

	function Board:undoNull()
		local ply = self.ply
		self.ply = ply - 1
		self.side = -self.side
		self.ep = self.uEp[ply]
		self.h1 = self.uH1[ply]
		self.h2 = self.uH2[ply]
	end

	function Board:legalMoves()
		local pseudo = {}
		local cnt = self:genPseudo(pseudo, false)
		local legal = {}
		local side = self.side
		for i = 1, cnt do
			local m = pseudo[i]
			self:makeMove(m)
			if not self:isAttacked(self.kingSq[side], -side) then
				legal[#legal + 1] = m
			end
			self:undoMove()
		end
		return legal
	end

	function Board:moveFromUci(uci)
		if type(uci) ~= "string" or #uci < 4 then return nil end
		local fromSq = PureChess.algToSq(string.sub(uci, 1, 2))
		local toSq = PureChess.algToSq(string.sub(uci, 3, 4))
		if not fromSq or not toSq then return nil end
		local promoCh = string.lower(string.sub(uci, 5, 5))
		local promo = (promoCh ~= "") and (CHAR_TO_PIECE[promoCh] or 0) or 0
		for _, m in ipairs(self:legalMoves()) do
			if band(m, 127) == fromSq and extract(m, 7, 7) == toSq and extract(m, 14, 3) == promo then
				return m
			end
		end
		return nil
	end

	function Board:moveToSan(m)
		local b = self.board
		local fromSq = band(m, 127)
		local toSq = extract(m, 7, 7)
		local promo = extract(m, 14, 3)
		local flag = extract(m, 17, 3)
		local pc = b[fromSq]
		local pt = abs(pc)
		local san
		if flag == F_OO then
			san = "O-O"
		elseif flag == F_OOO then
			san = "O-O-O"
		else
			local isCap = (b[toSq] ~= EMPTY) or (flag == F_EP)
			if pt == PAWN then
				san = isCap and (FILES[(fromSq - 2) % 10 + 1] .. "x" .. PureChess.sqToAlg(toSq)) or PureChess.sqToAlg(toSq)
				if promo ~= 0 then
					san = san .. "=" .. SAN_LETTER[promo]
				end
			else
				local ambig, sameFile, sameRank = false, false, false
				for _, lm in ipairs(self:legalMoves()) do
					local lf = band(lm, 127)
					if lf ~= fromSq and extract(lm, 7, 7) == toSq and b[lf] == pc then
						ambig = true
						if (lf - 2) % 10 == (fromSq - 2) % 10 then sameFile = true end
						if (lf - 22) // 10 == (fromSq - 22) // 10 then sameRank = true end
					end
				end
				local dis = ""
				if ambig then
					if not sameFile then
						dis = FILES[(fromSq - 2) % 10 + 1]
					elseif not sameRank then
						dis = tostring((fromSq - 22) // 10 + 1)
					else
						dis = PureChess.sqToAlg(fromSq)
					end
				end
				san = SAN_LETTER[pt] .. dis .. (isCap and "x" or "") .. PureChess.sqToAlg(toSq)
			end
		end
		self:makeMove(m)
		if self:inCheck() then
			san = san .. (#self:legalMoves() == 0 and "#" or "+")
		end
		self:undoMove()
		return san
	end

	function Board:evaluate()
		local b = self.board
		local mgW, mgB, egW, egB, phase = 0, 0, 0, 0, 0
		local bishW, bishB = 0, 0
		for i = 1, 64 do
			local sq = SQUARES[i]
			local pc = b[sq]
			if pc > 0 then
				local idx = PST_IDX_W[sq]
				mgW += MG_VAL[pc] + MG_PST[pc][idx]
				egW += EG_VAL[pc] + EG_PST[pc][idx]
				phase += PHASE_W[pc]
				if pc == BISHOP then bishW += 1 end
			elseif pc < 0 then
				local pt = -pc
				local idx = PST_IDX_B[sq]
				mgB += MG_VAL[pt] + MG_PST[pt][idx]
				egB += EG_VAL[pt] + EG_PST[pt][idx]
				phase += PHASE_W[pt]
				if pt == BISHOP then bishB += 1 end
			end
		end
		if bishW >= 2 then mgW += 30; egW += 45 end
		if bishB >= 2 then mgB += 30; egB += 45 end
		local mg = mgW - mgB
		local eg = egW - egB
		if phase > 24 then phase = 24 end
		local score = floor((mg * phase + eg * (24 - phase)) / 24)
		return score * self.side
	end

	function Board:hasNonPawnMaterial()
		local b = self.board
		local side = self.side
		for i = 1, 64 do
			local pc = b[SQUARES[i]]
			if pc ~= 0 and (pc > 0) == (side > 0) then
				local pt = abs(pc)
				if pt >= KNIGHT and pt <= QUEEN then
					return true
				end
			end
		end
		return false
	end

	-- Fixed-size Transposition Table (32,768 slots)
	local TT_SIZE = 32768
	local TT_MASK = TT_SIZE - 1
	local ttH1 = table.create(TT_SIZE, -1)
	local ttH2 = table.create(TT_SIZE, 0)
	local ttDepth = table.create(TT_SIZE, -1)
	local ttScore = table.create(TT_SIZE, 0)
	local ttFlag = table.create(TT_SIZE, 0) -- 1=EXACT, 2=LOWER, 3=UPPER
	local ttMove = table.create(TT_SIZE, 0)

	function PureChess.clearTT()
		for i = 1, TT_SIZE do
			ttH1[i] = -1
		end
	end

	local function fen4(fen)
		local p = string.split(fen, " ")
		return (p[1] or "") .. " " .. (p[2] or "w") .. " " .. (p[3] or "-") .. " " .. (p[4] or "-")
	end

	function PureChess.search(fen, maxDepth, timeBudget, cancelFn)
		local t0 = os.clock()
		local board = PureChess.new(fen)

		-- Opening book instant lookup
		local bookList = BOOK[fen4(fen)]
		if bookList and #bookList > 0 then
			local pick = bookList[math.random(1, #bookList)]
			local bm = board:moveFromUci(pick)
			if bm then
				return {
					best = pick,
					ponder = nil,
					evalCp = 25 * board.side,
					mate = nil,
					depth = 0,
					nodes = 0,
					ms = 1,
					pv = { pick },
					san = board:moveToSan(bm),
					source = "Book",
				}
			end
		end

		local deadline = t0 + (timeBudget or 0.55)
		local maxD = math.clamp(maxDepth or 6, 1, 10)
		local nodes = 0
		local aborted = false
		local lastYield = t0
		local killers1 = table.create(64, 0)
		local killers2 = table.create(64, 0)
		local history = {}

		local function checkStop()
			if cancelFn and cancelFn() then
				aborted = true
				return true
			end
			local now = os.clock()
			if now >= deadline then
				aborted = true
				return true
			end
			if now - lastYield >= 0.012 then
				lastYield = now
				task.wait()
				if cancelFn and cancelFn() then
					aborted = true
					return true
				end
				if os.clock() >= deadline then
					aborted = true
					return true
				end
			end
			return false
		end

		local function scoreMove(m, ttM, ply)
			if m == ttM then return 10000000 end
			local toSq = extract(m, 7, 7)
			local promo = extract(m, 14, 3)
			local flag = extract(m, 17, 3)
			local cap = board.board[toSq]
			if cap ~= EMPTY or flag == F_EP then
				local victim = (flag == F_EP) and PAWN or abs(cap)
				local attacker = abs(board.board[band(m, 127)])
				return 1000000 + MVV_VAL[victim] * 10 - attacker
			end
			if promo ~= 0 then
				return 900000 + MVV_VAL[promo]
			end
			if m == killers1[ply] then return 800000 end
			if m == killers2[ply] then return 750000 end
			return history[band(m, 16383)] or 0
		end

		local function pickBest(moves, scores, startIdx, count)
			local bestI = startIdx
			local bestS = scores[startIdx]
			for j = startIdx + 1, count do
				if scores[j] > bestS then
					bestS = scores[j]
					bestI = j
				end
			end
			if bestI ~= startIdx then
				moves[startIdx], moves[bestI] = moves[bestI], moves[startIdx]
				scores[startIdx], scores[bestI] = scores[bestI], scores[startIdx]
			end
			return moves[startIdx]
		end

		local function qsearch(alpha, beta, ply)
			nodes += 1
			if band(nodes, 4095) == 0 and checkStop() then
				return 0
			end
			if ply >= 60 then
				return board:evaluate()
			end
			local standPat = board:evaluate()
			if standPat >= beta then
				return beta
			end
			if standPat > alpha then
				alpha = standPat
			end

			local moves = {}
			local cnt = board:genPseudo(moves, true)
			if cnt == 0 then
				return alpha
			end
			local scores = table.create(cnt, 0)
			for i = 1, cnt do
				scores[i] = scoreMove(moves[i], 0, ply)
			end

			local side = board.side
			for i = 1, cnt do
				local m = pickBest(moves, scores, i, cnt)
				board:makeMove(m)
				if not board:isAttacked(board.kingSq[side], -side) then
					local sc = -qsearch(-beta, -alpha, ply + 1)
					board:undoMove()
					if aborted then return 0 end
					if sc >= beta then return beta end
					if sc > alpha then alpha = sc end
				else
					board:undoMove()
				end
			end
			return alpha
		end

		local function isRepetition()
			local curPly = board.ply
			local limit = math.max(0, curPly - board.halfmove)
			local ch1, ch2 = board.h1, board.h2
			for p = curPly - 2, limit, -2 do
				if board.posH1[p] == ch1 and board.posH2[p] == ch2 then
					return true
				end
			end
			return false
		end

		local function negamax(depth, alpha, beta, ply, allowNull)
			nodes += 1
			if band(nodes, 4095) == 0 and checkStop() then
				return 0
			end
			if ply >= 60 then
				return board:evaluate()
			end
			if ply > 0 and (board.halfmove >= 100 or isRepetition()) then
				return 0
			end

			local inChk = board:inCheck()
			if inChk then
				depth += 1
			end
			if depth <= 0 then
				return qsearch(alpha, beta, ply)
			end

			local origAlpha = alpha
			local slot = band(board.h1, TT_MASK) + 1
			local ttM = 0
			if ttH1[slot] == board.h1 and ttH2[slot] == board.h2 then
				ttM = ttMove[slot]
				if ply > 0 and ttDepth[slot] >= depth then
					local sc = ttScore[slot]
					if sc > MATE - 200 then sc -= ply
					elseif sc < -MATE + 200 then sc += ply end
					local fl = ttFlag[slot]
					if fl == 1 then return sc
					elseif fl == 2 and sc > alpha then alpha = sc
					elseif fl == 3 and sc < beta then beta = sc end
					if alpha >= beta then return sc end
				end
			end

			-- Null-Move Pruning
			if allowNull and not inChk and depth >= 3 and ply > 0 and board:hasNonPawnMaterial() then
				board:makeNull()
				local nullScore = -negamax(depth - 3, -beta, -beta + 1, ply + 1, false)
				board:undoNull()
				if aborted then return 0 end
				if nullScore >= beta then
					return beta
				end
			end

			local moves = {}
			local cnt = board:genPseudo(moves, false)
			local scores = table.create(cnt, 0)
			for i = 1, cnt do
				scores[i] = scoreMove(moves[i], ttM, ply)
			end

			local side = board.side
			local bestMove = 0
			local bestScore = -INF
			local legalCount = 0

			for i = 1, cnt do
				local m = pickBest(moves, scores, i, cnt)
				local toSq = extract(m, 7, 7)
				local isQuiet = (board.board[toSq] == EMPTY) and (extract(m, 14, 3) == 0) and (extract(m, 17, 3) ~= F_EP)

				board:makeMove(m)
				if not board:isAttacked(board.kingSq[side], -side) then
					legalCount += 1
					local sc
					if legalCount == 1 then
						sc = -negamax(depth - 1, -beta, -alpha, ply + 1, true)
					else
						-- Late Move Reduction + PVS
						local reduction = (depth >= 3 and legalCount >= 4 and isQuiet and not inChk and not board:inCheck()) and 1 or 0
						sc = -negamax(depth - 1 - reduction, -alpha - 1, -alpha, ply + 1, true)
						if sc > alpha and reduction > 0 and not aborted then
							sc = -negamax(depth - 1, -alpha - 1, -alpha, ply + 1, true)
						end
						if sc > alpha and sc < beta and not aborted then
							sc = -negamax(depth - 1, -beta, -alpha, ply + 1, true)
						end
					end
					board:undoMove()
					if aborted then return 0 end

					if sc > bestScore then
						bestScore = sc
						bestMove = m
					end
					if sc > alpha then
						alpha = sc
						if alpha >= beta then
							if isQuiet then
								killers2[ply] = killers1[ply]
								killers1[ply] = m
								local hk = band(m, 16383)
								history[hk] = math.min((history[hk] or 0) + depth * depth, 500000)
							end
							break
						end
					end
				else
					board:undoMove()
				end
			end

			if legalCount == 0 then
				return inChk and (-MATE + ply) or 0
			end

			if not aborted then
				local storeScore = bestScore
				if storeScore > MATE - 200 then storeScore += ply
				elseif storeScore < -MATE + 200 then storeScore -= ply end
				local fl = (bestScore <= origAlpha) and 3 or ((bestScore >= beta) and 2 or 1)
				ttH1[slot] = board.h1
				ttH2[slot] = board.h2
				ttDepth[slot] = depth
				ttScore[slot] = storeScore
				ttFlag[slot] = fl
				ttMove[slot] = bestMove
			end

			return bestScore
		end

		local function extractPv(maxLen)
			local pv = {}
			local seen = {}
			local pushed = 0
			for _ = 1, maxLen do
				local slot = band(board.h1, TT_MASK) + 1
				if ttH1[slot] ~= board.h1 or ttH2[slot] ~= board.h2 then break end
				local m = ttMove[slot]
				if m == 0 then break end
				local sig = tostring(board.h1) .. ":" .. tostring(board.h2)
				if seen[sig] then break end
				seen[sig] = true
				local valid = false
				for _, lm in ipairs(board:legalMoves()) do
					if lm == m then valid = true; break end
				end
				if not valid then break end
				pv[#pv + 1] = PureChess.moveToUci(m)
				board:makeMove(m)
				pushed += 1
			end
			for _ = 1, pushed do
				board:undoMove()
			end
			return pv
		end

		local legalRoot = board:legalMoves()
		if #legalRoot == 0 then
			return nil
		end

		local bestMove = legalRoot[1]
		local bestScore = 0
		local reachedDepth = 1

		-- Only 1 legal move? Still evaluate quickly at depth 2 for eval bar, then return
		local targetDepth = (#legalRoot == 1) and math.min(2, maxD) or maxD

		for d = 1, targetDepth do
			local sc = negamax(d, -INF, INF, 0, true)
			if aborted then
				break
			end
			local slot = band(board.h1, TT_MASK) + 1
			if ttH1[slot] == board.h1 and ttH2[slot] == board.h2 and ttMove[slot] ~= 0 then
				bestMove = ttMove[slot]
			end
			bestScore = sc
			reachedDepth = d
			if abs(bestScore) > MATE - 200 then
				break
			end
			if os.clock() >= deadline then
				break
			end
		end

		local pv = extractPv(6)
		local bestUci = PureChess.moveToUci(bestMove)
		if pv[1] ~= bestUci then
			pv = { bestUci }
		end

		-- Convert score to White's perspective
		local whiteScore = bestScore * board.side
		local mateVal = nil
		if abs(whiteScore) > MATE - 200 then
			local pliesToMate = MATE - abs(whiteScore)
			local movesToMate = math.max(1, math.ceil(pliesToMate / 2))
			mateVal = (whiteScore > 0) and movesToMate or -movesToMate
		end

		return {
			best = bestUci,
			ponder = pv[2],
			evalCp = whiteScore,
			mate = mateVal,
			depth = reachedDepth,
			nodes = nodes,
			ms = math.floor((os.clock() - t0) * 1000),
			pv = pv,
			san = board:moveToSan(bestMove),
			source = "Luau",
		}
	end
end

-- ============================================================================
-- 3. HYBRID ENGINE ROUTER (TIMEOUT-SAFE STOCKFISH + PONDER PREFETCH + LUAU)
-- ============================================================================
local function fen4Key(fen)
	local p = string.split(fen, " ")
	return table.concat({ p[1] or "", p[2] or "w", p[3] or "-", p[4] or "-" }, " ")
end

local function fenCacheKey(fen, modeGroup)
	return fen4Key(fen) .. "|" .. modeGroup
end

local function cachePut(key, val)
	if not STATE.Cache[key] then
		table.insert(STATE.CacheOrder, key)
		if #STATE.CacheOrder > STATE.CacheMax then
			local old = table.remove(STATE.CacheOrder, 1)
			STATE.Cache[old] = nil
		end
	end
	STATE.Cache[key] = val
end

local function countFenPieces(fen)
	if type(fen) ~= "string" then
		return 32
	end
	local sp = string.find(fen, " ", 1, true)
	local boardPart = sp and string.sub(fen, 1, sp - 1) or fen
	local total = 0
	for i = 1, #boardPart do
		local b = string.byte(boardPart, i)
		if (b >= 65 and b <= 90) or (b >= 97 and b <= 122) then
			total += 1
		end
	end
	return total
end

local function enrichMoveInfo(fen, res)
	if not res or type(res.best) ~= "string" or #res.best < 4 then
		return nil
	end
	local board = PureChess.new(fen)
	local m = board:moveFromUci(res.best)
	if not m then
		return nil
	end
	res.fromSq = PureChess.algToIndex64(string.sub(res.best, 1, 2))
	res.toSq = PureChess.algToIndex64(string.sub(res.best, 3, 4))
	local promoCh = string.lower(string.sub(res.best, 5, 5))
	local promoMap = { q = 5, r = 4, b = 3, n = 2 }
	res.promo = promoMap[promoCh] or 0
	res.promoChar = promoCh ~= "" and string.upper(promoCh) or nil
	res.san = res.san or board:moveToSan(m)
	res.isCapture = (type(res.san) == "string" and string.find(res.san, "x", 1, true) ~= nil)

	if type(res.ponder) == "string" and #res.ponder >= 4 then
		res.ponderFrom = PureChess.algToIndex64(string.sub(res.ponder, 1, 2))
		res.ponderTo = PureChess.algToIndex64(string.sub(res.ponder, 3, 4))
	else
		res.ponderFrom = nil
		res.ponderTo = nil
	end
	return res
end

-- Non-blocking HTTP request with hard timeout + cancel check (prevents Stockfish hangs!)
local function httpRequestWithTimeout(opts, timeoutSec, cancelFn)
	if type(httpRequest) ~= "function" then
		return false, "no_http"
	end
	local box = { done = false, ok = false, res = nil }
	task.spawn(function()
		local ok, res = pcall(httpRequest, opts)
		box.ok = ok
		box.res = res
		box.done = true
	end)
	local deadline = os.clock() + (timeoutSec or 2.6)
	while not box.done do
		if (not STATE.Alive) or (cancelFn and cancelFn()) then
			return false, "cancelled"
		end
		if os.clock() >= deadline then
			return false, "timeout"
		end
		task.wait(0.03)
	end
	return box.ok, box.res
end

local function hasVpsConfigured()
	return type(CONFIG.VpsApiUrl) == "string" and string.match(CONFIG.VpsApiUrl, "^https?://.+") ~= nil
end

local function queryVpsStockfish(fen, depth, movetimeMs, multipv, timeoutSec, cancelFn)
	if type(httpRequest) ~= "function" then
		return nil, "no_http"
	end
	if not hasVpsConfigured() then
		return nil, "no_vps"
	end
	if os.clock() < STATE.VpsCooldownUntil then
		return nil, "vps_cooldown"
	end
	local base = string.gsub(CONFIG.VpsApiUrl, "/+$", "")
	local d = math.clamp(depth or 15, 1, 22)
	local mt = math.clamp(math.floor(movetimeMs or 280), 0, 3000)
	local mpv = math.clamp(math.floor(multipv or 1), 1, 3)
	local t0 = os.clock()
	local url = base .. "/eval?fen=" .. HttpService:UrlEncode(fen) .. "&depth=" .. tostring(d) .. "&multipv=" .. tostring(mpv)
	if mt > 0 then
		url = url .. "&movetime=" .. tostring(mt)
	end
	local headers = { ["Accept"] = "application/json" }
	if type(CONFIG.VpsApiKey) == "string" and CONFIG.VpsApiKey ~= "" then
		headers["X-Api-Key"] = CONFIG.VpsApiKey
	end

	local ok, res = httpRequestWithTimeout({
		Url = url,
		Method = "GET",
		Headers = headers,
	}, timeoutSec or 2.2, cancelFn)
	local ms = math.floor((os.clock() - t0) * 1000)

	if res == "cancelled" then
		return nil, "cancelled"
	end
	if not ok or type(res) ~= "table" or not res.Success or res.StatusCode ~= 200 then
		STATE.VpsFailStreak += 1
		if STATE.VpsFailStreak >= 2 then
			STATE.VpsCooldownUntil = os.clock() + 12
		end
		return nil, tostring(res)
	end
	local dok, data = pcall(HttpService.JSONDecode, HttpService, res.Body or "")
	if not dok or type(data) ~= "table" or data.success ~= true then
		STATE.VpsFailStreak += 1
		if STATE.VpsFailStreak >= 2 then
			STATE.VpsCooldownUntil = os.clock() + 12
		end
		return nil, "bad_json"
	end
	local bestUci = (type(data.best) == "string" and #data.best >= 4) and data.best
		or string.match(tostring(data.bestmove or ""), "bestmove%s+([a-h][1-8][a-h][1-8][qrbn]?)")
	if not bestUci then
		return nil, "no_move"
	end
	STATE.VpsFailStreak = 0
	STATE.VpsCooldownUntil = 0

	local ponderUci = (type(data.ponder) == "string" and #data.ponder >= 4) and data.ponder
		or string.match(tostring(data.bestmove or ""), "ponder%s+([a-h][1-8][a-h][1-8][qrbn]?)")
	local pv = {}
	if type(data.pv) == "table" and #data.pv > 0 then
		for i = 1, math.min(#data.pv, 6) do
			pv[i] = tostring(data.pv[i])
		end
	elseif type(data.continuation) == "string" then
		for mv in string.gmatch(data.continuation, "%S+") do
			pv[#pv + 1] = mv
			if #pv >= 6 then break end
		end
	end
	if #pv == 0 then pv[1] = bestUci end
	if not ponderUci and pv[2] then ponderUci = pv[2] end

	local mateVal = tonumber(data.mate)
	local evalCp = tonumber(data.evalCp)
	if not evalCp then
		local evPawns = tonumber(data.evaluation)
		evalCp = evPawns and math.floor(evPawns * 100 + 0.5) or (mateVal and (mateVal > 0 and 29000 or -29000) or 0)
	end
	local engName = (type(data.engine) == "string" and data.engine ~= "") and data.engine or "Stockfish 19"

	local lines = nil
	if type(data.lines) == "table" and #data.lines >= 1 then
		lines = {}
		for i = 1, math.min(#data.lines, 3) do
			local ln = data.lines[i]
			if type(ln) == "table" and type(ln.best) == "string" and #ln.best >= 4 then
				local lpv = {}
				if type(ln.pv) == "table" then
					for j = 1, math.min(#ln.pv, 6) do
						lpv[j] = tostring(ln.pv[j])
					end
				end
				if #lpv == 0 then lpv[1] = ln.best end
				table.insert(lines, {
					rank = tonumber(ln.rank) or i,
					best = ln.best,
					ponder = (type(ln.ponder) == "string" and #ln.ponder >= 4) and ln.ponder or lpv[2],
					evalCp = tonumber(ln.evalCp) or 0,
					mate = tonumber(ln.mate),
					depth = tonumber(ln.depth) or d,
					pv = lpv,
				})
			end
		end
	end

	return enrichMoveInfo(fen, {
		best = bestUci,
		ponder = ponderUci,
		evalCp = evalCp,
		mate = mateVal,
		depth = tonumber(data.depth) or d,
		ms = ms,
		pv = pv,
		lines = lines,
		pvGapCp = tonumber(data.pvGapCp),
		multipv = tonumber(data.multipv) or (lines and #lines or 1),
		source = "VpsSF",
		engineName = engName,
	})
end

local function queryStockfishOnline(fen, depth, timeoutSec, cancelFn)
	if type(httpRequest) ~= "function" then
		return nil, "no_http"
	end
	if os.clock() < STATE.SfCooldownUntil then
		return nil, "cooldown"
	end
	local d = math.clamp(depth or 12, 1, 15)
	local t0 = os.clock()
	local url = "https://stockfish.online/api/s/v2.php?fen=" .. HttpService:UrlEncode(fen) .. "&depth=" .. tostring(d)
	local ok, res = httpRequestWithTimeout({
		Url = url,
		Method = "GET",
		Headers = { ["Accept"] = "application/json" },
	}, timeoutSec or 2.6, cancelFn)
	local ms = math.floor((os.clock() - t0) * 1000)

	if res == "cancelled" then
		return nil, "cancelled"
	end
	if not ok or type(res) ~= "table" or not res.Success or res.StatusCode ~= 200 then
		STATE.SfFailStreak += 1
		if STATE.SfFailStreak >= 2 then
			STATE.SfCooldownUntil = os.clock() + 15
		end
		return nil, tostring(res)
	end
	local dok, data = pcall(HttpService.JSONDecode, HttpService, res.Body or "")
	if not dok or type(data) ~= "table" or data.success ~= true then
		STATE.SfFailStreak += 1
		if STATE.SfFailStreak >= 2 then
			STATE.SfCooldownUntil = os.clock() + 12
		end
		return nil, "bad_json"
	end
	local bestStr = tostring(data.bestmove or "")
	local bestUci = string.match(bestStr, "bestmove%s+([a-h][1-8][a-h][1-8][qrbn]?)")
	if not bestUci then
		return nil, "no_move"
	end
	STATE.SfFailStreak = 0
	STATE.SfCooldownUntil = 0

	local ponderUci = string.match(bestStr, "ponder%s+([a-h][1-8][a-h][1-8][qrbn]?)")
	local pv = {}
	if type(data.continuation) == "string" then
		for mv in string.gmatch(data.continuation, "%S+") do
			pv[#pv + 1] = mv
			if #pv >= 6 then break end
		end
	end
	if #pv == 0 then pv[1] = bestUci end
	if not ponderUci and pv[2] then ponderUci = pv[2] end

	local mateVal = tonumber(data.mate)
	local evalCp = tonumber(data.evaluation)
	evalCp = evalCp and math.floor(evalCp * 100 + 0.5) or (mateVal and (mateVal > 0 and 29000 or -29000) or 0)

	return enrichMoveInfo(fen, {
		best = bestUci,
		ponder = ponderUci,
		evalCp = evalCp,
		mate = mateVal,
		depth = d,
		ms = ms,
		pv = pv,
		source = "Stockfish",
	})
end

local function queryLocalWs(fen, depth, cancelFn)
	if not wsLibrary or type(wsLibrary.connect) ~= "function" then
		return nil, "no_ws"
	end
	local t0 = os.clock()
	local ok, ws = pcall(wsLibrary.connect, CONFIG.LocalWsUrl)
	if not ok or not ws then
		return nil, "ws_connect_fail"
	end
	local result = nil
	local conn = ws.OnMessage:Connect(function(msg)
		local dok, d = pcall(HttpService.JSONDecode, HttpService, msg)
		if dok and type(d) == "table" and (d.best or d.move or d.bestmove) then
			result = d
		end
	end)
	pcall(ws.Send, ws, HttpService:JSONEncode({ fen = fen, depth = depth }))
	local dl = os.clock() + 2.5
	while not result and os.clock() < dl and STATE.Alive do
		if cancelFn and cancelFn() then break end
		task.wait(0.02)
	end
	pcall(function() conn:Disconnect() end)
	pcall(function() ws:Close() end)
	if not result then
		return nil, "ws_timeout"
	end
	local bestUci = result.best or result.move or string.match(tostring(result.bestmove or ""), "([a-h][1-8][a-h][1-8][qrbn]?)")
	return enrichMoveInfo(fen, {
		best = bestUci,
		ponder = result.ponder,
		evalCp = tonumber(result.evalCp) or (tonumber(result.eval) and math.floor(tonumber(result.eval) * 100) or 0),
		mate = tonumber(result.mate),
		depth = tonumber(result.depth) or depth,
		ms = math.floor((os.clock() - t0) * 1000),
		pv = type(result.pv) == "table" and result.pv or { bestUci },
		source = "LocalSF",
	})
end

-- GM Move Shaper: selects authentic GM/IM moves from MultiPV 3 while never missing critical tactics.
-- Automatically bypassed whenever Anti-Engine Turbo or an Engine Opponent is active!
local GM_STYLE_PROFILES = {
	SuperGM = { openGap = 25, midGap = 24, winGap = 40, endGap = 15, p2Close = 0.34, p3Close = 0.08, p2Med = 0.18, openW = { 58, 28, 14 } },
	GM = { openGap = 32, midGap = 40, winGap = 60, endGap = 22, p2Close = 0.46, p3Close = 0.14, p2Med = 0.30, openW = { 46, 34, 20 } },
	Master = { openGap = 42, midGap = 65, winGap = 90, endGap = 35, p2Close = 0.54, p3Close = 0.22, p2Med = 0.38, openW = { 38, 36, 26 } },
}

local function isEdgePawnPush(uci)
	return uci == "a2a3" or uci == "a2a4" or uci == "h2h3" or uci == "h2h4"
		or uci == "a7a6" or uci == "a7a5" or uci == "h7h6" or uci == "h7h5"
end

local function applyGmMoveShaper(fen, session, rawRes, turbo)
	if not rawRes then
		return nil
	end
	local out = table.clone(rawRes)
	local style = CONFIG.PlayStyle or "GM"
	local prof = GM_STYLE_PROFILES[style]
	if not prof or turbo or STATE.Opp.engineDetected then
		return out
	end
	if not session or (session.kind ~= "online" and session.kind ~= "bot") then
		return out
	end
	if session.myColor ~= nil and not session:isMyTurn() then
		return out
	end
	if type(rawRes.lines) ~= "table" or #rawRes.lines < 2 then
		return out
	end

	local fenParts = string.split(fen, " ")
	local side = (fenParts[2] == "b") and -1 or 1
	local pv1 = rawRes.lines[1]
	if not pv1 or pv1.mate ~= nil then
		-- Never deviate from forced mate sequences
		return out
	end

	local myEval1 = (pv1.evalCp or 0) * side
	local ply = (session.ucis and #session.ucis) or 0
	local totalPieces = countFenPieces(fen)

	local function getGap(ln)
		if not ln or ln.mate ~= nil then
			return 99999
		end
		return math.max(0, myEval1 - ((ln.evalCp or 0) * side))
	end

	local pv2 = rawRes.lines[2]
	local pv3 = rawRes.lines[3]
	local gap2 = getGap(pv2)
	local gap3 = getGap(pv3)
	local picked = pv1
	local pickedGap = 0

	if ply <= 7 then
		-- Opening repertoire diversity (e4/d4/Nf3/c4, Sicilian/e5/Caro-Kann/etc.)
		local cands = { { ln = pv1, w = prof.openW[1], g = 0 } }
		if pv2 and gap2 <= prof.openGap then
			table.insert(cands, { ln = pv2, w = prof.openW[2], g = gap2 })
		end
		if pv3 and gap3 <= prof.openGap then
			table.insert(cands, { ln = pv3, w = prof.openW[3], g = gap3 })
		end
		local totalW = 0
		for _, c in ipairs(cands) do totalW += c.w end
		local roll = math.random() * totalW
		local acc = 0
		for _, c in ipairs(cands) do
			acc += c.w
			if roll <= acc then
				picked = c.ln
				pickedGap = c.g
				break
			end
		end
	else
		local maxGap = (totalPieces <= (CONFIG.EndgamePieces or 10)) and prof.endGap
			or ((myEval1 >= 180) and prof.winGap or prof.midGap)
		if myEval1 < -120 then
			-- Tighten precision while defending so we don't collapse
			maxGap = math.floor(maxGap * 0.5)
		end

		if pv2 and gap2 <= maxGap then
			local r = math.random()
			local edgeBonus = (gap2 <= 18 and isEdgePawnPush(pv1.best) and not isEdgePawnPush(pv2.best)) and 0.16 or 0
			if gap2 <= 16 then
				local p3 = (pv3 and gap3 <= math.min(maxGap, 20)) and prof.p3Close or 0
				local p2 = math.min(0.68, prof.p2Close + edgeBonus)
				if r < p3 then
					picked, pickedGap = pv3, gap3
				elseif r < p3 + p2 then
					picked, pickedGap = pv2, gap2
				end
			elseif gap2 <= math.floor(maxGap * 0.72) then
				local p3 = (pv3 and gap3 <= maxGap) and (prof.p3Close * 0.55) or 0
				local p2 = math.min(0.55, prof.p2Med + edgeBonus)
				if r < p3 then
					picked, pickedGap = pv3, gap3
				elseif r < p3 + p2 then
					picked, pickedGap = pv2, gap2
				end
			else
				if r < (prof.p2Med * 0.55) then
					picked, pickedGap = pv2, gap2
				end
			end
		end
	end

	local baseName = (rawRes.engineName or "Stockfish 19") .. " VPS"
	if picked.rank and picked.rank > 1 then
		out.best = picked.best
		out.ponder = picked.ponder
		out.evalCp = picked.evalCp
		out.mate = picked.mate
		out.pv = picked.pv
		out.san = nil
		out.ponderFrom = nil
		out.ponderTo = nil
		out = enrichMoveInfo(fen, out) or out
		out.gmRank = picked.rank
		out.gmLossCp = pickedGap
		out.engineLabel = string.format("%s · %s (PV%d -%dcp)", baseName, style, picked.rank, pickedGap)
		out.engineKind = "gm"
	else
		out.gmRank = 1
		out.gmLossCp = 0
		out.engineLabel = string.format("%s · %s (PV1)", baseName, style)
		out.engineKind = "gm"
	end
	return out
end

-- Speculative Ponder Prefetch: solve the position AFTER opponent's expected Stockfish reply during their turn!
local function launchPonderPrefetch(curFen, ponderUci)
	if not CONFIG.AntiEngineTurbo or not CONFIG.Enabled or STATE.PrefetchInFlight then
		return
	end
	if type(ponderUci) ~= "string" or #ponderUci < 4 then
		return
	end
	if CONFIG.EngineMode == "Luau" then
		return
	end
	local useVps = hasVpsConfigured() and os.clock() >= STATE.VpsCooldownUntil
	local useCloud = os.clock() >= STATE.SfCooldownUntil
	if not useVps and not useCloud then
		return
	end
	local b = PureChess.new(curFen)
	local pm = b:moveFromUci(ponderUci)
	if not pm then
		return
	end
	b:makeMove(pm)
	local nextFen = b:getFen()
	local isTurbo = STATE.Opp.turboActive or STATE.Opp.engineDetected
	local wantMpv = (useVps and not isTurbo and CONFIG.PlayStyle ~= "Full") and 3 or 1
	local cGroup = (wantMpv > 1) and "sf3" or "sf"
	local cKey = fenCacheKey(nextFen, cGroup)
	if STATE.Cache[cKey] or STATE.PrefetchKey == cKey then
		return
	end

	STATE.PrefetchKey = cKey
	STATE.PrefetchInFlight = true
	local d = isTurbo and math.min(CONFIG.StockfishDepth, 15) or CONFIG.StockfishDepth

	task.spawn(function()
		local cancelPrefetch = function()
			return (not STATE.Alive) or (STATE.PrefetchKey ~= cKey)
		end
		local res = nil
		if useVps then
			res = queryVpsStockfish(nextFen, d, isTurbo and 115 or 260, wantMpv, 2.0, cancelPrefetch)
		end
		if not res and useCloud and not cancelPrefetch() then
			res = queryStockfishOnline(nextFen, math.min(d, 15), 2.4, cancelPrefetch)
		end
		if res and STATE.Alive then
			if res.source == "VpsSF" then
				res.engineLabel = (res.engineName or "Stockfish 19") .. " VPS (Ponder Hit)"
				res.engineKind = "vpssf"
			else
				res.engineLabel = "Stockfish Cloud (Ponder Hit)"
				res.engineKind = "stockfish"
			end
			res.prefetched = true
			cachePut(cKey, res)
		end
		if STATE.PrefetchKey == cKey then
			STATE.PrefetchInFlight = false
		end
	end)
end

local function solvePosition(fen, session, gen, onStage)
	local function isCancelled()
		return (not STATE.Alive) or (gen ~= STATE.SearchGen)
	end
	local function reportStage(label, kind)
		if isCancelled() then return end
		STATE.ActiveEngine = label
		STATE.ActiveEngineKind = kind or "thinking"
		if onStage then
			onStage(label, kind)
		end
	end

	-- Direct puzzle solution when available locally (non-live puzzles)
	if CONFIG.PuzzleHelper and session and (session.kind == "puzzle" or session.kind == "rush") then
		local pz = session.pz
		if pz and type(pz.sol) == "table" and type(pz.step) == "number" then
			local solUci = pz.sol[pz.step]
			if type(solUci) == "string" and #solUci >= 4 then
				local enriched = enrichMoveInfo(fen, {
					best = solUci,
					ponder = pz.sol[pz.step + 1],
					evalCp = (session.myColor or 1) * 500,
					mate = nil,
					depth = 99,
					ms = 0,
					pv = { solUci, pz.sol[pz.step + 1] },
					source = "Puzzle",
					engineLabel = "Puzzle Solution",
					engineKind = "puzzle",
				})
				if enriched then
					return enriched
				end
			end
		end
	end

	-- Adaptive clock & Anti-Engine Turbo routing
	local myMs = nil
	if session and session.clocks and session.myColor then
		myMs = session.clocks[session.myColor]
	end
	local turbo = CONFIG.AntiEngineTurbo and STATE.Opp.turboActive and session and session.kind == "online"
	local mode = CONFIG.EngineMode
	local sfDepth = CONFIG.StockfishDepth
	local vpsReady = hasVpsConfigured() and os.clock() >= STATE.VpsCooldownUntil
	local wantMultiPv = (vpsReady and not turbo and not STATE.Opp.engineDetected
		and CONFIG.PlayStyle ~= "Full"
		and session and (session.kind == "online" or session.kind == "bot")
		and (not myMs or myMs >= 25000)) and 3 or 1
	local vpsMoveTime = turbo and 95 or (wantMultiPv > 1 and 300 or 260)
	local vpsTimeout = turbo and 1.25 or 2.2
	local sfTimeout = turbo and 1.35 or 2.6
	local luauTime = turbo and 0.28 or CONFIG.LuauTimeBudget
	local lowClockSwitch = false

	if turbo then
		sfDepth = math.min(sfDepth, vpsReady and 16 or 11)
	end
	if myMs and session.kind == "online" then
		local luauCutMs = vpsReady and 8000 or 15000
		if myMs < luauCutMs and mode == "Hybrid" then
			mode = "Luau"
			luauTime = 0.16
			lowClockSwitch = true
		elseif myMs < 25000 then
			wantMultiPv = 1
			vpsMoveTime = math.min(vpsMoveTime, 75)
			vpsTimeout = math.min(vpsTimeout, 1.0)
			sfDepth = math.min(sfDepth, vpsReady and 14 or 10)
			sfTimeout = math.min(sfTimeout, 1.3)
			luauTime = math.min(luauTime, 0.25)
		elseif myMs < 40000 then
			vpsMoveTime = math.min(vpsMoveTime, 150)
			sfDepth = math.min(sfDepth, vpsReady and 15 or 11)
		end
	end

	-- Check Ponder/Stockfish cache FIRST (instant 0ms ponder hit; GM Shaper runs fresh per turn!)
	if mode ~= "Luau" then
		local sfHit = (wantMultiPv > 1 and STATE.Cache[fenCacheKey(fen, "sf3")])
			or (wantMultiPv == 1 and (STATE.Cache[fenCacheKey(fen, "sf")] or STATE.Cache[fenCacheKey(fen, "sf3")]))
		if sfHit then
			local hitCopy = applyGmMoveShaper(fen, session, sfHit, turbo)
			hitCopy.ms = 0
			if sfHit.prefetched then
				local baseLbl = hitCopy.engineLabel or ((sfHit.source == "VpsSF") and "Stockfish 19 VPS" or "Stockfish")
				if not string.find(baseLbl, "Ponder", 1, true) then
					hitCopy.engineLabel = baseLbl .. " · Ponder Hit"
				end
			else
				local baseLbl = hitCopy.engineLabel or "Stockfish"
				if not string.find(baseLbl, "Cached", 1, true) then
					hitCopy.engineLabel = baseLbl .. " (Cached)"
				end
			end
			return hitCopy
		end
	end
	local luauHit = (mode == "Luau") and STATE.Cache[fenCacheKey(fen, "luau")]
	if luauHit then
		local hitCopy = table.clone(luauHit)
		hitCopy.ms = 0
		return hitCopy
	end

	local function runLuau(tagLabel, tagKind)
		reportStage(tagLabel, "thinking")
		local r = enrichMoveInfo(fen, PureChess.search(fen, CONFIG.LuauMaxDepth, luauTime, isCancelled))
		if r then
			if r.source == "Book" then
				r.engineLabel = "Opening Book (Luau)"
				r.engineKind = "book"
			else
				r.engineLabel = tagLabel
				r.engineKind = tagKind
			end
		end
		return r
	end

	local res = nil
	if mode == "LocalWS" then
		reportStage("Local Stockfish WS", "thinking")
		res = queryLocalWs(fen, sfDepth, isCancelled)
		if res then
			res.engineLabel = "Local Stockfish WS"
			res.engineKind = "localws"
		elseif not isCancelled() and vpsReady then
			reportStage("Stockfish 19 VPS (WS Fallback)", "thinking")
			res = queryVpsStockfish(fen, sfDepth, vpsMoveTime, wantMultiPv, vpsTimeout, isCancelled)
			if res then
				res.engineLabel = (res.engineName or "Stockfish 19") .. " VPS (WS Fallback)"
				res.engineKind = "vpssf"
			end
		end
		if not res and not isCancelled() then
			reportStage("Stockfish Cloud (WS Fallback)", "thinking")
			res = queryStockfishOnline(fen, math.min(sfDepth, 15), sfTimeout, isCancelled)
			if res then
				res.engineLabel = "Stockfish Cloud (WS Fallback)"
				res.engineKind = "stockfish"
			elseif not isCancelled() then
				res = runLuau("Offline Luau (Fallback)", "fallback")
			end
		end
	elseif mode == "Stockfish" or mode == "Hybrid" then
		local vpsAttempted = false
		if vpsReady then
			vpsAttempted = true
			local vpsTag = turbo and "Stockfish 19 VPS (Turbo)" or (wantMultiPv > 1 and ("Stockfish 19 VPS · " .. CONFIG.PlayStyle) or "Stockfish 19 VPS")
			reportStage(vpsTag, "thinking")
			res = queryVpsStockfish(fen, sfDepth, vpsMoveTime, wantMultiPv, vpsTimeout, isCancelled)
			if res then
				local nm = res.engineName or "Stockfish 19"
				res.engineLabel = turbo and (nm .. " VPS (Turbo)") or (nm .. " VPS")
				res.engineKind = turbo and "turbo" or "vpssf"
			end
		end

		if not res and not isCancelled() then
			if os.clock() >= STATE.SfCooldownUntil then
				local cloudTag = vpsAttempted and "Stockfish Cloud (VPS Fallback)" or (turbo and "Stockfish Turbo" or "Stockfish Cloud")
				reportStage(cloudTag, "thinking")
				res = queryStockfishOnline(fen, math.min(sfDepth, 15), sfTimeout, isCancelled)
				if res then
					res.engineLabel = cloudTag
					res.engineKind = turbo and "turbo" or "stockfish"
				end
			end
		end

		if not res and not isCancelled() then
			res = runLuau("Offline Luau (API Fallback)", "fallback")
		end
	else -- "Luau" (or Hybrid low-clock switch)
		res = runLuau(lowClockSwitch and "Offline Luau (Low Clock)" or "Offline Luau", lowClockSwitch and "fallback" or "luau")
	end

	if res and not isCancelled() then
		local grp = (res.source == "VpsSF" and res.multipv and res.multipv > 1) and "sf3"
			or ((res.source == "VpsSF" or res.source == "Stockfish" or res.source == "LocalSF") and "sf" or "luau")
		cachePut(fenCacheKey(fen, grp), res)
		res = applyGmMoveShaper(fen, session, res, turbo)
	end
	return res
end

-- ============================================================================
-- 4. ISOLATED VISUAL OVERLAY (gethui() ScreenGui — ZERO TOUCH ON ChessUI)
-- ============================================================================
local uiParent = (type(gethui) == "function" and gethui()) or CoreGui

local overlayGui = Instance.new("ScreenGui")
overlayGui.Name = "RoChessOverlay_" .. tostring(math.random(10000, 99999))
overlayGui.ResetOnSpawn = false
overlayGui.IgnoreGuiInset = false -- Matches App.board.frame.AbsolutePosition 1:1
overlayGui.DisplayOrder = 100
overlayGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
overlayGui.Parent = uiParent

local boardProxy = Instance.new("Frame")
boardProxy.Name = "BoardProxy"
boardProxy.BackgroundTransparency = 1
boardProxy.ClipsDescendants = false
boardProxy.Visible = false
boardProxy.Parent = overlayGui

local hlLayer = Instance.new("Frame")
hlLayer.Name = "Highlights"
hlLayer.BackgroundTransparency = 1
hlLayer.Size = UDim2.fromScale(1, 1)
hlLayer.ZIndex = 1
hlLayer.Parent = boardProxy

local arrowLayer = Instance.new("Frame")
arrowLayer.Name = "Arrows"
arrowLayer.BackgroundTransparency = 1
arrowLayer.Size = UDim2.fromScale(1, 1)
arrowLayer.ZIndex = 2
arrowLayer.Parent = boardProxy

local badgeLayer = Instance.new("Frame")
badgeLayer.Name = "Badges"
badgeLayer.BackgroundTransparency = 1
badgeLayer.Size = UDim2.fromScale(1, 1)
badgeLayer.ZIndex = 3
badgeLayer.Parent = boardProxy

-- Procedural anti-aliased triangular arrowhead (4x4 supersampled EditableImage)
local arrowHeadContent = nil
local arrowHeadImageObj = nil
do
	local ok, contentObj, imgObj = pcall(function()
		local buf = buffer.create(65536) -- 128 x 128 x 4 RGBA
		for y = 0, 127 do
			for x = 0, 127 do
				local hits = 0
				for sy = 0, 3 do
					local py = y + (sy + 0.5) / 4
					for sx = 0, 3 do
						local px = x + (sx + 0.5) / 4
						-- Triangle pointing right (+X): tip at (128, 64), base at x=0, y in [0..128]
						if math.abs(py - 64) <= (1 - px / 128) * 64 then
							hits += 1
						end
					end
				end
				local alpha = math.floor(hits / 16 * 255 + 0.5)
				local off = (y * 128 + x) * 4
				buffer.writeu32(buf, off, alpha * 16777216 + 16777215) -- White RGB + alpha
			end
		end
		local ei = AssetService:CreateEditableImage({ Size = Vector2.new(128, 128) })
		ei:WritePixelsBuffer(Vector2.zero, Vector2.new(128, 128), buf)
		return Content.fromObject(ei), ei
	end)
	if ok and contentObj then
		arrowHeadContent = contentObj
		arrowHeadImageObj = imgObj
	end
end

-- Square Highlights (From & To) — clean subtle tint
local function makeHighlight(name, color)
	local f = Instance.new("Frame")
	f.Name = name
	f.Size = UDim2.fromScale(0.125, 0.125)
	f.BackgroundColor3 = color
	f.BackgroundTransparency = 0.78
	f.BorderSizePixel = 0
	f.Visible = false
	f.Parent = hlLayer
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0.06, 0)
	c.Parent = f
	local st = Instance.new("UIStroke")
	st.Color = color
	st.Thickness = 1.8
	st.Transparency = 0.25
	st.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	st.Parent = f
	return f, st
end

local hlFromFrame, hlFromStroke = makeHighlight("FromHL", Color3.fromRGB(56, 217, 169))
local hlToFrame, hlToStroke = makeHighlight("ToHL", Color3.fromRGB(56, 217, 169))

-- Promotion Badge
local promoBadge = Instance.new("TextLabel")
promoBadge.Name = "PromoBadge"
promoBadge.Size = UDim2.fromOffset(30, 22)
promoBadge.AnchorPoint = Vector2.new(1, 0)
promoBadge.BackgroundColor3 = Color3.fromRGB(240, 198, 74)
promoBadge.TextColor3 = Color3.fromRGB(18, 20, 26)
promoBadge.Font = Enum.Font.GothamBold
promoBadge.TextSize = 13
promoBadge.Text = "=Q"
promoBadge.Visible = false
promoBadge.Parent = badgeLayer
do
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, 6)
	c.Parent = promoBadge
	local st = Instance.new("UIStroke")
	st.Color = Color3.fromRGB(18, 20, 26)
	st.Thickness = 1.5
	st.Parent = promoBadge
end

-- Compact On-Board Active Engine Pill (always visible even when menu is hidden)
local engineBadge = Instance.new("Frame")
engineBadge.Name = "EngineBadge"
engineBadge.AnchorPoint = Vector2.new(0.5, 0)
engineBadge.Position = UDim2.new(0.5, 0, 0, 6)
engineBadge.Size = UDim2.fromOffset(0, 22)
engineBadge.AutomaticSize = Enum.AutomaticSize.X
engineBadge.BackgroundColor3 = Color3.fromRGB(13, 14, 18)
engineBadge.BackgroundTransparency = 0.14
engineBadge.BorderSizePixel = 0
engineBadge.Visible = false
engineBadge.Parent = badgeLayer
do
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, 5)
	c.Parent = engineBadge
	local st = Instance.new("UIStroke")
	st.Color = Color3.fromRGB(48, 54, 68)
	st.Thickness = 1
	st.Parent = engineBadge
	local pad = Instance.new("UIPadding")
	pad.PaddingLeft = UDim.new(0, 8)
	pad.PaddingRight = UDim.new(0, 9)
	pad.Parent = engineBadge
	local list = Instance.new("UIListLayout")
	list.FillDirection = Enum.FillDirection.Horizontal
	list.VerticalAlignment = Enum.VerticalAlignment.Center
	list.Padding = UDim.new(0, 6)
	list.SortOrder = Enum.SortOrder.LayoutOrder
	list.Parent = engineBadge
end

local engineBadgeDot = Instance.new("Frame")
engineBadgeDot.LayoutOrder = 1
engineBadgeDot.Size = UDim2.fromOffset(6, 6)
engineBadgeDot.BackgroundColor3 = Color3.fromRGB(56, 217, 169)
engineBadgeDot.BorderSizePixel = 0
engineBadgeDot.Parent = engineBadge
do
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(1, 0)
	c.Parent = engineBadgeDot
end

local engineBadgeText = Instance.new("TextLabel")
engineBadgeText.LayoutOrder = 2
engineBadgeText.BackgroundTransparency = 1
engineBadgeText.Size = UDim2.fromScale(0, 1)
engineBadgeText.AutomaticSize = Enum.AutomaticSize.X
engineBadgeText.Font = Enum.Font.RobotoMono
engineBadgeText.TextSize = 11
engineBadgeText.TextColor3 = Color3.fromRGB(232, 236, 244)
engineBadgeText.Text = "Stockfish Cloud"
engineBadgeText.Parent = engineBadge

-- Vertical Eval Bar docked left of board
local evalBarFrame = Instance.new("Frame")
evalBarFrame.Name = "EvalBar"
evalBarFrame.BackgroundColor3 = Color3.fromRGB(36, 39, 48)
evalBarFrame.BorderSizePixel = 0
evalBarFrame.ClipsDescendants = true
evalBarFrame.Visible = false
evalBarFrame.Parent = overlayGui
do
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, 5)
	c.Parent = evalBarFrame
	local st = Instance.new("UIStroke")
	st.Color = Color3.fromRGB(64, 72, 92)
	st.Thickness = 1
	st.Parent = evalBarFrame
end

local evalWhiteFill = Instance.new("Frame")
evalWhiteFill.Name = "WhiteFill"
evalWhiteFill.BackgroundColor3 = Color3.fromRGB(238, 241, 248)
evalWhiteFill.BorderSizePixel = 0
evalWhiteFill.AnchorPoint = Vector2.new(0, 1)
evalWhiteFill.Position = UDim2.fromScale(0, 1)
evalWhiteFill.Size = UDim2.fromScale(1, 0.5)
evalWhiteFill.Parent = evalBarFrame

local evalBarLabel = Instance.new("TextLabel")
evalBarLabel.Name = "EvalScore"
evalBarLabel.BackgroundTransparency = 1
evalBarLabel.Size = UDim2.new(1, 0, 0, 18)
evalBarLabel.AnchorPoint = Vector2.new(0, 1)
evalBarLabel.Position = UDim2.new(0, 0, 1, -3)
evalBarLabel.Font = Enum.Font.GothamBold
evalBarLabel.TextSize = 10
evalBarLabel.TextColor3 = Color3.fromRGB(20, 22, 28)
evalBarLabel.Text = "0.0"
evalBarLabel.ZIndex = 3
evalBarLabel.Parent = evalBarFrame

local function sqColRow(sq64, flipped)
	local f = (sq64 - 1) % 8
	local r = (sq64 - 1) // 8
	if flipped then
		return 7 - f, r
	end
	return f, 7 - r
end

local function sqCenterLocal(sq64, flipped, sqPx)
	local c, r = sqColRow(sq64, flipped)
	return Vector2.new((c + 0.5) * sqPx, (r + 0.5) * sqPx)
end

-- Unified CanvasGroup Arrow Drawer (supports straight + L-shaped knight arrows, zero overlap seams)
local activeArrows = {}

local function clearArrows()
	for _, g in ipairs(activeArrows) do
		if g and g.Parent then
			g:Destroy()
		end
	end
	table.clear(activeArrows)
end

local function drawBoardArrow(fromSq, toSq, flipped, sqPx, color, transparency, zOrder)
	if not fromSq or not toSq or fromSq == toSq or sqPx <= 4 then
		return
	end
	local p1 = sqCenterLocal(fromSq, flipped, sqPx)
	local p2 = sqCenterLocal(toSq, flipped, sqPx)
	local delta = p2 - p1
	if delta.Magnitude < 2 then return end

	local cg = Instance.new("CanvasGroup")
	cg.Name = "ChessArrow"
	cg.BackgroundTransparency = 1
	cg.Size = UDim2.fromScale(1, 1)
	cg.GroupTransparency = transparency or 0.18
	cg.ZIndex = zOrder or 2
	cg.Parent = arrowLayer
	table.insert(activeArrows, cg)

	local shaftW = math.max(5, math.floor(sqPx * 0.16))
	local headL = math.max(12, math.floor(sqPx * 0.36))
	local headW = math.max(16, math.floor(sqPx * 0.48))
	local tailInset = sqPx * 0.20
	local tipInset = sqPx * 0.08

	local dx = math.abs(math.floor(delta.X / sqPx + 0.5))
	local dy = math.abs(math.floor(delta.Y / sqPx + 0.5))
	local isKnight = (dx == 1 and dy == 2) or (dx == 2 and dy == 1)

	local function addCircle(pt, diam)
		local cFrame = Instance.new("Frame")
		cFrame.BorderSizePixel = 0
		cFrame.BackgroundColor3 = color
		cFrame.AnchorPoint = Vector2.new(0.5, 0.5)
		cFrame.Position = UDim2.fromOffset(pt.X, pt.Y)
		cFrame.Size = UDim2.fromOffset(diam, diam)
		cFrame.Parent = cg
		local uc = Instance.new("UICorner")
		uc.CornerRadius = UDim.new(0.5, 0)
		uc.Parent = cFrame
	end

	local function addBar(a, b)
		local seg = b - a
		local len = seg.Magnitude
		if len < 1 then return end
		local mid = (a + b) / 2
		local f = Instance.new("Frame")
		f.BorderSizePixel = 0
		f.BackgroundColor3 = color
		f.AnchorPoint = Vector2.new(0.5, 0.5)
		f.Position = UDim2.fromOffset(mid.X, mid.Y)
		f.Size = UDim2.fromOffset(len, shaftW)
		f.Rotation = math.deg(math.atan2(seg.Y, seg.X))
		f.Parent = cg
	end

	local tipDir, shaftStart, tipPos
	if isKnight then
		-- L-shape: longer leg first, rounded tail + exact 90-degree rounded elbow
		local bend = (dx > dy) and Vector2.new(p2.X, p1.Y) or Vector2.new(p1.X, p2.Y)
		local leg1Dir = (bend - p1).Unit
		local start1 = p1 + leg1Dir * tailInset
		addCircle(start1, shaftW)
		addBar(start1, bend)
		addCircle(bend, shaftW)

		tipDir = (p2 - bend).Unit
		shaftStart = bend
		tipPos = p2 - tipDir * tipInset
	else
		tipDir = delta.Unit
		shaftStart = p1 + tipDir * tailInset
		tipPos = p2 - tipDir * tipInset
		addCircle(shaftStart, shaftW)
	end

	local shaftEnd = tipPos - tipDir * (headL - 2)
	if (shaftEnd - shaftStart):Dot(tipDir) > 1 then
		addBar(shaftStart, shaftEnd)
	end

	local headCenter = tipPos - tipDir * (headL * 0.5)
	local angleDeg = math.deg(math.atan2(tipDir.Y, tipDir.X))

	if arrowHeadContent then
		local head = Instance.new("ImageLabel")
		head.Name = "Head"
		head.BackgroundTransparency = 1
		head.ImageContent = arrowHeadContent
		head.ImageColor3 = color
		head.ScaleType = Enum.ScaleType.Stretch
		head.AnchorPoint = Vector2.new(0.5, 0.5)
		head.Position = UDim2.fromOffset(headCenter.X, headCenter.Y)
		head.Size = UDim2.fromOffset(headL, headW)
		head.Rotation = angleDeg
		head.Parent = cg
	else
		-- Crisp fallback chevron
		for _, sgn in { -1, 1 } do
			local wing = Instance.new("Frame")
			wing.BorderSizePixel = 0
			wing.BackgroundColor3 = color
			wing.AnchorPoint = Vector2.new(1, 0.5)
			wing.Position = UDim2.fromOffset(tipPos.X, tipPos.Y)
			wing.Size = UDim2.fromOffset(headL * 0.95, shaftW * 0.85)
			wing.Rotation = angleDeg + sgn * 36
			wing.Parent = cg
			local wc = Instance.new("UICorner")
			wc.CornerRadius = UDim.new(0.5, 0)
			wc.Parent = wing
		end
	end
end

local function formatEvalText(cp, mate)
	if mate and mate ~= 0 then
		return (mate > 0 and "+M" or "-M") .. tostring(math.abs(mate))
	end
	local pawns = (cp or 0) / 100
	if pawns > 0 then
		return string.format("+%.2f", pawns)
	elseif pawns < 0 then
		return string.format("%.2f", pawns)
	end
	return "0.00"
end

local function updateEvalBarVisual(cp, mate, flipped)
	local whiteFrac
	if mate and mate ~= 0 then
		whiteFrac = (mate > 0) and 0.97 or 0.03
	else
		local clamped = math.clamp(cp or 0, -1000, 1000)
		whiteFrac = math.clamp(1 / (1 + math.exp(-0.004 * clamped)), 0.04, 0.96)
	end

	evalWhiteFill.AnchorPoint = flipped and Vector2.new(0, 0) or Vector2.new(0, 1)
	evalWhiteFill.Position = flipped and UDim2.fromScale(0, 0) or UDim2.fromScale(0, 1)
	TweenService:Create(evalWhiteFill, TweenInfo.new(0.25, Enum.EasingStyle.Quart, Enum.EasingDirection.Out), {
		Size = UDim2.fromScale(1, whiteFrac),
	}):Play()

	local whiteBetter = (mate and mate ~= 0) and (mate > 0) or ((cp or 0) >= 0)
	local atBottom = (whiteBetter and not flipped) or ((not whiteBetter) and flipped)
	evalBarLabel.AnchorPoint = atBottom and Vector2.new(0, 1) or Vector2.new(0, 0)
	evalBarLabel.Position = atBottom and UDim2.new(0, 0, 1, -3) or UDim2.new(0, 0, 0, 3)
	evalBarLabel.TextColor3 = whiteBetter and Color3.fromRGB(20, 22, 28) or Color3.fromRGB(235, 238, 245)
	if mate and mate ~= 0 then
		evalBarLabel.Text = "M" .. tostring(math.abs(mate))
	else
		evalBarLabel.Text = string.format("%.1f", math.abs((cp or 0) / 100))
	end
end

-- ============================================================================
-- 5. BEVERLYLIB INTERFACE (CLEAN, MINIMAL TOGGLES, POLISHED COPYWRITING)
-- ============================================================================
local THEME = {
	Accent = Color3.fromRGB(56, 217, 169),
	Gold = Color3.fromRGB(245, 196, 81),
	Amber = Color3.fromRGB(235, 168, 76),
}

local function httpGetText(url, retries)
	local attempts = retries or 3
	for i = 1, attempts do
		local ok, res = pcall(function()
			return game:HttpGet(url)
		end)
		if ok and type(res) == "string" and #res > 50 and not string.find(res, "^404:") then
			return res
		end
		if type(httpRequest) == "function" then
			local rok, rres = pcall(httpRequest, { Url = url, Method = "GET" })
			if rok and type(rres) == "table" and rres.Success and type(rres.Body) == "string" and #rres.Body > 50 then
				return rres.Body
			end
		end
		if i < attempts then
			task.wait(0.3 * i)
		end
	end
	return nil
end

local function loadRemoteLua(path)
	local src = httpGetText(LIB_BASE .. path, 3)
	if not src then
		return nil, "Failed to download " .. path
	end
	local fn, compileErr = loadstring(src)
	if type(fn) ~= "function" then
		return nil, "Compile error in " .. path .. ": " .. tostring(compileErr)
	end
	local ok, mod = pcall(fn)
	if not ok then
		return nil, "Runtime error in " .. path .. ": " .. tostring(mod)
	end
	return mod, nil
end

local Library, libErr = loadRemoteLua("Library.lua")
if not Library then
	error("[BeverlyHub] Failed to load BeverlyLIB: " .. tostring(libErr))
end
local ThemeManager = loadRemoteLua("addons/ThemeManager.lua")
local SaveManager = loadRemoteLua("addons/SaveManager.lua")

local Options = Library.Options
local Toggles = Library.Toggles

local Window = Library:CreateWindow({
	Title = "BeverlyHub",
	Badge = "RoChess",
	Footer = "RoChess! · Hybrid Stockfish Engine",
	FooterLeft = "BeverlyHub",
	FooterRight = "v" .. HUB_VERSION,
	Size = UDim2.fromOffset(575, 535),
	Center = true,
	AutoShow = true,
	Resizable = true,
	TabLayout = "Top",
	NotifySide = "Right",
})

local Tabs = {
	Main = Window:AddTab("Engine", "cpu", "Board assist, engine mode, and live evaluation"),
	Settings = Window:AddTab("Settings", "settings", "Keybinds, offline tuning, themes, and configs"),
}

local triggerRecalc -- forward declaration
local performSafeAutoMove -- forward declaration
local cleanup -- forward declaration

local function hasLayer(map, name)
	if type(map) ~= "table" then
		return false
	end
	if map[name] == true then
		return true
	end
	for _, v in ipairs(map) do
		if v == name then
			return true
		end
	end
	return false
end

local function syncConfigFromUI()
	CONFIG.Enabled = (Toggles.BoardAssist == nil) or (Toggles.BoardAssist.Value == true)
	local layers = Options.VisualLayers and Options.VisualLayers.Value
	if type(layers) == "table" then
		CONFIG.ShowArrows = hasLayer(layers, "Best Move Arrow")
		CONFIG.ShowPonder = hasLayer(layers, "Opponent Ponder")
		CONFIG.ShowHighlights = hasLayer(layers, "Square Highlights")
		CONFIG.ShowEvalBar = hasLayer(layers, "Eval Bar")
		CONFIG.ShowEngineBadge = hasLayer(layers, "Engine Badge")
	end
	if Options.ArrowColor and typeof(Options.ArrowColor.Value) == "Color3" then
		CONFIG.ArrowColor = Options.ArrowColor.Value
	end
	if Options.EngineMode and type(Options.EngineMode.Value) == "string" then
		CONFIG.EngineMode = Options.EngineMode.Value
	end
	if Options.PlayStyle and type(Options.PlayStyle.Value) == "string" then
		CONFIG.PlayStyle = Options.PlayStyle.Value
	end
	if Options.StockfishDepth and tonumber(Options.StockfishDepth.Value) then
		CONFIG.StockfishDepth = math.clamp(math.floor(tonumber(Options.StockfishDepth.Value)), 8, 18)
	end
	if Options.LuauDepth and tonumber(Options.LuauDepth.Value) then
		CONFIG.LuauMaxDepth = math.clamp(math.floor(tonumber(Options.LuauDepth.Value)), 3, 8)
	end
	if Options.VpsApiUrl and type(Options.VpsApiUrl.Value) == "string" then
		CONFIG.VpsApiUrl = string.gsub(Options.VpsApiUrl.Value, "^%s*(.-)%s*$", "%1")
	end
	if Options.LocalWsUrl and type(Options.LocalWsUrl.Value) == "string" and Options.LocalWsUrl.Value ~= "" then
		CONFIG.LocalWsUrl = Options.LocalWsUrl.Value
	end
	CONFIG.OnlyMyTurn = (Toggles.OnlyMyTurn == nil) or (Toggles.OnlyMyTurn.Value == true)
	CONFIG.AntiEngineTurbo = (Toggles.AntiEngineTurbo == nil) or (Toggles.AntiEngineTurbo.Value == true)
	CONFIG.AutoPlay = (Toggles.AutoPlay ~= nil) and (Toggles.AutoPlay.Value == true)
	if Options.AutoDelayMin and tonumber(Options.AutoDelayMin.Value) then
		CONFIG.AutoDelayMin = math.clamp(tonumber(Options.AutoDelayMin.Value), 0.2, 5.0)
	end
	if Options.AutoDelayMax and tonumber(Options.AutoDelayMax.Value) then
		CONFIG.AutoDelayMax = math.clamp(tonumber(Options.AutoDelayMax.Value), 0.5, 10.0)
	end
	CONFIG.SmartDelay = (Toggles.SmartDelay == nil) or (Toggles.SmartDelay.Value == true)
	if Options.FastOpeningMoves and tonumber(Options.FastOpeningMoves.Value) then
		CONFIG.FastOpeningMoves = math.clamp(math.floor(tonumber(Options.FastOpeningMoves.Value)), 0, 12)
	end
	if Options.EndgamePieces and tonumber(Options.EndgamePieces.Value) then
		CONFIG.EndgamePieces = math.clamp(math.floor(tonumber(Options.EndgamePieces.Value)), 4, 18)
	end
	if Options.MaxClockLead and tonumber(Options.MaxClockLead.Value) then
		CONFIG.MaxClockLead = math.clamp(math.floor(tonumber(Options.MaxClockLead.Value)), 0, 90)
	end
	CONFIG.AutoFindMatch = (Toggles.AutoFindMatch ~= nil) and (Toggles.AutoFindMatch.Value == true)
	if Options.AutoFindTc and type(Options.AutoFindTc.Value) == "string" then
		CONFIG.AutoFindTc = Options.AutoFindTc.Value
	end
	STATE.LastArrowSig = ""
end

-- Tab 1 · Left: Board Assist & Automation
local AssistBox = Tabs.Main:AddGroupbox({
	Side = "Left",
	Name = "Board Assist",
	IconName = "compass",
})

AssistBox:AddToggle("BoardAssist", {
	Text = "Enable Assist",
	Default = true,
	Tooltip = "Displays move suggestions and evaluation directly on the board.",
}):AddKeyPicker("AssistKey", {
	Default = "G",
	Mode = "Toggle",
	SyncToggleState = true,
	Text = "Board Assist",
}):AddColorPicker("ArrowColor", {
	Default = Color3.fromRGB(56, 217, 169),
	Title = "Arrow Color",
})

AssistBox:AddDropdown("VisualLayers", {
	Text = "Visuals",
	Multi = true,
	Values = { "Best Move Arrow", "Opponent Ponder", "Square Highlights", "Eval Bar", "Engine Badge" },
	Default = { "Best Move Arrow", "Opponent Ponder", "Square Highlights", "Eval Bar", "Engine Badge" },
	Tooltip = "Select which visual guides appear over the board.",
})

AssistBox:AddDropdown("EngineMode", {
	Text = "Engine",
	Values = {
		Hybrid = "Hybrid (VPS SF19 → Cloud → Luau)",
		Stockfish = "Stockfish 19 VPS / Cloud",
		Luau = "Offline Luau (~2000 Elo)",
		LocalWS = "Local Bridge (WS)",
	},
	Default = "Hybrid",
	Tooltip = "Hybrid prioritizes your self-hosted Stockfish 19 VPS, falls back to Stockfish Cloud, then Offline Luau under 8s or on error.",
})

AssistBox:AddSlider("StockfishDepth", {
	Text = "Search Depth",
	Default = 15,
	Min = 8,
	Max = 18,
	Rounding = 0,
	Suffix = " ply",
	Tooltip = "Stockfish 19 VPS supports up to 18 ply with adaptive movetime (stockfish.online fallback auto-clamps to 15).",
})

AssistBox:AddDivider("Automation")

AssistBox:AddToggle("AutoPlay", {
	Text = "Auto Play",
	Default = false,
	Risky = true,
	Tooltip = "Automatically plays the best move using simulated mouse input with verified retry.",
})

AssistBox:AddSlider("AutoDelayMin", {
	Text = "Min Delay",
	Default = 1.0,
	Min = 0.2,
	Max = 5.0,
	Rounding = 1,
	Suffix = "s",
	Compact = true,
	Tooltip = "Minimum random delay before playing a move.",
})

AssistBox:AddSlider("AutoDelayMax", {
	Text = "Max Delay",
	Default = 5.0,
	Min = 0.5,
	Max = 10.0,
	Rounding = 1,
	Suffix = "s",
	Compact = true,
	Tooltip = "Maximum random delay before playing a move.",
})

AssistBox:AddToggle("AutoFindMatch", {
	Text = "Auto Find Match",
	Default = false,
	Tooltip = "Automatically queues a new online match when idle or after a game ends (pauses during tournaments).",
})

AssistBox:AddDropdown("AutoFindTc", {
	Text = "Queue Time Control",
	Values = {
		Selected = "Current Selected",
		["1+0"] = "Bullet 1 min",
		["1+1"] = "Bullet 1 | 1",
		["2+1"] = "Bullet 2 | 1",
		["3+0"] = "Blitz 3 min",
		["3+2"] = "Blitz 3 | 2",
		["5+0"] = "Blitz 5 min",
		["10+0"] = "Rapid 10 min",
		["15+10"] = "Rapid 15 | 10",
		["30+0"] = "Rapid 30 min",
	},
	Default = "Selected",
	Tooltip = "Time control used by Auto Find Match.",
})

-- Tab 1 · Right: Live Analysis & Anti-Engine Combat
local AnalysisBox = Tabs.Main:AddGroupbox({
	Side = "Right",
	Name = "Live Analysis",
	IconName = "activity",
})

AnalysisBox:AddLabel("MatchLabel", { Text = "Match: Idle", DoesWrap = false })
AnalysisBox:AddLabel("EngineLabel", { Text = "Active Engine: Idle", DoesWrap = false })
AnalysisBox:AddLabel("OpponentLabel", { Text = "Opponent: --", DoesWrap = false })
AnalysisBox:AddLabel("BestMoveLabel", { Text = "Best Move: --", DoesWrap = false })
AnalysisBox:AddLabel("EvalLabel", { Text = "Eval: 0.00  ·  Ready", DoesWrap = false })
AnalysisBox:AddLabel("LineLabel", { Text = "Line: --", DoesWrap = true })

AnalysisBox:AddDivider("Combat & Preferences")

AnalysisBox:AddDropdown("PlayStyle", {
	Text = "Play Style",
	Values = {
		GM = "GM (~2600 · Balanced)",
		SuperGM = "Super-GM (~2850 · Sharp)",
		Master = "Master (~2350 · Casual)",
		Full = "Full Engine (~3500 · PV1)",
	},
	Default = "GM",
	Tooltip = "Uses VPS MultiPV 3 to play authentic GM/Master moves & opening variety. Automatically switches to Full Engine when an engine opponent is detected.",
})

AnalysisBox:AddToggle("AntiEngineTurbo", {
	Text = "Anti-Engine Turbo",
	Default = true,
	Tooltip = "Detects engine opponents via Stockfish agreement & cadence, prefetches ponder replies during their turn (0ms), and switches to fast pacing when matched or down on time.",
})

AnalysisBox:AddToggle("OnlyMyTurn", {
	Text = "My Turn Only",
	Default = true,
	Tooltip = "Hide arrows while waiting for your opponent (ponder prefetch still prepares your next reply).",
})

AnalysisBox:AddButton("Recalculate", function()
	syncConfigFromUI()
	STATE.VpsCooldownUntil = 0
	STATE.VpsFailStreak = 0
	STATE.SfCooldownUntil = 0
	STATE.SfFailStreak = 0
	if triggerRecalc then
		triggerRecalc(true)
	end
end):AddButton("Clear Cache", function()
	table.clear(STATE.Cache)
	table.clear(STATE.CacheOrder)
	PureChess.clearTT()
	STATE.VpsCooldownUntil = 0
	STATE.VpsFailStreak = 0
	STATE.SfCooldownUntil = 0
	STATE.SfFailStreak = 0
	Library:Notify({ Title = "Cache Cleared", Description = "Position cache, TT, and API cooldowns reset.", Time = 2.5 })
	if triggerRecalc then
		triggerRecalc(true)
	end
end)

-- Tab 2: Settings
local MenuGroup = Tabs.Settings:AddGroupbox({
	Side = "Left",
	Name = "Menu & Advanced",
	IconName = "sliders-horizontal",
})

MenuGroup:AddLabel("Menu Keybind"):AddKeyPicker("MenuKeybind", {
	Default = "RightShift",
	NoUI = true,
	Text = "Menu Keybind",
})

MenuGroup:AddSlider("LuauDepth", {
	Text = "Offline Luau Depth",
	Default = 6,
	Min = 3,
	Max = 8,
	Rounding = 0,
	Suffix = " ply",
	Tooltip = "Maximum search depth for the built-in offline Luau fallback engine.",
})

MenuGroup:AddInput("VpsApiUrl", {
	Text = "Stockfish VPS URL",
	Default = CONFIG.VpsApiUrl,
	Placeholder = "http://your-vps:8765 or tunnel URL",
	ClearTextOnFocus = false,
	Finished = true,
	Tooltip = "Self-hosted Stockfish 19 HTTP endpoint (clear to use stockfish.online directly).",
})

MenuGroup:AddInput("LocalWsUrl", {
	Text = "Local Bridge URL",
	Default = "ws://127.0.0.1:8765",
	Placeholder = "ws://127.0.0.1:8765",
	ClearTextOnFocus = false,
	Finished = true,
	Tooltip = "WebSocket endpoint used when Engine is set to Local Bridge.",
})

MenuGroup:AddDivider("Smart Delay Pacing")

MenuGroup:AddToggle("SmartDelay", {
	Text = "Smart Phase Delay",
	Default = true,
	Tooltip = "Fast moves in opening, forced tactics, recaptures, and endgames; normal randomized delay in middlegame.",
})

MenuGroup:AddSlider("FastOpeningMoves", {
	Text = "Fast Opening",
	Default = 5,
	Min = 0,
	Max = 12,
	Rounding = 0,
	Suffix = " moves",
	Compact = true,
	Tooltip = "First N full moves play quickly (~0.25–0.85s) like opening theory.",
})

MenuGroup:AddSlider("EndgamePieces", {
	Text = "Endgame Speedup",
	Default = 10,
	Min = 4,
	Max = 18,
	Rounding = 0,
	Suffix = " pcs",
	Compact = true,
	Tooltip = "Automatically speed up Auto Play once total pieces remaining on the board drop to <= N.",
})

MenuGroup:AddSlider("MaxClockLead", {
	Text = "Max Clock Lead",
	Default = 30,
	Min = 0,
	Max = 90,
	Rounding = 0,
	Suffix = "s",
	Compact = true,
	Tooltip = "Caps how far ahead your clock stays vs your opponent (0 = off). Naturally thinks longer if ahead by more than N seconds (paused in Turbo or low clock).",
})

MenuGroup:AddDivider()

MenuGroup:AddButton({
	Text = "Unload BeverlyHub",
	Risky = true,
	Func = function()
		if cleanup then
			cleanup()
		end
	end,
})

Library.ToggleKeybind = Options.MenuKeybind

-- Hook UI callbacks
Toggles.BoardAssist:OnChanged(function()
	syncConfigFromUI()
	if triggerRecalc then triggerRecalc(true) end
end)
Options.ArrowColor:OnChanged(syncConfigFromUI)
Options.VisualLayers:OnChanged(syncConfigFromUI)
Options.EngineMode:OnChanged(function()
	syncConfigFromUI()
	if triggerRecalc then triggerRecalc(true) end
end)
Options.PlayStyle:OnChanged(function()
	syncConfigFromUI()
	if triggerRecalc then triggerRecalc(true) end
end)
Options.StockfishDepth:OnChanged(function()
	syncConfigFromUI()
	if triggerRecalc then triggerRecalc(true) end
end)
Options.LuauDepth:OnChanged(function()
	syncConfigFromUI()
	if CONFIG.EngineMode == "Luau" and triggerRecalc then triggerRecalc(true) end
end)
Options.VpsApiUrl:OnChanged(function()
	syncConfigFromUI()
	STATE.VpsCooldownUntil = 0
	STATE.VpsFailStreak = 0
	if triggerRecalc then triggerRecalc(true) end
end)
Options.LocalWsUrl:OnChanged(syncConfigFromUI)
Toggles.OnlyMyTurn:OnChanged(function()
	syncConfigFromUI()
	if triggerRecalc then triggerRecalc(true) end
end)
Toggles.AntiEngineTurbo:OnChanged(function()
	syncConfigFromUI()
	if not CONFIG.AntiEngineTurbo then
		STATE.Opp.turboActive = false
		STATE.Opp.turboReason = nil
	end
end)
Toggles.AutoPlay:OnChanged(function(val)
	syncConfigFromUI()
	if val then
		STATE.LastAutoKey = ""
		STATE.AutoRetryAfter = 0
		if STATE.CurrentResult and STATE.App and STATE.App.session then
			performSafeAutoMove(STATE.App.session, STATE.CurrentResult, STATE.LastKey)
		elseif triggerRecalc then
			triggerRecalc(true)
		end
	end
end)
Options.AutoDelayMin:OnChanged(syncConfigFromUI)
Options.AutoDelayMax:OnChanged(syncConfigFromUI)
Toggles.SmartDelay:OnChanged(syncConfigFromUI)
Options.FastOpeningMoves:OnChanged(syncConfigFromUI)
Options.EndgamePieces:OnChanged(syncConfigFromUI)
Options.MaxClockLead:OnChanged(syncConfigFromUI)
Toggles.AutoFindMatch:OnChanged(function(val)
	syncConfigFromUI()
	if val then
		STATE.AutoFindLastQueueAt = 0
	end
end)
Options.AutoFindTc:OnChanged(syncConfigFromUI)

-- ThemeManager & SaveManager
if ThemeManager and SaveManager then
	pcall(function()
		ThemeManager:SetLibrary(Library)
		SaveManager:SetLibrary(Library)
		SaveManager:IgnoreThemeSettings()
		SaveManager:SetIgnoreIndexes({ "MenuKeybind" })
		ThemeManager:SetFolder("BeverlyHub")
		SaveManager:SetFolder("BeverlyHub/RoChess")
		SaveManager:BuildConfigSection(Tabs.Settings)
		ThemeManager:ApplyToTab(Tabs.Settings)
		SaveManager:LoadAutoloadConfig()
	end)
end

syncConfigFromUI()

-- ============================================================================
-- 6. SAFE AUTO-PLAY VIA REAL VIRTUAL INPUT CLICKS (PASSES u152 & fromInput())
-- ============================================================================
local function sendSafeClick(viewportX, viewportY)
	local ok, vim = pcall(function()
		return game:GetService("VirtualInputManager")
	end)
	if not ok or not vim then
		return false
	end
	pcall(function()
		vim:SendMouseMoveEvent(viewportX, viewportY, game)
	end)
	task.wait(0.03 + math.random() * 0.04)
	pcall(function()
		vim:SendMouseButtonEvent(viewportX, viewportY, 0, true, game, 1)
	end)
	task.wait(0.03 + math.random() * 0.04)
	pcall(function()
		vim:SendMouseButtonEvent(viewportX, viewportY, 0, false, game, 1)
	end)
	return true
end

local function randTriangular(lo, hi)
	if hi <= lo then
		return lo
	end
	local u = (math.random() + math.random()) * 0.5
	return lo + u * (hi - lo)
end

local function getLiveClockMs(session, color)
	if not session or not session.clocks or not color then
		return nil
	end
	if type(session.clockFor) == "function" then
		local ok, ms = pcall(session.clockFor, session, color, workspace:GetServerTimeNow())
		if ok and type(ms) == "number" then
			return ms
		end
	end
	return session.clocks[color]
end

local function computeSmartAutoDelay(session, res)
	local kind = session.kind
	local turbo = CONFIG.AntiEngineTurbo and STATE.Opp.turboActive and kind == "online"
	local lo = math.min(CONFIG.AutoDelayMin or 1.0, CONFIG.AutoDelayMax or 5.0)
	local hi = math.max(CONFIG.AutoDelayMin or 1.0, CONFIG.AutoDelayMax or 5.0)
	local msLeft = (kind == "online" and session.myColor) and getLiveClockMs(session, session.myColor) or nil
	local oppMsLeft = (kind == "online" and session.myColor) and getLiveClockMs(session, -session.myColor) or nil

	if turbo then
		local fastHi = (msLeft and msLeft < 10000) and 0.24 or 0.34
		return randTriangular(0.10, fastHi), "Turbo"
	end
	if msLeft and msLeft < 12000 then
		return randTriangular(0.09, 0.24), "Scramble"
	end
	if kind == "puzzle" or kind == "rush" then
		return randTriangular(math.min(lo, 0.25), math.min(hi, 0.90)), "Puzzle"
	end

	local target = randTriangular(lo, hi)
	local phaseTag = "Normal"
	local isForcedMate = (res.mate ~= nil and math.abs(res.mate) <= 2)

	if CONFIG.SmartDelay and session.engine then
		local ply = (session.ucis and #session.ucis) or 0
		local fullMove = math.floor(ply / 2) + 1
		local fen = session.engine:getFen()
		local totalPieces = countFenPieces(fen)

		-- Detect forced single legal move (quick check)
		local onlyOneLegal = false
		pcall(function()
			local b = PureChess.new(fen)
			local legal = b:legalMoves()
			if #legal == 1 then
				onlyOneLegal = true
			end
		end)

		-- Detect immediate recapture on opponent's last destination square
		local lastOppUci = (ply >= 1 and session.ucis) and session.ucis[ply] or nil
		local isRecapture = (type(lastOppUci) == "string" and #lastOppUci >= 4 and type(res.best) == "string" and #res.best >= 4)
			and (string.sub(lastOppUci, 3, 4) == string.sub(res.best, 3, 4))

		if isForcedMate or onlyOneLegal then
			-- Instant forced mate or only legal move
			target = randTriangular(math.min(lo, 0.18), math.min(hi, 0.55))
			phaseTag = onlyOneLegal and "Forced" or "Mate Snap"
		elseif CONFIG.FastOpeningMoves > 0 and fullMove <= CONFIG.FastOpeningMoves then
			-- Opening book / theory phase: fast & natural slight ramp from move 1 to N
			local progress = (fullMove - 1) / math.max(1, CONFIG.FastOpeningMoves)
			local openLo = math.min(lo, 0.22 + progress * 0.12)
			local openHi = math.min(hi, 0.62 + progress * 0.32)
			target = randTriangular(openLo, math.max(openLo + 0.05, openHi))
			phaseTag = "Opening #" .. tostring(fullMove)
		elseif totalPieces <= (CONFIG.EndgamePieces or 10) then
			-- Simplified endgame speedup
			if totalPieces <= 6 then
				target = randTriangular(math.min(lo, 0.16), math.min(hi, 0.48))
			else
				target = randTriangular(math.min(lo, 0.22), math.min(hi, 0.78))
			end
			phaseTag = "Endgame · " .. tostring(totalPieces) .. " pcs"
		elseif isRecapture then
			-- Natural quick recapture in middlegame
			target = math.max(0.32, randTriangular(lo, hi) * 0.48)
			phaseTag = "Recapture"
		else
			-- Complexity-aware Middlegame: correlate think time with tactical sharpness (pvGapCp & evalSwing)
			local mid = 0.65 * randTriangular(lo, hi) + 0.35 * (lo + math.random() * math.max(0.04, hi - lo))
			local pvGap = res.pvGapCp
			local evalSwing = res.evalSwing or 0
			local isQuietSharp = (not res.isCapture) and ((pvGap ~= nil and pvGap >= 55 and pvGap <= 280) or evalSwing >= 140)
			local isCalm = (pvGap ~= nil and pvGap <= 18 and evalSwing < 55)

			if isQuietSharp then
				target = math.min(hi + 2.6, mid * randTriangular(1.25, 1.65))
				phaseTag = "Deep Think"
			elseif isCalm then
				target = math.max(lo * 0.72, mid * randTriangular(0.68, 0.92))
				phaseTag = "Calm Mid"
			else
				target = mid
				phaseTag = "Middlegame"
			end
		end
	end

	-- Base online clock safety cap (never stall on low clock or bullet games)
	if msLeft then
		local secLeft = msLeft / 1000
		if secLeft < 15 then
			target = math.min(target, 0.28)
		elseif secLeft < 30 then
			target = math.min(target, 0.85)
		elseif secLeft < 60 then
			target = math.min(target, math.max(0.45, secLeft * 0.055))
		elseif secLeft < 120 then
			target = math.min(target, math.max(0.75, secLeft * 0.045))
		end
	end

	-- Max Clock Lead Cap (anti-sus pacing: keeps remaining clock at most ~N sec ahead of opponent)
	local leadCap = CONFIG.MaxClockLead or 30
	if leadCap > 0 and msLeft and oppMsLeft and not STATE.Opp.engineDetected and not isForcedMate then
		local mySec = msLeft / 1000
		local oppSec = oppMsLeft / 1000
		local leadSec = mySec - oppSec

		-- Safety guard: only bleed lead while we still have a healthy clock (>= 42s) and never bleed below 35s
		if mySec >= 42 then
			local safeBleedBudget = math.max(0, mySec - 35)
			if leadSec > leadCap then
				-- Smoothly bleed excess lead back down to <= leadCap (max ~12s per single move so it looks natural)
				local excess = leadSec - leadCap
				local bleed = excess * randTriangular(0.55, 0.90) + randTriangular(0.4, 1.8)
				local maxThink = math.min(12.0, safeBleedBudget)
				target = math.min(maxThink, math.max(target + bleed * 0.55, bleed))
				phaseTag = string.format("Lead Cap (+%ds)", math.floor(leadSec + 0.5))
			elseif leadSec >= (leadCap - 7) and mySec >= 55 then
				-- Soft cushion near the cap so our clock cruises smoothly around +23..30s instead of overshooting
				local closeness = math.clamp((leadSec - (leadCap - 7)) / 7, 0, 1)
				local cushion = closeness * randTriangular(0.5, 1.9)
				target = math.min(safeBleedBudget, target + cushion)
			end
		end
	end

	return target, phaseTag
end

performSafeAutoMove = function(session, res, expectedKey)
	if STATE.AutoPending or not CONFIG.AutoPlay or not STATE.Alive then
		return
	end
	if os.clock() < (STATE.AutoRetryAfter or 0) then
		return
	end
	if not session or session.over or not session:isMyTurn() then
		return
	end
	local kind = session.kind
	if kind ~= "online" and kind ~= "bot" and kind ~= "puzzle" and kind ~= "rush" and kind ~= "tutorial" then
		return
	end
	local app = STATE.App
	local board = app and app.board or STATE.Board
	if not board or not board.frame or not board.frame.Visible or not board.interactive or board.frame.AbsoluteSize.X < 80 then
		return
	end
	if app and type(app.fullPage) == "function" then
		local okFull, isFull = pcall(app.fullPage)
		if okFull and isFull then
			return
		end
	end
	if not res or not res.fromSq or not res.toSq then
		return
	end

	STATE.AutoPending = true
	STATE.AutoPendingAt = os.clock()
	STATE.LastAutoKey = expectedKey

	task.spawn(function()
		local turbo = CONFIG.AntiEngineTurbo and STATE.Opp.turboActive and kind == "online"
		local targetTotal, phaseTag = computeSmartAutoDelay(session, res)
		local spent = (res.ms or 0) / 1000
		local minAfterArrow = turbo and 0.06 or 0.16
		local waitSec = math.max(minAfterArrow, targetTotal - spent)

		-- On move 1 (ply 0), ensure game-start board transition/flip has settled before clicking!
		local plyNow = (session.ucis and #session.ucis) or 0
		if plyNow == 0 and STATE.SessionStartedAt > 0 then
			local sinceStart = os.clock() - STATE.SessionStartedAt
			local settleNeed = 0.40 - sinceStart
			if settleNeed > waitSec then
				waitSec = settleNeed
			end
		end

		STATE.AutoExpectedWait = waitSec
		if Window and type(Window.SetScriptStatus) == "function" then
			pcall(Window.SetScriptStatus, Window, "Auto · " .. phaseTag, string.format("%s · %.2fs", res.san or res.best, waitSec))
		end

		local endAt = os.clock() + waitSec
		while os.clock() < endAt do
			if not STATE.Alive or not CONFIG.AutoPlay or STATE.LastKey ~= expectedKey then
				STATE.AutoPending = false
				return
			end
			-- If Turbo activates mid-wait, cut remaining wait immediately!
			if CONFIG.AntiEngineTurbo and STATE.Opp.turboActive and kind == "online" and (endAt - os.clock()) > 0.25 then
				endAt = os.clock() + 0.12
			end
			task.wait(0.04)
		end

		-- Verified click loop (up to 3 attempts; clears LastAutoKey with backoff if clicks did not register!)
		local targetPly = #session.ucis
		local moveRegistered = false
		for attempt = 1, 3 do
			local curApp = STATE.App
			if not STATE.Alive or not CONFIG.AutoPlay or not curApp or curApp.session ~= session or session.over or not session:isMyTurn() then
				moveRegistered = true
				break
			end
			if #session.ucis ~= targetPly then
				moveRegistered = true
				break
			end
			local curBoard = curApp.board
			local f = curBoard and curBoard.frame
			if not f or not f.Visible or not curBoard.interactive or f.AbsoluteSize.X < 80 then
				task.wait(0.14)
				continue
			end

			if attempt > 1 and type(curBoard.deselect) == "function" then
				pcall(function() curBoard:deselect() end)
				task.wait(0.05)
			end

			local inset = GuiService:GetGuiInset()
			local sqPx = f.AbsoluteSize.X / 8
			local jitter = sqPx * 0.11
			local pFrom = f.AbsolutePosition + inset + sqCenterLocal(res.fromSq, curBoard.flipped, sqPx)
			local pTo = f.AbsolutePosition + inset + sqCenterLocal(res.toSq, curBoard.flipped, sqPx)

			sendSafeClick(pFrom.X + (math.random() * 2 - 1) * jitter, pFrom.Y + (math.random() * 2 - 1) * jitter)
			-- Occasional brief human piece-hold pause in non-Turbo middlegame before dropping piece
			local clickPause = (turbo and 0.045 or 0.075) + math.random() * (turbo and 0.035 or 0.065)
			if not turbo and plyNow >= 8 and attempt == 1 and math.random() < 0.22 then
				local msCheck = (kind == "online" and session.myColor) and getLiveClockMs(session, session.myColor) or 60000
				if msCheck and msCheck > 30000 then
					clickPause += 0.16 + math.random() * 0.34
				end
			end
			task.wait(clickPause)

			if not STATE.Alive or curApp.session ~= session or #session.ucis ~= targetPly then
				moveRegistered = true
				break
			end
			sendSafeClick(pTo.X + (math.random() * 2 - 1) * jitter, pTo.Y + (math.random() * 2 - 1) * jitter)

			-- Handle manual promotion popup if it opens
			if res.promo and res.promo ~= 0 and curBoard.overlayLayer then
				task.wait(0.10)
				local col = curBoard.overlayLayer:FindFirstChild("PromoColumn")
				if col then
					local btn = col:FindFirstChild("Choice" .. tostring(res.promo))
					if btn and btn:IsA("GuiObject") then
						local pc = btn.AbsolutePosition + inset + btn.AbsoluteSize * 0.5
						sendSafeClick(pc.X, pc.Y)
					end
				end
			end

			-- Verify move registered before finishing
			local verifyUntil = os.clock() + (turbo and 0.24 or 0.38)
			while os.clock() < verifyUntil do
				if not STATE.Alive or curApp.session ~= session or session.over or #session.ucis ~= targetPly or not session:isMyTurn() then
					moveRegistered = true
					break
				end
				task.wait(0.04)
			end
			if moveRegistered or #session.ucis ~= targetPly or not session:isMyTurn() or session.over then
				moveRegistered = true
				break
			end
		end

		-- CRITICAL START-OF-GAME RECOVERY: If board/intro ate all 3 clicks, unlock LastAutoKey so watchdog retries!
		if not moveRegistered and STATE.Alive and STATE.App and STATE.App.session == session and not session.over and session:isMyTurn() and #session.ucis == targetPly then
			STATE.LastAutoKey = ""
			STATE.AutoRetryAfter = os.clock() + 0.55
		end
		STATE.AutoPending = false
	end)
end

-- ============================================================================
-- 7. MAIN WATCHER & RENDER LOOP
-- ============================================================================
local function connectToRoChess()
	local chessClient = ReplicatedStorage:FindFirstChild("ChessClient")
	if not chessClient then return false end
	local appMod = chessClient:FindFirstChild("App")
	if not appMod then return false end
	local ok, app = pcall(require, appMod)
	if not ok or type(app) ~= "table" then return false end
	STATE.App = app
	STATE.Board = app.board
	return true
end

local function isBoardRenderable()
	local app = STATE.App
	if not app or not app.board or not app.board.frame then
		return false
	end
	if not app.board.frame.Visible then
		return false
	end
	if type(app.fullPage) == "function" then
		local ok, isFull = pcall(app.fullPage)
		if ok and isFull then
			return false
		end
	end
	local sess = app.session
	if not sess or sess.kind == "idle" then
		return false
	end
	return true
end

local function renderOverlay()
	local app = STATE.App
	local board = app and app.board
	local sess = app and app.session
	local show = CONFIG.Enabled and isBoardRenderable() and board and board.frame and board.frame.AbsoluteSize.X > 40

	if not show then
		boardProxy.Visible = false
		evalBarFrame.Visible = false
		return
	end

	local f = board.frame
	local pos = f.AbsolutePosition
	local sz = f.AbsoluteSize
	local sqPx = sz.X / 8
	local flipped = board.flipped == true

	boardProxy.Visible = true
	boardProxy.Position = UDim2.fromOffset(pos.X, pos.Y)
	boardProxy.Size = UDim2.fromOffset(sz.X, sz.Y)

	-- Eval Bar (hide if game's native evalBar is already shown)
	local nativeEvalOn = app.evalBar and app.evalBar.Visible
	if CONFIG.ShowEvalBar and not nativeEvalOn then
		evalBarFrame.Visible = true
		evalBarFrame.Size = UDim2.fromOffset(22, sz.Y)
		evalBarFrame.Position = UDim2.fromOffset(pos.X - 28, pos.Y)
		if STATE.LastEvalFlip ~= flipped and STATE.CurrentResult then
			STATE.LastEvalFlip = flipped
			updateEvalBarVisual(STATE.CurrentResult.evalCp, STATE.CurrentResult.mate, flipped)
		end
	else
		evalBarFrame.Visible = false
	end

	-- Active Engine Badge on top-right corner of board (visible even when BeverlyHub menu is hidden)
	if CONFIG.ShowEngineBadge and not sess.over then
		engineBadge.Visible = true
	else
		engineBadge.Visible = false
	end

	local res = STATE.CurrentResult
	local validForTurn = res ~= nil
		and (not sess.over)
		and (not CONFIG.OnlyMyTurn or sess.myColor == nil or sess:isMyTurn())

	if not validForTurn then
		clearArrows()
		hlFromFrame.Visible = false
		hlToFrame.Visible = false
		promoBadge.Visible = false
		return
	end

	-- Highlights (controlled by Visuals multi-dropdown & custom arrow color)
	local accentColor = (res.mate and res.mate ~= 0) and THEME.Gold or (CONFIG.ArrowColor or THEME.Accent)
	if CONFIG.ShowHighlights and res.fromSq and res.toSq then
		local fc, fr = sqColRow(res.fromSq, flipped)
		local tc, tr = sqColRow(res.toSq, flipped)
		hlFromFrame.Position = UDim2.fromScale(fc / 8, fr / 8)
		hlToFrame.Position = UDim2.fromScale(tc / 8, tr / 8)
		hlFromFrame.BackgroundColor3 = accentColor
		hlToFrame.BackgroundColor3 = accentColor
		hlFromStroke.Color = accentColor
		hlToStroke.Color = accentColor
		hlFromFrame.Visible = true
		hlToFrame.Visible = true
	else
		hlFromFrame.Visible = false
		hlToFrame.Visible = false
	end

	-- Redraw arrows only when result, color, or board layout changed
	local arrowSig = table.concat({
		tostring(res.fromSq), tostring(res.toSq),
		tostring(res.ponderFrom), tostring(res.ponderTo),
		tostring(flipped), tostring(math.floor(sqPx)),
		tostring(CONFIG.ShowArrows), tostring(CONFIG.ShowPonder),
		tostring(res.mate), tostring(accentColor),
	}, "|")
	if STATE.LastArrowSig ~= arrowSig then
		STATE.LastArrowSig = arrowSig
		clearArrows()
		if CONFIG.ShowArrows then
			if CONFIG.ShowPonder and res.ponderFrom and res.ponderTo then
				drawBoardArrow(res.ponderFrom, res.ponderTo, flipped, sqPx, THEME.Amber, 0.56, 2)
			end
			drawBoardArrow(res.fromSq, res.toSq, flipped, sqPx, accentColor, 0.14, 3)
		end
	end

	-- Promotion badge
	if CONFIG.ShowArrows and res.promoChar and res.toSq then
		local tc, tr = sqColRow(res.toSq, flipped)
		promoBadge.Position = UDim2.fromOffset((tc + 1) * sqPx - 3, tr * sqPx + 3)
		promoBadge.Text = "=" .. res.promoChar
		promoBadge.Visible = true
	else
		promoBadge.Visible = false
	end
end

local function setUiLabel(name, text)
	local lbl = Library and Library.Labels and Library.Labels[name]
	if lbl and type(lbl.SetText) == "function" then
		lbl:SetText(text)
	end
end

local function setPulseStatus(status, detail)
	if Window and type(Window.SetScriptStatus) == "function" then
		pcall(Window.SetScriptStatus, Window, status, detail)
	end
end

local BADGE_COLORS = {
	vpssf = Color3.fromRGB(52, 211, 255),
	gm = Color3.fromRGB(72, 224, 168),
	stockfish = Color3.fromRGB(56, 217, 169),
	turbo = Color3.fromRGB(240, 86, 86),
	localws = Color3.fromRGB(96, 185, 255),
	luau = Color3.fromRGB(168, 130, 255),
	fallback = Color3.fromRGB(235, 168, 76),
	book = Color3.fromRGB(120, 210, 150),
	puzzle = Color3.fromRGB(245, 196, 81),
	thinking = Color3.fromRGB(245, 196, 81),
	idle = Color3.fromRGB(110, 118, 138),
}

local function updateEngineBadge(text, kind)
	engineBadgeText.Text = text
	engineBadgeDot.BackgroundColor3 = BADGE_COLORS[kind] or BADGE_COLORS.idle
end

local function resetOpponentTracker(gameId)
	local o = STATE.Opp
	o.gameId = gameId
	o.lastPly = -1
	o.oppTurnStartAt = os.clock()
	o.expectedByPly = {}
	o.checked = 0
	o.hits = 0
	o.streak = 0
	o.maxStreak = 0
	o.fastHits = 0
	o.blunders = 0
	o.lastEvalForMe = nil
	o.times = {}
	o.suspicion = 0
	o.engineDetected = false
	o.turboActive = false
	o.turboReason = nil
	o.notified = false
	STATE.LastMyTurnResult = nil
	STATE.PrefetchKey = ""
	STATE.PrefetchInFlight = false
end

local function recomputeOpponentSuspicion()
	local o = STATE.Opp
	local score = 0
	local rate = (o.checked > 0) and (o.hits / o.checked) or 0

	if o.checked >= 5 then
		score += math.clamp(math.floor((rate - 0.45) * 140), 0, 62)
	elseif o.checked >= 3 then
		-- Preview score only (cannot trigger engineDetected until checked >= 5)
		score += math.clamp(math.floor((rate - 0.50) * 90), 0, 38)
	end

	if o.streak >= 6 then
		score += 36
	elseif o.streak == 5 then
		score += 26
	elseif o.streak == 4 then
		score += 15
	end

	if o.fastHits >= 5 then
		score += 20
	elseif o.fastHits == 4 then
		score += 12
	end

	-- Robotic cadence only contributes if opponent ALSO has high non-trivial accuracy (>= 65%)
	if #o.times >= 6 and o.checked >= 4 and rate >= 0.65 then
		local sum = 0
		for _, t in ipairs(o.times) do sum += t end
		local mean = sum / #o.times
		local var = 0
		for _, t in ipairs(o.times) do var += (t - mean) * (t - mean) end
		local std = math.sqrt(var / #o.times)
		if std < 0.32 and mean < 3.4 then
			score += 16
		end
	end

	-- Clear human blunder penalty (engines do not hang >= 2.00 pawns in balanced/playable positions)
	if (o.blunders or 0) > 0 then
		score -= o.blunders * 35
	end

	o.suspicion = math.clamp(score, 0, 100)

	-- Hysteresis latch: requires >= 5 non-trivial post-opening moves and >= 72% to engage;
	-- automatically disengages if suspicion falls below 45% (prevents permanent false positives!)
	if o.checked >= 5 and o.suspicion >= 72 then
		o.engineDetected = true
	elseif o.engineDetected and o.suspicion < 45 then
		o.engineDetected = false
		o.notified = false
	end
end

local function formatOpponentLabel(sess)
	if not sess or sess.kind ~= "online" then
		return "Opponent: --"
	end
	local o = STATE.Opp
	if o.engineDetected then
		return string.format("Opponent: ENGINE (%d%% · %d/%d) · TURBO", o.suspicion, o.hits, o.checked)
	elseif o.turboActive then
		return string.format("Opponent: %d%% · TURBO (%s)", o.suspicion, o.turboReason or "Clock")
	elseif o.checked > 0 then
		return string.format("Opponent: Human (%d%% · %d/%d match)", o.suspicion, o.hits, o.checked)
	end
	return "Opponent: Scanning..."
end

local function updateOpponentDetector(sess)
	if not sess or sess.kind ~= "online" or not sess.engine then
		if STATE.Opp.gameId ~= nil then
			resetOpponentTracker(nil)
		end
		return
	end

	local gid = tostring(sess.id or "online")
	local o = STATE.Opp
	if o.gameId ~= gid then
		resetOpponentTracker(gid)
	end

	local ply = sess.ucis and #sess.ucis or 0
	local now = os.clock()

	if ply ~= o.lastPly then
		local prevPly = o.lastPly
		o.lastPly = ply

		if not sess.over then
			if not sess:isMyTurn() then
				-- We just played our move; start opponent timer & prefetch their expected Stockfish ponder reply!
				o.oppTurnStartAt = now
				local myUci = sess.ucis[ply]
				local lastRes = STATE.LastMyTurnResult
				if lastRes and lastRes.best == myUci and type(lastRes.ponder) == "string" and #lastRes.ponder >= 4 then
					local oppFen = sess.engine:getFen()
					o.expectedByPly[ply + 1] = {
						uci = lastRes.ponder,
						myCapture = lastRes.isCapture == true,
						myToSq = string.sub(myUci, 3, 4),
						oppFen = oppFen,
					}
					launchPonderPrefetch(oppFen, lastRes.ponder)
				end
			elseif prevPly >= 0 and ply == prevPly + 1 then
				-- Opponent just moved! Filter out opening book (< ply 13), recaptures, and forced check evasions (<= 2 legal moves)
				local dt = now - (o.oppTurnStartAt > 0 and o.oppTurnStartAt or now)
				local oppUci = sess.ucis[ply]
				local exp = o.expectedByPly[ply]
				local isTrivial = false

				if type(exp) == "table" then
					local oppTo = (type(oppUci) == "string" and #oppUci >= 4) and string.sub(oppUci, 3, 4) or ""
					-- 1. Immediate recapture on the square we just captured on
					if exp.myCapture and oppTo == exp.myToSq then
						isTrivial = true
					end
					-- 2. Forced move / check evasion with <= 2 legal moves
					if not isTrivial and type(exp.oppFen) == "string" then
						pcall(function()
							local b = PureChess.new(exp.oppFen)
							if #b:legalMoves() <= 2 then
								isTrivial = true
							end
						end)
					end
				end

				-- Only record cadence timing on non-trivial post-opening moves so instant recaptures don't look robotic
				if ply >= 13 and not isTrivial and dt >= 0.04 and dt <= 120 then
					table.insert(o.times, dt)
					if #o.times > 20 then
						table.remove(o.times, 1)
					end
				end

				if ply >= 13 and type(exp) == "table" and exp.uci and not isTrivial then
					o.checked += 1
					if oppUci == exp.uci then
						o.hits += 1
						o.streak += 1
						if o.streak > o.maxStreak then o.maxStreak = o.streak end
						if dt <= 2.2 then
							o.fastHits += 1
						end
					else
						o.streak = 0
					end
				end

				recomputeOpponentSuspicion()
			end
		end
	end

	-- Smarter clock-deficit check (won't false-trigger in bullet or when we're already way ahead on time!)
	local clockPressure = false
	if not sess.over and sess.clocks and sess.myColor and type(sess.clockFor) == "function" then
		local srvNow = workspace:GetServerTimeNow()
		local myMs = sess:clockFor(sess.myColor, srvNow)
		local oppMs = sess:clockFor(-sess.myColor, srvNow)
		if myMs < 14000
			or (myMs < 26000 and oppMs > (myMs - 4000))
			or ((oppMs - myMs) >= 18000 and myMs < 75000)
		then
			clockPressure = true
		end
	end

	local wantTurbo = CONFIG.AntiEngineTurbo and (o.engineDetected or clockPressure)
	o.turboActive = wantTurbo
	o.turboReason = o.engineDetected and "Engine" or (clockPressure and "Clock" or nil)

	if o.engineDetected and not o.notified and CONFIG.AntiEngineTurbo then
		o.notified = true
		pcall(function()
			Library:Notify({
				Title = "Engine Opponent Detected",
				Description = string.format("Suspicion %d%% (%d/%d non-trivial top moves). Full SF19 + Turbo engaged.", o.suspicion, o.hits, o.checked),
				Time = 4.5,
			})
		end)
	end

	setUiLabel("OpponentLabel", formatOpponentLabel(sess))
end

local function tickAutoFindMatch(app, sess, now)
	if not CONFIG.AutoFindMatch or not app or not app.profile then
		return
	end
	if app.searching or app.joining then
		return
	end
	if type(app.inLiveGame) == "function" and app.inLiveGame() then
		STATE.AutoFindOverAt = 0
		return
	end
	-- Do not interfere while enrolled in a running Tournament bracket
	if app.Tournament and type(app.Tournament.isEntrant) == "function" then
		local okT, isInTour = pcall(app.Tournament.isEntrant)
		if okT and isInTour then
			return
		end
	end

	local canQueue = false
	if not sess or sess.kind == "idle" then
		canQueue = true
	elseif sess.kind == "online" and sess.over then
		if STATE.AutoFindOverAt == 0 then
			STATE.AutoFindOverAt = now
		end
		if now - STATE.AutoFindOverAt >= 2.4 then
			canQueue = true
		end
	else
		STATE.AutoFindOverAt = 0
	end

	if canQueue and (now - STATE.AutoFindLastQueueAt >= 5.0) and type(app.startSearch) == "function" then
		STATE.AutoFindLastQueueAt = now
		STATE.AutoFindOverAt = 0
		local tc = (CONFIG.AutoFindTc == "Selected") and app.selectedTc or CONFIG.AutoFindTc
		if app.modals and type(app.modals.closeAll) == "function" then
			pcall(app.modals.closeAll)
		end
		pcall(app.startSearch, tc)
	end
end

local function updateHudReadout(sess, res, thinking)
	if not sess or sess.kind == "idle" then
		setUiLabel("MatchLabel", "Match: Idle")
		setUiLabel("EngineLabel", "Active Engine: Standby (" .. CONFIG.EngineMode .. ")")
		setUiLabel("OpponentLabel", "Opponent: --")
		setUiLabel("BestMoveLabel", "Best Move: --")
		setUiLabel("EvalLabel", "Eval: 0.00  ·  Ready")
		setUiLabel("LineLabel", "Line: Start a match, bot game, or puzzle.")
		setPulseStatus("Idle", "Standby · " .. CONFIG.EngineMode)
		updateEngineBadge("Standby · " .. CONFIG.EngineMode, "idle")
		return
	end

	local kindCap = string.upper(string.sub(sess.kind, 1, 1)) .. string.sub(sess.kind, 2)
	local sideTxt = (sess.myColor == 1 and "White") or (sess.myColor == -1 and "Black") or (sess.engine.side == 1 and "White" or "Black")
	local turnTxt = sess.over and "Finished"
		or (sess.myColor == nil and (sideTxt .. " to move"))
		or (sess:isMyTurn() and ("Your Turn (" .. sideTxt .. ")") or "Opponent's Turn")

	setUiLabel("MatchLabel", "Match: " .. kindCap .. " · " .. turnTxt)
	setUiLabel("OpponentLabel", formatOpponentLabel(sess))

	local turboTag = (CONFIG.AntiEngineTurbo and STATE.Opp.turboActive and sess.kind == "online") and " [TURBO]" or ""

	if thinking then
		local activeName = STATE.ActiveEngine or CONFIG.EngineMode
		setUiLabel("EngineLabel", "Active Engine: " .. activeName .. turboTag .. " (Thinking...)")
		setUiLabel("BestMoveLabel", "Best Move: Calculating...")
		setUiLabel("EvalLabel", "Eval: --")
		setPulseStatus("Thinking", activeName .. turboTag)
		updateEngineBadge(activeName .. turboTag .. " ...", "thinking")
		return
	end

	if res then
		local engName = res.engineLabel or res.source or "Engine"
		local engKind = (turboTag ~= "" and "turbo") or (res.engineKind or "stockfish")
		local depthTag = (res.depth and res.depth > 0 and res.depth < 99) and (" d" .. tostring(res.depth)) or ""
		local msTag = (res.ms and res.ms >= 0) and (" · " .. tostring(res.ms) .. "ms") or ""

		setUiLabel("EngineLabel", "Active Engine: " .. engName .. depthTag .. msTag .. turboTag)
		local shortCoords = string.sub(res.best, 1, 2) .. " → " .. string.sub(res.best, 3, 4) .. (res.promoChar and ("=" .. res.promoChar) or "")
		setUiLabel("BestMoveLabel", "Best Move: " .. (res.san or res.best) .. "  (" .. shortCoords .. ")")
		local evStr = formatEvalText(res.evalCp, res.mate)
		setUiLabel("EvalLabel", "Eval: " .. evStr)
		setUiLabel("LineLabel", "Line: " .. table.concat(res.pv or { res.best }, "  "))
		updateEvalBarVisual(res.evalCp, res.mate, STATE.Board and STATE.Board.flipped == true)
		setPulseStatus(engName .. turboTag, (res.san or res.best) .. " (" .. evStr .. ")" .. depthTag)
		updateEngineBadge(engName .. depthTag .. msTag .. turboTag, engKind)
	else
		local waitTxt = STATE.PrefetchInFlight and "Prefetching Ponder..." or ("Waiting (" .. CONFIG.EngineMode .. ")")
		setUiLabel("EngineLabel", "Active Engine: " .. waitTxt .. turboTag)
		setUiLabel("BestMoveLabel", sess.over and "Best Move: Game Over" or "Best Move: Waiting...")
		setUiLabel("EvalLabel", "Eval: --")
		setUiLabel("LineLabel", "Line: --")
		setPulseStatus(sess.over and "Finished" or "Waiting", kindCap .. " · " .. turnTxt)
		updateEngineBadge((sess.over and "Game Over" or waitTxt) .. turboTag, turboTag ~= "" and "turbo" or "idle")
	end
end

triggerRecalc = function(force)
	if not STATE.Alive then return end
	local app = STATE.App
	if not app then return end
	local sess = app.session
	if not sess or sess.kind == "idle" or not sess.engine then
		if STATE.LastKey ~= "IDLE" or STATE.LastSessionRef ~= nil then
			STATE.LastSessionRef = nil
			STATE.SessionStartedAt = 0
			STATE.LastKey = "IDLE"
			STATE.LastAutoKey = ""
			STATE.AutoPending = false
			STATE.AutoRetryAfter = 0
			STATE.SearchGen += 1
			STATE.Searching = false
			STATE.CurrentResult = nil
			STATE.LastArrowSig = ""
			updateHudReadout(sess, nil, false)
		end
		return
	end

	-- Cleanly reset stale AutoPlay / turn state whenever a brand-new game session starts (rematch, bot, tournament round)!
	if sess ~= STATE.LastSessionRef then
		STATE.LastSessionRef = sess
		STATE.SessionStartedAt = os.clock()
		STATE.LastAutoKey = ""
		STATE.AutoPending = false
		STATE.AutoPendingAt = 0
		STATE.AutoRetryAfter = 0
		STATE.LastKey = ""
		STATE.CurrentResult = nil
		STATE.LastEvalCp = nil
		STATE.MissingResultSince = 0
		STATE.LastArrowSig = ""
		force = true
	end

	-- Use displayed ply for analysis/review, live engine for active games
	local eng = (sess.kind == "analysis" or sess.kind == "review") and sess:engineAt(sess.viewPly) or sess.engine
	local fen = eng:getFen()
	local isMyTurnNow = (type(sess.isMyTurn) == "function") and (sess:isMyTurn() == true) or false
	local plyCount = (sess.ucis and #sess.ucis) or 0
	local key = table.concat({
		tostring(sess),
		tostring(sess.id or ""),
		tostring(sess.kind),
		tostring(sess.myColor),
		tostring(isMyTurnNow),
		tostring(plyCount),
		tostring(sess.viewPly),
		tostring(sess.over),
		fen,
		CONFIG.EngineMode,
		CONFIG.PlayStyle,
		tostring(CONFIG.StockfishDepth),
		tostring(CONFIG.LuauMaxDepth),
		tostring(CONFIG.OnlyMyTurn),
	}, "|")

	if not force and key == STATE.LastKey then
		return
	end
	STATE.LastKey = key
	STATE.SearchGen += 1
	local myGen = STATE.SearchGen
	STATE.CurrentResult = nil
	STATE.LastArrowSig = ""
	STATE.MissingResultSince = 0

	if sess.over or not CONFIG.Enabled then
		STATE.Searching = false
		updateHudReadout(sess, nil, false)
		return
	end

	if CONFIG.OnlyMyTurn and sess.myColor ~= nil and not sess:isMyTurn() then
		STATE.Searching = false
		updateHudReadout(sess, nil, false)
		return
	end

	STATE.Searching = true
	STATE.SearchStartedAt = os.clock()
	STATE.ActiveEngine = (CONFIG.EngineMode == "Luau") and "Offline Luau"
		or ((CONFIG.EngineMode == "LocalWS") and "Local Stockfish WS"
			or ((hasVpsConfigured() and os.clock() >= STATE.VpsCooldownUntil) and "Stockfish 19 VPS" or "Stockfish Cloud"))
	STATE.ActiveEngineKind = "thinking"
	updateHudReadout(sess, nil, true)

	task.spawn(function()
		local okSolve, res = pcall(solvePosition, fen, sess, myGen, function(stageLabel)
			if STATE.Alive and myGen == STATE.SearchGen then
				STATE.ActiveEngine = stageLabel
				updateHudReadout(sess, nil, true)
			end
		end)
		if not STATE.Alive or myGen ~= STATE.SearchGen then
			return
		end
		STATE.Searching = false
		if not okSolve then
			res = nil
		end
		STATE.CurrentResult = res
		if res then
			if sess:isMyTurn() then
				local rawTopCp = (type(res.lines) == "table" and res.lines[1] and res.lines[1].evalCp) or res.evalCp
				res.evalSwing = (STATE.LastEvalCp ~= nil and rawTopCp ~= nil) and math.abs(rawTopCp - STATE.LastEvalCp) or 0
				STATE.LastEvalCp = rawTopCp
				STATE.LastMyTurnResult = res

				-- Opponent Blunder Check (engines never hang >= 2.00 pawns in playable positions)
				if sess.kind == "online" and sess.myColor and rawTopCp ~= nil and res.mate == nil then
					local myEvalNow = rawTopCp * sess.myColor
					local prevMe = STATE.Opp.lastEvalForMe
					if prevMe ~= nil and math.abs(prevMe) < 500 and (myEvalNow - prevMe) >= 200 then
						STATE.Opp.blunders = (STATE.Opp.blunders or 0) + 1
						STATE.Opp.streak = 0
						recomputeOpponentSuspicion()
						setUiLabel("OpponentLabel", formatOpponentLabel(sess))
					end
					STATE.Opp.lastEvalForMe = myEvalNow
				end
			end
			STATE.ActiveEngine = res.engineLabel or res.source or CONFIG.EngineMode
			STATE.ActiveEngineKind = res.engineKind or "stockfish"
			STATE.MissingResultSince = 0
		end
		STATE.LastArrowSig = ""
		updateHudReadout(sess, res, false)

		if res and CONFIG.AutoPlay and STATE.LastAutoKey ~= key then
			performSafeAutoMove(sess, res, key)
		end
	end)
end

-- Multi-Layer Stuck-Protection Watchdogs (guarantees solver & AutoPlay never freeze)
local function tickWatchdogs(app, sess, now)
	if not app or not sess or sess.kind == "idle" or sess.over then
		STATE.MissingResultSince = 0
		return
	end

	local needMove = CONFIG.Enabled and (not CONFIG.OnlyMyTurn or sess.myColor == nil or sess:isMyTurn())

	-- 0. Tournament / Background-Page Start Detection:
	-- When a live online/tournament game starts while sitting on the Tournament/Home page (keepTourPanel),
	-- switch to the game board automatically if Auto Play is ON so move 1 never times out hidden behind the bracket!
	if CONFIG.AutoPlay and sess.kind == "online" and sess:isMyTurn() and app.pages and app.pages.current ~= "game" then
		if (now - STATE.SessionStartedAt) >= 0.35 and (now - STATE.LastPageSwitchAt) >= 2.0 and type(app.pages.show) == "function" then
			STATE.LastPageSwitchAt = now
			pcall(app.pages.show, "game")
		end
	end

	-- 1. Hard Search Timeout Watchdog (recovers if anything hangs mid-search)
	if STATE.Searching then
		local maxWait = (CONFIG.AntiEngineTurbo and STATE.Opp.turboActive) and 2.2 or 4.2
		if STATE.SearchStartedAt > 0 and (now - STATE.SearchStartedAt) > maxWait then
			STATE.SearchGen += 1
			STATE.Searching = false
			if hasVpsConfigured() and now >= STATE.VpsCooldownUntil then
				STATE.VpsFailStreak += 1
				if STATE.VpsFailStreak >= 2 then
					STATE.VpsCooldownUntil = now + 12
				end
			else
				STATE.SfFailStreak += 1
				if STATE.SfFailStreak >= 2 then
					STATE.SfCooldownUntil = now + 15
				end
			end
			STATE.LastKey = ""
			triggerRecalc(true)
			return
		end
	end

	-- 2. Empty-Result Recovery Watchdog (auto-retriggers if turn has no result)
	if needMove and (not STATE.Searching) and STATE.CurrentResult == nil then
		if STATE.MissingResultSince == 0 then
			STATE.MissingResultSince = now
		elseif (now - STATE.MissingResultSince) >= 0.75 then
			STATE.MissingResultSince = 0
			STATE.LastKey = ""
			triggerRecalc(true)
			return
		end
	else
		STATE.MissingResultSince = 0
	end

	-- 3. AutoPlay Deadlock Watchdog (clears stale AutoPending if anything interrupted click loop)
	if STATE.AutoPending then
		local maxPending = math.max((STATE.AutoExpectedWait or 0) + 5.0, math.max(CONFIG.AutoDelayMin or 1, CONFIG.AutoDelayMax or 5) + 5.5)
		if STATE.AutoPendingAt > 0 and (now - STATE.AutoPendingAt) > maxPending then
			STATE.AutoPending = false
			STATE.AutoExpectedWait = 0
			STATE.LastAutoKey = ""
		end
	elseif CONFIG.AutoPlay and STATE.CurrentResult and sess:isMyTurn() and STATE.LastAutoKey ~= STATE.LastKey then
		-- 4. Missed AutoPlay Turn Trigger
		performSafeAutoMove(sess, STATE.CurrentResult, STATE.LastKey)
	end
end

-- Cleanup routine (wired bidirectionally with Library:OnUnload)
local unloading = false
cleanup = function()
	if unloading then return end
	unloading = true
	STATE.Alive = false
	STATE.SearchGen += 1
	for _, conn in ipairs(STATE.Connections) do
		pcall(function() conn:Disconnect() end)
	end
	table.clear(STATE.Connections)
	clearArrows()
	pcall(function() overlayGui:Destroy() end)
	if arrowHeadImageObj then
		pcall(function() arrowHeadImageObj:Destroy() end)
	end
	if globalEnv.__RoChessHubCleanup == cleanup then
		globalEnv.__RoChessHubCleanup = nil
	end
	if Library and not Library.Unloaded and type(Library.Unload) == "function" then
		pcall(function() Library:Unload() end)
	end
end
globalEnv.__RoChessHubCleanup = cleanup
Library:OnUnload(cleanup)

-- Startup & Heartbeat Loop
task.spawn(function()
	local tries = 0
	while STATE.Alive and not connectToRoChess() and tries < 50 do
		tries += 1
		task.wait(0.2)
	end
	if not STATE.Alive then return end
	if not STATE.App then
		setUiLabel("MatchLabel", "Match: RoChess client not detected")
		return
	end

	STATE.Board = STATE.App.board
	updateHudReadout(STATE.App.session, nil, false)
	triggerRecalc(true)

	local lastCheck = 0
	trackConn(RunService.RenderStepped:Connect(function()
		if not STATE.Alive then return end
		local app = STATE.App
		STATE.Board = app and app.board
		renderOverlay()
		local now = os.clock()
		if now - lastCheck >= 0.12 then
			lastCheck = now
			local sess = app and app.session
			updateOpponentDetector(sess)
			triggerRecalc(false)
			tickWatchdogs(app, sess, now)
			tickAutoFindMatch(app, sess, now)
		end
	end))
end)
