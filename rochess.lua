--!nocheck
--[[
	BeverlyHub v2.4.0 — RoChess!
	Hybrid Chess Engine (Stockfish 19 VPS + Cloud + Independent Offline Luau Engine)
	RoChess-Native Coach HUD, Broadcast Eval Bar, Spectator Turbo Guard & Auto Next Puzzle
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
local HUB_VERSION = "2.4.0"

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
	DynamicModeColors = true, -- Automatically color arrows & highlights by active engine/mode
	ArrowColor = Color3.fromRGB(56, 217, 169),
	OnlyMyTurn = true,
	PuzzleHelper = true,
	AntiEngineTurbo = true, -- Auto-detect engine opponent + ponder prefetch + fast mode
	PauseTurboOnSpectate = true, -- Automatically pause Turbo while spectators are watching, resume when 0
	AutoPlay = false, -- OFF by default
	AutoNextPuzzle = false, -- OFF by default (auto-clicks Next when a puzzle finishes)
	AutoDelayMin = 1.0, -- seconds (middlegame base min)
	AutoDelayMax = 5.0, -- seconds (middlegame base max)
	SmartDelay = true, -- Fast opening & endgame, complexity middlegame, clock-aware cap
	FastOpeningMoves = 5, -- First N full moves play fast
	EndgamePieces = 10, -- Speed up when total pieces on board <= N
	MaxClockLead = 30, -- Max seconds ahead of opponent clock before naturally slowing down (0 = off)
	AutoFindMatch = false, -- OFF by default
	AutoFindTc = "Selected", -- "Selected" or TC id ("1+0", "3+2", etc.)
	AutoReloadOnTeleport = true, -- Re-queue loader automatically on cross-server match teleports
	-- Auto-Farm Elo (Natural Elo Grinder + Anti-Rungkat Controlled Loss)
	AutoFarm = false, -- OFF by default
	FarmLossMode = "BlunderResign", -- "BlunderResign" | "PlayWeak" | "LateResign"
	FarmLossAfterElo = 45, -- Target Elo gained before 1 controlled loss (with +-20% natural jitter)
	FarmStopAtElo = 0, -- Stop auto-farming once rating reaches target (0 = unlimited)
	FarmHumanBreather = true, -- Periodic 20-45s human breather every 5-8 games
	FarmKeepPositive = true, -- Anti-Rungkat Guard: defer throw if expected Elo loss is unsafe
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
	ActiveEngineKind = "idle", -- "idle" | "thinking" | "vpssf" | "gm" | "farm" | "stockfish" | "localws" | "luau" | "fallback" | "book" | "puzzle" | "turbo"
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
		gameRef = nil,
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
		spectators = 0,
		spectatorPaused = false,
		spectatorNotified = false,
		notified = false,
		adaptTier = nil,
		lastAdaptPly = -1,
	},
	-- Auto Find Match, Auto Next Puzzle & Auto-Farm Elo state
	AutoFindOverAt = 0,
	AutoFindLastQueueAt = 0,
	PuzzleDoneKey = "",
	PuzzleDoneAt = 0,
	PuzzleNextDelay = 1.15,
	PuzzleNextClickAt = 0,
	Farm = {
		data = nil,
		activeClass = nil,
		gameRef = nil,
		gameId = nil,
		gameAccounted = false,
		settlingGame = false,
		preMyRating = nil,
		preOppRating = nil,
		preProv = false,
		throwArmed = false,
		phase = "idle", -- "idle" | "opening" | "blunder" | "weak" | "resigning"
		throwStartMove = 10,
		maxBlunderMoves = 6,
		resignMinMove = 14,
		blunderMovesPlayed = 0,
		lastBlunderPly = -1,
		resignGen = 0,
		resignPending = false,
		deferReason = nil,
		breakUntil = 0,
		nextQueueDelay = 0,
		idleSince = 0,
		lastUiUpdate = 0,
		autoEnabledAutoPlay = false,
		autoEnabledAutoFind = false,
	},
	Cache = {},
	CacheOrder = {},
	CacheMax = 384,
	WsConn = nil,
}

