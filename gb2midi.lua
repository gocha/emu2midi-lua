-- Note: do not use vba-rr v24, it doesn't work on GB games. use v23 instead.
require("emu2midi")

function GBSoundWriter()
	local self = VGMSoundWriter()

	-- functions in base class
	self.base = ToFunctionTable(self);

	-- channel type list
	self.CHANNEL_TYPE = {
		SQUARE = "square";
		WAVEMEMORY = "wavememory";
		NOISE = "noise";
	};

	-- pseudo patch number for noise
	self.NOISE_PATCH_NUMBER = {
		LONG = 0;
		SHORT = 1;
	};

	self.FRAMERATE = 16777216 / 280896;

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
		elseif patchType == self.CHANNEL_TYPE.WAVEMEMORY then
			return string.format("@13-%d", patchNumber)
		elseif patchType == self.CHANNEL_TYPE.NOISE then
			if patchNumber == self.NOISE_PATCH_NUMBER.LONG then
				return "@11"
			elseif patchNumber == self.NOISE_PATCH_NUMBER.SHORT then
				return "@12"
			else
				error(string.format("Unknown patch number '%d' for '%s'", patchNumber, patchType))
			end
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
				if waveChannelType == self.CHANNEL_TYPE.WAVEMEMORY then
					mml = mml .. string.format("#WAV13 %d,%s\n", waveIndex - 1, waveValue)
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

local writer = GBSoundWriter()

emu.registerafter(function()
	local ch = {}
	local channels = {}
	local snd = sound.get()

	ch = snd.square1
	ch.type = writer.CHANNEL_TYPE.SQUARE
	ch.patch = ch.duty
	table.insert(channels, ch)

	ch = snd.square2
	ch.type = writer.CHANNEL_TYPE.SQUARE
	ch.patch = ch.duty
	table.insert(channels, ch)

	ch = snd.wavememory
	ch.type = writer.CHANNEL_TYPE.WAVEMEMORY
	ch.patch = writer.bytestohex(ch.waveform)
	table.insert(channels, ch)

	ch = snd.noise
	ch.type = writer.CHANNEL_TYPE.NOISE
	ch.midikey = writer.gbNoiseFreqRegToNote(ch.regs.frequency)
	ch.patch = (ch.short and writer.NOISE_PATCH_NUMBER.SHORT or writer.NOISE_PATCH_NUMBER.LONG)
	table.insert(channels, ch)

	writer:write(channels)
end)

_registerexit_firstrun = true
emu.registerexit(function()
	if _registerexit_firstrun then
		-- vba: without this, we will get an infinite loop on error
		_registerexit_firstrun = false

		writer:writeTextFile("testVGM.txt")
		writer:writeMidiFile("testVGM.mid")
		writer:writeFlMMLFile("testVGM.mml")
	end
end)
