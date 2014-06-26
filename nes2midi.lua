require("emu2midi")
local base64 = require("base64") -- http://www.tecgraf.puc-rio.br/~lhf/ftp/lua/#lbase64 (visit LuaForWindows for Windows installation)

function NESSoundWriter()
	local self = VGMSoundWriter()

	-- functions in base class
	self.base = ToFunctionTable(self);

	-- channel type list
	self.CHANNEL_TYPE = {
		SQUARE = "square";
		TRIANGLE = "triangle";
		NOISE = "noise";
		DPCM = "dpcm";
	};

	-- pseudo patch number for noise
	self.NOISE_PATCH_NUMBER = {
		LONG = 0;
		SHORT = 1;
	};

	self.FRAMERATE = 39375000 / 11 * 3 / 2 / 341 / 262;

	-- reset current logging state
	self.clear = function(self)
		self.base.clear(self)

		-- tempo (fixed value)
		local bpm = self.FRAMERATE
		table.insert(self.scoreGlobal, { 'set_tempo', 0, math.floor(60000000 / bpm) })
	end;

	-- get MIDI TPQN (integer)
	self.getTPQN = function(self)
		return 60
	end;

	-- event conversion: convert patch event for MIDI
	-- @param source 'patch_change' event
	self.eventPatchToMidi = function(self, event)
		return { { 'patch_change', event[2], event[3], event[4] } }
	end;

	-- get FlMML patch command
	-- @param string patch type (wavememory, dpcm, etc.)
	-- @param number patch number
	-- @return string patch mml text
	self.getFlMMLPatchCmd = function(self, patchType, patchNumber)
		if patchType == self.CHANNEL_TYPE.SQUARE then
			if patchNumber >= 0 and patchNumber <= 3 then
				local dutyTable = { 1, 2, 4, 6 }
				return string.format("@5@W%d", dutyTable[1 + patchNumber])
			else
				error(string.format("Unknown patch number '%d' for '%s'", patchNumber, patchType))
			end
		elseif patchType == self.CHANNEL_TYPE.TRIANGLE then
			return "@6-1"
		elseif patchType == self.CHANNEL_TYPE.NOISE then
			if patchNumber == self.NOISE_PATCH_NUMBER.LONG then
				return "@7"
			elseif patchNumber == self.NOISE_PATCH_NUMBER.SHORT then
				return "@8"
			else
				error(string.format("Unknown patch number '%d' for '%s'", patchNumber, patchType))
			end
		elseif patchType == self.CHANNEL_TYPE.DPCM then
			return string.format("@9-%d", patchNumber)
		else
			error(string.format("Unknown patch type '%s'", patchType))
		end
	end;

	-- get FlMML waveform definition MML
	-- @return string waveform define mml
	self.getFlMMLWaveformDef = function(self)
		local mml = ""
		for waveChannelType, waveList in pairs(self.waveformList) do
			for waveIndex, waveValue in ipairs(waveList) do
				if waveChannelType == self.CHANNEL_TYPE.DPCM then
					mml = mml .. string.format("#WAV9 %d,%s\n", waveIndex - 1, waveValue)
				else
					error(string.format("Unknown patch type '%s'", waveChannelType))
				end
			end
		end
		return mml
	end;

	self:clear()
	return self
end

local writer = NESSoundWriter()

emu.registerafter(function()
	local ch = {}
	local channels = {}
	local snd = sound.get()

	ch = snd.rp2a03.square1
	ch.type = writer.CHANNEL_TYPE.SQUARE
	ch.patch = ch.duty
	table.insert(channels, ch)

	ch = snd.rp2a03.square2
	ch.type = writer.CHANNEL_TYPE.SQUARE
	ch.patch = ch.duty
	table.insert(channels, ch)

	ch = snd.rp2a03.triangle
	ch.type = writer.CHANNEL_TYPE.TRIANGLE
	ch.patch = 0
	if ch.regs.frequency == 0 then -- freq reg = 0 (pseudo mute)
		ch.midikey = 0
		ch.volume = 0
	end
	table.insert(channels, ch)

	ch = snd.rp2a03.noise
	ch.type = writer.CHANNEL_TYPE.NOISE
	ch.midikey = ch.regs.frequency
	ch.patch = (ch.short and writer.NOISE_PATCH_NUMBER.SHORT or writer.NOISE_PATCH_NUMBER.LONG)
	table.insert(channels, ch)

	ch = snd.rp2a03.dpcm
	ch.type = writer.CHANNEL_TYPE.DPCM
	ch.midikey = ch.regs.frequency
	ch.patch = nil
	if ch.volume ~= 0 then
		ch.patch = string.format("%d,%d,%s", ch.dmcseed, ch.dmcloop and 1 or 0, base64.encode(memory.readbyterange(ch.dmcaddress, ch.dmcsize)))
	end
	table.insert(channels, ch)

	writer:write(channels)
end)

_registerexit_firstrun = true
emu.registerexit(function()
	if _registerexit_firstrun then
		-- fceux: without this, we will get an error message for several times
		_registerexit_firstrun = false

		writer:writeTextFile("testVGM.txt")
		writer:writeMidiFile("testVGM.mid")
		writer:writeFlMMLFile("testVGM.mml")
	end
end)