local Farm = {} -- Populated after UI helpers; single top-level module for Auto-Farm Elo

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
	local CENTER_DIST = table.create(120, 0)
	for rank = 0, 7 do
		for file = 0, 7 do
			local idx64 = rank * 8 + file + 1
			local sq = 22 + file + rank * 10
			SQUARES[idx64] = sq
			SQ64[sq] = idx64
			PST_IDX_W[sq] = (7 - rank) * 8 + file + 1
			PST_IDX_B[sq] = rank * 8 + file + 1
			local df = math.max(3 - file, file - 4)
			local dr = math.max(3 - rank, rank - 4)
			CENTER_DIST[sq] = df + dr
		end
	end
	local PASSED_MG = { 5, 10, 20, 35, 60, 100 }
	local PASSED_EG = { 10, 20, 40, 75, 130, 210 }
	local evalWMinR = table.create(8, 8)
	local evalBMaxR = table.create(8, -1)
	local evalWPawns = table.create(8, 0)
	local evalBPawns = table.create(8, 0)

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

					-- Captures & EP (unrolled: zero per-pawn table allocation)
					for ci = -1, 1, 2 do
						local toSq = sq + dir + ci
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

	function Board:applyUciFast(uci)
		if type(uci) ~= "string" or #uci < 4 then return false end
		local fromSq = PureChess.algToSq(string.sub(uci, 1, 2))
		local toSq = PureChess.algToSq(string.sub(uci, 3, 4))
		if not fromSq or not toSq then return false end
		local pc = self.board[fromSq]
		if pc == EMPTY or pc == OFF or (pc > 0) ~= (self.side > 0) then
			return false
		end
		local pt = abs(pc)
		local promoCh = string.lower(string.sub(uci, 5, 5))
		local promo = (promoCh ~= "") and (CHAR_TO_PIECE[promoCh] or 0) or 0
		local flag = F_NONE
		if pt == KING and abs(toSq - fromSq) == 2 then
			flag = (toSq > fromSq) and F_OO or F_OOO
		elseif pt == PAWN then
			if abs(toSq - fromSq) == 20 then
				flag = F_DOUBLE
			elseif toSq == self.ep and self.ep ~= 0 then
				flag = F_EP
			end
		end
		self:makeMove(encodeMove(fromSq, toSq, promo, flag))
		return true
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
		local wPCount, bPCount = 0, 0
		for f = 1, 8 do
			evalWMinR[f] = 8
			evalBMaxR[f] = -1
		end
		for i = 1, 64 do
			local sq = SQUARES[i]
			local pc = b[sq]
			if pc > 0 then
				local idx = PST_IDX_W[sq]
				mgW += MG_VAL[pc] + MG_PST[pc][idx]
				egW += EG_VAL[pc] + EG_PST[pc][idx]
				phase += PHASE_W[pc]
				if pc == BISHOP then
					bishW += 1
				elseif pc == PAWN then
					wPCount += 1
					evalWPawns[wPCount] = sq
					local fi = (sq - 2) % 10 + 1
					local r = (sq - 22) // 10
					if r < evalWMinR[fi] then evalWMinR[fi] = r end
				end
			elseif pc < 0 then
				local pt = -pc
				local idx = PST_IDX_B[sq]
				mgB += MG_VAL[pt] + MG_PST[pt][idx]
				egB += EG_VAL[pt] + EG_PST[pt][idx]
				phase += PHASE_W[pt]
				if pt == BISHOP then
					bishB += 1
				elseif pt == PAWN then
					bPCount += 1
					evalBPawns[bPCount] = sq
					local fi = (sq - 2) % 10 + 1
					local r = (sq - 22) // 10
					if r > evalBMaxR[fi] then evalBMaxR[fi] = r end
				end
			end
		end
		if bishW >= 2 then mgW += 30; egW += 45 end
		if bishB >= 2 then mgB += 30; egB += 45 end

		-- Passed-pawn bonus (zero-alloc via per-file min/max opposing rank arrays)
		for i = 1, wPCount do
			local sq = evalWPawns[i]
			local fi = (sq - 2) % 10 + 1
			local r = (sq - 22) // 10
			if (fi == 1 or evalBMaxR[fi - 1] <= r) and evalBMaxR[fi] <= r and (fi == 8 or evalBMaxR[fi + 1] <= r) then
				mgW += PASSED_MG[r] or 0
				egW += PASSED_EG[r] or 0
			end
		end
		for i = 1, bPCount do
			local sq = evalBPawns[i]
			local fi = (sq - 2) % 10 + 1
			local r = (sq - 22) // 10
			if (fi == 1 or evalWMinR[fi - 1] >= r) and evalWMinR[fi] >= r and (fi == 8 or evalWMinR[fi + 1] >= r) then
				local relR = 7 - r
				mgB += PASSED_MG[relR] or 0
				egB += PASSED_EG[relR] or 0
			end
		end

		-- Endgame mop-up: drive enemy king to corner & close king distance when winning
		if phase <= 6 then
			local rawEg = egW - egB
			if rawEg > 220 or rawEg < -220 then
				local winCol = (rawEg > 0) and 1 or -1
				local winK = self.kingSq[winCol]
				local loseK = self.kingSq[-winCol]
				if winK ~= 0 and loseK ~= 0 then
					local wf, wr = (winK - 2) % 10, (winK - 22) // 10
					local lf, lr = (loseK - 2) % 10, (loseK - 22) // 10
					local md = abs(wf - lf) + abs(wr - lr)
					local mopUp = CENTER_DIST[loseK] * 14 + (14 - md) * 6
					if winCol == 1 then
						egW += mopUp
					else
						egB += mopUp
					end
				end
			end
		end

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

	function PureChess.search(fen, maxDepth, timeBudget, cancelFn, recentUcis)
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

		-- Precompute reversible game-history hashes so won endgames avoid 3-fold draws
		local histH1, histH2 = {}, {}
		local histCount = 0
		if type(recentUcis) == "table" then
			if type(recentUcis.h1) == "table" and type(recentUcis.h2) == "table" then
				for i = 1, #recentUcis.h1 do
					histCount += 1
					histH1[histCount] = recentUcis.h1[i]
					histH2[histCount] = recentUcis.h2[i]
				end
			elseif #recentUcis > 0 and board.halfmove > 0 then
				local hb = PureChess.new()
				local okReplay = true
				for i = 1, #recentUcis do
					if not hb:applyUciFast(recentUcis[i]) then
						okReplay = false
						break
					end
				end
				if okReplay and hb.h1 == board.h1 and hb.h2 == board.h2 then
					local startP = math.max(0, hb.ply - hb.halfmove)
					for p = startP, hb.ply - 1 do
						histCount += 1
						histH1[histCount] = hb.posH1[p]
						histH2[histCount] = hb.posH2[p]
					end
				end
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
		local iterBestMove = 0
		local iterBestScore = -INF

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
			if band(nodes, 511) == 0 and checkStop() then
				return 0
			end
			if ply >= 60 then
				return board:evaluate()
			end
			local inChk = board:inCheck()
			if not inChk then
				local standPat = board:evaluate()
				if standPat >= beta then
					return beta
				end
				if standPat > alpha then
					alpha = standPat
				end
			end

			local moves = {}
			local cnt = board:genPseudo(moves, not inChk)
			if cnt == 0 then
				return inChk and (-MATE + ply) or alpha
			end
			local scores = table.create(cnt, 0)
			for i = 1, cnt do
				scores[i] = scoreMove(moves[i], 0, ply)
			end

			local side = board.side
			local legalCount = 0
			for i = 1, cnt do
				local m = pickBest(moves, scores, i, cnt)
				board:makeMove(m)
				if not board:isAttacked(board.kingSq[side], -side) then
					legalCount += 1
					local sc = -qsearch(-beta, -alpha, ply + 1)
					board:undoMove()
					if aborted then return 0 end
					if sc >= beta then return beta end
					if sc > alpha then alpha = sc end
				else
					board:undoMove()
				end
			end
			if inChk and legalCount == 0 then
				return -MATE + ply
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
			if histCount > 0 then
				for i = 1, histCount do
					if histH1[i] == ch1 and histH2[i] == ch2 then
						return true
					end
				end
			end
			return false
		end

		local function negamax(depth, alpha, beta, ply, allowNull)
			nodes += 1
			if band(nodes, 511) == 0 and checkStop() then
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
						if ply == 0 then
							iterBestMove = m
							iterBestScore = sc
						end
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
			iterBestMove = 0
			iterBestScore = -INF
			local sc = negamax(d, -INF, INF, 0, true)
			if aborted then
				if iterBestMove ~= 0 then
					bestMove = iterBestMove
					bestScore = iterBestScore
				end
				break
			end
			if iterBestMove ~= 0 then
				bestMove = iterBestMove
			else
				local slot = band(board.h1, TT_MASK) + 1
				if ttH1[slot] == board.h1 and ttH2[slot] == board.h2 and ttMove[slot] ~= 0 then
					bestMove = ttMove[slot]
				end
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

	-- Plausible Human-Like Blunder / Weak-Play Picker (never touches main TT; ~4-12ms)
	function PureChess.pickHumanBlunder(fen, minDropCp, maxDropCp, opts)
		local t0 = os.clock()
		local board = PureChess.new(fen)
		local legal = board:legalMoves()
		local cnt = #legal
		if cnt == 0 then
			return nil
		end

		local mySide = board.side
		local oppSide = -mySide
		local minDrop = minDropCp or 250
		local maxDrop = maxDropCp or 650
		local allowMateIn1 = (type(opts) == "table" and opts.allowMateIn1 == true)
		local inCheckNow = board:inCheck()

		local totalPieces = 0
		for i = 1, 64 do
			if board.board[SQUARES[i]] ~= EMPTY then
				totalPieces += 1
			end
		end

		if cnt == 1 then
			local onlyM = legal[1]
			local onlyUci = PureChess.moveToUci(onlyM)
			local sc = board:evaluate() * mySide
			return {
				best = onlyUci,
				ponder = nil,
				evalCp = sc,
				mate = nil,
				depth = 1,
				ms = math.floor((os.clock() - t0) * 1000),
				pv = { onlyUci },
				san = board:moveToSan(onlyM),
				source = "FarmBlunder",
				blunderDropCp = 0,
				engineLabel = "Farm · Forced",
				engineKind = "farm",
			}
		end

		local nodes = 0
		local lastYield = t0
		local cands = {}
		local bestScore = -INF
		local oppBuf = {}
		local capBuf = {}

		for i = 1, cnt do
			local m = legal[i]
			local fromSq = band(m, 127)
			local toSq = extract(m, 7, 7)
			local flag = extract(m, 17, 3)
			local pc = board.board[fromSq]
			local pt = abs(pc)
			local isCap = (board.board[toSq] ~= EMPTY) or (flag == F_EP)
			local fromRank = (fromSq - 22) // 10
			local toRank = (toSq - 22) // 10
			local isAdvance = (mySide == 1 and toRank > fromRank) or (mySide == -1 and toRank < fromRank)
			local isEdgeRook = (pt == ROOK) and (not isCap) and (fromRank == toRank) and (fromRank == 0 or fromRank == 7)

			board:makeMove(m)
			local givesCheck = board:inCheck()

			local oppCnt = board:genPseudo(oppBuf, false)
			local oppLegal = 0
			local worstForMe = INF
			local allowsMate1 = false

			for j = 1, oppCnt do
				local r = oppBuf[j]
				board:makeMove(r)
				if not board:isAttacked(board.kingSq[oppSide], mySide) then
					oppLegal += 1
					nodes += 1
					local scoreForMe
					if board:inCheck() then
						local myReplies = board:legalMoves()
						if #myReplies == 0 then
							allowsMate1 = true
							scoreForMe = -MATE + 2
						else
							scoreForMe = board:evaluate()
						end
					else
						scoreForMe = board:evaluate()
						local cCnt = board:genPseudo(capBuf, true)
						for k = 1, cCnt do
							local cm = capBuf[k]
							board:makeMove(cm)
							if not board:isAttacked(board.kingSq[mySide], oppSide) then
								local recScore = -board:evaluate()
								if recScore > scoreForMe then
									scoreForMe = recScore
								end
							end
							board:undoMove()
						end
					end
					if scoreForMe < worstForMe then
						worstForMe = scoreForMe
					end
				end
				board:undoMove()
				if band(nodes, 1023) == 0 then
					local now = os.clock()
					if now - lastYield >= 0.012 then
						lastYield = now
						task.wait()
					end
				end
			end

			local deliversMate = false
			if oppLegal == 0 then
				if givesCheck then
					deliversMate = true
					worstForMe = MATE - 1
				else
					worstForMe = 0
				end
			end
			board:undoMove()

			if worstForMe > bestScore then
				bestScore = worstForMe
			end
			cands[#cands + 1] = {
				m = m,
				score = worstForMe,
				allowsMate1 = allowsMate1,
				deliversMate = deliversMate,
				pt = pt,
				flag = flag,
				isCap = isCap,
				givesCheck = givesCheck,
				isAdvance = isAdvance,
				isEdgeRook = isEdgeRook,
			}
		end

		local midDrop = (minDrop + maxDrop) * 0.5
		local dropSpan = math.max(80, maxDrop - minDrop)
		for _, c in ipairs(cands) do
			local drop = math.max(0, bestScore - c.score)
			c.drop = drop
			local p = 0
			if c.pt == KING and c.flag ~= F_OO and c.flag ~= F_OOO and totalPieces > 12 and not inCheckNow then
				p -= 400
			end
			if c.isEdgeRook then
				p -= 120
			end
			if drop > 950 then
				p -= 80
			end
			if c.isAdvance then
				p += 80
			end
			if c.isCap or c.givesCheck then
				p += 70
			end
			if c.pt == PAWN or c.pt == KNIGHT or c.pt == BISHOP or c.pt == QUEEN then
				p += 45
			end
			p += 50 * math.max(0, 1 - abs(drop - midDrop) / dropSpan)
			c.plaus = p
		end

		local function pickFromPool(pool)
			if #pool == 0 then
				return nil
			end
			table.sort(pool, function(a, b)
				return a.plaus > b.plaus
			end)
			local topN = math.min(#pool, 3)
			local weights = { 55, 30, 15 }
			local totalW = 0
			for idx = 1, topN do
				totalW += weights[idx]
			end
			local roll = math.random() * totalW
			local acc = 0
			for idx = 1, topN do
				acc += weights[idx]
				if roll <= acc then
					return pool[idx]
				end
			end
			return pool[1]
		end

		local pool1, pool2, pool3, pool4 = {}, {}, {}, {}
		for _, c in ipairs(cands) do
			if not c.deliversMate then
				pool4[#pool4 + 1] = c
				if not c.allowsMate1 and c.drop >= minDrop and c.drop <= maxDrop then
					pool1[#pool1 + 1] = c
				elseif not c.allowsMate1 and c.drop >= 130 and c.drop <= 880 then
					pool2[#pool2 + 1] = c
				end
				if (allowMateIn1 or not c.allowsMate1) and c.drop >= 50 then
					pool3[#pool3 + 1] = c
				end
			end
		end

		local picked = pickFromPool(pool1) or pickFromPool(pool2) or pickFromPool(pool3)
		if not picked then
			if #pool4 > 0 then
				table.sort(pool4, function(a, b)
					return a.score < b.score
				end)
				picked = pool4[1]
			else
				picked = cands[1]
			end
		end

		local bestUci = PureChess.moveToUci(picked.m)
		local whiteScore = picked.score * mySide
		local mateVal = nil
		if abs(whiteScore) > MATE - 200 then
			local pliesToMate = MATE - abs(whiteScore)
			local movesToMate = math.max(1, math.ceil(pliesToMate / 2))
			mateVal = (whiteScore > 0) and movesToMate or -movesToMate
		end

		return {
			best = bestUci,
			ponder = nil,
			evalCp = whiteScore,
			mate = mateVal,
			depth = 2,
			ms = math.floor((os.clock() - t0) * 1000),
			pv = { bestUci },
			san = board:moveToSan(picked.m),
			source = "FarmBlunder",
			blunderDropCp = picked.drop,
			engineLabel = string.format("Farm · Blunder (-%dcp)", picked.drop),
			engineKind = "farm",
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

local function resolveSessionTimeControl(sess)
	if not sess then
		return nil, 0
	end
	local tc = sess.tc
	local tcStr = nil
	if type(tc) == "string" then
		tcStr = tc
	elseif type(tc) == "table" then
		local rawBase = tonumber(tc.baseMs or tc.initialMs)
		local rawInc = tonumber(tc.incMs) or 0
		if rawBase and rawBase >= 10000 then
			return rawBase, rawInc
		end
		local baseSec = tonumber(tc.base or tc.initial or tc.seconds)
		if baseSec and baseSec > 0 then
			local bMs = (baseSec >= 10000) and baseSec or (baseSec * 1000)
			local iSec = tonumber(tc.inc or tc.increment) or 0
			local iMs = (iSec >= 1000) and iSec or (iSec * 1000)
			return bMs, iMs
		end
		tcStr = (type(tc.id) == "string" and tc.id) or (type(tc.name) == "string" and tc.name) or nil
	end
	if type(tcStr) == "string" then
		local mStr, iStr = string.match(tcStr, "(%d+%.?%d*)%+(%d+%.?%d*)")
		if mStr then
			local mins = tonumber(mStr)
			local incS = tonumber(iStr) or 0
			if mins and mins > 0 then
				return math.floor(mins * 60000 + 0.5), math.floor(incS * 1000 + 0.5)
			end
		end
	end
	local ply = (type(sess.ucis) == "table") and #sess.ucis or 0
	if ply <= 1 and sess.clocks then
		local cMax = math.max(tonumber(sess.clocks[1]) or 0, tonumber(sess.clocks[-1]) or 0)
		if cMax >= 10000 then
			return cMax, 0
		end
	end
	return nil, 0
end

local function cancelPrefetchState()
	STATE.PrefetchGen += 1
	STATE.PrefetchKey = ""
	STATE.PrefetchFen4 = ""
	STATE.PrefetchDone = nil
end

local function isStockfishSource(src)
	return src == "VpsSF" or src == "Stockfish" or src == "LocalSF"
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

local function queryVpsStockfish(fen, depth, movetimeMs, multipv, timeoutSec, cancelFn, reqOpts)
	if type(httpRequest) ~= "function" then
		return nil, "no_http"
	end
	if not hasVpsConfigured() then
		return nil, "no_vps"
	end
	if os.clock() < STATE.VpsCooldownUntil then
		return nil, "vps_cooldown"
	end
	local isSpeculative = (type(reqOpts) == "table" and reqOpts.speculative == true)
	local noPenalty = isSpeculative or (type(reqOpts) == "table" and reqOpts.noPenalty == true)

	local base = string.gsub(CONFIG.VpsApiUrl, "/+$", "")
	local d = math.clamp(depth or 15, 1, 22)
	local mt = math.clamp(math.floor(movetimeMs or 280), 0, 3000)
	local mpv = math.clamp(math.floor(multipv or 1), 1, 3)
	local t0 = os.clock()
	local url = base .. "/eval?fen=" .. HttpService:UrlEncode(fen) .. "&depth=" .. tostring(d) .. "&multipv=" .. tostring(mpv)
	if mt > 0 then
		url = url .. "&movetime=" .. tostring(mt)
	end
	if isSpeculative then
		url = url .. "&speculative=1"
	end
	local headers = { ["Accept"] = "application/json" }
	if type(CONFIG.VpsApiKey) == "string" and CONFIG.VpsApiKey ~= "" then
		headers["X-Api-Key"] = CONFIG.VpsApiKey
	end

	local ok, res = httpRequestWithTimeout({
		Url = url,
		Method = "GET",
		Headers = headers,
	}, timeoutSec or 2.0, cancelFn)
	local ms = math.floor((os.clock() - t0) * 1000)

	if res == "cancelled" then
		return nil, "cancelled"
	end
	if not ok or type(res) ~= "table" or not res.Success or res.StatusCode ~= 200 then
		if not noPenalty then
			STATE.VpsFailStreak += 1
			if STATE.VpsFailStreak >= 2 then
				STATE.VpsCooldownUntil = os.clock() + 12
			end
		end
		return nil, tostring(res)
	end
	local dok, data = pcall(HttpService.JSONDecode, HttpService, res.Body or "")
	if not dok or type(data) ~= "table" or data.success ~= true then
		if dok and type(data) == "table" and data.preempted == true then
			return nil, "preempted"
		end
		if not noPenalty then
			STATE.VpsFailStreak += 1
			if STATE.VpsFailStreak >= 2 then
				STATE.VpsCooldownUntil = os.clock() + 12
			end
		end
		return nil, "bad_json"
	end
	local bestUci = (type(data.best) == "string" and #data.best >= 4) and data.best
		or string.match(tostring(data.bestmove or ""), "bestmove%s+([a-h][1-8][a-h][1-8][qrbn]?)")
	if not bestUci then
		return nil, "no_move"
	end
	if not noPenalty then
		STATE.VpsFailStreak = 0
		STATE.VpsCooldownUntil = 0
	end

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
	}, timeoutSec or 2.4, cancelFn)
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

-- GM Move Shaper + Dynamic Auto-Adapt Strength:
-- Selects authentic GM/Master moves from MultiPV 2/3 with proportional thresholds and eval-floor guards.
-- Automatically escalates strength against sharp/engine opponents or worse positions, and de-escalates smoothly when winning.
local GM_STYLE_PROFILES = {
	SuperGM = { openGap = 25, midGap = 26, winGap = 45, endGap = 18, p2Close = 0.36, p3Close = 0.09, p2Med = 0.20, openW = { 56, 30, 14 } },
	GM = { openGap = 38, midGap = 52, winGap = 78, endGap = 30, p2Close = 0.50, p3Close = 0.16, p2Med = 0.34, openW = { 44, 34, 22 } },
	Master = { openGap = 52, midGap = 85, winGap = 115, endGap = 48, p2Close = 0.58, p3Close = 0.24, p2Med = 0.42, openW = { 36, 36, 28 } },
}
local STYLE_TIERS = { "Master", "GM", "SuperGM", "Full" }
local STYLE_TO_TIER = { Master = 1, GM = 2, SuperGM = 3, Full = 4 }

local function isEdgePawnPush(uci)
	return uci == "a2a3" or uci == "a2a4" or uci == "h2h3" or uci == "h2h4"
		or uci == "a7a6" or uci == "a7a5" or uci == "h7h6" or uci == "h7h5"
end

local function getEffectivePlayStyle(session, turbo, suspect, evalOverride, allowCommit)
	local userStyle = CONFIG.PlayStyle or "GM"
	local baseTier = STYLE_TO_TIER[userStyle] or 2
	if userStyle == "Full" or not session or session.kind ~= "online" then
		return userStyle, false
	end
	-- During an armed Auto-Farm controlled-loss game, suppress AutoAdapt / Turbo escalation
	if STATE.Farm.throwArmed and CONFIG.AutoFarm then
		return userStyle, false
	end

	local o = STATE.Opp
	if turbo or o.engineDetected or suspect then
		if allowCommit and CONFIG.AutoAdapt then
			o.adaptTier = 4
			o.lastAdaptPly = (type(session.ucis) == "table") and #session.ucis or 0
		end
		return "Full", (CONFIG.AutoAdapt == true)
	end

	if not CONFIG.AutoAdapt then
		return userStyle, false
	end

	local rate = (o.checked > 0) and (o.hits / o.checked) or 0
	local myEval = (evalOverride ~= nil) and evalOverride or o.lastEvalForMe
	local curTier = math.max(baseTier, o.adaptTier or baseTier)
	local desiredTier = baseTier

	if (o.checked >= 4 and rate >= 0.70) or (myEval ~= nil and myEval <= -150) then
		desiredTier = 4
	elseif (o.checked >= 3 and rate >= 0.60) or (myEval ~= nil and myEval <= -60) then
		desiredTier = math.min(4, baseTier + 1)
	end

	local nextTier = curTier
	if myEval ~= nil and myEval >= 200 and not o.engineDetected and not o.suspect and not turbo then
		nextTier = math.max(baseTier, curTier - 1)
	elseif desiredTier > curTier then
		nextTier = desiredTier
	end

	if allowCommit then
		local curPly = (type(session.ucis) == "table") and #session.ucis or 0
		if o.lastAdaptPly ~= curPly or nextTier > (o.adaptTier or baseTier) then
			o.adaptTier = nextTier
			o.lastAdaptPly = curPly
		else
			nextTier = math.max(baseTier, o.adaptTier or baseTier)
		end
	end

	local effStyle = STYLE_TIERS[nextTier] or userStyle
	return effStyle, (effStyle ~= userStyle)
end

-- Shared Query Profile between live solvePosition and launchPonderPrefetch so (depth, movetime, multipv) match identically
local function computeQueryProfile(session, turbo, suspect)
	local myMs = (session and session.myColor) and getLiveClockMs(session, session.myColor) or nil
	local vpsReady = hasVpsConfigured() and os.clock() >= STATE.VpsCooldownUntil
	local effStyle, isAdapted = getEffectivePlayStyle(session, turbo, suspect, nil, false)
	local baseMs = (session and session.kind == "online") and STATE.Opp.baseMs or nil
	local isBullet1 = (baseMs ~= nil and baseMs <= 65000)

	local sfDepth = CONFIG.StockfishDepth
	local wantMultiPv = 1
	if vpsReady
		and not turbo
		and not suspect
		and not (STATE.Opp.engineDetected and not STATE.Opp.spectatorPaused)
		and effStyle ~= "Full"
		and session
		and (session.kind == "online" or session.kind == "bot")
	then
		if isBullet1 or (myMs and myMs < 12000) then
			wantMultiPv = 1
		elseif myMs and myMs < 25000 then
			wantMultiPv = 2
		else
			wantMultiPv = 3
		end
	end

	local vpsMoveTime = turbo and 95 or (suspect and 120 or (wantMultiPv == 3 and 300 or (wantMultiPv == 2 and 90 or 220)))
	local vpsTimeout = turbo and 1.25 or 2.0
	local sfTimeout = turbo and 0.90 or 1.50 -- post-VPS Cloud fallback timeout (aligned below Watchdog #1)
	local sfStandaloneTimeout = turbo and 1.35 or 2.40
	local luauTime = turbo and 0.24 or CONFIG.LuauTimeBudget
	local lowClockSwitch = false

	if turbo then
		sfDepth = math.min(sfDepth, vpsReady and 16 or 11)
	elseif suspect then
		sfDepth = math.min(sfDepth, vpsReady and 16 or 12)
	end

	if myMs and session and session.kind == "online" then
		local luauCutMs = vpsReady and 8000 or 15000
		if myMs < luauCutMs and CONFIG.EngineMode == "Hybrid" then
			lowClockSwitch = true
			luauTime = 0.16
		elseif myMs < 25000 then
			if wantMultiPv == 2 then
				vpsMoveTime = math.min(vpsMoveTime, 90)
				vpsTimeout = math.min(vpsTimeout, 1.05)
			else
				vpsMoveTime = math.min(vpsMoveTime, 75)
				vpsTimeout = math.min(vpsTimeout, 1.00)
			end
			sfDepth = math.min(sfDepth, vpsReady and 14 or 10)
			sfTimeout = math.min(sfTimeout, 0.90)
			sfStandaloneTimeout = math.min(sfStandaloneTimeout, 1.25)
			luauTime = math.min(luauTime, 0.22)
		elseif myMs < 40000 then
			vpsMoveTime = math.min(vpsMoveTime, 150)
			sfDepth = math.min(sfDepth, vpsReady and 15 or 11)
		end
	end

	local cacheGroup = (wantMultiPv >= 3) and "sf3" or ((wantMultiPv == 2) and "sf2" or "sf")
	return {
		myMs = myMs,
		vpsReady = vpsReady,
		sfDepth = sfDepth,
		wantMultiPv = wantMultiPv,
		vpsMoveTime = vpsMoveTime,
		vpsTimeout = vpsTimeout,
		sfTimeout = sfTimeout,
		sfStandaloneTimeout = sfStandaloneTimeout,
		luauTime = luauTime,
		lowClockSwitch = lowClockSwitch,
		cacheGroup = cacheGroup,
		effStyle = effStyle,
		isAdapted = isAdapted,
	}
end

local function lookupSfCache(f4, wantMultiPv, anyForLowClock)
	if anyForLowClock or wantMultiPv <= 1 then
		return STATE.Cache[f4 .. "|sf"] or STATE.Cache[f4 .. "|sf2"] or STATE.Cache[f4 .. "|sf3"]
	elseif wantMultiPv == 2 then
		return STATE.Cache[f4 .. "|sf2"] or STATE.Cache[f4 .. "|sf3"]
	end
	return STATE.Cache[f4 .. "|sf3"]
end

local function deriveResultCacheGroup(res)
	if not res then
		return "luau"
	end
	if res.source == "VpsSF" then
		local mpv = tonumber(res.multipv) or (type(res.lines) == "table" and #res.lines or 1)
		if mpv >= 3 then return "sf3" end
		if mpv == 2 then return "sf2" end
		return "sf"
	elseif res.source == "Stockfish" or res.source == "LocalSF" then
		return "sf"
	end
	return "luau"
end

local function applyGmMoveShaper(fen, session, rawRes, turbo, suspect)
	if not rawRes then
		return nil
	end
	local out = table.clone(rawRes)
	if not session or (session.kind ~= "online" and session.kind ~= "bot") then
		return out
	end
	if session.myColor ~= nil and not session:isMyTurn() then
		return out
	end

	local fenParts = string.split(fen, " ")
	local side = (fenParts[2] == "b") and -1 or 1
	local pv1 = (type(rawRes.lines) == "table" and rawRes.lines[1]) or nil
	local rawTopCp = (pv1 and pv1.evalCp) or rawRes.evalCp or 0
	local myEval1 = rawTopCp * side

	local effStyle, isAdapted = getEffectivePlayStyle(session, turbo, suspect, myEval1, true)
	local baseName = (rawRes.source == "VpsSF") and ((rawRes.engineName or "Stockfish 19") .. " VPS")
		or (rawRes.engineLabel or rawRes.source or "Stockfish")

	local prof = GM_STYLE_PROFILES[effStyle]
	if not prof or turbo or STATE.Opp.engineDetected or suspect then
		if isAdapted and rawRes.source == "VpsSF" then
			out.gmRank = 1
			out.gmLossCp = 0
			out.engineLabel = string.format("%s · Auto→Full (PV1)", baseName)
			out.engineKind = (turbo or STATE.Opp.engineDetected) and "turbo" or "vpssf"
		end
		return out
	end

	if type(rawRes.lines) ~= "table" or #rawRes.lines < 2 or not pv1 then
		if isAdapted and rawRes.source == "VpsSF" then
			out.engineLabel = string.format("%s · Auto→%s (PV1)", baseName, effStyle)
		end
		return out
	end

	if pv1.mate ~= nil then
		-- Never deviate from forced mate sequences
		out.gmRank = 1
		out.gmLossCp = 0
		out.engineLabel = isAdapted and string.format("%s · Auto→%s (PV1)", baseName, effStyle)
			or string.format("%s · %s (PV1)", baseName, effStyle)
		out.engineKind = "gm"
		return out
	end

	local ply = (type(session.ucis) == "table") and #session.ucis or 0
	local totalPieces = countFenPieces(fen)

	local function getGap(ln)
		if not ln or ln.mate ~= nil then
			return 99999
		end
		return math.max(0, myEval1 - ((ln.evalCp or 0) * side))
	end

	-- Eval-floor guard: wider GM/Master gaps never throw away a clearly winning game or blunder into a lost position
	local function isSafeCandidate(ln)
		if not ln or ln.mate ~= nil then
			return false
		end
		local candEval = (ln.evalCp or 0) * side
		if myEval1 >= 150 and candEval < 60 then
			return false
		end
		if myEval1 >= -60 and candEval < -160 then
			return false
		end
		return true
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
		if pv2 and gap2 <= prof.openGap and isSafeCandidate(pv2) then
			table.insert(cands, { ln = pv2, w = prof.openW[2], g = gap2 })
		end
		if pv3 and gap3 <= prof.openGap and isSafeCandidate(pv3) then
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
			maxGap = math.max(10, math.floor(maxGap * 0.5))
		end

		local closeCut = math.max(6, math.floor(maxGap * 0.40))
		local medCut = math.max(closeCut + 2, math.floor(maxGap * 0.72))

		if pv2 and gap2 <= maxGap and isSafeCandidate(pv2) then
			local r = math.random()
			local edgeBonus = (gap2 <= closeCut and isEdgePawnPush(pv1.best) and not isEdgePawnPush(pv2.best)) and 0.16 or 0
			local pv3Ok = pv3 and isSafeCandidate(pv3)
			if gap2 <= closeCut then
				local p3 = (pv3Ok and gap3 <= math.min(maxGap, medCut)) and prof.p3Close or 0
				local p2 = math.min(0.70, prof.p2Close + edgeBonus)
				if r < p3 then
					picked, pickedGap = pv3, gap3
				elseif r < p3 + p2 then
					picked, pickedGap = pv2, gap2
				end
			elseif gap2 <= medCut then
				local p3 = (pv3Ok and gap3 <= maxGap) and (prof.p3Close * 0.55) or 0
				local p2 = math.min(0.56, prof.p2Med + edgeBonus)
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

	local styleTag = isAdapted and ("Auto→" .. effStyle) or effStyle
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
		out.engineLabel = string.format("%s · %s (PV%d -%dcp)", baseName, styleTag, picked.rank, pickedGap)
		out.engineKind = "gm"
	else
		out.gmRank = 1
		out.gmLossCp = 0
		out.engineLabel = string.format("%s · %s (PV1)", baseName, styleTag)
		out.engineKind = "gm"
	end
	return out
end

-- Speculative Ponder Prefetch: solve the position AFTER opponent's expected Stockfish reply during their turn!
-- Uses VPS speculative=1 (preemptible server-side), NEVER runs Cloud fallback, NEVER mutates FailStreaks.
local function launchPonderPrefetch(curFen, ponderUci, session)
	if not CONFIG.AntiEngineTurbo or not CONFIG.Enabled then
		return
	end
	if type(ponderUci) ~= "string" or #ponderUci < 4 then
		return
	end
	if CONFIG.EngineMode == "Luau" then
		return
	end
	if not hasVpsConfigured() or os.clock() < STATE.VpsCooldownUntil then
		return
	end

	local b = PureChess.new(curFen)
	local pm = b:moveFromUci(ponderUci)
	if not pm then
		return
	end
	b:makeMove(pm)
	local nextFen = b:getFen()
	local f4 = fen4Key(nextFen)

	local turbo = CONFIG.AntiEngineTurbo and STATE.Opp.turboActive
	local suspect = CONFIG.AntiEngineTurbo and STATE.Opp.suspect
	local prof = computeQueryProfile(session, turbo, suspect)
	local cKey = f4 .. "|" .. prof.cacheGroup

	if lookupSfCache(f4, prof.wantMultiPv, false) then
		return
	end
	if STATE.PrefetchDone and not STATE.PrefetchDone.done and STATE.PrefetchFen4 == f4 and STATE.PrefetchKey == cKey then
		return
	end

	STATE.PrefetchGen += 1
	local myPGen = STATE.PrefetchGen
	local pBox = { done = false, res = nil, fen4 = f4, cacheKey = cKey, gen = myPGen }
	STATE.PrefetchKey = cKey
	STATE.PrefetchFen4 = f4
	STATE.PrefetchDone = pBox

	task.spawn(function()
		local cancelPrefetch = function()
			return (not STATE.Alive) or (STATE.PrefetchGen ~= myPGen)
		end
		local res = queryVpsStockfish(
			nextFen,
			prof.sfDepth,
			prof.vpsMoveTime,
			prof.wantMultiPv,
			math.min(prof.vpsTimeout, 1.8),
			cancelPrefetch,
			{ speculative = true, noPenalty = true }
		)
		if res and STATE.Alive then
			res.engineLabel = (res.engineName or "Stockfish 19") .. " VPS (Ponder Hit)"
			res.engineKind = "vpssf"
			res.prefetched = true
			local actualGrp = deriveResultCacheGroup(res)
			cachePut(f4 .. "|" .. actualGrp, res)
			pBox.res = res
		end
		pBox.done = true
	end)
end

local function solvePosition(fen, session, gen, onStage)
	local function isCancelled()
		return (not STATE.Alive) or (gen ~= STATE.SearchGen)
	end
	local function reportStage(label, kind, stageTag)
		if isCancelled() then return end
		STATE.ActiveEngine = label
		STATE.ActiveEngineKind = kind or "thinking"
		if stageTag ~= nil then
			STATE.ActiveStage = stageTag
		end
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
					if not isCancelled() then
						STATE.ActiveStage = nil
					end
					return enriched
				end
			end
		end
	end

	-- Auto-Farm Controlled-Loss Throw Phase routing (BlunderResign / PlayWeak / LateResign)
	if Farm.shouldUseThrowMove and Farm.shouldUseThrowMove(session) then
		reportStage("Farm · Blunder", "farm", "luau")
		local throwRes = Farm.pickThrowMove(fen, session, isCancelled)
		if throwRes and not isCancelled() then
			STATE.ActiveStage = nil
			return throwRes
		end
	end

	local farmThrowSuppress = (CONFIG.AutoFarm and STATE.Farm.throwArmed == true)
	local turbo = (not farmThrowSuppress) and CONFIG.AntiEngineTurbo and STATE.Opp.turboActive and session and session.kind == "online"
	local suspect = (not farmThrowSuppress) and CONFIG.AntiEngineTurbo and STATE.Opp.suspect and session and session.kind == "online"
	local prof = computeQueryProfile(session, turbo, suspect)
	local liveF4 = fen4Key(fen)

	local function finalizeCacheHit(sfHit, waitMs)
		local hitCopy = applyGmMoveShaper(fen, session, sfHit, turbo, suspect)
		hitCopy.ms = waitMs or 0
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
		if not isCancelled() then
			STATE.ActiveStage = nil
		end
		return hitCopy
	end

	-- 1. Check Ponder/Stockfish cache BEFORE lowClockSwitch so 0ms SF19 ponder hits ALWAYS win under < 8s!
	if CONFIG.EngineMode ~= "Luau" then
		local sfHit = lookupSfCache(liveF4, prof.wantMultiPv, prof.lowClockSwitch)
		if sfHit then
			return finalizeCacheHit(sfHit, 0)
		end

		-- 2. If a matching speculative prefetch is already in-flight for this live fen4, await up to 0.65s (0.35s under <8s)
		local pBox = STATE.PrefetchDone
		if pBox and not pBox.done and pBox.fen4 == liveF4 then
			local tAwait0 = os.clock()
			local awaitLimit = prof.lowClockSwitch and 0.35 or 0.65
			local awaitUntil = tAwait0 + awaitLimit
			reportStage("Stockfish 19 VPS (Ponder)", "thinking", "vps")
			while (not pBox.done) and (not isCancelled()) and os.clock() < awaitUntil do
				task.wait(0.02)
			end
			if isCancelled() then
				return nil
			end
			local awaitedHit = pBox.res or lookupSfCache(liveF4, prof.wantMultiPv, prof.lowClockSwitch)
			if awaitedHit then
				local actualMpv = tonumber(awaitedHit.multipv) or 1
				if prof.lowClockSwitch or prof.wantMultiPv <= 1 or actualMpv >= prof.wantMultiPv then
					return finalizeCacheHit(awaitedHit, math.floor((os.clock() - tAwait0) * 1000))
				end
			end
			-- v2.1.0 Fix #5: cancel timed-out or lower-MultiPV pBox before issuing live VPS call
			cancelPrefetchState()
		elseif pBox and not pBox.done and pBox.fen4 ~= liveF4 then
			-- Non-matching speculative prefetch: cancel client-side immediately so live request preempts cleanly
			cancelPrefetchState()
		end
	end

	-- 3. Apply lowClockSwitch (< 8s) only AFTER cache + active ponder check missed
	local mode = prof.lowClockSwitch and "Luau" or CONFIG.EngineMode
	if mode == "Luau" then
		local luauHit = STATE.Cache[fenCacheKey(fen, "luau")]
		if luauHit then
			local hitCopy = table.clone(luauHit)
			hitCopy.ms = 0
			if not isCancelled() then
				STATE.ActiveStage = nil
			end
			return hitCopy
		end
	end

	local function runLuau(tagLabel, tagKind)
		reportStage(tagLabel, "thinking", "luau")
		local recentUcis = (session and type(session.ucis) == "table") and session.ucis or nil
		local r = enrichMoveInfo(fen, PureChess.search(fen, CONFIG.LuauMaxDepth, prof.luauTime, isCancelled, recentUcis))
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
		reportStage("Local Stockfish WS", "thinking", "ws")
		res = queryLocalWs(fen, prof.sfDepth, isCancelled)
		if res then
			res.engineLabel = "Local Stockfish WS"
			res.engineKind = "localws"
		elseif not isCancelled() and prof.vpsReady then
			reportStage("Stockfish 19 VPS (WS Fallback)", "thinking", "vps")
			res = queryVpsStockfish(fen, prof.sfDepth, prof.vpsMoveTime, prof.wantMultiPv, prof.vpsTimeout, isCancelled)
			if res then
				res.engineLabel = (res.engineName or "Stockfish 19") .. " VPS (WS Fallback)"
				res.engineKind = "vpssf"
			end
		end
		if not res and not isCancelled() then
			reportStage("Stockfish Cloud (WS Fallback)", "thinking", "cloud")
			res = queryStockfishOnline(fen, math.min(prof.sfDepth, 15), prof.sfTimeout, isCancelled)
			if res then
				res.engineLabel = "Stockfish Cloud (WS Fallback)"
				res.engineKind = "stockfish"
			elseif not isCancelled() then
				res = runLuau("Offline Luau (Fallback)", "fallback")
			end
		end
	elseif mode == "Stockfish" or mode == "Hybrid" then
		local vpsAttempted = false
		if prof.vpsReady then
			vpsAttempted = true
			local styleLbl = prof.isAdapted and ("Auto→" .. prof.effStyle) or prof.effStyle
			local vpsTag = turbo and "Stockfish 19 VPS (Turbo)"
				or (prof.wantMultiPv > 1 and ("Stockfish 19 VPS · " .. styleLbl)
					or (prof.isAdapted and ("Stockfish 19 VPS · " .. styleLbl) or "Stockfish 19 VPS"))
			reportStage(vpsTag, "thinking", "vps")
			res = queryVpsStockfish(fen, prof.sfDepth, prof.vpsMoveTime, prof.wantMultiPv, prof.vpsTimeout, isCancelled)
			if res then
				local nm = res.engineName or "Stockfish 19"
				res.engineLabel = turbo and (nm .. " VPS (Turbo)") or (nm .. " VPS")
				res.engineKind = turbo and "turbo" or "vpssf"
			end
		end

		if not res and not isCancelled() then
			if os.clock() >= STATE.SfCooldownUntil then
				local cloudTag = vpsAttempted and "Stockfish Cloud (VPS Fallback)" or (turbo and "Stockfish Turbo" or "Stockfish Cloud")
				reportStage(cloudTag, "thinking", "cloud")
				local cloudTimeout = vpsAttempted and prof.sfTimeout or prof.sfStandaloneTimeout
				res = queryStockfishOnline(fen, math.min(prof.sfDepth, 15), cloudTimeout, isCancelled)
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
		res = runLuau(prof.lowClockSwitch and "Offline Luau (Low Clock)" or "Offline Luau", prof.lowClockSwitch and "fallback" or "luau")
	end

	if not isCancelled() then
		STATE.ActiveStage = nil
		if res then
			-- v2.1.0 Fix #6a: never cache Book picks so Luau Opening Book stays varied across games
			if res.source ~= "Book" then
				local grp = deriveResultCacheGroup(res)
				cachePut(fenCacheKey(fen, grp), res)
			end
			res = applyGmMoveShaper(fen, session, res, turbo, suspect)
		end
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

-- Mode / Engine Color Palette (shared by Board Arrows, Highlights, and Draggable Tactical HUD)
local BADGE_COLORS = {
	vpssf = Color3.fromRGB(52, 211, 255),
	gm = Color3.fromRGB(72, 224, 168),
	farm = Color3.fromRGB(245, 138, 86),
	stockfish = Color3.fromRGB(56, 217, 169),
	turbo = Color3.fromRGB(240, 86, 86),
	suspect = Color3.fromRGB(255, 154, 74),
	localws = Color3.fromRGB(96, 185, 255),
	luau = Color3.fromRGB(168, 130, 255),
	fallback = Color3.fromRGB(235, 168, 76),
	book = Color3.fromRGB(120, 210, 150),
	puzzle = Color3.fromRGB(245, 196, 81),
	mate = Color3.fromRGB(245, 196, 81),
	thinking = Color3.fromRGB(245, 196, 81),
	idle = Color3.fromRGB(110, 118, 138),
}

-- RoChess-Native Draggable Coach HUD (studio-illustrated vector Coach avatars, clean BuilderSans typography)
local HUD = {
	root = nil,
	card = nil,
	stroke = nil,
	dot = nil,
	title = nil,
	evalPill = nil,
	evalStroke = nil,
	evalText = nil,
	fyiText = nil,
	grip = nil,
	avatarFrame = nil,
	avatarImg = nil,
	avatarRing = nil,
	avatarAssets = {},
	-- Runtime state
	dragging = false,
	customPos = false,
	tempHiddenForClick = false,
	lastClickAt = 0,
	lastKind = "idle",
	lastMood = "",
	lastMsg = "",
	bounceStartAt = 0,
	hovered = false,
}

local COACH_ASSET_BASE = "https://raw.githubusercontent.com/bevankeren/rochess/main/assets/coach/"
local COACH_MOODS = { "calm", "hyped", "smug", "cool", "panic", "thinking", "draw", "mischief", "sleepy" }
local COACH_FALLBACK_THUMB = string.format("rbxthumb://type=AvatarHeadShot&id=%d&w=150&h=150", LocalPlayer.UserId)

local function preloadCoachAvatars()
	local getAssetFn = (type(getcustomasset) == "function" and getcustomasset)
		or (type(getsynasset) == "function" and getsynasset)
		or nil
	if not getAssetFn or type(writefile) ~= "function" or type(isfile) ~= "function" then
		return
	end
	if type(isfolder) == "function" and type(makefolder) == "function" then
		pcall(function()
			if not isfolder("BeverlyHub") then makefolder("BeverlyHub") end
			if not isfolder("BeverlyHub/RoChess") then makefolder("BeverlyHub/RoChess") end
			if not isfolder("BeverlyHub/RoChess/coach_v1") then makefolder("BeverlyHub/RoChess/coach_v1") end
		end)
	end
	local function fetchBytes(url)
		local ok, body = pcall(function() return game:HttpGet(url) end)
		if ok and type(body) == "string" and #body > 200 and string.sub(body, 1, 4) == "\137PNG" then
			return body
		end
		if type(httpRequest) == "function" then
			local rok, rres = pcall(httpRequest, { Url = url, Method = "GET" })
			if rok and type(rres) == "table" and rres.Success and type(rres.Body) == "string"
				and #rres.Body > 200 and string.sub(rres.Body, 1, 4) == "\137PNG"
			then
				return rres.Body
			end
		end
		return nil
	end
	task.spawn(function()
		for _, mood in ipairs(COACH_MOODS) do
			if not STATE.Alive then
				return
			end
			local path = "BeverlyHub/RoChess/coach_v1/" .. mood .. ".png"
			local ready = false
			local okExist, exists = pcall(isfile, path)
			if okExist and exists then
				ready = true
			else
				local png = fetchBytes(COACH_ASSET_BASE .. mood .. ".png")
				if png then
					local okW = pcall(writefile, path, png)
					ready = okW == true
				end
			end
			if ready then
				local okId, assetId = pcall(getAssetFn, path)
				if okId and type(assetId) == "string" and assetId ~= "" then
					HUD.avatarAssets[mood] = assetId
					if HUD.avatarImg and (HUD.lastMood == mood or (HUD.lastMood == "" and mood == "calm")) then
						HUD.avatarImg.Image = assetId
					end
				end
			end
		end
	end)
end

local function applyCoachMood(mood)
	mood = mood or "calm"
	if HUD.lastMood == mood or not HUD.avatarImg then
		return
	end
	HUD.lastMood = mood
	local imgId = HUD.avatarAssets[mood] or HUD.avatarAssets.calm or COACH_FALLBACK_THUMB
	if HUD.avatarImg.Image ~= imgId then
		HUD.avatarImg.Image = imgId
	end
end

function HUD.say(msg, mood, accentCol)
	if not HUD.fyiText then
		return
	end
	applyCoachMood(mood)
	if HUD.avatarRing then
		local ringCol = Color3.fromRGB(72, 76, 86)
		if mood == "hyped" then
			ringCol = Color3.fromRGB(242, 190, 66)
		elseif mood == "panic" or mood == "cool" then
			ringCol = Color3.fromRGB(214, 72, 68)
		elseif mood == "smug" then
			ringCol = Color3.fromRGB(46, 196, 182)
		elseif mood == "mischief" then
			ringCol = Color3.fromRGB(245, 166, 65)
		elseif accentCol then
			ringCol = Color3.fromRGB(72, 76, 86):Lerp(accentCol, 0.45)
		end
		HUD.avatarRing.Color = ringCol
	end
	if HUD.lastMsg ~= msg then
		HUD.lastMsg = msg
		HUD.fyiText.Text = msg
		HUD.bounceStartAt = os.clock()
	end
end

function HUD.tickAnim(now)
	-- Subtle crisp pop-bounce on avatar when Coach drops a new line
	if HUD.avatarFrame then
		local dt = now - (HUD.bounceStartAt or 0)
		local yOff = 10
		if dt >= 0 and dt < 0.22 then
			yOff = 10 - math.floor(math.sin((dt / 0.22) * math.pi) * 2.6 + 0.5)
		end
		if HUD.avatarFrame.Position.Y.Offset ~= yOff then
			HUD.avatarFrame.Position = UDim2.fromOffset(12, yOff)
		end
	end
	-- Gentle dot pulse only while actively thinking or Turbo
	if HUD.dot then
		if HUD.lastKind == "thinking" or HUD.lastKind == "turbo" then
			HUD.dot.BackgroundTransparency = 0.08 + 0.38 * (0.5 + 0.5 * math.sin(now * 6.0))
		else
			HUD.dot.BackgroundTransparency = (HUD.lastKind == "idle") and 0.35 or 0.06
		end
	end
end

do
	-- Transparent outer wrapper keeps card + soft drop-shadow locked together while dragging
	local wrap = Instance.new("Frame")
	wrap.Name = "TacticalHudCard"
	wrap.AnchorPoint = Vector2.new(0.5, 0)
	wrap.Position = UDim2.new(0.5, 0, 0, 10)
	wrap.Size = UDim2.fromOffset(436, 78)
	wrap.BackgroundTransparency = 1
	wrap.BorderSizePixel = 0
	wrap.Active = true
	wrap.ZIndex = 12
	wrap.Visible = false
	wrap.Parent = overlayGui
	HUD.root = wrap

	local shadow = Instance.new("Frame")
	shadow.Name = "DropShadow"
	shadow.Position = UDim2.fromOffset(0, 3)
	shadow.Size = UDim2.new(1, 0, 1, -2)
	shadow.BackgroundColor3 = Color3.fromRGB(10, 11, 14)
	shadow.BackgroundTransparency = 0.52
	shadow.BorderSizePixel = 0
	shadow.ZIndex = 11
	shadow.Parent = wrap
	local shCorner = Instance.new("UICorner")
	shCorner.CornerRadius = UDim.new(0, 14)
	shCorner.Parent = shadow

	-- Main RoChess-native matte panel (Theme.panelHeader = 36,38,42; Theme.outline = 64,68,76)
	local card = Instance.new("Frame")
	card.Name = "CoachCard"
	card.Position = UDim2.fromOffset(0, 0)
	card.Size = UDim2.new(1, 0, 1, -2)
	card.BackgroundColor3 = Color3.fromRGB(36, 38, 42)
	card.BackgroundTransparency = 0.02
	card.BorderSizePixel = 0
	card.ClipsDescendants = true
	card.ZIndex = 12
	card.Parent = wrap
	HUD.card = card

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 14)
	corner.Parent = card

	local stroke = Instance.new("UIStroke")
	stroke.Color = Color3.fromRGB(64, 68, 76)
	stroke.Thickness = 1.1
	stroke.Transparency = 0.08
	stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	stroke.Parent = card
	HUD.stroke = stroke

	-- Circular Studio-Illustrated Coach Portrait (56x56)
	local avFrame = Instance.new("Frame")
	avFrame.Name = "CoachPortrait"
	avFrame.Position = UDim2.fromOffset(12, 10)
	avFrame.Size = UDim2.fromOffset(56, 56)
	avFrame.BackgroundColor3 = Color3.fromRGB(48, 52, 62)
	avFrame.BorderSizePixel = 0
	avFrame.ClipsDescendants = true
	avFrame.ZIndex = 13
	avFrame.Parent = card
	HUD.avatarFrame = avFrame

	local avCorner = Instance.new("UICorner")
	avCorner.CornerRadius = UDim.new(1, 0)
	avCorner.Parent = avFrame

	local avRing = Instance.new("UIStroke")
	avRing.Color = Color3.fromRGB(72, 76, 86)
	avRing.Thickness = 1.6
	avRing.Transparency = 0.08
	avRing.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	avRing.Parent = avFrame
	HUD.avatarRing = avRing

	local avImg = Instance.new("ImageLabel")
	avImg.Name = "AvatarImg"
	avImg.BackgroundTransparency = 1
	avImg.Size = UDim2.fromScale(1, 1)
	avImg.ScaleType = Enum.ScaleType.Crop
	avImg.Image = COACH_FALLBACK_THUMB
	avImg.ZIndex = 14
	avImg.Parent = avFrame
	local imgCorner = Instance.new("UICorner")
	imgCorner.CornerRadius = UDim.new(1, 0)
	imgCorner.Parent = avImg
	HUD.avatarImg = avImg

	-- Top Meta Row: Status Dot + Crisp Engine Context + High-Contrast Eval Pill + Drag Grip
	local dot = Instance.new("Frame")
	dot.Name = "PulseDot"
	dot.AnchorPoint = Vector2.new(0.5, 0.5)
	dot.Position = UDim2.fromOffset(82, 18)
	dot.Size = UDim2.fromOffset(7, 7)
	dot.BackgroundColor3 = Color3.fromRGB(74, 127, 214)
	dot.BorderSizePixel = 0
	dot.ZIndex = 13
	dot.Parent = card
	local dotCorner = Instance.new("UICorner")
	dotCorner.CornerRadius = UDim.new(1, 0)
	dotCorner.Parent = dot
	HUD.dot = dot

	local title = Instance.new("TextLabel")
	title.Name = "EngineTitle"
	title.BackgroundTransparency = 1
	title.Position = UDim2.fromOffset(92, 9)
	title.Size = UDim2.new(1, -182, 0, 18)
	title.FontFace = Font.fromEnum(Enum.Font.BuilderSansMedium)
	title.TextSize = 12
	title.TextXAlignment = Enum.TextXAlignment.Left
	title.TextTruncate = Enum.TextTruncate.AtEnd
	title.TextColor3 = Color3.fromRGB(178, 182, 190)
	title.Text = "Stockfish 19 · Ready"
	title.ZIndex = 13
	title.Parent = card
	HUD.title = title

	-- High-contrast Chess.com/Lichess Eval Pill
	local evalPill = Instance.new("Frame")
	evalPill.Name = "EvalPill"
	evalPill.AnchorPoint = Vector2.new(1, 0)
	evalPill.Position = UDim2.new(1, -28, 0, 8)
	evalPill.Size = UDim2.fromOffset(58, 20)
	evalPill.BackgroundColor3 = Color3.fromRGB(50, 52, 57)
	evalPill.BorderSizePixel = 0
	evalPill.ZIndex = 13
	evalPill.Parent = card
	local epCorner = Instance.new("UICorner")
	epCorner.CornerRadius = UDim.new(0, 6)
	epCorner.Parent = evalPill
	local epStroke = Instance.new("UIStroke")
	epStroke.Color = Color3.fromRGB(74, 78, 88)
	epStroke.Thickness = 1
	epStroke.Transparency = 0.35
	epStroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	epStroke.Parent = evalPill
	HUD.evalPill = evalPill
	HUD.evalStroke = epStroke

	local evalText = Instance.new("TextLabel")
	evalText.Name = "EvalText"
	evalText.BackgroundTransparency = 1
	evalText.Size = UDim2.fromScale(1, 1)
	evalText.FontFace = Font.new(Font.fromEnum(Enum.Font.RobotoMono).Family, Enum.FontWeight.Bold)
	evalText.TextSize = 12
	evalText.TextColor3 = Color3.fromRGB(243, 244, 246)
	evalText.Text = "0.0"
	evalText.ZIndex = 14
	evalText.Parent = evalPill
	HUD.evalText = evalText

	local grip = Instance.new("TextLabel")
	grip.Name = "Grip"
	grip.BackgroundTransparency = 1
	grip.AnchorPoint = Vector2.new(1, 0)
	grip.Position = UDim2.new(1, -9, 0, 8)
	grip.Size = UDim2.fromOffset(14, 19)
	grip.FontFace = Font.fromEnum(Enum.Font.BuilderSansBold)
	grip.TextSize = 13
	grip.TextColor3 = Color3.fromRGB(108, 114, 126)
	grip.Text = "⋮⋮"
	grip.ZIndex = 13
	grip.Parent = card
	HUD.grip = grip

	-- Main Coach Dialogue (BuilderSans 14px, generous right padding — never clips!)
	local fyiText = Instance.new("TextLabel")
	fyiText.Name = "CoachSpeech"
	fyiText.BackgroundTransparency = 1
	fyiText.Position = UDim2.fromOffset(79, 31)
	fyiText.Size = UDim2.new(1, -95, 0, 38)
	fyiText.FontFace = Font.fromEnum(Enum.Font.BuilderSansMedium)
	fyiText.TextSize = 14
	fyiText.LineHeight = 1.14
	fyiText.TextWrapped = true
	fyiText.TextXAlignment = Enum.TextXAlignment.Left
	fyiText.TextYAlignment = Enum.TextYAlignment.Top
	fyiText.TextColor3 = Color3.fromRGB(243, 244, 246)
	fyiText.Text = "Siap nemenin main. Kartu ini bisa di-drag (double-click reset)."
	fyiText.ZIndex = 13
	fyiText.Parent = card
	HUD.fyiText = fyiText

	applyCoachMood("calm")
	preloadCoachAvatars()

	-- Subtle hover feedback on grip
	trackConn(wrap.MouseEnter:Connect(function()
		HUD.hovered = true
		if HUD.grip then HUD.grip.TextColor3 = Color3.fromRGB(196, 202, 214) end
	end))
	trackConn(wrap.MouseLeave:Connect(function()
		HUD.hovered = false
		if HUD.grip then HUD.grip.TextColor3 = Color3.fromRGB(108, 114, 126) end
	end))

	-- Smooth drag + double-click reset (clamped inside screen bounds)
	local dragStartMouse = nil
	local dragStartPos = nil
	local movedDuringDrag = false

	trackConn(wrap.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			local now = os.clock()
			if (now - HUD.lastClickAt) <= 0.32 and not movedDuringDrag then
				HUD.customPos = false
				wrap.AnchorPoint = Vector2.new(0.5, 0)
				wrap.Position = UDim2.new(0.5, 0, 0, 10)
				HUD.lastClickAt = 0
				return
			end
			HUD.lastClickAt = now
			HUD.dragging = true
			movedDuringDrag = false
			dragStartMouse = Vector2.new(input.Position.X, input.Position.Y)
			local absPos = wrap.AbsolutePosition
			wrap.AnchorPoint = Vector2.new(0, 0)
			wrap.Position = UDim2.fromOffset(absPos.X, absPos.Y)
			dragStartPos = absPos
		end
	end))

	trackConn(UserInputService.InputChanged:Connect(function(input)
		if not HUD.dragging or not dragStartMouse or not dragStartPos then
			return
		end
		if input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch then
			local delta = Vector2.new(input.Position.X, input.Position.Y) - dragStartMouse
			if delta.Magnitude >= 4 then
				movedDuringDrag = true
				HUD.customPos = true
			end
			local cam = workspace.CurrentCamera
			local vp = cam and cam.ViewportSize or Vector2.new(1280, 720)
			local inset = GuiService:GetGuiInset()
			local maxX = math.max(8, vp.X - wrap.AbsoluteSize.X - 8)
			local maxY = math.max(8, vp.Y - inset.Y - wrap.AbsoluteSize.Y - 8)
			local nx = math.clamp(dragStartPos.X + delta.X, 8, maxX)
			local ny = math.clamp(dragStartPos.Y + delta.Y, 6, maxY)
			wrap.Position = UDim2.fromOffset(nx, ny)
		end
	end))

	trackConn(UserInputService.InputEnded:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			HUD.dragging = false
		end
	end))
end

-- Broadcast-Grade Vertical Eval & Win-Chance Bar docked left of board (RoChess-native + viewport-clamped)
local EVALBAR = {
	frame = nil,
	whiteFill = nil,
	horizon = nil,
	scoreLabel = nil,
	winPctLabel = nil,
	oppPctLabel = nil,
	tooltip = nil,
	tipTop = nil,
	tipSub = nil,
	hovered = false,
	lastAtBottom = true,
	lastVisTop = 0,
	lastVisBot = 600,
}
do
	local bar = Instance.new("Frame")
	bar.Name = "EvalBar"
	bar.BackgroundColor3 = Color3.fromRGB(36, 38, 42)
	bar.BorderSizePixel = 0
	bar.ClipsDescendants = true
	bar.Visible = false
	bar.ZIndex = 6
	bar.Parent = overlayGui
	EVALBAR.frame = bar

	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, 6)
	c.Parent = bar
	local st = Instance.new("UIStroke")
	st.Color = Color3.fromRGB(64, 68, 76)
	st.Thickness = 1
	st.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	st.Parent = bar

	local wf = Instance.new("Frame")
	wf.Name = "WhiteFill"
	wf.BackgroundColor3 = Color3.fromRGB(240, 239, 234)
	wf.BorderSizePixel = 0
	wf.AnchorPoint = Vector2.new(0, 1)
	wf.Position = UDim2.fromScale(0, 1)
	wf.Size = UDim2.fromScale(1, 0.5)
	wf.ZIndex = 7
	wf.Parent = bar
	EVALBAR.whiteFill = wf

	-- Crisp 2px advantage horizon line tracking White/Black balance
	local horizon = Instance.new("Frame")
	horizon.Name = "Horizon"
	horizon.AnchorPoint = Vector2.new(0, 0.5)
	horizon.Position = UDim2.fromScale(0, 0.5)
	horizon.Size = UDim2.new(1, 0, 0, 2)
	horizon.BackgroundColor3 = Color3.fromRGB(118, 124, 138)
	horizon.BorderSizePixel = 0
	horizon.ZIndex = 9
	horizon.Parent = bar
	EVALBAR.horizon = horizon

	-- Subtle 50% equilibrium notch (left + right)
	for _, xSpec in ipairs({ { 0, 0 }, { 1, 1 } }) do
		local tk = Instance.new("Frame")
		tk.AnchorPoint = Vector2.new(xSpec[1], 0.5)
		tk.Position = UDim2.fromScale(xSpec[2], 0.50)
		tk.Size = UDim2.fromOffset(5, 1)
		tk.BackgroundColor3 = Color3.fromRGB(130, 136, 150)
		tk.BackgroundTransparency = 0.25
		tk.BorderSizePixel = 0
		tk.ZIndex = 8
		tk.Parent = bar
	end

	-- Winning-side primary Eval Score (viewport-clamped so never clipped off-screen!)
	local scoreLbl = Instance.new("TextLabel")
	scoreLbl.Name = "EvalScore"
	scoreLbl.BackgroundTransparency = 1
	scoreLbl.Size = UDim2.new(1, 0, 0, 15)
	scoreLbl.AnchorPoint = Vector2.new(0, 1)
	scoreLbl.Position = UDim2.new(0, 0, 1, -4)
	scoreLbl.FontFace = Font.fromEnum(Enum.Font.BuilderSansBold)
	scoreLbl.TextSize = 11
	scoreLbl.TextColor3 = Color3.fromRGB(24, 26, 32)
	scoreLbl.Text = "0.0"
	scoreLbl.ZIndex = 10
	scoreLbl.Parent = bar
	EVALBAR.scoreLabel = scoreLbl

	-- Winning-side secondary Win-Chance %
	local pctLbl = Instance.new("TextLabel")
	pctLbl.Name = "WinPct"
	pctLbl.BackgroundTransparency = 1
	pctLbl.Size = UDim2.new(1, 0, 0, 12)
	pctLbl.AnchorPoint = Vector2.new(0, 1)
	pctLbl.Position = UDim2.new(0, 0, 1, -18)
	pctLbl.FontFace = Font.new(Font.fromEnum(Enum.Font.RobotoMono).Family, Enum.FontWeight.Bold)
	pctLbl.TextSize = 9
	pctLbl.TextColor3 = Color3.fromRGB(82, 86, 98)
	pctLbl.Text = "50%"
	pctLbl.ZIndex = 10
	pctLbl.Parent = bar
	EVALBAR.winPctLabel = pctLbl

	-- Opposite-end subtle remaining Win % (hidden when trailing region <20%)
	local oppLbl = Instance.new("TextLabel")
	oppLbl.Name = "OppPct"
	oppLbl.BackgroundTransparency = 1
	oppLbl.Size = UDim2.new(1, 0, 0, 12)
	oppLbl.AnchorPoint = Vector2.new(0, 0)
	oppLbl.Position = UDim2.new(0, 0, 0, 4)
	oppLbl.FontFace = Font.new(Font.fromEnum(Enum.Font.RobotoMono).Family, Enum.FontWeight.Medium)
	oppLbl.TextSize = 9
	oppLbl.TextColor3 = Color3.fromRGB(168, 174, 186)
	oppLbl.Text = "50%"
	oppLbl.ZIndex = 10
	oppLbl.Parent = bar
	EVALBAR.oppPctLabel = oppLbl

	-- RoChess-native Hover Breakdown Card
	local tip = Instance.new("Frame")
	tip.Name = "EvalTooltip"
	tip.Size = UDim2.fromOffset(182, 42)
	tip.BackgroundColor3 = Color3.fromRGB(36, 38, 42)
	tip.BackgroundTransparency = 0.02
	tip.BorderSizePixel = 0
	tip.Visible = false
	tip.ZIndex = 16
	tip.Parent = overlayGui
	local tc = Instance.new("UICorner")
	tc.CornerRadius = UDim.new(0, 10)
	tc.Parent = tip
	local tst = Instance.new("UIStroke")
	tst.Color = Color3.fromRGB(64, 68, 76)
	tst.Thickness = 1
	tst.Parent = tip
	EVALBAR.tooltip = tip

	local tipTop = Instance.new("TextLabel")
	tipTop.BackgroundTransparency = 1
	tipTop.Position = UDim2.fromOffset(10, 5)
	tipTop.Size = UDim2.new(1, -20, 0, 16)
	tipTop.FontFace = Font.fromEnum(Enum.Font.BuilderSansBold)
	tipTop.TextSize = 12
	tipTop.TextXAlignment = Enum.TextXAlignment.Left
	tipTop.TextColor3 = Color3.fromRGB(243, 244, 246)
	tipTop.Text = "Putih 50%  ·  Hitam 50%"
	tipTop.ZIndex = 17
	tipTop.Parent = tip
	EVALBAR.tipTop = tipTop

	local tipSub = Instance.new("TextLabel")
	tipSub.BackgroundTransparency = 1
	tipSub.Position = UDim2.fromOffset(10, 22)
	tipSub.Size = UDim2.new(1, -20, 0, 14)
	tipSub.FontFace = Font.fromEnum(Enum.Font.BuilderSansMedium)
	tipSub.TextSize = 11
	tipSub.TextXAlignment = Enum.TextXAlignment.Left
	tipSub.TextColor3 = Color3.fromRGB(178, 182, 190)
	tipSub.Text = "Eval 0.00 · Seimbang"
	tipSub.ZIndex = 17
	tipSub.Parent = tip
	EVALBAR.tipSub = tipSub

	trackConn(bar.MouseEnter:Connect(function()
		EVALBAR.hovered = true
		if bar.Visible then
			tip.Visible = true
		end
	end))
	trackConn(bar.MouseLeave:Connect(function()
		EVALBAR.hovered = false
		tip.Visible = false
	end))
end

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
	STATE.LastArrowSig = ""
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

local function positionEvalBarLabels(atBottom, visTop, visBot)
	if not EVALBAR.scoreLabel then
		return
	end
	local topY = math.max(4, math.floor((visTop or 0) + 4))
	local botY = math.max(topY + 34, math.floor((visBot or 400) - 4))
	if atBottom then
		EVALBAR.scoreLabel.AnchorPoint = Vector2.new(0, 1)
		EVALBAR.scoreLabel.Position = UDim2.fromOffset(0, botY)
		EVALBAR.winPctLabel.AnchorPoint = Vector2.new(0, 1)
		EVALBAR.winPctLabel.Position = UDim2.fromOffset(0, botY - 14)
		EVALBAR.oppPctLabel.AnchorPoint = Vector2.new(0, 0)
		EVALBAR.oppPctLabel.Position = UDim2.fromOffset(0, topY)
	else
		EVALBAR.scoreLabel.AnchorPoint = Vector2.new(0, 0)
		EVALBAR.scoreLabel.Position = UDim2.fromOffset(0, topY)
		EVALBAR.winPctLabel.AnchorPoint = Vector2.new(0, 0)
		EVALBAR.winPctLabel.Position = UDim2.fromOffset(0, topY + 14)
		EVALBAR.oppPctLabel.AnchorPoint = Vector2.new(0, 1)
		EVALBAR.oppPctLabel.Position = UDim2.fromOffset(0, botY)
	end
end

local function updateEvalBarVisual(cp, mate, flipped)
	if not EVALBAR.frame then
		return
	end
	local isMate = (mate ~= nil and mate ~= 0)
	local whiteWinPct, whiteFrac
	if isMate then
		whiteWinPct = (mate > 0) and 100 or 0
		whiteFrac = (mate > 0) and 0.975 or 0.025
	else
		-- Official Lichess / Stockfish logistic winning-chance curve
		local clamped = math.clamp(cp or 0, -1500, 1500)
		whiteWinPct = 100 / (1 + math.exp(-0.00368208 * clamped))
		whiteFrac = math.clamp(whiteWinPct / 100, 0.035, 0.965)
	end

	local ti = TweenInfo.new(0.28, Enum.EasingStyle.Quart, Enum.EasingDirection.Out)
	EVALBAR.whiteFill.AnchorPoint = flipped and Vector2.new(0, 0) or Vector2.new(0, 1)
	EVALBAR.whiteFill.Position = flipped and UDim2.fromScale(0, 0) or UDim2.fromScale(0, 1)
	TweenService:Create(EVALBAR.whiteFill, ti, {
		Size = UDim2.fromScale(1, whiteFrac),
	}):Play()

	local horizonY = flipped and whiteFrac or (1 - whiteFrac)
	local absCp = math.abs(cp or 0)
	local horizonCol = isMate and Color3.fromRGB(242, 190, 66)
		or (absCp >= 300 and Color3.fromRGB(224, 178, 72))
		or (absCp >= 80 and Color3.fromRGB(46, 196, 182))
		or Color3.fromRGB(118, 124, 138)
	TweenService:Create(EVALBAR.horizon, ti, {
		Position = UDim2.fromScale(0, horizonY),
		BackgroundColor3 = horizonCol,
	}):Play()

	local whiteBetter = isMate and (mate > 0) or ((cp or 0) >= 0)
	local atBottom = (whiteBetter and not flipped) or ((not whiteBetter) and flipped)
	EVALBAR.lastAtBottom = atBottom
	positionEvalBarLabels(atBottom, EVALBAR.lastVisTop, EVALBAR.lastVisBot)

	if isMate then
		EVALBAR.scoreLabel.TextColor3 = whiteBetter and Color3.fromRGB(146, 98, 10) or Color3.fromRGB(242, 190, 66)
	else
		EVALBAR.scoreLabel.TextColor3 = whiteBetter and Color3.fromRGB(24, 26, 32) or Color3.fromRGB(243, 244, 246)
	end
	EVALBAR.winPctLabel.TextColor3 = whiteBetter and Color3.fromRGB(82, 86, 98) or Color3.fromRGB(178, 182, 190)

	local wPctInt = math.clamp(math.floor(whiteWinPct + 0.5), 0, 100)
	local bPctInt = 100 - wPctInt
	local leadPct = whiteBetter and wPctInt or bPctInt
	local trailPct = 100 - leadPct

	if isMate then
		EVALBAR.scoreLabel.Text = "M" .. tostring(math.abs(mate))
		EVALBAR.winPctLabel.Text = "WIN"
	else
		local pawns = (cp or 0) / 100
		if math.abs(pawns) < 0.05 then
			EVALBAR.scoreLabel.Text = "0.0"
		elseif math.abs(pawns) >= 10 then
			EVALBAR.scoreLabel.Text = string.format("%+.0f", pawns)
		else
			EVALBAR.scoreLabel.Text = string.format("%+.1f", pawns)
		end
		EVALBAR.winPctLabel.Text = tostring(leadPct) .. "%"
	end

	local trailingFrac = whiteBetter and (1 - whiteFrac) or whiteFrac
	EVALBAR.oppPctLabel.Visible = (not isMate) and (trailingFrac >= 0.20)
	if EVALBAR.oppPctLabel.Visible then
		EVALBAR.oppPctLabel.TextColor3 = whiteBetter and Color3.fromRGB(168, 174, 186) or Color3.fromRGB(92, 96, 110)
		EVALBAR.oppPctLabel.Text = tostring(trailPct) .. "%"
	end

	if EVALBAR.tipTop and EVALBAR.tipSub then
		EVALBAR.tipTop.Text = string.format("Putih %d%%  ·  Hitam %d%%", wPctInt, bPctInt)
		if isMate then
			EVALBAR.tipSub.Text = string.format("Skakmat Paksa · %s M%d", (mate > 0) and "Putih" or "Hitam", math.abs(mate))
		else
			local tone = (absCp < 55) and "Seimbang"
				or (absCp < 160 and "Unggul tipis")
				or (absCp < 350 and "Unggul jelas")
				or "Menang telak"
			EVALBAR.tipSub.Text = string.format("Eval %s · %s", formatEvalText(cp, nil), tone)
		end
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
	pcall(function() overlayGui:Destroy() end)
	if arrowHeadImageObj then
		pcall(function() arrowHeadImageObj:Destroy() end)
	end
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
	Farm = Window:AddTab("Auto-Farm", "trending-up", "AFK Elo farming, anti-rungkat controlled losses, and stats"),
	Settings = Window:AddTab("Settings", "settings", "Keybinds, offline tuning, themes, and configs"),
}

local triggerRecalc -- forward declaration
local performSafeAutoMove -- forward declaration
local cleanup -- forward declaration

local recalcQueued = false
local function scheduleRecalc()
	if recalcQueued then
		return
	end
	recalcQueued = true
	task.defer(function()
		recalcQueued = false
		if STATE.Alive and STATE.App and triggerRecalc then
			triggerRecalc(true)
		end
	end)
end

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
		CONFIG.DynamicModeColors = hasLayer(layers, "Dynamic Mode Colors")
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
	CONFIG.AutoAdapt = (Toggles.AutoAdapt == nil) or (Toggles.AutoAdapt.Value == true)
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
	CONFIG.PauseTurboOnSpectate = (Toggles.PauseTurboOnSpectate == nil) or (Toggles.PauseTurboOnSpectate.Value == true)
	CONFIG.AutoPlay = (Toggles.AutoPlay ~= nil) and (Toggles.AutoPlay.Value == true)
	CONFIG.AutoNextPuzzle = (Toggles.AutoNextPuzzle ~= nil) and (Toggles.AutoNextPuzzle.Value == true)
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
	CONFIG.AutoReloadOnTeleport = (Toggles.AutoReloadOnTeleport == nil) or (Toggles.AutoReloadOnTeleport.Value == true)
	CONFIG.AutoFarm = (Toggles.AutoFarm ~= nil) and (Toggles.AutoFarm.Value == true)
	if Options.FarmLossMode and type(Options.FarmLossMode.Value) == "string" then
		CONFIG.FarmLossMode = Options.FarmLossMode.Value
	end
	if Options.FarmLossAfterElo and tonumber(Options.FarmLossAfterElo.Value) then
		CONFIG.FarmLossAfterElo = math.clamp(math.floor(tonumber(Options.FarmLossAfterElo.Value)), 20, 150)
	end
	if Options.FarmStopAtElo and tonumber(Options.FarmStopAtElo.Value) then
		CONFIG.FarmStopAtElo = math.clamp(math.floor(tonumber(Options.FarmStopAtElo.Value)), 0, 3000)
	end
	CONFIG.FarmHumanBreather = (Toggles.FarmHumanBreather == nil) or (Toggles.FarmHumanBreather.Value == true)
	CONFIG.FarmKeepPositive = (Toggles.FarmKeepPositive == nil) or (Toggles.FarmKeepPositive.Value == true)
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
	Values = { "Best Move Arrow", "Opponent Ponder", "Square Highlights", "Eval Bar", "Engine Badge", "Dynamic Mode Colors" },
	Default = { "Best Move Arrow", "Opponent Ponder", "Square Highlights", "Eval Bar", "Engine Badge", "Dynamic Mode Colors" },
	Tooltip = "Select which visual guides appear over the board. Dynamic Mode Colors tints arrows & highlights per active engine/mode.",
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

AssistBox:AddToggle("AutoNextPuzzle", {
	Text = "Auto Next Puzzle",
	Default = false,
	Tooltip = "Automatically clicks Next with a short natural pause once a puzzle is finished.",
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
	Tooltip = "Uses VPS MultiPV 2/3 to play authentic GM/Master moves & opening variety. Automatically adapts strength against sharp or engine opponents.",
})

AnalysisBox:AddToggle("AntiEngineTurbo", {
	Text = "Anti-Engine Turbo",
	Default = true,
	Tooltip = "Detects engine opponents early via Stockfish agreement & cadence, prefetches ponder replies (0ms), and speeds up under pressure.",
})

AnalysisBox:AddToggle("PauseTurboOnSpectate", {
	Text = "Pause Turbo on Spectate",
	Default = true,
	Tooltip = "Automatically pauses Turbo Mode while anyone is spectating your match, then resumes once spectators leave.",
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
	STATE.AutoGen += 1
	STATE.AutoPending = false
	STATE.LastAutoKey = ""
	STATE.AutoRetryAfter = 0
	cancelPrefetchState()
	local app = STATE.App
	local sess = app and app.session
	if sess and sess.engine then
		local eng = (sess.kind == "analysis" or sess.kind == "review") and sess:engineAt(sess.viewPly) or sess.engine
		if eng and type(eng.getFen) == "function" then
			local okF, fStr = pcall(eng.getFen, eng)
			if okF and type(fStr) == "string" then
				local f4 = fen4Key(fStr)
				STATE.Cache[f4 .. "|sf"] = nil
				STATE.Cache[f4 .. "|sf2"] = nil
				STATE.Cache[f4 .. "|sf3"] = nil
				STATE.Cache[f4 .. "|luau"] = nil
			end
		end
	end
	if triggerRecalc then
		triggerRecalc(true)
	end
end):AddButton("Clear Cache", function()
	table.clear(STATE.Cache)
	table.clear(STATE.CacheOrder)
	PureChess.clearTT()
	cancelPrefetchState()
	STATE.VpsCooldownUntil = 0
	STATE.VpsFailStreak = 0
	STATE.SfCooldownUntil = 0
	STATE.SfFailStreak = 0
	STATE.AutoGen += 1
	STATE.AutoPending = false
	STATE.LastAutoKey = ""
	STATE.AutoRetryAfter = 0
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

MenuGroup:AddToggle("AutoReloadOnTeleport", {
	Text = "Auto-Reload on Teleport",
	Default = true,
	Tooltip = "Automatically re-queues BeverlyHub via queue_on_teleport when RoChess teleports into a cross-server match.",
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

MenuGroup:AddToggle("AutoAdapt", {
	Text = "Auto-Adapt Strength",
	Default = true,
	Tooltip = "Dynamically escalates Play Style (+1 tier vs sharp opponents or eval <= -0.6; straight to Full vs Suspect/Engine/Turbo or eval <= -1.5) and smoothly eases back when comfortably winning (+2.0+).",
})

MenuGroup:AddToggle("SmartDelay", {
	Text = "Smart Phase Delay",
	Default = true,
	Tooltip = "Fast moves in opening, forced tactics, recaptures, and endgames; TC-scaled randomized delay in middlegame.",
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
	Tooltip = "Caps how far ahead your clock stays vs your opponent (0 = off). Automatically skipped in Bullet, openings, forced moves, recaptures, Suspect, or Turbo.",
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

-- Tab 2: Auto-Farm Elo (wrapped in do..end so zero extra top-level locals are consumed)
do
	local FarmLeft = Tabs.Farm:AddGroupbox({
		Side = "Left",
		Name = "Elo Auto-Farm",
		IconName = "trending-up",
	})

	FarmLeft:AddToggle("AutoFarm", {
		Text = "Enable Auto-Farm Elo",
		Default = false,
		Risky = true,
		Tooltip = "Automatically plays rated matches, tracks Elo across server teleports, and mixes in safe controlled losses so win streaks stay natural.",
	})

	FarmLeft:AddDropdown("FarmLossMode", {
		Text = "Loss Style",
		Values = {
			BlunderResign = "Blunder + Resign (Natural)",
			PlayWeak = "Play Weak (~900 Elo)",
			LateResign = "Late Resign (Move 16-24)",
		},
		Default = "BlunderResign",
		Tooltip = "How a scheduled controlled loss is played once your +Elo cycle target is reached.",
	})

	FarmLeft:AddSlider("FarmLossAfterElo", {
		Text = "Loss After +Elo",
		Default = 45,
		Min = 20,
		Max = 150,
		Rounding = 0,
		Suffix = " Elo",
		Compact = true,
		Tooltip = "Schedule 1 controlled loss after earning roughly +N Elo (+-20% random jitter). Real losses reset the counter automatically.",
	})

	FarmLeft:AddSlider("FarmStopAtElo", {
		Text = "Stop At Target Elo",
		Default = 0,
		Min = 0,
		Max = 3000,
		Rounding = 0,
		Suffix = " Elo",
		Compact = true,
		Tooltip = "Automatically stop Auto-Farm when your rating reaches this value (0 = no limit).",
	})

	FarmLeft:AddDivider("AFK Pacing & Protection")

	FarmLeft:AddToggle("FarmHumanBreather", {
		Text = "Human Breather (20-45s)",
		Default = true,
		Tooltip = "Takes a natural 20-45s break every 5-8 games and varies inter-game queue wait (3-9s).",
	})

	FarmLeft:AddToggle("FarmKeepPositive", {
		Text = "Anti-Rungkat Guard",
		Default = true,
		Tooltip = "Defers any scheduled loss if opponent is much lower rated or expected Elo loss would exceed 40% of cycle profit (guarantees net-positive Elo).",
	})

	local FarmRight = Tabs.Farm:AddGroupbox({
		Side = "Right",
		Name = "Farm Session",
		IconName = "activity",
	})

	FarmRight:AddLabel("FarmStatusLabel", { Text = "Status: Standby", DoesWrap = false })
	FarmRight:AddLabel("FarmRatingLabel", { Text = "Rating: -- (Net +0 Elo)", DoesWrap = false })
	FarmRight:AddLabel("FarmRecordLabel", { Text = "Record: 0W · 0L · 0D (0 Ctrl)", DoesWrap = false })
	FarmRight:AddLabel("FarmCycleLabel", { Text = "Loss Cycle: +0 / ~45 Elo", DoesWrap = false })
	FarmRight:AddLabel("FarmGuardLabel", { Text = "Guard: Ready", DoesWrap = true })

	FarmRight:AddDivider("Actions")

	FarmRight:AddButton("Reset Farm Stats", function()
		if Farm.resetStats then
			Farm.resetStats()
		end
	end):AddButton("Disarm Throw", function()
		if Farm.disarmThrow then
			Farm.disarmThrow("Manual disarm")
		end
	end)
end

Library.ToggleKeybind = Options.MenuKeybind

-- Hook UI callbacks (debounced with 1-frame coalescing so SaveManager autoload never triggers HTTP storms)
Toggles.BoardAssist:OnChanged(function()
	syncConfigFromUI()
	scheduleRecalc()
end)
Options.ArrowColor:OnChanged(syncConfigFromUI)
Options.VisualLayers:OnChanged(syncConfigFromUI)
Options.EngineMode:OnChanged(function()
	syncConfigFromUI()
	scheduleRecalc()
end)
Options.PlayStyle:OnChanged(function()
	STATE.Opp.adaptTier = nil
	STATE.Opp.lastAdaptPly = -1
	syncConfigFromUI()
	scheduleRecalc()
end)
Toggles.AutoAdapt:OnChanged(function()
	syncConfigFromUI()
	if not CONFIG.AutoAdapt then
		STATE.Opp.adaptTier = nil
		STATE.Opp.lastAdaptPly = -1
	end
	scheduleRecalc()
end)
Options.StockfishDepth:OnChanged(function()
	syncConfigFromUI()
	scheduleRecalc()
end)
Options.LuauDepth:OnChanged(function()
	syncConfigFromUI()
	if CONFIG.EngineMode == "Luau" then
		scheduleRecalc()
	end
end)
Options.VpsApiUrl:OnChanged(function()
	syncConfigFromUI()
	STATE.VpsCooldownUntil = 0
	STATE.VpsFailStreak = 0
	scheduleRecalc()
end)
Options.LocalWsUrl:OnChanged(syncConfigFromUI)
Toggles.OnlyMyTurn:OnChanged(function()
	syncConfigFromUI()
	scheduleRecalc()
end)
Toggles.AntiEngineTurbo:OnChanged(function()
	syncConfigFromUI()
	if not CONFIG.AntiEngineTurbo then
		STATE.Opp.turboActive = false
		STATE.Opp.turboReason = nil
		STATE.Opp.spectatorPaused = false
		STATE.Opp.suspect = false
		cancelPrefetchState()
	end
	scheduleRecalc()
end)
Toggles.PauseTurboOnSpectate:OnChanged(function()
	syncConfigFromUI()
	if STATE.App and STATE.App.session then
		scheduleRecalc()
	end
end)
Toggles.AutoNextPuzzle:OnChanged(function(val)
	syncConfigFromUI()
	if val then
		STATE.PuzzleNextClickAt = 0
	end
end)
Toggles.AutoPlay:OnChanged(function(val)
	syncConfigFromUI()
	if val then
		STATE.LastAutoKey = ""
		STATE.AutoRetryAfter = 0
		if STATE.App and STATE.App.session then
			if STATE.CurrentResult then
				performSafeAutoMove(STATE.App.session, STATE.CurrentResult, STATE.LastKey)
			else
				scheduleRecalc()
			end
		end
	else
		STATE.AutoGen += 1
		STATE.AutoPending = false
		STATE.AutoExpectedWait = 0
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
Toggles.AutoReloadOnTeleport:OnChanged(syncConfigFromUI)
Toggles.AutoFarm:OnChanged(function(val)
	syncConfigFromUI()
	if val then
		local enabledAny = false
		if Toggles.AutoPlay and not Toggles.AutoPlay.Value then
			STATE.Farm.autoEnabledAutoPlay = true
			Toggles.AutoPlay:SetValue(true)
			enabledAny = true
		end
		if Toggles.AutoFindMatch and not Toggles.AutoFindMatch.Value then
			STATE.Farm.autoEnabledAutoFind = true
			Toggles.AutoFindMatch:SetValue(true)
			enabledAny = true
		end
		STATE.Farm.idleSince = os.clock()
		if Farm.refreshUi then Farm.refreshUi(STATE.App, STATE.App and STATE.App.session) end
		if Farm.saveState then Farm.saveState(false) end
		if enabledAny then
			pcall(function()
				Library:Notify({
					Title = "Auto-Farm Elo Enabled",
					Description = "Auto Play & Auto Find Match turned ON automatically with Anti-Rungkat protection.",
					Time = 3.5,
				})
			end)
		end
	else
		if Farm.disarmThrow then
			Farm.disarmThrow("Auto-Farm disabled")
		end
		STATE.Farm.breakUntil = 0
		if Farm.clearResume then
			Farm.clearResume()
		end
		if Farm.refreshUi then Farm.refreshUi(STATE.App, STATE.App and STATE.App.session) end
	end
end)
Options.FarmLossMode:OnChanged(function()
	syncConfigFromUI()
	if Farm.refreshUi then Farm.refreshUi(STATE.App, STATE.App and STATE.App.session) end
end)
Options.FarmLossAfterElo:OnChanged(function()
	syncConfigFromUI()
	if Farm.onLossTargetChanged then Farm.onLossTargetChanged() end
	if Farm.refreshUi then Farm.refreshUi(STATE.App, STATE.App and STATE.App.session) end
end)
Options.FarmStopAtElo:OnChanged(function()
	syncConfigFromUI()
	if Farm.refreshUi then Farm.refreshUi(STATE.App, STATE.App and STATE.App.session) end
end)
Toggles.FarmHumanBreather:OnChanged(syncConfigFromUI)
Toggles.FarmKeepPositive:OnChanged(syncConfigFromUI)

-- ThemeManager & SaveManager
if ThemeManager and SaveManager then
	pcall(function()
		ThemeManager:SetLibrary(Library)
		SaveManager:SetLibrary(Library)
		SaveManager:IgnoreThemeSettings()
		SaveManager:SetIgnoreIndexes({ "MenuKeybind", "VpsApiUrl" })
		if type(SaveManager.SetLoadingOrder) == "function" then
			SaveManager:SetLoadingOrder(true, { "Input", "Dropdown", "Slider", "ColorPicker", "KeyPicker", "Toggle" })
		end
		ThemeManager:SetFolder("BeverlyHub")
		SaveManager:SetFolder("BeverlyHub/RoChess")
		SaveManager:BuildConfigSection(Tabs.Settings)
		ThemeManager:ApplyToTab(Tabs.Settings)
		SaveManager:LoadAutoloadConfig()
	end)
end

syncConfigFromUI()

-- ============================================================================
-- 6. SAFE AUTO-PLAY VIA REAL VIRTUAL INPUT CLICKS (PASSES u152, fromInput() & bl=0)
-- ============================================================================
-- Track Roblox window focus so AutoPlay NEVER clicks while alt-tabbed (Layer-5 bl focus safety)
trackConn(UserInputService.WindowFocusReleased:Connect(function()
	STATE.WindowFocused = false
end))
trackConn(UserInputService.WindowFocused:Connect(function()
	STATE.WindowFocused = true
end))

local function getSessionPly(sess)
	return (sess and type(sess.ucis) == "table") and #sess.ucis or 0
end

local function isSafeToSendInput()
	if not STATE.WindowFocused then
		return false, "Focus"
	end
	if HUD.dragging then
		return false, "Dragging HUD"
	end
	if UserInputService:GetFocusedTextBox() ~= nil then
		return false, "Typing"
	end
	if UserInputService:IsMouseButtonPressed(Enum.UserInputType.MouseButton1) then
		return false, "Mouse Held"
	end
	return true, nil
end

local function isPointOverBadge(vpPoint, inset)
	local card = HUD.root
	if not card or not card.Visible then
		return false
	end
	local pos = card.AbsolutePosition + inset
	local sz = card.AbsoluteSize
	return vpPoint.X >= (pos.X - 6) and vpPoint.X <= (pos.X + sz.X + 6)
		and vpPoint.Y >= (pos.Y - 6) and vpPoint.Y <= (pos.Y + sz.Y + 6)
end

local function isPointOverMenu(vpPoint, inset)
	local mf = Window and Window.MainFrame
	if not mf or not mf.Visible or not Library or not Library.Toggled then
		return false
	end
	local mPos = mf.AbsolutePosition + inset
	local mSz = mf.AbsoluteSize
	return vpPoint.X >= (mPos.X - 6) and vpPoint.X <= (mPos.X + mSz.X + 6)
		and vpPoint.Y >= (mPos.Y - 6) and vpPoint.Y <= (mPos.Y + mSz.Y + 6)
end

local function ensureBoardUnoccluded(pFrom, pTo, inset)
	if not (isPointOverMenu(pFrom, inset) or isPointOverMenu(pTo, inset)) then
		return false
	end
	local mf = Window and Window.MainFrame
	if Library and type(Library.Toggle) == "function" then
		-- Hide instantly (bypass 0.3s fade animation during AutoPlay so VIM clicks never hit MainFrame)
		local prevAnim = Library.Animations and Library.Animations.ToggleWindow
		if Library.Animations then
			Library.Animations.ToggleWindow = false
		end
		pcall(function()
			Library:Toggle(false)
		end)
		if Library.Animations then
			Library.Animations.ToggleWindow = prevAnim
		end
	end
	-- Wait 1 frame (and up to 0.36s if a prior fade tween was already running)
	pcall(function()
		RunService.RenderStepped:Wait()
	end)
	if mf then
		local waitHideUntil = os.clock() + 0.36
		while mf.Visible and STATE.Alive and os.clock() < waitHideUntil do
			task.wait(0.02)
		end
	end
	if not STATE.MenuAutoHiddenNotified then
		STATE.MenuAutoHiddenNotified = true
		pcall(function()
			Library:Notify({
				Title = "Menu Auto-Hidden",
				Description = "BeverlyHub hid to avoid blocking Auto Play clicks. Press RightShift to reopen.",
				Time = 3.5,
			})
		end)
	end
	return true
end

local function sendSafeClick(viewportX, viewportY, fast)
	local ok, vim = pcall(function()
		return game:GetService("VirtualInputManager")
	end)
	if not ok or not vim then
		return false
	end
	local waitMin = fast and 0.012 or 0.030
	local waitSpan = fast and 0.010 or 0.040
	local okMove = pcall(function()
		vim:SendMouseMoveEvent(viewportX, viewportY, game)
	end)
	if not okMove then
		return false
	end
	task.wait(waitMin + math.random() * waitSpan)
	local okDown = pcall(function()
		vim:SendMouseButtonEvent(viewportX, viewportY, 0, true, game, 1)
	end)
	if not okDown then
		return false
	end
	task.wait(waitMin + math.random() * waitSpan)
	local okUp = pcall(function()
		vim:SendMouseButtonEvent(viewportX, viewportY, 0, false, game, 1)
	end)
	return okUp == true
end

local function randTriangular(lo, hi)
	if hi <= lo then
		return lo
	end
	local u = (math.random() + math.random()) * 0.5
	return lo + u * (hi - lo)
end

local function computeSmartAutoDelay(session, res)
	local kind = session.kind
	local isFarmThrow = (CONFIG.AutoFarm and STATE.Farm.throwArmed == true and (STATE.Farm.phase == "blunder" or STATE.Farm.phase == "weak"))
	local turbo = (not isFarmThrow) and CONFIG.AntiEngineTurbo and STATE.Opp.turboActive and kind == "online"
	local suspect = (not isFarmThrow) and CONFIG.AntiEngineTurbo and STATE.Opp.suspect and kind == "online"
	local lo = math.min(CONFIG.AutoDelayMin or 1.0, CONFIG.AutoDelayMax or 5.0)
	local hi = math.max(CONFIG.AutoDelayMin or 1.0, CONFIG.AutoDelayMax or 5.0)
	local msLeft = (kind == "online" and session.myColor) and getLiveClockMs(session, session.myColor) or nil
	local oppMsLeft = (kind == "online" and session.myColor) and getLiveClockMs(session, -session.myColor) or nil
	local baseMs = (kind == "online") and STATE.Opp.baseMs or nil
	local isBullet = (baseMs ~= nil and baseMs <= 120000)

	if isFarmThrow then
		local tcScale = baseMs and math.clamp(baseMs / 180000, 0.30, 1.0) or 1.0
		local fLo = math.max(0.45, lo * tcScale * 0.85)
		local fHi = math.max(fLo + 0.35, math.min(hi * tcScale, 4.2))
		local t = randTriangular(fLo, fHi)
		if msLeft and msLeft < 15000 then
			t = math.min(t, 0.45)
		elseif msLeft and msLeft < 30000 then
			t = math.min(t, 1.10)
		end
		return t, (STATE.Farm.phase == "weak") and "Farm Weak" or "Farm Blunder"
	end

	if turbo then
		local fastHi = (msLeft and msLeft < 12000) and 0.22 or 0.32
		return randTriangular(0.08, fastHi), (msLeft and msLeft < 12000) and "Turbo Scramble" or "Turbo"
	end
	if msLeft and msLeft < 12000 then
		return randTriangular(0.08, 0.22), "Scramble"
	end
	if kind == "puzzle" or kind == "rush" then
		-- Respect user AutoDelayMin/Max in Puzzle/Rush (no artificial 0.25-0.90s speed clamp)
		return randTriangular(lo, hi), "Puzzle"
	end

	-- Scale middlegame AutoDelayMin/Max smoothly by time control (1+0 -> 0.33x, 2+1 -> 0.67x, 3+0+ -> 1.0x)
	local tcScale = baseMs and math.clamp(baseMs / 180000, 0.30, 1.0) or 1.0
	local effLo = (kind == "online") and math.max(0.18, lo * tcScale) or lo
	local effHi = (kind == "online") and math.max(effLo + 0.08, hi * tcScale) or hi

	local target = randTriangular(effLo, effHi)
	local phaseTag = "Normal"
	local isForcedMate = (res.mate ~= nil and math.abs(res.mate) <= 2)
	local onlyOneLegal = false
	local isRecapture = false
	local isOpening = false

	if CONFIG.SmartDelay and session.engine then
		local ply = getSessionPly(session)
		local fullMove = math.floor(ply / 2) + 1
		local fen = session.engine:getFen()
		local totalPieces = countFenPieces(fen)

		-- Detect forced single legal move (quick check)
		pcall(function()
			local b = PureChess.new(fen)
			local legal = b:legalMoves()
			if #legal == 1 then
				onlyOneLegal = true
			end
		end)

		-- Detect immediate recapture on opponent's last destination square
		local lastOppUci = (ply >= 1 and type(session.ucis) == "table") and session.ucis[ply] or nil
		isRecapture = (type(lastOppUci) == "string" and #lastOppUci >= 4 and type(res.best) == "string" and #res.best >= 4)
			and (string.sub(lastOppUci, 3, 4) == string.sub(res.best, 3, 4))
		isOpening = (CONFIG.FastOpeningMoves > 0 and fullMove <= CONFIG.FastOpeningMoves)

		if isForcedMate or onlyOneLegal then
			-- Instant forced mate or only legal move
			target = randTriangular(math.min(effLo, 0.18), math.min(effHi, 0.55))
			phaseTag = onlyOneLegal and "Forced" or "Mate Snap"
		elseif isOpening then
			-- Opening book / theory phase: fast & natural slight ramp from move 1 to N
			local progress = (fullMove - 1) / math.max(1, CONFIG.FastOpeningMoves)
			local openLo = math.min(effLo, (0.22 + progress * 0.12) * math.max(0.65, tcScale))
			local openHi = math.min(effHi, (0.62 + progress * 0.32) * math.max(0.65, tcScale))
			target = randTriangular(openLo, math.max(openLo + 0.05, openHi))
			phaseTag = "Opening #" .. tostring(fullMove)
		elseif totalPieces <= (CONFIG.EndgamePieces or 10) then
			-- Simplified endgame speedup
			if totalPieces <= 6 then
				target = randTriangular(math.min(effLo, 0.16), math.min(effHi, 0.48))
			else
				target = randTriangular(math.min(effLo, 0.22), math.min(effHi, 0.78))
			end
			phaseTag = "Endgame · " .. tostring(totalPieces) .. " pcs"
		elseif isRecapture then
			-- Natural quick recapture in middlegame
			target = math.max(0.28, randTriangular(effLo, effHi) * 0.48)
			phaseTag = "Recapture"
		else
			-- Complexity-aware Middlegame: correlate think time with tactical sharpness (pvGapCp & evalSwing)
			local mid = 0.65 * randTriangular(effLo, effHi) + 0.35 * (effLo + math.random() * math.max(0.04, effHi - effLo))
			local pvGap = res.pvGapCp
			local evalSwing = res.evalSwing or 0
			local isQuietSharp = (not suspect) and (not res.isCapture) and ((pvGap ~= nil and pvGap >= 55 and pvGap <= 280) or evalSwing >= 140)
			local isCalm = (pvGap ~= nil and pvGap <= 18 and evalSwing < 55)

			if isQuietSharp then
				target = math.min(effHi + 2.6 * tcScale, mid * randTriangular(1.25, 1.65))
				phaseTag = "Deep Think"
			elseif isCalm then
				target = math.max(effLo * 0.72, mid * randTriangular(0.68, 0.92))
				phaseTag = "Calm Mid"
			else
				target = mid
				phaseTag = "Middlegame"
			end
		end
	end

	-- Early Suspect tier: disable Deep Think (above) and cap total delay <= 0.90s!
	if suspect then
		if target > 0.90 then
			target = randTriangular(0.35, 0.90)
			phaseTag = "Suspect Pace"
		end
	end

	-- Monotonic online clock safety cap (zero 60s inversion jump)
	local safetyCap = 12.0
	if msLeft then
		local secLeft = msLeft / 1000
		if secLeft < 12 then
			safetyCap = 0.24
		elseif secLeft < 15 then
			safetyCap = 0.32
		elseif secLeft < 30 then
			safetyCap = math.clamp(secLeft * 0.028, 0.32, 0.85)
		elseif secLeft < 120 then
			safetyCap = math.max(0.85, secLeft * 0.04)
		end
		target = math.min(target, safetyCap)
	end

	-- Max Clock Lead Cap (anti-sus pacing: keeps remaining clock at most ~N sec ahead of opponent)
	-- Excluded on Bullet, openings, forced moves, recaptures, forced mates, Suspect, Engine, and Turbo!
	local leadCap = CONFIG.MaxClockLead or 30
	if leadCap > 0
		and msLeft
		and oppMsLeft
		and not isBullet
		and not onlyOneLegal
		and not isRecapture
		and not isOpening
		and not isForcedMate
		and not suspect
		and not (STATE.Opp.engineDetected and not STATE.Opp.spectatorPaused)
	then
		local mySec = msLeft / 1000
		local oppSec = oppMsLeft / 1000
		local leadSec = mySec - oppSec

		if leadSec > 0 and mySec >= 42 then
			local safeBleedBudget = math.max(0, mySec - 35)
			local maxThink = math.min(12.0, safeBleedBudget, safetyCap * 2.5)
			local cushionStart = math.max(1, leadCap - 7)
			if leadSec > leadCap then
				local excess = leadSec - leadCap
				local bleed = excess * randTriangular(0.55, 0.90) + randTriangular(0.4, 1.8)
				target = math.min(maxThink, math.max(target + bleed * 0.55, bleed))
				phaseTag = string.format("Lead Cap (+%ds)", math.floor(leadSec + 0.5))
			elseif leadSec >= cushionStart and mySec >= 55 then
				local span = math.max(1, leadCap - cushionStart)
				local closeness = math.clamp((leadSec - cushionStart) / span, 0, 1)
				local cushion = closeness * randTriangular(0.5, 1.9)
				target = math.min(maxThink, target + cushion)
			end
		end
	end

	return target, phaseTag
end

performSafeAutoMove = function(session, res, expectedKey)
	if STATE.AutoPending or not CONFIG.AutoPlay or not STATE.Alive then
		return
	end
	if STATE.Farm.resignPending or STATE.Farm.phase == "resigning" then
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

	STATE.AutoGen += 1
	local myAutoGen = STATE.AutoGen
	STATE.AutoPending = true
	STATE.AutoPendingAt = os.clock()
	STATE.LastAutoKey = expectedKey

	task.spawn(function()
		local function isStaleAuto()
			return (not STATE.Alive) or (not CONFIG.AutoPlay) or (STATE.AutoGen ~= myAutoGen) or (STATE.LastKey ~= expectedKey)
		end

		local turbo = CONFIG.AntiEngineTurbo and STATE.Opp.turboActive and kind == "online"
		local liveMsInit = (kind == "online" and session.myColor) and getLiveClockMs(session, session.myColor) or nil
		local isFastInit = turbo or (liveMsInit ~= nil and liveMsInit < 12000)
		local targetTotal, phaseTag = computeSmartAutoDelay(session, res)
		local spent = (res.ms or 0) / 1000
		local clickOverhead = isFastInit and 0.095 or 0.24
		local minAfterArrow = isFastInit and 0.03 or 0.10
		local waitSec = math.max(minAfterArrow, targetTotal - spent - clickOverhead)

		-- On move 1 (ply <= 1: both White & Black) or immediately after Watchdog #0 page switch,
		-- ensure game-start board transition/flip has settled before clicking!
		local plyNow = getSessionPly(session)
		local nowT = os.clock()
		if plyNow <= 1 and STATE.SessionStartedAt > 0 then
			local anchor = math.max(STATE.SessionStartedAt, STATE.LastPageSwitchAt or 0)
			local settleNeed = 0.40 - (nowT - anchor)
			if settleNeed > waitSec then
				waitSec = settleNeed
			end
		elseif (STATE.LastPageSwitchAt or 0) > 0 then
			local pageSettle = 0.40 - (nowT - STATE.LastPageSwitchAt)
			if pageSettle > waitSec then
				waitSec = pageSettle
			end
		end

		STATE.AutoExpectedWait = waitSec
		if Window and type(Window.SetScriptStatus) == "function" then
			pcall(Window.SetScriptStatus, Window, "Auto · " .. phaseTag, string.format("%s · %.2fs", res.san or res.best, waitSec))
		end

		local endAt = os.clock() + waitSec
		while os.clock() < endAt do
			if isStaleAuto() then
				if STATE.AutoGen == myAutoGen then
					STATE.AutoPending = false
				end
				return
			end
			-- If Turbo activates mid-wait, cut remaining wait immediately!
			if CONFIG.AntiEngineTurbo and STATE.Opp.turboActive and kind == "online" and (endAt - os.clock()) > 0.14 then
				endAt = os.clock() + 0.06
			end
			task.wait(0.03)
		end

		-- Refresh turbo & fastClick state AFTER wait loop so mid-wait Turbo gets fast clicks immediately!
		turbo = CONFIG.AntiEngineTurbo and STATE.Opp.turboActive and kind == "online"
		local liveMsAfter = (kind == "online" and session.myColor) and getLiveClockMs(session, session.myColor) or nil
		local fastClick = turbo or (liveMsAfter ~= nil and liveMsAfter < 12000)

		-- Verified click loop (up to 3 attempts; clears LastAutoKey with backoff if clicks did not register!)
		local targetPly = getSessionPly(session)
		local moveRegistered = false
		local attempt = 0
		while attempt < 3 do
			local curApp = STATE.App
			if isStaleAuto() or not curApp or curApp.session ~= session or session.over or not session:isMyTurn() then
				moveRegistered = true
				break
			end
			if getSessionPly(session) ~= targetPly then
				moveRegistered = true
				break
			end

			-- Pause cleanly if unfocused / typing / holding mouse button (protects Layer-5 bl=0!)
			local safeIn, pauseWhy = isSafeToSendInput()
			if not safeIn then
				STATE.AutoPendingAt = os.clock()
				if Window and type(Window.SetScriptStatus) == "function" then
					pcall(Window.SetScriptStatus, Window, "Auto · Paused", pauseWhy or "Waiting")
				end
				task.wait(0.08)
				continue
			end

			-- Re-check fullPage() inside retry loop before clicking!
			if type(curApp.fullPage) == "function" then
				local okFull, isFull = pcall(curApp.fullPage)
				if okFull and isFull then
					STATE.AutoPendingAt = os.clock()
					task.wait(0.14)
					continue
				end
			end

			local curBoard = curApp.board
			local f = curBoard and curBoard.frame
			if not f or not f.Visible or not curBoard.interactive or f.AbsoluteSize.X < 80 then
				task.wait(0.14)
				continue
			end

			attempt += 1
			if attempt > 1 and type(curBoard.deselect) == "function" then
				pcall(function() curBoard:deselect() end)
				task.wait(0.04)
			end

			local inset = GuiService:GetGuiInset()
			local sqPx = f.AbsoluteSize.X / 8
			local jitter = sqPx * 0.11
			local pFrom = f.AbsolutePosition + inset + sqCenterLocal(res.fromSq, curBoard.flipped, sqPx)
			local pTo = f.AbsolutePosition + inset + sqCenterLocal(res.toSq, curBoard.flipped, sqPx)

			-- Never click BeverlyHub's own MainFrame: auto-hide cleanly and re-sample coordinates
			if ensureBoardUnoccluded(pFrom, pTo, inset) then
				if isStaleAuto() or curApp.session ~= session or getSessionPly(session) ~= targetPly then
					moveRegistered = true
					break
				end
				inset = GuiService:GetGuiInset()
				sqPx = f.AbsoluteSize.X / 8
				jitter = sqPx * 0.11
				pFrom = f.AbsolutePosition + inset + sqCenterLocal(res.fromSq, curBoard.flipped, sqPx)
			end

			-- If user dragged the Tactical HUD directly over pFrom/pTo, hide it for the click instant
			if (isPointOverBadge(pFrom, inset) or isPointOverBadge(pTo, inset)) and HUD.root then
				HUD.tempHiddenForClick = true
				HUD.root.Visible = false
				pcall(function() RunService.RenderStepped:Wait() end)
			end

			local okFrom = sendSafeClick(
				pFrom.X + (math.random() * 2 - 1) * jitter,
				pFrom.Y + (math.random() * 2 - 1) * jitter,
				fastClick
			)
			if not okFrom then
				HUD.tempHiddenForClick = false
				task.wait(0.08)
				continue
			end

			-- Refresh fastClick again & brief human piece-hold pause in non-Turbo middlegame
			turbo = CONFIG.AntiEngineTurbo and STATE.Opp.turboActive and kind == "online"
			local msCheck = (kind == "online" and session.myColor) and getLiveClockMs(session, session.myColor) or 60000
			fastClick = turbo or (msCheck ~= nil and msCheck < 12000)

			local clickPause = fastClick
				and (0.022 + math.random() * 0.020)
				or (0.075 + math.random() * 0.065)
			if not fastClick and not STATE.Opp.suspect and plyNow >= 8 and attempt == 1 and math.random() < 0.22 then
				if msCheck and msCheck > 30000 then
					clickPause += 0.16 + math.random() * 0.34
				end
			end
			task.wait(clickPause)

			if isStaleAuto() or curApp.session ~= session or session.over or getSessionPly(session) ~= targetPly or not session:isMyTurn() then
				HUD.tempHiddenForClick = false
				moveRegistered = true
				break
			end
			if not isSafeToSendInput() then
				HUD.tempHiddenForClick = false
				if type(curBoard.deselect) == "function" then
					pcall(function() curBoard:deselect() end)
				end
				attempt = math.max(0, attempt - 1)
				continue
			end
			if type(curApp.fullPage) == "function" then
				local okFull2, isFull2 = pcall(curApp.fullPage)
				if okFull2 and isFull2 then
					HUD.tempHiddenForClick = false
					if type(curBoard.deselect) == "function" then
						pcall(function() curBoard:deselect() end)
					end
					continue
				end
			end

			-- Recompute fresh pTo + inset after clickPause (guards against resize/reposition)
			local f2 = curApp.board and curApp.board.frame
			if not f2 or not f2.Visible or f2.AbsoluteSize.X < 80 then
				HUD.tempHiddenForClick = false
				continue
			end
			local inset2 = GuiService:GetGuiInset()
			local sqPx2 = f2.AbsoluteSize.X / 8
			local jitter2 = sqPx2 * 0.11
			pTo = f2.AbsolutePosition + inset2 + sqCenterLocal(res.toSq, curApp.board.flipped, sqPx2)
			ensureBoardUnoccluded(pTo, pTo, inset2)
			if not HUD.tempHiddenForClick and isPointOverBadge(pTo, inset2) and HUD.root then
				HUD.tempHiddenForClick = true
				HUD.root.Visible = false
				pcall(function() RunService.RenderStepped:Wait() end)
			end

			local okTo = sendSafeClick(
				pTo.X + (math.random() * 2 - 1) * jitter2,
				pTo.Y + (math.random() * 2 - 1) * jitter2,
				fastClick
			)
			HUD.tempHiddenForClick = false
			if not okTo then
				task.wait(0.08)
				continue
			end
			STATE.LastAutoClickAt = os.clock()

			-- Handle manual promotion popup if it opens (poll up to 0.40s with bounded jitter)
			if res.promo and res.promo ~= 0 and curBoard.overlayLayer then
				local promoDeadline = os.clock() + 0.40
				local promoBtn = nil
				while os.clock() < promoDeadline and STATE.Alive and STATE.AutoGen == myAutoGen do
					if curApp.session ~= session or session.over or getSessionPly(session) ~= targetPly then
						break
					end
					local col = curBoard.overlayLayer:FindFirstChild("PromoColumn")
					if col then
						local found = col:FindFirstChild("Choice" .. tostring(res.promo))
						if found and found:IsA("GuiObject") and found.Visible and found.AbsoluteSize.X > 4 then
							promoBtn = found
							break
						end
					end
					task.wait(0.025)
				end
				if promoBtn and promoBtn.Parent and isSafeToSendInput() then
					local pInset = GuiService:GetGuiInset()
					local pj = math.min(promoBtn.AbsoluteSize.X, promoBtn.AbsoluteSize.Y) * 0.12
					local pc = promoBtn.AbsolutePosition + pInset + promoBtn.AbsoluteSize * 0.5
					ensureBoardUnoccluded(pc, pc, pInset)
					sendSafeClick(
						pc.X + (math.random() * 2 - 1) * pj,
						pc.Y + (math.random() * 2 - 1) * pj,
						fastClick
					)
				end
			end

			-- Verify move registered before finishing
			local verifyUntil = os.clock() + (fastClick and 0.22 or 0.36)
			while os.clock() < verifyUntil do
				if not STATE.Alive or STATE.AutoGen ~= myAutoGen or curApp.session ~= session or session.over or getSessionPly(session) ~= targetPly or not session:isMyTurn() then
					moveRegistered = true
					break
				end
				task.wait(0.03)
			end
			if moveRegistered or getSessionPly(session) ~= targetPly or not session:isMyTurn() or session.over then
				moveRegistered = true
				break
			end
		end

		-- CRITICAL START-OF-GAME RECOVERY: If board/intro ate all 3 clicks, unlock LastAutoKey so watchdog retries!
		if not moveRegistered
			and STATE.Alive
			and STATE.AutoGen == myAutoGen
			and STATE.App
			and STATE.App.session == session
			and not session.over
			and session:isMyTurn()
			and getSessionPly(session) == targetPly
		then
			STATE.LastAutoKey = ""
			STATE.AutoRetryAfter = os.clock() + 0.55
		end
		if STATE.AutoGen == myAutoGen then
			HUD.tempHiddenForClick = false
			STATE.AutoPending = false
		end
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

local function resolveMoveAccentColor(sess, res)
	if res and res.mate and res.mate ~= 0 then
		return BADGE_COLORS.mate
	end
	if not CONFIG.DynamicModeColors then
		return CONFIG.ArrowColor or THEME.Accent
	end
	if res and res.source == "FarmBlunder" then
		return BADGE_COLORS.farm
	end
	if CONFIG.AutoFarm and STATE.Farm.throwArmed and STATE.Farm.phase ~= "opening" and STATE.Farm.phase ~= "idle" then
		return BADGE_COLORS.farm
	end
	if CONFIG.AntiEngineTurbo and sess and sess.kind == "online" then
		if STATE.Opp.turboActive then
			return BADGE_COLORS.turbo
		elseif STATE.Opp.suspect then
			return BADGE_COLORS.suspect
		end
	end
	local k = res and res.engineKind
	if k and BADGE_COLORS[k] then
		return BADGE_COLORS[k]
	end
	return CONFIG.ArrowColor or THEME.Accent
end

local function renderOverlay()
	local app = STATE.App
	local board = app and app.board
	local sess = app and app.session
	local show = CONFIG.Enabled and isBoardRenderable() and board and board.frame and board.frame.AbsoluteSize.X > 40

	-- Expressive Coach HUD visibility + idle breathing / blink animation
	if HUD.root then
		local showHud = CONFIG.Enabled and CONFIG.ShowEngineBadge and (not HUD.tempHiddenForClick)
			and (show or (CONFIG.AutoFarm and app ~= nil and app.profile ~= nil))
		HUD.root.Visible = showHud
		if showHud then
			HUD.tickAnim(os.clock())
		end
	end

	if not show then
		boardProxy.Visible = false
		if EVALBAR.frame then EVALBAR.frame.Visible = false end
		if EVALBAR.tooltip then EVALBAR.tooltip.Visible = false end
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

	-- Broadcast Eval & Win-Chance Bar (hide if game's native evalBar is already shown)
	local nativeEvalOn = app.evalBar and app.evalBar.Visible
	if CONFIG.ShowEvalBar and not nativeEvalOn and EVALBAR.frame then
		local barW = (pos.X >= 38) and 28 or 24
		local barX = math.max(4, pos.X - barW - 6)
		EVALBAR.frame.Visible = true
		EVALBAR.frame.Size = UDim2.fromOffset(barW, sz.Y)
		EVALBAR.frame.Position = UDim2.fromOffset(barX, pos.Y)

		-- Clamp score/win% inside visible screen bounds so tall/bottom-clipped boards stay 100% readable
		local cam = workspace.CurrentCamera
		local vp = cam and cam.ViewportSize or Vector2.new(1280, 720)
		local inset = GuiService:GetGuiInset()
		local visTop = math.max(0, -pos.Y)
		local visBot = math.min(sz.Y, vp.Y - inset.Y - pos.Y)
		if math.abs(visTop - EVALBAR.lastVisTop) >= 2 or math.abs(visBot - EVALBAR.lastVisBot) >= 2 then
			EVALBAR.lastVisTop = visTop
			EVALBAR.lastVisBot = visBot
			positionEvalBarLabels(EVALBAR.lastAtBottom, visTop, visBot)
		end

		if EVALBAR.tooltip then
			local tipY = math.clamp(pos.Y + math.floor((visTop + visBot) * 0.5) - 21, 8, math.max(8, vp.Y - inset.Y - 50))
			EVALBAR.tooltip.Position = UDim2.fromOffset(barX + barW + 8, tipY)
			EVALBAR.tooltip.Visible = EVALBAR.hovered
		end
		if STATE.LastEvalFlip ~= flipped then
			STATE.LastEvalFlip = flipped
			local evCp = (STATE.CurrentResult and STATE.CurrentResult.evalCp) or STATE.EvalWhiteCp or 0
			local evMate = (STATE.CurrentResult and STATE.CurrentResult.mate) or STATE.EvalMate
			updateEvalBarVisual(evCp, evMate, flipped)
		end
	else
		if EVALBAR.frame then EVALBAR.frame.Visible = false end
		if EVALBAR.tooltip then EVALBAR.tooltip.Visible = false end
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

	-- Dynamic per-engine/mode highlight & arrow color (or custom ArrowColor when Dynamic Mode Colors is off)
	local accentColor = resolveMoveAccentColor(sess, res)
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
		clearArrows()
		STATE.LastArrowSig = arrowSig
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

local function computeLiveFyi(sess, res, thinking)
	local now = os.clock()
	local f = STATE.Farm
	local o = STATE.Opp

	-- 1. Idle / Lobby / Breather
	if not sess or sess.kind == "idle" or not sess.engine then
		if CONFIG.AutoFarm then
			if f.breakUntil > now then
				return "sleepy", string.format("Ngopi dulu %.0fd biar kelihatan istirahat natural sebelum cari match baru.", f.breakUntil - now), BADGE_COLORS.fallback
			elseif not STATE.WindowFocused then
				return "sleepy", "Window lagi gak fokus — Auto-Farm aku pause bentar biar aman.", BADGE_COLORS.fallback
			else
				local b = Farm.getBucket and Farm.getBucket(f.activeClass)
				if b then
					return "calm", string.format("Lagi antre match otomatis · siklus +%d/%d Elo (Net %+d).", b.eloGainedSinceLoss, b.nextLossTargetElo, b.netElo), BADGE_COLORS.farm
				end
			end
		end
		return "sleepy", "Siap nemenin main! Kartu ini bisa di-drag bebas (double-click reset).", BADGE_COLORS.idle
	end

	if sess.over then
		if CONFIG.AutoFarm and f.breakUntil > now then
			return "sleepy", string.format("Match beres! Rehat %.0fd dulu sebelum lanjut antre.", f.breakUntil - now), BADGE_COLORS.fallback
		end
		return "calm", "Match kelar! Cek papan atau langsung gas ronde berikutnya.", BADGE_COLORS.idle
	end

	local myColor = sess.myColor or (sess.engine.side or 1)
	local evalCp = (res and res.evalCp) or STATE.EvalWhiteCp or 0
	local mateVal = (res and res.mate) or STATE.EvalMate
	local myEval = evalCp * myColor
	local myMate = mateVal and (mateVal * myColor) or nil
	local ply = getSessionPly(sess)
	local fullMove = math.floor(ply / 2) + 1
	local fen = nil
	pcall(function() fen = sess.engine:getFen() end)
	local totalPieces = fen and countFenPieces(fen) or 32
	local halfmove = 0
	if type(fen) == "string" then
		local parts = string.split(fen, " ")
		halfmove = tonumber(parts[5]) or 0
	end

	-- 2. Forced Checkmate Alerts
	if myMate and myMate > 0 then
		if myMate == 1 then
			return "hyped", "Skakmat satu langkah — tutup papan, pulang!", BADGE_COLORS.mate
		elseif myMate <= 4 then
			return "hyped", string.format("Skakmat otw dalam %d langkah! Jangan sampai kepeleset.", myMate), BADGE_COLORS.mate
		else
			return "hyped", string.format("Ada jalur skakmat paksa nih (M%d), tinggal kawal bersih.", myMate), BADGE_COLORS.mate
		end
	elseif myMate and myMate < 0 then
		return "panic", string.format("Woi bahaya! Lawan punya skakmat M%d — rapetin pertahanan!", math.abs(myMate)), BADGE_COLORS.turbo
	end

	-- 3. Auto-Farm Controlled-Loss & Guard Callouts
	if CONFIG.AutoFarm and sess.kind == "online" then
		if f.phase == "resigning" or f.resignPending then
			return "mischief", "Pura-pura mikir bentar terus resign rapi — anti-rungkat aman.", BADGE_COLORS.farm
		elseif f.throwArmed and (f.phase == "blunder" or f.phase == "weak") then
			return "mischief", string.format("Akting blunder natural (%d/%d) biar win streak nggak dicurigai.", f.blunderMovesPlayed, f.maxBlunderMoves), BADGE_COLORS.farm
		elseif f.throwArmed and f.phase == "opening" then
			return "mischief", string.format("Opening normal dulu, jadwal kalah aman mulai di langkah #%d.", f.throwStartMove), BADGE_COLORS.farm
		elseif type(f.deferReason) == "string" and string.find(f.deferReason, "Deferred", 1, true) then
			return "smug", "Tahan dulu throw-nya — " .. f.deferReason .. ".", BADGE_COLORS.vpssf
		end
	end

	-- 4. Spectator Turbo Pause & Anti-Engine Turbo / Suspect Alerts
	if CONFIG.AntiEngineTurbo and sess.kind == "online" then
		if o.spectatorPaused and (o.spectators or 0) > 0 then
			return "mischief", string.format("Ada %d penonton — Turbo dipause dulu sampai sepi.", o.spectators), BADGE_COLORS.fallback
		elseif o.engineDetected and o.turboActive then
			return "cool", string.format("Lawan bau engine (%d%%) — kacamata item, Full SF19!", o.suspicion), BADGE_COLORS.turbo
		elseif o.turboActive then
			return "cool", "Jam mulai mepet — mode Turbo ngebut otomatis.", BADGE_COLORS.turbo
		elseif o.suspect then
			return "thinking", string.format("Lawan main tajam banget (%d%%), tempo dinaikin.", o.suspicion), BADGE_COLORS.suspect
		end
	end

	-- 4b. Puzzle Finished / Auto Next Puzzle
	if sess.kind == "puzzle" and sess.pz and sess.pz.done then
		if CONFIG.AutoNextPuzzle then
			return "hyped", "Puzzle beres! Otomatis lanjut ke puzzle berikutnya...", BADGE_COLORS.puzzle
		end
		return "hyped", "Mantap, puzzle selesai! Klik Next buat lanjut.", BADGE_COLORS.puzzle
	end

	-- 5. Tactical Highlights (Blunder, Ponder Hit, Promo, Sharp Only-Move, Auto-Adapt)
	if res then
		if res.evalSwing and res.evalSwing >= 200 and myEval >= 150 then
			return "smug", string.format("Lawan blunder! Hukum pakai %s (+%.1f).", res.san or res.best, myEval / 100), BADGE_COLORS.gm
		end
		if res.prefetched and (res.ms or 0) <= 5 then
			return "smug", "Ponder Hit 0ms! Balasan lawan udah ketebak.", BADGE_COLORS.vpssf
		end
		if res.promoChar then
			return "hyped", string.format("Pion nyampe ujung — langsung promosi =%s!", res.promoChar), BADGE_COLORS.mate
		end
		if res.pvGapCp and res.pvGapCp >= 110 and not res.isCapture then
			return "thinking", string.format("Posisi tajam! Cuma %s yang kuat (+%.1f).", res.san or res.best, res.pvGapCp / 100), BADGE_COLORS.mate
		end
		if res.isAdapted and res.effStyle then
			return "cool", string.format("Lawan alot — engine otomatis naik ke %s.", res.effStyle), BADGE_COLORS.vpssf
		end
	end

	-- 6. Draw / 50-Move / Tight Endgame Warnings
	if halfmove >= 60 then
		return "draw", string.format("Awas aturan 50 langkah (%d/100) — bisa remis.", halfmove), BADGE_COLORS.fallback
	elseif totalPieces <= 4 and math.abs(myEval) <= 35 then
		return "draw", "Bidak sisa dikit dan seri — bau-bau draw kuat.", BADGE_COLORS.fallback
	elseif totalPieces <= 10 and math.abs(myEval) <= 25 then
		return "draw", string.format("Endgame ketat (%d bidak) — adu tempo & presisi.", totalPieces), BADGE_COLORS.fallback
	elseif ply >= 40 and math.abs(myEval) <= 18 then
		return "draw", "Posisi masih buntu & seimbang, peluang draw tinggi.", BADGE_COLORS.fallback
	end

	-- 7. Clock Drama Alerts (Online)
	if sess.kind == "online" and sess.clocks and sess.myColor then
		local myMs = getLiveClockMs(sess, sess.myColor)
		local oppMs = getLiveClockMs(sess, -sess.myColor)
		if myMs and oppMs then
			local mySec = myMs / 1000
			local oppSec = oppMs / 1000
			if oppSec < 15 and mySec > (oppSec + 8) then
				return "smug", string.format("Jam lawan tinggal %.0fd — terus tekan!", oppSec), BADGE_COLORS.gm
			elseif mySec < 20 then
				return "panic", string.format("Jam mepet (%.0fd)! Gerak cepat biar aman.", mySec), BADGE_COLORS.turbo
			elseif (CONFIG.MaxClockLead or 30) > 0 and (mySec - oppSec) > (CONFIG.MaxClockLead or 30) and mySec >= 42 then
				return "calm", string.format("Jam unggul +%dd — santaiin dikit biar natural.", math.floor(mySec - oppSec)), BADGE_COLORS.vpssf
			end
		end
	end

	-- 8. Thinking / Waiting / General Position Commentary
	if thinking then
		return "thinking", "Bentaran, lagi ngintip variasi paling tajam...", BADGE_COLORS.thinking
	end
	if sess.myColor ~= nil and not sess:isMyTurn() then
		if sess.kind == "puzzle" or sess.kind == "rush" then
			return "calm", "Langkah bagus! Tunggu balasan puzzle sebentar...", BADGE_COLORS.puzzle
		end
		local prefetching = (STATE.PrefetchDone ~= nil and not STATE.PrefetchDone.done)
		if prefetching then
			return "thinking", "Sambil lawan mikir, aku siapin balasan 0ms.", BADGE_COLORS.vpssf
		end
		return "calm", "Giliran lawan — kita liat dia berani ke mana.", BADGE_COLORS.idle
	end

	if myEval >= 320 and totalPieces <= 12 then
		return "smug", string.format("Menang telak (+%.1f), konversi endgame bersih!", myEval / 100), BADGE_COLORS.gm
	elseif myEval >= 180 then
		return "smug", string.format("Posisi enak (+%.1f) — jaga tekanan terus.", myEval / 100), BADGE_COLORS.gm
	elseif myEval <= -180 then
		return "panic", string.format("Lagi ketekan (%.1f), cari counterplay!", myEval / 100), BADGE_COLORS.fallback
	elseif fullMove <= (CONFIG.FastOpeningMoves or 5) then
		return "calm", string.format("Opening lancar (#%d), hemat waktu buat tengah.", fullMove), BADGE_COLORS.book
	elseif res and res.gmRank and res.gmRank > 1 then
		return "calm", string.format("Ambil opsi #%d (-%dcp) biar main natural.", res.gmRank, res.gmLossCp or 0), BADGE_COLORS.gm
	end

	return "calm", "Posisi aman terkendali — lanjut sesuai rencana.", BADGE_COLORS.stockfish
end

local function updateEngineBadge(text, kind, sess, res, thinking)
	if not HUD.root then
		return
	end
	sess = sess or (STATE.App and STATE.App.session)
	local col = BADGE_COLORS[kind] or BADGE_COLORS.idle
	if res and res.mate and res.mate ~= 0 then
		col = BADGE_COLORS.mate
	end
	HUD.lastKind = kind or "idle"
	HUD.title.Text = text
	HUD.dot.BackgroundColor3 = col

	-- Clean RoChess-native outline (subtle tint only on Mate / Turbo)
	local isMateAlert = (res and res.mate and res.mate ~= 0)
	if isMateAlert then
		HUD.stroke.Color = Color3.fromRGB(168, 134, 58)
	elseif kind == "turbo" then
		HUD.stroke.Color = Color3.fromRGB(164, 62, 62)
	else
		HUD.stroke.Color = Color3.fromRGB(64, 68, 76)
	end

	-- High-contrast Chess.com / Lichess Eval Pill
	local evCp = (res and res.evalCp) or STATE.EvalWhiteCp or 0
	local evMate = (res and res.mate) or STATE.EvalMate
	local hasGame = (sess ~= nil and sess.kind ~= "idle")
	local evTxt = "--"
	if hasGame then
		if evMate and evMate ~= 0 then
			evTxt = (evMate > 0 and "+M" or "-M") .. tostring(math.abs(evMate))
		else
			local pw = evCp / 100
			if math.abs(pw) < 0.05 then
				evTxt = "0.0"
			elseif math.abs(pw) >= 10 then
				evTxt = string.format("%+.0f", pw)
			else
				evTxt = string.format("%+.1f", pw)
			end
		end
	end
	HUD.evalText.Text = evTxt

	local myColor = (sess and sess.myColor) or 1
	local myM = evMate and (evMate * myColor) or nil
	if not hasGame then
		HUD.evalPill.BackgroundColor3 = Color3.fromRGB(50, 52, 57)
		HUD.evalText.TextColor3 = Color3.fromRGB(178, 182, 190)
		if HUD.evalStroke then HUD.evalStroke.Color = Color3.fromRGB(70, 74, 84) end
	elseif myM and myM ~= 0 then
		if myM > 0 then
			HUD.evalPill.BackgroundColor3 = Color3.fromRGB(242, 190, 66)
			HUD.evalText.TextColor3 = Color3.fromRGB(26, 20, 8)
			if HUD.evalStroke then HUD.evalStroke.Color = Color3.fromRGB(242, 190, 66) end
		else
			HUD.evalPill.BackgroundColor3 = Color3.fromRGB(202, 52, 49)
			HUD.evalText.TextColor3 = Color3.fromRGB(255, 255, 255)
			if HUD.evalStroke then HUD.evalStroke.Color = Color3.fromRGB(224, 86, 82) end
		end
	elseif evCp >= 30 then
		-- White advantage: crisp ivory pill + dark ink
		HUD.evalPill.BackgroundColor3 = Color3.fromRGB(240, 239, 234)
		HUD.evalText.TextColor3 = Color3.fromRGB(22, 24, 30)
		if HUD.evalStroke then HUD.evalStroke.Color = Color3.fromRGB(210, 208, 200) end
	elseif evCp <= -30 then
		-- Black advantage: crisp obsidian pill + bright white ink
		HUD.evalPill.BackgroundColor3 = Color3.fromRGB(23, 24, 27)
		HUD.evalText.TextColor3 = Color3.fromRGB(243, 244, 246)
		if HUD.evalStroke then HUD.evalStroke.Color = Color3.fromRGB(78, 82, 92) end
	else
		HUD.evalPill.BackgroundColor3 = Color3.fromRGB(54, 57, 64)
		HUD.evalText.TextColor3 = Color3.fromRGB(236, 238, 244)
		if HUD.evalStroke then HUD.evalStroke.Color = Color3.fromRGB(78, 82, 92) end
	end

	-- Update Coach Avatar Mood & Speech
	local mood, msg, fyiCol = computeLiveFyi(sess, res, thinking)
	HUD.say(msg, mood, fyiCol)
end

local function resetOpponentTracker(sess, gameId)
	local o = STATE.Opp
	o.gameRef = sess
	o.gameId = gameId
	o.lastPly = -1
	o.oppTurnStartAt = os.clock()
	o.baseMs = nil
	o.incMs = 0
	o.expectedByPly = {}
	o.checked = 0
	o.hits = 0
	o.streak = 0
	o.maxStreak = 0
	o.fastHits = 0
	o.blunders = 0
	o.blunderPenalty = 0
	o.lastEvalForMe = nil
	o.lastEvalSource = nil
	o.times = {}
	o.suspicion = 0
	o.suspect = false
	o.engineDetected = false
	o.clockPressure = false
	o.turboActive = false
	o.turboReason = nil
	o.spectators = 0
	o.spectatorPaused = false
	o.spectatorNotified = false
	o.notified = false
	o.adaptTier = nil
	o.lastAdaptPly = -1
	STATE.LastMyTurnResult = nil
	cancelPrefetchState()
end

local function recomputeOpponentSuspicion()
	local o = STATE.Opp
	local score = 0
	local rate = (o.checked > 0) and (o.hits / o.checked) or 0

	if o.checked >= 5 then
		score += math.clamp(math.floor((rate - 0.45) * 140), 0, 62)
	elseif o.checked >= 3 then
		-- Early Suspect-tier scoring (cannot trigger confirmed ENGINE until checked >= 5)
		score += math.clamp(math.floor((rate - 0.42) * 115), 0, 48)
	end

	-- Credit best streak (maxStreak) so 4/5 fast hits doesn't fail on mid-sequence permutation
	local effStreak = math.max(o.streak or 0, o.maxStreak or 0)
	if effStreak >= 6 then
		score += 36
	elseif effStreak == 5 then
		score += 26
	elseif effStreak == 4 then
		score += 18
	elseif effStreak == 3 then
		score += 10
	end

	if o.fastHits >= 5 then
		score += 20
	elseif o.fastHits == 4 then
		score += 14
	elseif o.fastHits == 3 then
		score += 8
	end

	-- Robotic cadence & fast-mean signal (requires >= 4 non-trivial timings & >= 65% accuracy)
	if #o.times >= 4 and o.checked >= 3 and rate >= 0.65 then
		local sum = 0
		for _, t in ipairs(o.times) do sum += t end
		local mean = sum / #o.times
		local var = 0
		for _, t in ipairs(o.times) do var += (t - mean) * (t - mean) end
		local std = math.sqrt(var / #o.times)
		if std < 0.38 and mean < 3.4 then
			score += 16
		elseif mean <= 1.25 and std < 0.65 then
			score += 10
		end
	end

	-- Rolling, capped human blunder penalty (decays after consecutive Stockfish hits)
	if (o.blunderPenalty or 0) > 0 then
		score -= math.min(o.blunderPenalty, 56)
	end

	o.suspicion = math.clamp(score, 0, 100)

	-- Confirmed ENGINE hysteresis latch: requires >= 5 non-trivial moves and >= 72%
	if o.checked >= 5 and o.suspicion >= 72 then
		o.engineDetected = true
	elseif o.engineDetected and o.suspicion < 45 then
		o.engineDetected = false
		o.notified = false
	end

	-- Early SUSPECT tier: checked >= 3 with 3/3 fast hits OR suspicion >= 52 (hysteresis release < 35)
	if o.engineDetected or (o.checked >= 3 and ((o.hits == o.checked and o.fastHits >= 3) or o.suspicion >= 52)) then
		o.suspect = true
	elseif o.suspect and o.suspicion < 35 then
		o.suspect = false
	end
end

local function getLiveSpectatorCount(sess)
	if not sess or sess.kind ~= "online" or sess.over then
		return 0
	end
	local n = tonumber(sess.watchers) or 0
	return (n > 0) and math.floor(n) or 0
end

local function formatOpponentLabel(sess)
	if not sess or sess.kind ~= "online" then
		return "Opponent: --"
	end
	local o = STATE.Opp
	local specSuffix = ((o.spectators or 0) > 0) and string.format(" · %d spec", o.spectators) or ""
	if o.spectatorPaused then
		return string.format("Opponent: %s (%d%%) · TURBO PAUSED%s", o.engineDetected and "ENGINE" or "Pressure", o.suspicion, specSuffix)
	elseif o.engineDetected then
		return string.format("Opponent: ENGINE (%d%% · %d/%d) · TURBO%s", o.suspicion, o.hits, o.checked, specSuffix)
	elseif o.turboActive then
		return string.format("Opponent: %s%d%% · TURBO (%s)%s", o.suspect and "SUSPECT " or "", o.suspicion, o.turboReason or "Clock", specSuffix)
	elseif o.suspect then
		return string.format("Opponent: SUSPECT (%d%% · %d/%d match)%s", o.suspicion, o.hits, o.checked, specSuffix)
	elseif o.checked > 0 then
		return string.format("Opponent: Human (%d%% · %d/%d match)%s", o.suspicion, o.hits, o.checked, specSuffix)
	end
	return "Opponent: Scanning..." .. specSuffix
end

local function updateOpponentDetector(sess)
	if not sess or sess.kind ~= "online" or not sess.engine then
		if STATE.Opp.gameId ~= nil or STATE.Opp.gameRef ~= nil then
			resetOpponentTracker(nil, nil)
		end
		return
	end

	local gid = tostring(sess.id or "online")
	local o = STATE.Opp
	-- v2.1.0 Fix #2: track both table ref and id so nil/reused sess.id never leaks prior game state
	if o.gameRef ~= sess or o.gameId ~= gid then
		resetOpponentTracker(sess, gid)
	end

	-- Capture TC baseMs at ply <= 1 (or infer from sess.tc)
	if o.baseMs == nil then
		local bMs, iMs = resolveSessionTimeControl(sess)
		if bMs then
			o.baseMs = bMs
			o.incMs = iMs or 0
		end
	end

	local ply = getSessionPly(sess)
	local now = os.clock()

	if ply ~= o.lastPly then
		local prevPly = o.lastPly
		o.lastPly = ply

		if not sess.over then
			if not sess:isMyTurn() then
				-- We just played our move; start opponent timer & prefetch their expected Stockfish ponder reply!
				o.oppTurnStartAt = now
				local myUci = (type(sess.ucis) == "table") and sess.ucis[ply] or nil
				local lastRes = STATE.LastMyTurnResult
				if lastRes
					and isStockfishSource(lastRes.source)
					and lastRes.best == myUci
					and type(lastRes.ponder) == "string"
					and #lastRes.ponder >= 4
				then
					local oppFen = sess.engine:getFen()
					o.expectedByPly[ply + 1] = {
						uci = lastRes.ponder,
						myUci = myUci,
						myCapture = lastRes.isCapture == true,
						myToSq = string.sub(myUci, 3, 4),
						oppFen = oppFen,
						source = lastRes.source,
					}
					launchPonderPrefetch(oppFen, lastRes.ponder, sess)
				else
					-- Clear any stale pre-seeded entry if user played a different move or source was Luau/Book
					o.expectedByPly[ply + 1] = nil
				end
			else
				-- Opponent just moved (it is our turn again!)
				-- Cancel non-matching speculative prefetch immediately so live solvePosition has zero lock contention
				local curF4 = fen4Key(sess.engine:getFen())
				if STATE.PrefetchFen4 ~= "" and STATE.PrefetchFen4 ~= curF4 then
					cancelPrefetchState()
				end

				-- Score opponent move on both normal +1 ply transitions AND instant <0.13s premove +2 ply jumps!
				if prevPly >= 0 and (ply == prevPly + 1 or ply == prevPly + 2) then
					local jumpedTwo = (ply == prevPly + 2)
					local oppUci = (type(sess.ucis) == "table") and sess.ucis[ply] or nil
					local exp = o.expectedByPly[ply]
					local validExp = (type(exp) == "table") and isStockfishSource(exp.source)
					if validExp and jumpedTwo then
						local myPlayed = (type(sess.ucis) == "table") and sess.ucis[ply - 1] or nil
						if exp.myUci ~= nil and myPlayed ~= exp.myUci then
							validExp = false
						end
					end

					local dt
					if jumpedTwo then
						if STATE.LastAutoClickAt > 0 and (now - STATE.LastAutoClickAt) <= 1.5 then
							dt = math.clamp(now - STATE.LastAutoClickAt, 0.05, 1.5)
						else
							dt = 0.08
						end
					else
						dt = now - (o.oppTurnStartAt > 0 and o.oppTurnStartAt or now)
					end

					local isTrivial = false
					if validExp then
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

					-- Start detection at ply >= 9 (Move 5+) on non-trivial moves
					if ply >= 9 and not isTrivial and dt >= 0.04 and dt <= 120 then
						table.insert(o.times, dt)
						if #o.times > 20 then
							table.remove(o.times, 1)
						end
					end

					if ply >= 9 and validExp and exp.uci and not isTrivial then
						o.checked += 1
						if oppUci == exp.uci then
							o.hits += 1
							o.streak += 1
							if o.streak > o.maxStreak then o.maxStreak = o.streak end
							if dt <= 2.2 then
								o.fastHits += 1
							end
							-- Rolling decay of blunder penalty on verified top-move hits
							if (o.blunderPenalty or 0) > 0 then
								o.blunderPenalty = math.max(0, o.blunderPenalty - 10)
							end
						else
							o.streak = 0
						end
					end

					recomputeOpponentSuspicion()
				end
			end
		end
	end

	-- TC-relative clockPressure WITH release hysteresis (prevents +1/+2s increment sawtooth flickering)
	local clockPressure = o.clockPressure == true
	if sess.over then
		clockPressure = false
	elseif sess.clocks and sess.myColor then
		local myMs = getLiveClockMs(sess, sess.myColor)
		local oppMs = getLiveClockMs(sess, -sess.myColor)
		if myMs and oppMs then
			local baseMs = o.baseMs or 180000
			local defTrigger = math.clamp(baseMs * 0.14, 8000, 20000)
			local defRelease = defTrigger * 0.65
			local deficit = oppMs - myMs

			local shouldEngage = (myMs < 14000)
				or (myMs < 26000 and oppMs > (myMs - 4000))
				or (deficit >= defTrigger and myMs < (baseMs * 0.85))

			if shouldEngage then
				clockPressure = true
			elseif clockPressure then
				local canRelease = (myMs >= 18000)
					and not (myMs < 30000 and oppMs > (myMs - 2000))
					and (deficit < defRelease or myMs >= (baseMs * 0.90))
				if canRelease then
					clockPressure = false
				end
			end
		end
	end
	o.clockPressure = clockPressure

	local farmSuppress = (CONFIG.AutoFarm and STATE.Farm.throwArmed == true)
	local spectators = getLiveSpectatorCount(sess)
	local rawWantTurbo = (not farmSuppress) and CONFIG.AntiEngineTurbo and (o.engineDetected or clockPressure)
	local specSuppress = CONFIG.PauseTurboOnSpectate and (spectators > 0)
	local wantTurbo = rawWantTurbo and (not specSuppress)

	o.spectators = spectators
	o.spectatorPaused = specSuppress and rawWantTurbo
	o.turboActive = wantTurbo
	o.turboReason = wantTurbo and (o.engineDetected and "Engine" or (clockPressure and "Clock" or nil)) or nil

	if o.spectatorPaused and not o.spectatorNotified then
		o.spectatorNotified = true
		pcall(function()
			Library:Notify({
				Title = "Turbo Paused (Spectator)",
				Description = string.format("Ada %d penonton — Turbo ditahan otomatis sampai nggak ada yang spectate.", spectators),
				Time = 4.0,
			})
		end)
	elseif spectators == 0 and o.spectatorNotified then
		o.spectatorNotified = false
		if wantTurbo then
			pcall(function()
				Library:Notify({
					Title = "Turbo Resumed",
					Description = "Semua penonton sudah keluar — Turbo Mode aktif kembali.",
					Time = 3.5,
				})
			end)
		end
	end

	if o.engineDetected and not o.notified and CONFIG.AntiEngineTurbo and not farmSuppress then
		o.notified = true
		pcall(function()
			Library:Notify({
				Title = "Engine Opponent Detected",
				Description = o.spectatorPaused
					and string.format("Suspicion %d%% (%d/%d). Turbo ditahan sementara karena ada %d penonton.", o.suspicion, o.hits, o.checked, spectators)
					or string.format("Suspicion %d%% (%d/%d non-trivial top moves). Full SF19 + Turbo engaged.", o.suspicion, o.hits, o.checked),
				Time = 4.5,
			})
		end)
	end

	setUiLabel("OpponentLabel", formatOpponentLabel(sess))
end

-- ============================================================================
-- 7B. AUTO-FARM ELO ENGINE (PERSISTENT ACROSS TELEPORTS + ANTI-RUNGKAT GUARD)
-- ============================================================================
do
	local FARM_DIR_ROOT = "BeverlyHub"
	local FARM_DIR = "BeverlyHub/RoChess"
	local FARM_FILE = "BeverlyHub/RoChess/farm_state.json"

	local function rollJitteredTarget(base)
		local b = math.clamp(math.floor(tonumber(base) or 45), 20, 150)
		return math.max(12, math.floor(b * (0.80 + math.random() * 0.40) + 0.5))
	end

	local function ensureRootData()
		if type(STATE.Farm.data) ~= "table" then
			STATE.Farm.data = { version = 1, resume = {}, buckets = {} }
		end
		if type(STATE.Farm.data.buckets) ~= "table" then
			STATE.Farm.data.buckets = {}
		end
		if type(STATE.Farm.data.resume) ~= "table" then
			STATE.Farm.data.resume = {}
		end
		return STATE.Farm.data
	end

	function Farm.loadState()
		ensureRootData()
		if type(isfile) ~= "function" or type(readfile) ~= "function" then
			return
		end
		local okF, exists = pcall(isfile, FARM_FILE)
		if not okF or not exists then
			return
		end
		local okR, raw = pcall(readfile, FARM_FILE)
		if not okR or type(raw) ~= "string" or #raw < 2 then
			return
		end
		local okD, parsed = pcall(HttpService.JSONDecode, HttpService, raw)
		if okD and type(parsed) == "table" then
			if type(parsed.buckets) ~= "table" then parsed.buckets = {} end
			if type(parsed.resume) ~= "table" then parsed.resume = {} end
			STATE.Farm.data = parsed
		end
	end

	function Farm.saveState(includeResume)
		local root = ensureRootData()
		if includeResume then
			if CONFIG.AutoFarm then
				root.resume = {
					active = true,
					untilTs = os.time() + 120,
					autoPlay = CONFIG.AutoPlay,
					autoFind = CONFIG.AutoFindMatch,
					autoFindTc = CONFIG.AutoFindTc,
					lossMode = CONFIG.FarmLossMode,
					lossAfter = CONFIG.FarmLossAfterElo,
					stopAt = CONFIG.FarmStopAtElo,
					breather = CONFIG.FarmHumanBreather,
					keepPos = CONFIG.FarmKeepPositive,
				}
			else
				root.resume = { active = false }
			end
		end
		if type(writefile) ~= "function" then
			return
		end
		pcall(function()
			if type(makefolder) == "function" then
				if type(isfolder) ~= "function" or not isfolder(FARM_DIR_ROOT) then
					pcall(makefolder, FARM_DIR_ROOT)
				end
				if type(isfolder) ~= "function" or not isfolder(FARM_DIR) then
					pcall(makefolder, FARM_DIR)
				end
			end
			local encoded = HttpService:JSONEncode(root)
			writefile(FARM_FILE, encoded)
		end)
	end

	function Farm.clearResume()
		local root = ensureRootData()
		root.resume = { active = false }
		Farm.saveState(false)
	end

	function Farm.applyTeleportResume()
		local root = ensureRootData()
		local r = root.resume
		if type(r) ~= "table" or not r.active then
			return
		end
		local untilTs = tonumber(r.untilTs) or 0
		root.resume = { active = false }
		Farm.saveState(false)
		if os.time() > untilTs then
			return
		end
		pcall(function()
			if Options.FarmLossMode and type(r.lossMode) == "string" then Options.FarmLossMode:SetValue(r.lossMode) end
			if Options.FarmLossAfterElo and tonumber(r.lossAfter) then Options.FarmLossAfterElo:SetValue(r.lossAfter) end
			if Options.FarmStopAtElo and tonumber(r.stopAt) then Options.FarmStopAtElo:SetValue(r.stopAt) end
			if Toggles.FarmHumanBreather and type(r.breather) == "boolean" then Toggles.FarmHumanBreather:SetValue(r.breather) end
			if Toggles.FarmKeepPositive and type(r.keepPos) == "boolean" then Toggles.FarmKeepPositive:SetValue(r.keepPos) end
			if Options.AutoFindTc and type(r.autoFindTc) == "string" then Options.AutoFindTc:SetValue(r.autoFindTc) end
			if Toggles.AutoPlay and r.autoPlay ~= false then Toggles.AutoPlay:SetValue(true) end
			if Toggles.AutoFindMatch and r.autoFind ~= false then Toggles.AutoFindMatch:SetValue(true) end
			if Toggles.AutoFarm then Toggles.AutoFarm:SetValue(true) end
			syncConfigFromUI()
		end)
	end

	local function classFromTcString(tc)
		if type(tc) ~= "string" then
			return nil
		end
		local mStr, iStr = string.match(tc, "(%d+%.?%d*)%+(%d+%.?%d*)")
		if not mStr then
			return nil
		end
		local estSec = (tonumber(mStr) or 0) * 60 + 40 * (tonumber(iStr) or 0)
		if estSec < 180 then return "bullet" end
		if estSec < 600 then return "blitz" end
		return "rapid"
	end

	function Farm.getSessionClass(app, sess)
		if sess then
			local c = sess.class or sess.tcClass or sess.category
			if type(c) == "string" and (c == "bullet" or c == "blitz" or c == "rapid") then
				return c
			end
			local bMs, iMs = resolveSessionTimeControl(sess)
			if bMs then
				local estSec = (bMs / 1000) + 40 * ((iMs or 0) / 1000)
				if estSec < 180 then return "bullet" end
				if estSec < 600 then return "blitz" end
				return "rapid"
			end
		end
		local chosenTc = (CONFIG.AutoFindTc ~= "Selected") and CONFIG.AutoFindTc or (app and app.selectedTc)
		return classFromTcString(chosenTc) or STATE.Farm.activeClass or "blitz"
	end

	function Farm.getBucket(className)
		local root = ensureRootData()
		local uid = tostring(LocalPlayer and LocalPlayer.UserId or 0)
		local cls = className or STATE.Farm.activeClass or "blitz"
		local key = uid .. ":" .. cls
		local b = root.buckets[key]
		if type(b) ~= "table" then
			b = {
				startRating = nil,
				lastKnownRating = nil,
				eloGainedSinceLoss = 0,
				nextLossTargetElo = rollJitteredTarget(CONFIG.FarmLossAfterElo),
				wins = 0,
				losses = 0,
				draws = 0,
				controlledLosses = 0,
				gamesSinceBreak = 0,
				nextBreakAfter = math.random(5, 8),
				netElo = 0,
				obsK = 24,
				lastGameId = "",
			}
			root.buckets[key] = b
		else
			if not tonumber(b.nextLossTargetElo) or b.nextLossTargetElo < 12 then
				b.nextLossTargetElo = rollJitteredTarget(CONFIG.FarmLossAfterElo)
			end
			if not tonumber(b.nextBreakAfter) or b.nextBreakAfter < 3 then
				b.nextBreakAfter = math.random(5, 8)
			end
			b.eloGainedSinceLoss = tonumber(b.eloGainedSinceLoss) or 0
			b.wins = tonumber(b.wins) or 0
			b.losses = tonumber(b.losses) or 0
			b.draws = tonumber(b.draws) or 0
			b.controlledLosses = tonumber(b.controlledLosses) or 0
			b.gamesSinceBreak = tonumber(b.gamesSinceBreak) or 0
			b.netElo = tonumber(b.netElo) or 0
			b.obsK = tonumber(b.obsK) or 24
			b.lastGameId = tostring(b.lastGameId or "")
		end
		return b
	end

	function Farm.isTournamentMatch(app, sess)
		if app and app.Tournament and type(app.Tournament.isEntrant) == "function" then
			local okT, isInTour = pcall(app.Tournament.isEntrant)
			if okT and isInTour then
				return true
			end
		end
		if sess and (sess.tourId ~= nil or sess.tournament ~= nil or sess.isTournament == true) then
			return true
		end
		return false
	end

	function Farm.isRatedOnline(app, sess)
		if not sess or sess.kind ~= "online" then
			return false
		end
		if Farm.isTournamentMatch(app, sess) then
			return false
		end
		if sess.rated == false or sess.isRated == false or sess.casual == true or sess.friendly == true then
			return false
		end
		return true
	end

	function Farm.getProfileRating(app, className)
		if app and type(app.profile) == "table" and type(app.profile.ratings) == "table" then
			local entry = app.profile.ratings[className]
			if type(entry) == "table" and tonumber(entry.r) then
				return math.floor(tonumber(entry.r) + 0.5), (entry.prov == true)
			end
		end
		return nil, false
	end

	function Farm.getSessionRatings(app, sess, className)
		local myR, oppR, oppUid, prov = nil, nil, nil, false
		if sess and sess.myColor then
			local mySlot = (sess.myColor == 1) and sess.white or sess.black
			local oppSlot = (sess.myColor == 1) and sess.black or sess.white
			if type(mySlot) == "table" then
				myR = tonumber(mySlot.rating)
				if mySlot.prov == true then prov = true end
			end
			if type(oppSlot) == "table" then
				oppR = tonumber(oppSlot.rating)
				oppUid = tonumber(oppSlot.userId or oppSlot.id)
			end
		end
		local profR, profProv = Farm.getProfileRating(app, className)
		if not myR then myR = profR end
		if profProv then prov = true end
		return myR, oppR, oppUid, prov
	end

	function Farm.estimateExpectedLoss(myRating, oppRating, bucket, isProv)
		local eMe = 1 / (1 + (10 ^ ((oppRating - myRating) / 400)))
		local baseK = math.clamp(tonumber(bucket and bucket.obsK) or 24, 16, 48)
		local kCons = isProv and math.max(40, baseK * 1.25) or math.max(24, baseK * 1.15)
		return math.ceil(kCons * eMe) + 2, eMe
	end

	function Farm.onLossTargetChanged()
		local b = Farm.getBucket(STATE.Farm.activeClass)
		local base = CONFIG.FarmLossAfterElo or 45
		local lo = math.max(12, math.floor(base * 0.80))
		local hi = math.max(lo + 2, math.ceil(base * 1.20))
		if b.nextLossTargetElo < lo or b.nextLossTargetElo > hi then
			b.nextLossTargetElo = rollJitteredTarget(base)
			Farm.saveState(false)
		end
	end

	function Farm.disarmThrow(reason)
		local f = STATE.Farm
		local wasArmed = f.throwArmed or f.resignPending or f.phase ~= "idle"
		f.throwArmed = false
		f.phase = "idle"
		f.resignGen += 1
		f.resignPending = false
		f.blunderMovesPlayed = 0
		f.lastBlunderPly = -1
		if reason then
			f.deferReason = reason
		end
		if wasArmed then
			STATE.LastAutoKey = ""
			STATE.AutoRetryAfter = 0
			scheduleRecalc()
		end
		Farm.refreshUi(STATE.App, STATE.App and STATE.App.session)
	end

	function Farm.resetStats()
		local cls = Farm.getSessionClass(STATE.App, STATE.App and STATE.App.session)
		local b = Farm.getBucket(cls)
		local curR = Farm.getProfileRating(STATE.App, cls) or b.lastKnownRating
		b.startRating = curR
		b.lastKnownRating = curR
		b.eloGainedSinceLoss = 0
		b.nextLossTargetElo = rollJitteredTarget(CONFIG.FarmLossAfterElo)
		b.wins = 0
		b.losses = 0
		b.draws = 0
		b.controlledLosses = 0
		b.gamesSinceBreak = 0
		b.nextBreakAfter = math.random(5, 8)
		b.netElo = 0
		b.lastGameId = ""
		STATE.Farm.breakUntil = 0
		STATE.Farm.deferReason = "Stats reset"
		Farm.disarmThrow("Stats reset")
		Farm.saveState(false)
		pcall(function()
			Library:Notify({ Title = "Farm Stats Reset", Description = "Cleared " .. cls .. " Elo cycle & record.", Time = 2.5 })
		end)
	end

	function Farm.shouldUseThrowMove(session)
		if not CONFIG.AutoFarm or not STATE.Farm.throwArmed then
			return false
		end
		if not session or session.kind ~= "online" or session.over or not session:isMyTurn() then
			return false
		end
		return STATE.Farm.phase == "blunder" or STATE.Farm.phase == "weak"
	end

	function Farm.pickThrowMove(fen, session, isCancelled)
		local f = STATE.Farm
		if f.phase == "weak" then
			if math.random() < 0.55 then
				local r = PureChess.pickHumanBlunder(fen, 90, 320, { allowMateIn1 = false })
				if r then
					r.engineLabel = string.format("Farm · Weak (-%dcp)", r.blunderDropCp or 0)
					return enrichMoveInfo(fen, r)
				end
			else
				local r = PureChess.search(fen, 2, 0.08, isCancelled)
				if r then
					r.source = "FarmBlunder"
					r.engineLabel = "Farm · Weak (d2)"
					r.engineKind = "farm"
					return enrichMoveInfo(fen, r)
				end
			end
		end
		local allowM1 = (f.blunderMovesPlayed >= 4)
		local r = PureChess.pickHumanBlunder(fen, 250, 650, { allowMateIn1 = allowM1 })
		return r and enrichMoveInfo(fen, r) or nil
	end

	local function executeCleanResign(app, sess)
		if not STATE.Alive or not CONFIG.AutoFarm or not STATE.Farm.throwArmed then
			return false
		end
		if not app or app.session ~= sess or sess.over then
			return true
		end
		if getSessionPly(sess) < 14 then
			return false
		end
		if not STATE.WindowFocused then
			return false
		end
		if type(app.resign) ~= "function" then
			return false
		end
		local hadSettings = type(app.settings) == "table"
		local prevConfirm = hadSettings and app.settings.confirmResign
		if hadSettings then
			app.settings.confirmResign = false
		end
		local okR = pcall(app.resign)
		if hadSettings then
			app.settings.confirmResign = prevConfirm
		end
		return okR == true
	end

	local function scheduleNaturalResign(app, sess)
		local f = STATE.Farm
		if f.resignPending or not f.throwArmed or sess.over then
			return
		end
		f.phase = "resigning"
		f.resignPending = true
		f.resignGen += 1
		local myGen = f.resignGen

		-- Cancel any in-flight AutoPlay click wait so we resign instead of moving
		STATE.AutoGen += 1
		STATE.AutoPending = false

		task.spawn(function()
			local pauseSec = (CONFIG.FarmLossMode == "LateResign") and randTriangular(3.0, 7.0) or randTriangular(2.5, 6.0)
			setPulseStatus("Farm · Resigning", string.format("Natural pause · %.1fs", pauseSec))
			updateEngineBadge("Farm · Resigning...", "farm")

			local endAt = os.clock() + pauseSec
			while os.clock() < endAt do
				if not STATE.Alive or not CONFIG.AutoFarm or not f.throwArmed or f.resignGen ~= myGen or not app or app.session ~= sess or sess.over then
					if f.resignGen == myGen then
						f.resignPending = false
					end
					return
				end
				task.wait(0.05)
			end

			-- Wait gently if user momentarily alt-tabbed so we don't fire while unfocused
			local focusWaitUntil = os.clock() + 8.0
			while not STATE.WindowFocused and os.clock() < focusWaitUntil do
				if not STATE.Alive or not CONFIG.AutoFarm or not f.throwArmed or f.resignGen ~= myGen or app.session ~= sess or sess.over then
					if f.resignGen == myGen then f.resignPending = false end
					return
				end
				task.wait(0.10)
			end

			for attempt = 1, 2 do
				if not STATE.Alive or not CONFIG.AutoFarm or not f.throwArmed or f.resignGen ~= myGen or app.session ~= sess or sess.over then
					break
				end
				executeCleanResign(app, sess)
				local waitOver = os.clock() + 1.8
				while os.clock() < waitOver and not sess.over and app.session == sess and f.resignGen == myGen do
					task.wait(0.08)
				end
				if sess.over or attempt == 2 then
					break
				end
			end

			if f.resignGen == myGen then
				f.resignPending = false
				if not sess.over and f.throwArmed then
					-- Fallback back to blunder phase if resign didn't land
					f.phase = "blunder"
					scheduleRecalc()
				end
			end
		end)
	end

	function Farm.onSessionStart(app, sess)
		local f = STATE.Farm
		f.gameRef = sess
		f.gameId = tostring(sess.id or "")
		f.gameAccounted = false
		f.settlingGame = false
		f.throwArmed = false
		f.phase = "idle"
		f.blunderMovesPlayed = 0
		f.lastBlunderPly = -1
		f.resignGen += 1
		f.resignPending = false
		f.deferReason = nil

		local cls = Farm.getSessionClass(app, sess)
		f.activeClass = cls
		local b = Farm.getBucket(cls)
		local myR, oppR, oppUid, prov = Farm.getSessionRatings(app, sess, cls)
		f.preMyRating = myR
		f.preOppRating = oppR
		f.preProv = prov
		if myR then
			if not b.startRating then b.startRating = myR end
			b.lastKnownRating = myR
			b.netElo = b.lastKnownRating - b.startRating
			Farm.saveState(false)
		end

		-- Evaluate all 7 Anti-Rungkat Arming Guards once at rated match start (ply <= 1)
		local ply = getSessionPly(sess)
		if ply > 1 then
			return
		end
		if not CONFIG.AutoFarm or not CONFIG.AutoPlay then
			return
		end
		if not Farm.isRatedOnline(app, sess) then
			f.deferReason = Farm.isTournamentMatch(app, sess) and "Tournament (protected)" or "Unrated match"
			return
		end
		if oppUid ~= nil and oppUid <= 0 then
			f.deferReason = "Fallback bot (skipped)"
			return
		end
		if b.eloGainedSinceLoss < b.nextLossTargetElo then
			return
		end

		-- Guard 4: Near Target Elo Cap
		if (CONFIG.FarmStopAtElo or 0) > 0 and myR and myR >= (CONFIG.FarmStopAtElo - 15) then
			f.deferReason = "Near Stop Target Elo (finishing)"
			return
		end

		-- Guard 5: Known & Comparable Opponent
		if not myR or not oppR or myR <= 0 or oppR <= 0 then
			f.deferReason = "Deferred: unknown ratings"
			return
		end
		if oppR < (myR - 120) then
			f.deferReason = string.format("Deferred: Opp -%d Elo (anti-rungkat)", math.floor(myR - oppR))
			return
		end

		-- Guards 6 & 7: Expected Loss Cap & Net Keep Floor (Anti-Rungkat Guarantee!)
		local estLoss = Farm.estimateExpectedLoss(myR, oppR, b, prov)
		if CONFIG.FarmKeepPositive then
			local maxAllowedLoss = math.max(10, math.floor(b.eloGainedSinceLoss * 0.40))
			if estLoss > maxAllowedLoss then
				f.deferReason = string.format("Deferred: Est -%d > 40%% cycle (+%d)", estLoss, b.eloGainedSinceLoss)
				return
			end
			local minKeepFloor = math.max(10, math.floor((CONFIG.FarmLossAfterElo or 45) * 0.25))
			if (b.netElo - estLoss) < minKeepFloor then
				f.deferReason = string.format("Deferred: Net +%d - %d < floor +%d", b.netElo, estLoss, minKeepFloor)
				return
			end
		end

		-- All 7 guards passed -> arm controlled loss naturally!
		f.throwArmed = true
		f.phase = "opening"
		local mode = CONFIG.FarmLossMode or "BlunderResign"
		if mode == "PlayWeak" then
			f.throwStartMove = math.random(4, 7)
			f.maxBlunderMoves = 99
			f.resignMinMove = 20
		elseif mode == "LateResign" then
			f.throwStartMove = math.random(16, 24)
			f.maxBlunderMoves = math.random(1, 2)
			f.resignMinMove = f.throwStartMove + 1
		else -- BlunderResign
			f.throwStartMove = math.random(8, 15)
			f.maxBlunderMoves = math.random(4, 8)
			f.resignMinMove = math.max(14, f.throwStartMove + 2)
		end
		f.deferReason = string.format("Armed (%s @ mv %d · est -%d)", mode, f.throwStartMove, estLoss)
		pcall(function()
			Library:Notify({
				Title = "Controlled Loss Armed",
				Description = string.format("Cycle +%d/%d Elo · %s from move %d (est -%d Elo).", b.eloGainedSinceLoss, b.nextLossTargetElo, mode, f.throwStartMove, estLoss),
				Time = 4.0,
			})
		end)
	end

	function Farm.onSessionOver(app, sess)
		local f = STATE.Farm
		if f.gameAccounted then
			return
		end
		f.gameAccounted = true
		f.resignGen += 1
		f.resignPending = false
		local wasControlled = f.throwArmed == true
		f.throwArmed = false
		f.phase = "idle"

		if not Farm.isRatedOnline(app, sess) then
			Farm.refreshUi(app, sess)
			return
		end

		local ply = getSessionPly(sess)
		local resStr = tostring(sess.result or "")
		local reasonStr = string.lower(tostring(sess.reason or ""))
		if resStr == "*" or ply < 2 or sess.aborted == true or reasonStr == "abort" or reasonStr == "aborted" then
			f.deferReason = "Aborted match (ignored)"
			Farm.refreshUi(app, sess)
			return
		end

		local cls = f.activeClass or Farm.getSessionClass(app, sess)
		local b = Farm.getBucket(cls)
		local curGid = tostring(sess.id or "")
		if curGid ~= "" and b.lastGameId == curGid then
			Farm.refreshUi(app, sess)
			return
		end

		f.settlingGame = true
		local preMyR = f.preMyRating or b.lastKnownRating
		local preOppR = f.preOppRating
		local preProv = f.preProv

		task.spawn(function()
			-- Poll up to 1.8s for server rating update to land on session slot / app.profile before queueing next match
			local postMyR = nil
			local dl = os.clock() + 1.8
			while STATE.Alive and os.clock() < dl do
				local slotR = Farm.getSessionRatings(app, sess, cls)
				local profR = Farm.getProfileRating(app, cls)
				if preMyR and slotR and slotR ~= preMyR then
					postMyR = slotR
					break
				end
				if preMyR and profR and profR ~= preMyR then
					postMyR = profR
					break
				end
				task.wait(0.15)
			end
			if not postMyR then
				local slotR = Farm.getSessionRatings(app, sess, cls)
				postMyR = slotR or Farm.getProfileRating(app, cls) or preMyR
			end

			local myWin = (sess.myColor == 1 and resStr == "1-0") or (sess.myColor == -1 and resStr == "0-1")
			local myLoss = (sess.myColor == 1 and resStr == "0-1") or (sess.myColor == -1 and resStr == "1-0")
			local myDraw = (resStr == "1/2-1/2")
			local delta = (preMyR and postMyR) and (postMyR - preMyR) or 0

			-- Update adaptive observed K-factor via EWMA when delta is non-zero
			if preMyR and preOppR and delta ~= 0 then
				local eMe = 1 / (1 + (10 ^ ((preOppR - preMyR) / 400)))
				local actualS = myWin and 1 or (myDraw and 0.5 or 0)
				local denom = math.abs(actualS - eMe)
				if denom >= 0.12 then
					local impliedK = math.clamp(math.abs(delta) / denom, 12, 64)
					b.obsK = math.floor(((b.obsK or 32) * 0.70 + impliedK * 0.30) * 10 + 0.5) / 10
				end
			end

			if postMyR then
				if not b.startRating then b.startRating = preMyR or postMyR end
				b.lastKnownRating = postMyR
				b.netElo = b.lastKnownRating - b.startRating
			else
				b.netElo = (b.netElo or 0) + delta
			end

			if myWin then
				b.wins += 1
				b.eloGainedSinceLoss += math.max(0, delta)
				f.deferReason = string.format("Won (%+d Elo)", delta)
			elseif myLoss then
				b.losses += 1
				if wasControlled then
					b.controlledLosses += 1
					f.deferReason = string.format("Controlled Loss (%+d Elo · cycle reset)", delta)
				else
					f.deferReason = string.format("Natural Loss (%+d Elo · cycle reset)", delta)
				end
				b.eloGainedSinceLoss = 0
				b.nextLossTargetElo = rollJitteredTarget(CONFIG.FarmLossAfterElo)
			elseif myDraw then
				b.draws += 1
				b.eloGainedSinceLoss = math.max(0, b.eloGainedSinceLoss + delta)
				f.deferReason = string.format("Draw (%+d Elo)", delta)
			end

			if curGid ~= "" then
				b.lastGameId = curGid
			end
			b.gamesSinceBreak += 1

			-- Periodic Human Breather (20-45s every 5-8 games)
			if CONFIG.AutoFarm and CONFIG.FarmHumanBreather and b.gamesSinceBreak >= b.nextBreakAfter then
				local breakSec = randTriangular(20.0, 45.0)
				f.breakUntil = os.clock() + breakSec
				b.gamesSinceBreak = 0
				b.nextBreakAfter = math.random(5, 8)
				f.deferReason = string.format("Breather (%.0fs pause)", breakSec)
			end

			-- Check Stop At Target Elo Cap
			if CONFIG.AutoFarm and (CONFIG.FarmStopAtElo or 0) > 0 and b.lastKnownRating and b.lastKnownRating >= CONFIG.FarmStopAtElo then
				f.deferReason = string.format("Target %d Elo Reached!", CONFIG.FarmStopAtElo)
				if Toggles.AutoFarm then Toggles.AutoFarm:SetValue(false) end
				if STATE.Farm.autoEnabledAutoFind and Toggles.AutoFindMatch then
					Toggles.AutoFindMatch:SetValue(false)
					STATE.Farm.autoEnabledAutoFind = false
				end
				pcall(function()
					Library:Notify({
						Title = "Target Elo Reached!",
						Description = string.format("Reached %d Elo (%+d net). Auto-Farm stopped.", b.lastKnownRating, b.netElo),
						Time = 6.0,
					})
				end)
			end

			-- Roll fresh inter-game queue wait (3-9s for Auto-Farm, 2.4-4.2s for standalone AutoFind)
			f.nextQueueDelay = CONFIG.AutoFarm and randTriangular(3.0, 9.0) or randTriangular(2.4, 4.2)
			Farm.saveState(false)
			f.settlingGame = false
			Farm.refreshUi(app, sess)
		end)
	end

	function Farm.refreshUi(app, sess)
		local f = STATE.Farm
		local cls = Farm.getSessionClass(app, sess)
		f.activeClass = cls
		local b = Farm.getBucket(cls)
		local curR = Farm.getProfileRating(app, cls) or b.lastKnownRating
		if curR and not b.startRating then
			b.startRating = curR
			b.lastKnownRating = curR
		end
		local clsCap = string.upper(string.sub(cls, 1, 1)) .. string.sub(cls, 2)
		local now = os.clock()

		local statusTxt = "Standby"
		if not CONFIG.AutoFarm then
			statusTxt = "Off (" .. clsCap .. ")"
		elseif f.settlingGame then
			statusTxt = "Settling Rating..."
		elseif f.breakUntil > now then
			statusTxt = string.format("Breather (%.0fs left)", f.breakUntil - now)
		elseif not STATE.WindowFocused then
			statusTxt = "Paused (Unfocused)"
		elseif f.throwArmed then
			if f.phase == "resigning" then
				statusTxt = "THROWING · Resigning..."
			elseif f.phase == "blunder" then
				statusTxt = string.format("THROWING · Blunder (%d/%d)", f.blunderMovesPlayed, f.maxBlunderMoves)
			elseif f.phase == "weak" then
				statusTxt = "THROWING · Weak Play"
			else
				statusTxt = string.format("THROW ARMED (mv %d)", f.throwStartMove)
			end
		elseif sess and sess.kind == "online" and not sess.over then
			statusTxt = "Farming (" .. clsCap .. " · Normal)"
		else
			statusTxt = "Auto-Queueing (" .. clsCap .. ")"
		end

		setUiLabel("FarmStatusLabel", "Status: " .. statusTxt)
		local netStr = (b.netElo >= 0) and ("+" .. tostring(b.netElo)) or tostring(b.netElo)
		local stopStr = (CONFIG.FarmStopAtElo and CONFIG.FarmStopAtElo > 0) and (" / " .. tostring(CONFIG.FarmStopAtElo)) or ""
		setUiLabel("FarmRatingLabel", string.format("Rating: %s%s (%s Elo)", curR and tostring(curR) or "--", stopStr, netStr))
		setUiLabel("FarmRecordLabel", string.format("Record: %dW · %dL · %dD (%d Ctrl)", b.wins, b.losses, b.draws, b.controlledLosses))
		setUiLabel("FarmCycleLabel", string.format("Loss Cycle: +%d / ~%d Elo", b.eloGainedSinceLoss, b.nextLossTargetElo))
		setUiLabel("FarmGuardLabel", "Guard: " .. (f.deferReason or (CONFIG.FarmKeepPositive and "Anti-Rungkat Active" or "Off")))
	end

	function Farm.tick(app, sess, now)
		local f = STATE.Farm
		if not app then
			return
		end

		-- Detect new online session start (plus lazy backfill if ratings arrived slightly after teleport)
		if sess and sess.kind == "online" then
			local gid = tostring(sess.id or "")
			if f.gameRef ~= sess or (gid ~= "" and f.gameId ~= gid) then
				Farm.onSessionStart(app, sess)
			elseif not sess.over and getSessionPly(sess) <= 1 and (not f.preMyRating or not f.preOppRating) then
				local cls = f.activeClass or Farm.getSessionClass(app, sess)
				local myR, oppR = Farm.getSessionRatings(app, sess, cls)
				if myR and oppR then
					Farm.onSessionStart(app, sess)
				end
			end

			if sess.over then
				Farm.onSessionOver(app, sess)
			elseif CONFIG.AutoFarm and f.throwArmed and sess:isMyTurn() and not f.resignPending then
				local ply = getSessionPly(sess)
				local fullMove = math.floor(ply / 2) + 1
				local mode = CONFIG.FarmLossMode or "BlunderResign"

				-- Phase 1 -> Phase 2 transition
				if f.phase == "opening" and fullMove >= f.throwStartMove then
					f.phase = (mode == "PlayWeak") and "weak" or "blunder"
					scheduleRecalc()
				end

				-- Phase 3 Resign evaluation (strictly >= 14 plies so never an abort!)
				if ply >= 14 and fullMove >= f.resignMinMove and (f.phase == "blunder" or f.phase == "weak") then
					local myColor = sess.myColor or 1
					local curRes = STATE.CurrentResult
					local rawCp = (curRes and curRes.evalCp) or STATE.EvalWhiteCp or 0
					local myEvalCp = rawCp * myColor
					local mateVal = (curRes and curRes.mate) or STATE.EvalMate
					local oppForcedMate = (mateVal ~= nil and (mateVal * myColor) < 0)
					local oppImmediateMate = oppForcedMate and math.abs(mateVal) <= 2

					local shouldResign = false
					if not oppImmediateMate then
						if mode == "BlunderResign" then
							shouldResign = (myEvalCp <= -450)
								or oppForcedMate
								or (f.blunderMovesPlayed >= f.maxBlunderMoves and myEvalCp <= -200)
								or (f.blunderMovesPlayed >= (f.maxBlunderMoves + 3))
						elseif mode == "LateResign" then
							shouldResign = (f.blunderMovesPlayed >= 1 and myEvalCp <= -320)
								or (f.blunderMovesPlayed >= 2)
						elseif mode == "PlayWeak" then
							shouldResign = (fullMove >= 20) and (myEvalCp <= -850 or oppForcedMate)
						end
					end

					if shouldResign then
						scheduleNaturalResign(app, sess)
					end
				end
			end
		elseif f.throwArmed then
			Farm.disarmThrow()
		end

		if now - f.lastUiUpdate >= 0.40 then
			f.lastUiUpdate = now
			Farm.refreshUi(app, sess)
		end
	end
end

local function findVisiblePuzzleNextButton(app)
	local pzPage = app and app.pages and app.pages.puzzles
	local root = pzPage and pzPage.frame
	if not root or not root.Visible then
		return nil
	end
	local function isAncestorChainVisible(obj)
		local cur = obj
		while cur and cur ~= root do
			if cur:IsA("GuiObject") and not cur.Visible then
				return false
			end
			cur = cur.Parent
		end
		return true
	end
	for _, desc in ipairs(root:GetDescendants()) do
		if (desc:IsA("TextLabel") or desc:IsA("TextButton")) and (desc.Text == "Next" or desc.Text == "Try Again") then
			local cur = desc:IsA("GuiButton") and desc or desc.Parent
			while cur and cur ~= root do
				if cur:IsA("GuiButton") then
					if cur.Visible and cur.AbsoluteSize.X >= 30 and cur.AbsoluteSize.Y >= 20 and isAncestorChainVisible(cur) then
						return cur
					end
					break
				end
				cur = cur.Parent
			end
		end
	end
	return nil
end

local function tickAutoNextPuzzle(app, sess, now)
	if not CONFIG.AutoNextPuzzle or not app or not app.pages or app.pages.current ~= "puzzles" then
		STATE.PuzzleDoneKey = ""
		STATE.PuzzleDoneAt = 0
		return
	end
	local pz = (sess and sess.kind == "puzzle") and sess.pz or nil
	if not pz or not pz.done or pz.busy then
		STATE.PuzzleDoneKey = ""
		STATE.PuzzleDoneAt = 0
		return
	end

	local pKey = tostring(sess) .. "|" .. tostring(pz.data and pz.data.id or "")
	if STATE.PuzzleDoneKey ~= pKey then
		STATE.PuzzleDoneKey = pKey
		STATE.PuzzleDoneAt = now
		STATE.PuzzleNextDelay = randTriangular(0.95, 1.55)
		return
	end
	if (now - STATE.PuzzleDoneAt) < (STATE.PuzzleNextDelay or 1.15) then
		return
	end
	if (now - (STATE.PuzzleNextClickAt or 0)) < 3.2 then
		return
	end
	local safeIn = isSafeToSendInput()
	if not safeIn then
		return
	end

	local nextBtn = findVisiblePuzzleNextButton(app)
	if not nextBtn then
		return
	end

	STATE.PuzzleNextClickAt = now
	task.spawn(function()
		if not STATE.Alive or not CONFIG.AutoNextPuzzle then
			return
		end
		local inset = GuiService:GetGuiInset()
		local btnPos = nextBtn.AbsolutePosition + inset
		local btnSz = nextBtn.AbsoluteSize
		if btnSz.X < 30 or btnSz.Y < 20 then
			return
		end
		local pt = Vector2.new(btnPos.X + btnSz.X * 0.5, btnPos.Y + btnSz.Y * 0.5)
		ensureBoardUnoccluded(pt, pt, inset)
		if isPointOverBadge(pt, inset) and HUD.root then
			HUD.tempHiddenForClick = true
			HUD.root.Visible = false
			pcall(function() RunService.RenderStepped:Wait() end)
		end
		local jx = (math.random() * 2 - 1) * math.min(8, btnSz.X * 0.14)
		local jy = (math.random() * 2 - 1) * math.min(5, btnSz.Y * 0.16)
		pcall(sendSafeClick, pt.X + jx, pt.Y + jy, false)
		HUD.tempHiddenForClick = false
	end)
end

local function tickAutoFindMatch(app, sess, now)
	if (not CONFIG.AutoFindMatch and not CONFIG.AutoFarm) or not app or not app.profile then
		STATE.Farm.idleSince = 0
		return
	end
	if app.searching or app.joining then
		return
	end
	if type(app.inLiveGame) == "function" and app.inLiveGame() then
		STATE.AutoFindOverAt = 0
		STATE.Farm.idleSince = 0
		return
	end
	-- Do not interfere while enrolled in a running Tournament bracket
	if Farm.isTournamentMatch and Farm.isTournamentMatch(app, sess) then
		return
	end
	-- v2.1.0 Fix #4: Pause queueing while window is unfocused if AutoPlay/AutoFarm is active (prevents AFK timeouts & bl=1)
	if (CONFIG.AutoPlay or CONFIG.AutoFarm) and not STATE.WindowFocused then
		return
	end
	-- Wait for post-game Elo delta settle & periodic human breather
	if STATE.Farm.settlingGame then
		return
	end
	if CONFIG.AutoFarm and STATE.Farm.breakUntil > now then
		setPulseStatus("Farm · Breather", string.format("Next queue in %.0fs", STATE.Farm.breakUntil - now))
		return
	end
	-- Check Target Elo Cap before queueing
	if CONFIG.AutoFarm and (CONFIG.FarmStopAtElo or 0) > 0 then
		local cls = Farm.getSessionClass(app, sess)
		local curR = Farm.getProfileRating(app, cls)
		if curR and curR >= CONFIG.FarmStopAtElo then
			if Toggles.AutoFarm then Toggles.AutoFarm:SetValue(false) end
			return
		end
	end

	local canQueue = false
	if not sess or sess.kind == "idle" then
		-- Enforce settle delay on idle so startup / post-teleport doesn't fire on frame 1
		if STATE.Farm.idleSince == 0 then
			STATE.Farm.idleSince = now
		end
		local idleNeed = CONFIG.AutoFarm and 2.2 or 1.8
		if (now - STATE.Farm.idleSince) >= idleNeed then
			canQueue = true
		end
	elseif sess.kind == "online" and sess.over then
		STATE.Farm.idleSince = 0
		if STATE.AutoFindOverAt == 0 then
			STATE.AutoFindOverAt = now
			if STATE.Farm.nextQueueDelay <= 0 then
				STATE.Farm.nextQueueDelay = CONFIG.AutoFarm and randTriangular(3.0, 9.0) or randTriangular(2.4, 4.2)
			end
		end
		if (now - STATE.AutoFindOverAt) >= math.max(2.0, STATE.Farm.nextQueueDelay or 3.0) then
			canQueue = true
		end
	else
		STATE.AutoFindOverAt = 0
		STATE.Farm.idleSince = 0
	end

	if canQueue and (now - STATE.AutoFindLastQueueAt >= 5.0) and type(app.startSearch) == "function" then
		local tc = (CONFIG.AutoFindTc == "Selected") and app.selectedTc or CONFIG.AutoFindTc
		if tc == nil then
			return
		end
		STATE.AutoFindLastQueueAt = now
		STATE.AutoFindOverAt = 0
		STATE.Farm.idleSince = 0
		STATE.Farm.nextQueueDelay = 0
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
		updateEngineBadge("Standby · " .. CONFIG.EngineMode, "idle", sess, nil, false)
		return
	end

	local kindCap = string.upper(string.sub(sess.kind, 1, 1)) .. string.sub(sess.kind, 2)
	local sideTxt = (sess.myColor == 1 and "White") or (sess.myColor == -1 and "Black") or (sess.engine.side == 1 and "White" or "Black")
	local turnTxt = sess.over and "Finished"
		or (sess.myColor == nil and (sideTxt .. " to move"))
		or (sess:isMyTurn() and ("Your Turn (" .. sideTxt .. ")") or "Opponent's Turn")

	setUiLabel("MatchLabel", "Match: " .. kindCap .. " · " .. turnTxt)
	setUiLabel("OpponentLabel", formatOpponentLabel(sess))

	local turboTag = ""
	if CONFIG.AutoFarm and STATE.Farm.throwArmed and sess.kind == "online" then
		turboTag = (STATE.Farm.phase == "resigning") and " · Resign" or " · Farm"
	elseif CONFIG.AntiEngineTurbo and sess.kind == "online" then
		if STATE.Opp.spectatorPaused and (STATE.Opp.spectators or 0) > 0 then
			turboTag = string.format(" · Turbo Pause (%d spec)", STATE.Opp.spectators)
		elseif STATE.Opp.turboActive then
			turboTag = " · Turbo"
		elseif STATE.Opp.suspect then
			turboTag = " · Suspect"
		elseif (STATE.Opp.spectators or 0) > 0 then
			turboTag = string.format(" · %d spec", STATE.Opp.spectators)
		end
	end

	if thinking then
		local activeName = STATE.ActiveEngine or CONFIG.EngineMode
		setUiLabel("EngineLabel", "Active Engine: " .. activeName .. turboTag .. " (Thinking...)")
		setUiLabel("BestMoveLabel", "Best Move: Calculating...")
		setUiLabel("EvalLabel", "Eval: --")
		setPulseStatus("Thinking", activeName .. turboTag)
		updateEngineBadge(activeName .. turboTag .. " ...", "thinking", sess, nil, true)
		return
	end

	if res then
		local engName = res.engineLabel or res.source or "Engine"
		local engKind = (STATE.Opp.turboActive and CONFIG.AntiEngineTurbo and sess.kind == "online" and "turbo")
			or (res.engineKind or "stockfish")
		local depthTag = (res.depth and res.depth > 0 and res.depth < 99) and (" d" .. tostring(res.depth)) or ""
		local msTag = (res.ms and res.ms >= 0) and (" · " .. tostring(res.ms) .. "ms") or ""

		setUiLabel("EngineLabel", "Active Engine: " .. engName .. depthTag .. msTag .. turboTag)
		local shortCoords = string.sub(res.best, 1, 2) .. " → " .. string.sub(res.best, 3, 4) .. (res.promoChar and ("=" .. res.promoChar) or "")
		setUiLabel("BestMoveLabel", "Best Move: " .. (res.san or res.best) .. "  (" .. shortCoords .. ")")
		local evStr = formatEvalText(res.evalCp, res.mate)
		setUiLabel("EvalLabel", "Eval: " .. evStr)
		setUiLabel("LineLabel", "Line: " .. table.concat(res.pv or { res.best }, "  "))
		STATE.EvalWhiteCp = res.evalCp or 0
		STATE.EvalMate = res.mate
		updateEvalBarVisual(res.evalCp, res.mate, STATE.Board and STATE.Board.flipped == true)
		setPulseStatus(engName .. turboTag, (res.san or res.best) .. " (" .. evStr .. ")" .. depthTag)
		updateEngineBadge(engName .. depthTag .. msTag .. turboTag, engKind, sess, res, false)
	else
		local isTerminal = (STATE.TerminalKey ~= "" and STATE.TerminalKey == STATE.LastKey)
		local prefetching = (STATE.PrefetchDone ~= nil and not STATE.PrefetchDone.done)
		local isPuzzleDone = (sess.kind == "puzzle" and sess.pz and sess.pz.done)
		local waitTxt = isPuzzleDone and "Puzzle · Selesai"
			or ((sess.kind == "puzzle" or sess.kind == "rush") and "Puzzle · Giliran Lawan")
			or (isTerminal and "Posisi Akhir")
			or (prefetching and "Ponder Prefetch...")
			or ("Menunggu · " .. CONFIG.EngineMode)
		setUiLabel("EngineLabel", "Active Engine: " .. waitTxt .. turboTag)
		setUiLabel("BestMoveLabel", (sess.over or isTerminal or isPuzzleDone) and "Best Move: Finished" or "Best Move: Waiting...")
		setUiLabel("EvalLabel", "Eval: --")
		setUiLabel("LineLabel", "Line: --")
		setPulseStatus((sess.over or isTerminal or isPuzzleDone) and "Finished" or "Waiting", kindCap .. " · " .. turnTxt)
		local badgeKind = (isPuzzleDone and "puzzle")
			or ((STATE.Opp.turboActive and CONFIG.AntiEngineTurbo and sess.kind == "online") and "turbo")
			or "idle"
		updateEngineBadge(((sess.over or isTerminal) and "Game Over" or waitTxt) .. turboTag, badgeKind, sess, nil, false)
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
			STATE.LastSessionId = nil
			STATE.SessionStartedAt = 0
			STATE.LastKey = "IDLE"
			STATE.TerminalKey = ""
			STATE.LastAutoKey = ""
			STATE.AutoGen += 1
			STATE.AutoPending = false
			STATE.AutoRetryAfter = 0
			STATE.SearchGen += 1
			STATE.Searching = false
			STATE.ActiveStage = nil
			STATE.CurrentResult = nil
			STATE.LastArrowSig = ""
			cancelPrefetchState()
			updateHudReadout(sess, nil, false)
		end
		return
	end

	-- Cleanly reset stale AutoPlay / turn state whenever a brand-new game session starts (rematch, bot, tournament round)!
	local curSessId = tostring(sess.id or "")
	if sess ~= STATE.LastSessionRef or curSessId ~= STATE.LastSessionId then
		STATE.LastSessionRef = sess
		STATE.LastSessionId = curSessId
		STATE.SessionStartedAt = os.clock()
		STATE.LastAutoKey = ""
		STATE.AutoGen += 1
		STATE.AutoPending = false
		STATE.AutoPendingAt = 0
		STATE.AutoExpectedWait = 0
		STATE.AutoRetryAfter = 0
		STATE.LastKey = ""
		STATE.TerminalKey = ""
		STATE.CurrentResult = nil
		STATE.LastEvalCp = nil
		STATE.LastEvalFlip = nil
		STATE.MissingResultSince = 0
		STATE.LastArrowSig = ""
		STATE.ActiveStage = nil
		updateEvalBarVisual(0, nil, STATE.Board and STATE.Board.flipped == true)
		force = true
	end

	-- Use displayed ply for analysis/review, live engine for active games
	local eng = (sess.kind == "analysis" or sess.kind == "review") and sess:engineAt(sess.viewPly) or sess.engine
	local fen = eng:getFen()
	local isMyTurnNow = (type(sess.isMyTurn) == "function") and (sess:isMyTurn() == true) or false
	local plyCount = getSessionPly(sess)
	local key = table.concat({
		tostring(sess),
		curSessId,
		tostring(sess.kind),
		tostring(sess.myColor),
		tostring(isMyTurnNow),
		tostring(plyCount),
		tostring(sess.viewPly),
		tostring(sess.over),
		fen,
		CONFIG.EngineMode,
		CONFIG.PlayStyle,
		tostring(CONFIG.AutoAdapt),
		tostring(CONFIG.AutoFarm),
		tostring(STATE.Farm.phase),
		tostring(CONFIG.StockfishDepth),
		tostring(CONFIG.LuauMaxDepth),
		tostring(CONFIG.OnlyMyTurn),
	}, "|")

	if not force and key == STATE.LastKey then
		return
	end
	if force then
		-- v2.1.0 Fix #1: clear LastAutoKey & AutoRetryAfter so forced recalc never deadlocks AutoPlay
		STATE.AutoGen += 1
		STATE.AutoPending = false
		STATE.LastAutoKey = ""
		STATE.AutoRetryAfter = 0
	end
	STATE.LastKey = key
	STATE.SearchGen += 1
	local myGen = STATE.SearchGen
	STATE.CurrentResult = nil
	STATE.LastArrowSig = ""
	STATE.MissingResultSince = 0

	if sess.over or not CONFIG.Enabled or STATE.Farm.resignPending or STATE.Farm.phase == "resigning" then
		STATE.Searching = false
		STATE.ActiveStage = nil
		STATE.TerminalKey = ""
		if not STATE.Farm.resignPending and STATE.Farm.phase ~= "resigning" then
			updateHudReadout(sess, nil, false)
		end
		return
	end

	if CONFIG.OnlyMyTurn and sess.myColor ~= nil and not sess:isMyTurn() then
		STATE.Searching = false
		STATE.ActiveStage = nil
		STATE.TerminalKey = ""
		updateHudReadout(sess, nil, false)
		return
	end

	-- Terminal position guard (checkmate/stalemate): skip API calls & Watchdog #2 spam in Analysis/Review
	local okTerm, isTerminal = pcall(function()
		local tb = PureChess.new(fen)
		return #tb:legalMoves() == 0
	end)
	if okTerm and isTerminal then
		STATE.TerminalKey = key
		STATE.Searching = false
		STATE.ActiveStage = nil
		STATE.MissingResultSince = 0
		updateHudReadout(sess, nil, false)
		return
	end
	STATE.TerminalKey = ""

	STATE.Searching = true
	STATE.SearchStartedAt = os.clock()
	STATE.ActiveStage = nil
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
		STATE.ActiveStage = nil
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

				if res.source == "FarmBlunder" and STATE.Farm.throwArmed and STATE.Farm.lastBlunderPly ~= plyCount then
					STATE.Farm.lastBlunderPly = plyCount
					STATE.Farm.blunderMovesPlayed += 1
				end

				local isSfSrc = isStockfishSource(res.source)

				-- Pre-seed expectedByPly[plyNow + 2] for Stockfish results so <0.13s premove +2 ply jumps are never missed!
				if sess.kind == "online" and isSfSrc and type(res.best) == "string" and #res.best >= 4 and type(res.ponder) == "string" and #res.ponder >= 4 then
					pcall(function()
						local sb = PureChess.new(fen)
						local sm = sb:moveFromUci(res.best)
						if sm then
							sb:makeMove(sm)
							STATE.Opp.expectedByPly[plyCount + 2] = {
								uci = res.ponder,
								myUci = res.best,
								myCapture = res.isCapture == true,
								myToSq = string.sub(res.best, 3, 4),
								oppFen = sb:getFen(),
								source = res.source,
							}
						end
					end)
				end

				-- Opponent Blunder Check: gated on ply >= 9, Stockfish-only prev+cur sources, oppUci ~= exp.uci, and rolling capped penalty
				if sess.kind == "online" and sess.myColor and isSfSrc and rawTopCp ~= nil and res.mate == nil then
					local myEvalNow = rawTopCp * sess.myColor
					local prevMe = STATE.Opp.lastEvalForMe
					local prevSf = isStockfishSource(STATE.Opp.lastEvalSource)
					if plyCount >= 9 and prevSf and prevMe ~= nil and math.abs(prevMe) < 500 and (myEvalNow - prevMe) >= 200 then
						local oppUci = (type(sess.ucis) == "table" and plyCount >= 1) and sess.ucis[plyCount] or nil
						local oppExp = STATE.Opp.expectedByPly[plyCount]
						local matchedExp = (type(oppExp) == "table" and oppExp.uci ~= nil and oppUci == oppExp.uci)
						if not matchedExp then
							STATE.Opp.blunders = (STATE.Opp.blunders or 0) + 1
							STATE.Opp.blunderPenalty = math.min(56, (STATE.Opp.blunderPenalty or 0) + 28)
							STATE.Opp.streak = 0
							recomputeOpponentSuspicion()
							setUiLabel("OpponentLabel", formatOpponentLabel(sess))
						end
					end
					STATE.Opp.lastEvalForMe = myEvalNow
					STATE.Opp.lastEvalSource = res.source
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

	-- 1. Hard Search Timeout Watchdog (aligned above VPS+Cloud+Luau chain; penalizes ONLY stalled ActiveStage)
	if STATE.Searching then
		local maxWait = (CONFIG.AntiEngineTurbo and STATE.Opp.turboActive) and 3.5 or 6.0
		if STATE.SearchStartedAt > 0 and (now - STATE.SearchStartedAt) > maxWait then
			local stalledStage = STATE.ActiveStage
			STATE.SearchGen += 1
			STATE.Searching = false
			STATE.ActiveStage = nil
			if stalledStage == "vps" then
				STATE.VpsFailStreak += 1
				if STATE.VpsFailStreak >= 2 then
					STATE.VpsCooldownUntil = now + 12
				end
			elseif stalledStage == "cloud" then
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

	-- 2. Empty-Result Recovery Watchdog (skips terminal checkmate/stalemate plies!)
	if needMove and (not STATE.Searching) and STATE.CurrentResult == nil and STATE.TerminalKey ~= STATE.LastKey then
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

	-- 3. AutoPlay Deadlock Watchdog (clears stale AutoPending & bumps AutoGen so old coroutines cannot clobber)
	if STATE.AutoPending then
		local maxPending = math.max((STATE.AutoExpectedWait or 0) + 5.0, math.max(CONFIG.AutoDelayMin or 1, CONFIG.AutoDelayMax or 5) + 5.5)
		if STATE.AutoPendingAt > 0 and (now - STATE.AutoPendingAt) > maxPending then
			STATE.AutoGen += 1
			STATE.AutoPending = false
			STATE.AutoExpectedWait = 0
			STATE.LastAutoKey = ""
		end
	elseif CONFIG.AutoPlay and STATE.CurrentResult and sess:isMyTurn() and STATE.LastAutoKey ~= STATE.LastKey then
		-- 4. Missed AutoPlay Turn Trigger
		performSafeAutoMove(sess, STATE.CurrentResult, STATE.LastKey)
	end
end

-- Cross-Server Teleport Persistence (re-queues BeverlyHub & flushes Farm state on RoChess match teleports)
if LocalPlayer and LocalPlayer.OnTeleport then
	trackConn(LocalPlayer.OnTeleport:Connect(function(tpState)
		if not STATE.Alive then
			return
		end
		if tpState == Enum.TeleportState.Failed then
			STATE.TeleportQueued = false
			return
		end
		-- v2.1.0 Fix #3: handle RequestedFromServer (server-initiated TeleportAsync) + Started/InProgress
		if tpState == Enum.TeleportState.RequestedFromServer
			or tpState == Enum.TeleportState.Started
			or tpState == Enum.TeleportState.InProgress
		then
			if Farm.saveState then
				Farm.saveState(true)
			end
			if CONFIG.AutoReloadOnTeleport and not STATE.TeleportQueued and type(queueOnTeleport) == "function" then
				STATE.TeleportQueued = true
				local okQ = pcall(queueOnTeleport, getTeleportLoaderSource())
				if not okQ then
					STATE.TeleportQueued = false
				end
			end
		end
	end))
end

-- Cleanup routine (wired bidirectionally with Library:OnUnload)
local unloading = false
cleanup = function()
	if unloading then return end
	unloading = true
	STATE.Alive = false
	STATE.SearchGen += 1
	STATE.AutoGen += 1
	STATE.Farm.resignGen += 1
	if Farm.saveState then
		Farm.saveState(false)
	end
	cancelPrefetchState()
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

-- Startup (persistent retry while STATE.Alive) & Per-Frame Ply Watcher + 0.10s Periodic Loop
task.spawn(function()
	-- Yield 1 frame so SaveManager autoload deferred callbacks settle before initial recalc
	task.wait()
	if Farm.loadState then Farm.loadState() end
	if Farm.applyTeleportResume then Farm.applyTeleportResume() end
	syncConfigFromUI()

	local tries = 0
	while STATE.Alive and not connectToRoChess() do
		tries += 1
		if tries == 20 then
			setUiLabel("MatchLabel", "Match: Waiting for RoChess client...")
		end
		task.wait(tries <= 20 and 0.25 or 1.0)
	end
	if not STATE.Alive or not STATE.App then
		return
	end

	STATE.Board = STATE.App.board
	if Farm.refreshUi then Farm.refreshUi(STATE.App, STATE.App.session) end
	updateHudReadout(STATE.App.session, nil, false)
	triggerRecalc(true)

	local lastCheck = 0
	local lastFramePly = -1
	local lastFrameSess = nil
	local lastFrameTurn = nil

	trackConn(RunService.RenderStepped:Connect(function()
		if not STATE.Alive then return end
		local app = STATE.App
		STATE.Board = app and app.board
		renderOverlay()
		local now = os.clock()
		local sess = app and app.session

		-- Lightweight per-frame ply/turn change detector (catches <0.13s premoves & +2 ply jumps immediately)
		local curPly = getSessionPly(sess)
		local curTurn = (sess and type(sess.isMyTurn) == "function") and (sess:isMyTurn() == true) or nil
		local plyChanged = (sess ~= lastFrameSess) or (curPly ~= lastFramePly) or (curTurn ~= lastFrameTurn)
		if plyChanged then
			lastFrameSess = sess
			lastFramePly = curPly
			lastFrameTurn = curTurn
			updateOpponentDetector(sess)
			if Farm.tick then Farm.tick(app, sess, now) end
			triggerRecalc(false)
		end

		-- Periodic watchdogs, Auto-Farm Elo, live FYI ticker & clock checks at 0.10s
		if now - lastCheck >= 0.10 then
			lastCheck = now
			if not plyChanged then
				updateOpponentDetector(sess)
				if Farm.tick then Farm.tick(app, sess, now) end
				triggerRecalc(false)
			end
			tickWatchdogs(app, sess, now)
			tickAutoFindMatch(app, sess, now)
			tickAutoNextPuzzle(app, sess, now)
			-- Live-refresh Coach speech & mood every ~0.35s so clock/breather/draw callouts stay fresh
			if HUD.root and HUD.root.Visible and (now - (HUD.lastFyiAt or 0)) >= 0.35 then
				HUD.lastFyiAt = now
				local mood, msg, fyiCol = computeLiveFyi(sess, STATE.CurrentResult, STATE.Searching)
				HUD.say(msg, mood, fyiCol)
			end
		end
	end))
end)
