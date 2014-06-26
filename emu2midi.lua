-- Generic MIDI/FlMML recorder abstruct class on EmuLua
-- @author gocha <http://twitter.com/gochaism>
-- @dependency http://www.pjb.com.au/comp/lua/MIDI.html

function ToFunctionTable(classObj)
	local funcTable = {}
	for k, v in pairs(classObj) do
		if type(v) == "function" then
			funcTable[k] = v
		end
	end
	return funcTable
end

function VGMSoundWriter()
	local self = {
		--[[
		class VGMSoundChannel {
			-- the following members must be given to write()
			number midikey;     -- real number, not integer
			number volume;      -- real number [0.0-1.0]
			number panpot;      -- real number [0.0-1.0], 0.5 for center
			string type;        -- type identifier, something like "square", "noise", etc.
			object patch;       -- patch identifier (number: patch number, string: patch identifier, waveform address for example)

			-- derived classes may have more additional members
		};
		]]

		-- function table for derived class
		-- IMPORTANT NOTE: multiple inheritance is not allowed
		base = {};

		-- tick for new event
		tick = 0;

		-- VGMSoundChannel[] last sound state, used for logging
		lastValue = {};

		-- waveform list, which is used to record existing waveforms in a song
		-- for example: waveformList["dpcm"][1] = "3A00 (value is wavetable identifier, such as waveform address or waveform itself)";
		waveformList = {};

		-- score[], sound state log for each channels
		scoreChannel = {};
		-- score, sound state log for global things (e.g. Master Volume)
		scoreGlobal = {};

		-- pitch bend amount to consider a new note
		NOTE_PITCH_THRESHOLD = 0.68;

		-- pitch bend amount to detect unwanted "small pitch change" with a new note
		NOTE_PITCH_STRIP_THRESHOLD = 0.0;

		-- volume up amount to consider a new note
		NOTE_VOLUME_THRESHOLD = 0.25;

		-- minimal volume (mute very small volume)
		VOLUME_MUTE_THRESHOLD = 0.0;

		-- midi note velocity value
		NOTE_VELOCITY = 100;

		-- midi pitch bend range value
		MIDI_PITCHBEND_RANGE = 12;

		-- midi volume/panpot curve on/off
		MIDI_LINEAR_CONVERSION = false;

		-- flmml timebase
		FLMML_TPQN = 96;

		-- static math.round
		-- http://lua-users.org/wiki/SimpleRound
		round = function(num, idp)
			local mult = 10^(idp or 0)
			return math.floor(num * mult + 0.5) / mult
		end;

		-- convert hex string ("414243") to byte string ("ABC")
		hextobytes = function(hexstr)
			if hexstr == nil then
				return nil
			end

			if #hexstr % 2 ~= 0 then
				error("illegal argument #1")
			end

			local bytestr = ""
			for i = 1, #hexstr, 2 do
				local s = hexstr:sub(i, i + 1)
				local n = tonumber(s, 16)
				if n == nil then
					error("illegal argument #1")
				end
				bytestr = bytestr .. string.char(n)
			end
			return bytestr
		end;

		-- convert byte string ("ABC") to hex string ("414243")
		bytestohex = function(bytestr)
			if bytestr == nil then
				return nil
			end

			local hexstr = ""
			for i = 1, #bytestr do
				hexstr = hexstr .. string.format("%02x", bytestr:byte(i))
			end
			return hexstr
		end;

		-- reset current logging state
		clear = function(self)
			self.lastValue = {}
			self.waveformList = {}
			self.scoreChannel = {}
			self.scoreGlobal = {}
			self.tick = 0
		end;

		-- add current sound state to scoreChannel, this function is called from write()
		-- @param number target channel index
		-- @param VGMSoundChannel current sound state of a channel
		addChannelState = function(self, chIndex, curr)
			if self.scoreChannel[chIndex] == nil then
				self.scoreChannel[chIndex] = {}
			end
			if self.lastValue[chIndex] == nil then
				self.lastValue[chIndex] = {}
			end

			local score = self.scoreChannel[chIndex]
			local prev = self.lastValue[chIndex]
			local channelNumber = chIndex - 1

			local currVolume = curr.volume
			if currVolume < self.VOLUME_MUTE_THRESHOLD then
				currVolume = 0.0
			end
			if currVolume ~= prev.volume then
				table.insert(score, { 'volume_change', self.tick, channelNumber, currVolume })
				prev.volume = currVolume
			end

			if currVolume ~= 0.0 then
				if curr.patch ~= prev.patch then
					local patchNumber = nil
					if type(curr.patch) == "number" then
						patchNumber = curr.patch
					else
						-- search in waveform table
						if self.waveformList[curr.type] ~= nil then
							for waveformIndex, waveform in ipairs(self.waveformList[curr.type]) do
								if curr.patch == waveform then
									patchNumber = waveformIndex - 1
									break
								end
							end
						else
							self.waveformList[curr.type] = {}
						end
						-- add new patch if needed
						if patchNumber == nil then
							patchNumber = #self.waveformList[curr.type]
							self.waveformList[curr.type][patchNumber + 1] = curr.patch
						end
					end
					table.insert(score, { 'patch_change', self.tick, channelNumber, patchNumber, curr.type })
					prev.patch = curr.patch
				end

				if curr.panpot ~= prev.panpot then
					table.insert(score, { 'panpot_change', self.tick, channelNumber, curr.panpot })
					prev.panpot = curr.panpot
				end
				if curr.midikey ~= prev.midikey then
					table.insert(score, { 'absolute_pitch_change', self.tick, channelNumber, curr.midikey })
					prev.midikey = curr.midikey
				end
			end
		end;

		-- add current sound state to scoreGlobal, this function is called from write()
		addGlobalState = function(self)
			-- do nothing
			local score = self.scoreGlobal
		end;

		-- write current sound state to score, this function must be called every tick (frame)
		-- @param VGMSoundChannel[] current sound state of each channels
		write = function(self, channels)
			for chIndex, channel in ipairs(channels) do
				self:addChannelState(chIndex, channel)
			end
			self:addGlobalState()
			self.tick = self.tick + 1
		end;

		-- get FlMML patch command
		-- @param string patch type (wavememory, dpcm, etc.)
		-- @param number patch number
		-- @return string patch mml text
		getFlMMLPatchCmd = function(self, patchType, patchNumber)
			return string.format("/*%s:@%d*/", patchType, patchNumber)
		end;

		-- get FlMML waveform definition MML
		-- @return string waveform define mml
		getFlMMLWaveformDef = function(self)
			local mml = ""
			for waveChannelType, waveList in pairs(self.waveformList) do
				for waveIndex, waveValue in ipairs(waveList) do
					mml = mml .. string.format("/* %s-%d=%s */\n", waveChannelType, waveIndex - 1, waveValue)
				end
			end
			return mml
		end;

		-- get FlMML tuning for each patches
		-- @param number origNoteNumber input note number
		-- @param string patchType patch type (square, noise, etc.)
		-- @return number output note number
		getFlMMLNoteNumber = function(self, origNoteNumber, patchType)
			return origNoteNumber
		end;

		-- get FlMML text
		-- @return string FlMML text
		getFlMML = function(self)
			local MML_TICK_MUL = 1
			local getOctaveAndScale = function(midikey)
				if midikey == nil then
					return nil, nil
				end

				local oct = math.floor(midikey / 12)
				local scale = midikey % 12
				return oct, scale
			end
			local keyToMML = function(midikey)
				local oct, scale = getOctaveAndScale(midikey)
				local notetable = { "c", "c+", "d", "d+", "e", "f", "f+", "g", "g+", "a", "a+", "b" }
				return string.format("o%d", oct), notetable[1 + scale]
			end
			local tickToMML = function(tick)
				return string.format("%%%d", tick * MML_TICK_MUL)
			end
			local needsTie = function(flmmlPatchCmd)
				return flmmlPatchCmd ~= "@7" and flmmlPatchCmd ~= "@8" and flmmlPatchCmd:sub(1,2) ~= "@9" and flmmlPatchCmd ~= "@11" and flmmlPatchCmd ~= "@12"
			end

			local scores = self:getFlMMLScore()
			local mml = ""
			local flmmlPatchCmd = ""
			for scoreIndex, score in ipairs(scores) do
				local mmlArray = {}
				local noteInfo = nil
				local prev = { tick = 0, slurEventIndex = nil }
				for eventIndex, event in ipairs(score) do
					local eventName = event[1]
					local tick = event[2]
					local tickDiff = tick - prev.tick

					-- delta time
					assert(tickDiff >= 0)
					if tickDiff ~= 0 then
						local tickMML = tickToMML(tickDiff)
						if noteInfo then
							table.insert(mmlArray, string.format("%s%s", noteInfo.noteMML, tickMML))
							-- NES/GB noise and DPCM has a problem with tie (&)
							--   for instance, c4&c4 doesn't work well.
							--   c4&4 works well, but it is problematic when
							--   you want to use something like c4&@v10c4 .
							-- Real NES RP2A03 doesn't need tie for them, though.
							-- Therefore, omit ties for these channels for now.
							if needsTie(flmmlPatchCmd) then
								table.insert(mmlArray, "&")
								prev.slurEventIndex = #mmlArray
							end
						else
							-- eliminate slur
							if prev.slurEventIndex then
								mmlArray[prev.slurEventIndex] = ""
								prev.slurEventIndex = nil
							end
							table.insert(mmlArray, string.format("r%s", tickMML))
						end

--						prev.tickChangeEventIndex = #mmlArray + 1
--						prev.tickHasNote = false
					end
					prev.tick = tick

					if eventName == 'end_track' then
						-- do nothing
					elseif eventName == 'set_tempo' then
						-- 1 tick := (1/framerate)[sec]
						local framerate = 60000000.0 / event[3]
						local mmlBPM = MML_TICK_MUL * 60 * framerate / self.FLMML_TPQN
						table.insert(mmlArray, string.format("T%.2f", mmlBPM))
					elseif eventName == 'volume_change' then
						table.insert(mmlArray, string.format("@X%d", event[4]))
					elseif eventName == 'panpot_change' then
						table.insert(mmlArray, string.format("@P%d", event[4]))
					elseif eventName == 'pitch_wheel_change' then
						table.insert(mmlArray, string.format("@D%d", event[4]))
					elseif eventName == 'patch_change' then
						flmmlPatchCmd = self:getFlMMLPatchCmd(event[5], event[4])
						table.insert(mmlArray, flmmlPatchCmd)
					elseif eventName == 'note_on' and event[5] ~= 0 then
						-- assert: next event has different tick, no events left at this time
						if eventIndex >= #score or tick >= score[eventIndex + 1][2] then
							error("FlMML conversion: unsupported event order, note on must be last.")
						end
						local nextTick = score[eventIndex + 1][2]

						-- register note info
						local oct, scale = getOctaveAndScale(event[4])
						local octMML, noteMML = keyToMML(event[4])
						noteInfo = { tick = event[2], midikey = event[4], velocity = event[5], octMML = octMML, noteMML = noteMML }
						-- omit octave command
						if oct == prev.oct then
							octMML = ""
						end

						-- write note command
						local noteTickDiff = nextTick - tick
						table.insert(mmlArray, string.format("%s%s%s", octMML, noteMML, tickToMML(noteTickDiff)))
						if needsTie(flmmlPatchCmd) then
							table.insert(mmlArray, "&")
							prev.slurEventIndex = #mmlArray
						end
						prev.tick = nextTick -- cancel next tick diff event

--						local octMML, noteMML = keyToMML(event[4])
--						noteInfo = { index = #mmlArray + 1, tick = event[2], tickTie = event[2], midikey = event[4], velocity = event[5], octMML = octMML, noteMML = noteMML }
--						prev.tickHasNote = true
					elseif eventName == 'note_off' or (eventName == 'note_on' and event[5] == 0) then
--						table.insert(mmlArray, noteInfo.index, noteInfo.octMML .. noteInfo.noteMML .. tickToMML(tick - noteInfo.tickTie))
						noteInfo = nil
					else
						--table.insert(mmlArray, "\n/* " .. event[1] .. " */\n")
						print(string.format("FlMML conversion: unsupported event '%s'", event[1]))
					end
				end
				table.insert(mmlArray, ";\n")

				-- close note tie
				if prev.slurEventIndex then
					mmlArray[prev.slurEventIndex] = ""
					prev.slurEventIndex = nil
				end

				-- mml join
				mml = mml .. "@E1,0,0,180,0Q16"
				for mmlPartIndex, mmlPart in ipairs(mmlArray) do
					mml = mml .. mmlPart
				end
			end
			mml = mml .. self:getFlMMLWaveformDef()
			return mml
		end;

		-- get score for FlMML conversion
		-- @return string score array
		getFlMMLScore = function(self)
			local mmlscore = {}

			-- global events
			if self.scoreGlobal then
				table.insert(mmlscore, self:scoreAddEndOfTrack(self.scoreGlobal))
			end

			-- channel events
			if self.scoreChannel then
				for chIndex, score in ipairs(self.scoreChannel) do
					local channelNumber = chIndex - 1
					local mscore = self:scoreRemoveDuplicatedEvent(self:scoreConvertToFlMML(self:scoreBuildNote(self:scoreAddEndOfTrack(score))))
					table.insert(mmlscore, mscore)
				end
			end

			return mmlscore
		end;

		-- get MIDI TPQN (integer)
		getTPQN = function(self)
			return 60
		end;

		-- get MIDI score
		-- @return string score array for MIDI.lua
		getMidiScore = function(self)
			local midiscore = {}

			-- global events
			if self.scoreGlobal then
				table.insert(midiscore, self:scoreAddEndOfTrack(self.scoreGlobal))
			end

			-- channel events
			if self.scoreChannel then
				for chIndex, score in ipairs(self.scoreChannel) do
					local channelNumber = chIndex - 1
					local mscore = self:scoreRemoveDuplicatedEvent(self:scoreConvertToMidi(self:scoreBuildNote(self:scoreAddEndOfTrack(score))))
					table.insert(mscore, 1, { 'control_change', 0, channelNumber, 101, 0 })
					table.insert(mscore, 2, { 'control_change', 0, channelNumber, 100, 0 })
					table.insert(mscore, 3, { 'control_change', 0, channelNumber, 6, self.MIDI_PITCHBEND_RANGE })
					table.insert(midiscore, mscore)
				end
			end

			return { self:getTPQN(), unpack(midiscore) }
		end;

		-- get readable text format of score (debug function)
		-- @param score target to convert
		getScoreText = function(self, score)
			local str = ""
			for i, event in ipairs(score) do
				for j, v in ipairs(event) do
					if j > 1 then
						str = str .. "\t"
					end
					str = str .. tostring(v)
				end
				str = str .. "\n"
			end
			return str
		end;

		-- write FlMML text to file
		-- @param string filename output filename
		writeFlMMLFile = function(self, filename)
			local file = assert(io.open(filename, "w"))
			file:write(self:getFlMML(self))
			file:close()
		end;

		-- write MIDI data to file
		-- @param string filename output filename
		writeMidiFile = function(self, filename)
			local MIDI = require("MIDI")
			local file = assert(io.open(filename, 'wb'))
			file:write(MIDI.score2midi(self:getMidiScore()))
			file:close()
		end;

		-- write readable text to file (debug function)
		-- @param string filename output filename
		writeTextFile = function(self, filename)
			local file = assert(io.open(filename, "w"))

			-- channel events
			for chIndex, score in ipairs(self.scoreChannel) do
				file:write(string.format("/* Channel %d */\n", chIndex - 1))

				local modscore = self:scoreRemoveDuplicatedEvent(self:scoreBuildNote(self:scoreAddEndOfTrack(score)))
				file:write(self:getScoreText(modscore))
				file:write("\n")
			end

			-- global events
			file:write("/* Global */\n")
			file:write(self:getScoreText(self.scoreGlobal))
			file:write("\n")

			-- wavetable table
			for waveChannelType, waveList in pairs(self.waveformList) do
				file:write(string.format("/* Waveform (%s) */\n", waveChannelType))
				for waveIndex, waveValue in ipairs(waveList) do
					file:write(waveIndex .. "\t" .. waveValue .. "\n")
				end
				file:write("\n")
			end

			file:close()
		end;

		-- event conversion: convert patch event for MIDI
		-- @param source 'patch_change' event
		eventPatchToMidi = function(self, event)
			return { { 'patch_change', event[2], event[3], event[4] } }
		end;

		-- score manipulation: add end of track
		-- @param score manipulation target
		scoreAddEndOfTrack = function(self, scoreIn)
			local score = {}
			for i, eventIn in ipairs(scoreIn) do
				local event = {}
				for j, v in ipairs(eventIn) do
					event[j] = v
				end
				table.insert(score, event)
			end
			table.insert(score, { 'end_track', self.tick })
			return score
		end;

		-- score manipulation: remove duplicated events
		-- @param score manipulation target
		scoreRemoveDuplicatedEvent = function(self, scoreIn)
			local score = {}
			local prev = {}
			for i, eventIn in ipairs(scoreIn) do
				if eventIn[1] == 'control_change' or eventIn[1] == 'volume_change' or eventIn[1] == 'panpot_change' or eventIn[1] == 'pitch_wheel_change' or eventIn[1] == 'absolute_pitch_change' then
					local name = eventIn[1]
					local value = eventIn[4]
					if name == 'control_change' then
						name = name .. string.format("-%d", eventIn[4])
						value = eventIn[5]
					end

					if value == prev[name] then
						eventIn = nil
					else
						prev[name] = value
					end
				end

				if eventIn ~= nil then
					local event = {}
					for j, v in ipairs(eventIn) do
						event[j] = v
					end
					table.insert(score, event)
				end
			end
			return score
		end;

		-- score manipulation: build note from volume and pitch
		-- @param score manipulation target
		scoreBuildNote = function(self, scoreIn)
			-- find event by name
			-- @return number event index, nil if not found
			local findEventByName = function(events, eventName)
				for i = #events, 1, -1 do
					local eventIn = events[i]
					if eventIn[1] == eventName then
						return i
					end
				end
				return nil
			end
			-- add note off event
			local addNoteOffEvent = function(events, tick, channelNumber, noteNumber, lastEvent)
				local indexLast = #events + 1
				if findEventByName(events, 'end_track') then
					indexLast = #events
				end
				table.insert(events, lastEvent and indexLast or 1, { 'note_off', tick, channelNumber, noteNumber, 0 })
			end
			-- add note on event
			local addNoteOnEvent = function(events, tick, channelNumber, noteNumber, velocity)
				local indexLast = #events + 1
				if findEventByName(events, 'end_track') then
					indexLast = #events
				end
				table.insert(events, indexLast, { 'note_on', tick, channelNumber, noteNumber, velocity })
			end
			-- remove specified event
			local removeEvent = function(events, eventName)
				for i = #events, 1, -1 do
					local event = events[i]
					if event[1] == eventName then
						table.remove(events, i)
					end
				end
			end
			-- replace specified event value
			local replaceEventValue = function(events, eventName, value)
				local eventIndex = findEventByName(events, eventName)
				if eventIndex then
					local eventIn = events[eventIndex]
					local event = {}
					for j, v in ipairs(eventIn) do
						event[j] = v
					end
					event[4] = value
					events[eventIndex] = event
				end
			end
			-- add absolute pitch event to note, if there is not
			local addPitchToNoteIfNeeded = function(events, absPitchEvent)
				if absPitchEvent == nil then
					return
				end
				assert(absPitchEvent[1] == 'absolute_pitch_change')

				-- if pitch event already exists, do not add more
				local eventIndex = findEventByName(events, 'absolute_pitch_change')
				if eventIndex then
					return
				end

				-- position needs to be before note on
				eventIndex = findEventByName(events, 'note_on')
				if eventIndex == nil then
					eventIndex = #events + 1
				end

				-- insert event
				local event = {}
				for j, v in ipairs(absPitchEvent) do
					event[j] = v
				end
				table.insert(events, eventIndex, event)
			end
			-- convert pitch bend absolute to relative
			local pitchAbsToRel = function(events, noteNumber)
				for i = #events, 1, -1 do
					local event = events[i]
					if event[1] == 'absolute_pitch_change' then
						if noteNumber ~= nil then
							local relPitch = event[4] - noteNumber
							events[i] = { 'pitch_wheel_change', event[2], event[3], relPitch }
						else
							table.remove(events, i)
						end
					end
				end
			end

			local score = {}
			local eventIndex = 1
			local prev = { tick = 0 }
			local channelNumber = nil
			local lastAbsPitchEvent = nil
			while eventIndex <= #scoreIn do
				local curr = {}
				local new_ = {}

				-- collect events at the same timing
				local events = { scoreIn[eventIndex] }
				curr.tick = scoreIn[eventIndex][2]
				while (eventIndex + 1) <= #scoreIn and scoreIn[eventIndex + 1][2] == curr.tick do
					eventIndex = eventIndex + 1
					table.insert(events, scoreIn[eventIndex])
				end

				-- get new volume/pitch, remove duplicated events (reverse order)
				-- channelNumber = nil
				for i = #events, 1, -1 do
					local event = events[i]
					if event[1] == 'volume_change' or event[1] == 'absolute_pitch_change' then
						if channelNumber == nil then
							channelNumber = event[3]
						else
							assert(channelNumber == event[3])
						end

						if event[1] == 'volume_change' then
							if new_.volume == nil then
								new_.volume = event[4]
							else
								table.remove(events, i)
							end
						elseif event[1] == 'absolute_pitch_change' then
							if new_.midikey == nil then
								new_.midikey = event[4]
								lastAbsPitchEvent = { unpack(event) }
							else
								table.remove(events, i)
							end
						end
					elseif event[1] == 'pitch_wheel_change' then
						error("relative pitch event is not supported.")
					end
				end
				-- set current volume/pitch value
				curr.volume = new_.volume or prev.volume
				curr.midikey = new_.midikey or prev.midikey
				curr.noteNumber = prev.noteNumber

				-- note on/off detection main
				local requireNoteOff = false
				local requireNoteOn = false
				if curr.volume and curr.volume ~= 0 then
					if prev.volume and prev.volume ~= 0 then
						local pitchDiff = math.abs(curr.midikey - prev.midikey)
						local volumeDistance = curr.volume - prev.volume
						if pitchDiff > 0 then
							if pitchDiff >= self.NOTE_PITCH_THRESHOLD then
								local nextNoteNumber = self.round(curr.midikey)
								if nextNoteNumber ~= prev.noteNumber then
									-- new note! (frequency changed)
									requireNoteOff = true
									requireNoteOn = true
								end
							end
						end
						if volumeDistance > 0 and volumeDistance >= self.NOTE_VOLUME_THRESHOLD then
							-- new note! (volume up)
							requireNoteOff = true
							requireNoteOn = true
						end
						prev.midikey = curr.midikey
					else
						-- new note! (from volume 0)
						requireNoteOn = true
					end
				else
					if prev.volume and prev.volume ~= 0 then
						-- end of note
						requireNoteOff = true
						removeEvent(events, 'volume_change')
					else
						-- no sound / rest before the first note
						removeEvent(events, 'volume_change')
					end
				end
				if requireNoteOff then
					addNoteOffEvent(events, curr.tick, channelNumber, prev.noteNumber)
					if not requireNoteOn then
						prev.noteNumber = nil
					end
					--removeEvent(events, 'volume_change')
				end
				if requireNoteOn then
					curr.noteNumber = self.round(curr.midikey)
					addNoteOnEvent(events, curr.tick, channelNumber, curr.noteNumber, self.NOTE_VELOCITY)
					prev.noteNumber = curr.noteNumber

					-- add possibly missing relative pitch event
					-- we need to duplicate pitch event when the situation is like the following:
					--   note on -> raise pitch quite slowly (note continues) -> volume down -> volume up ("new note" detected here)
					-- at the "new note" timing, there is no pitch event, because pitch doesn't changed from the previous tick.
					-- however, we need a new one because we will use "relative" pitch change event,
					-- and the "base key" for the relative pitch gets changed at the new note, even though the frequency doesn't change.
					-- anyway, we need a dirty fix here.
					lastAbsPitchEvent[2] = curr.tick
					addPitchToNoteIfNeeded(events, lastAbsPitchEvent)

					-- pitch bend remove hack
					if math.abs(curr.midikey - curr.noteNumber) < self.NOTE_PITCH_STRIP_THRESHOLD then
						-- set pitch=0, duplication remover will clean up them :)
						replaceEventValue(events, 'absolute_pitch_change', curr.noteNumber)
						lastAbsPitchEvent[4] = curr.noteNumber
					end
				end

				-- update status
				prev.midikey = curr.midikey
				prev.volume = curr.volume

				-- convert pitch bend absolute to relative
				pitchAbsToRel(events, curr.noteNumber)

				-- finally...
				if eventIndex == #scoreIn then
					-- add missing note off
					if prev.noteNumber then
						addNoteOffEvent(events, curr.tick, channelNumber, prev.noteNumber, true)
						prev.noteNumber = nil
					end
				end

				-- copy the modified events to output score
				for i, eventIn in ipairs(events) do
					local event = {}
					for j, v in ipairs(eventIn) do
						event[j] = v
					end
					table.insert(score, event)
				end

				eventIndex = eventIndex + 1
			end
			return score
		end;

		-- score manipulation: convert to FlMML compatible score
		-- @param score manipulation target
		scoreConvertToFlMML = function(self, scoreIn)
			local score = {}
			local patchType = nil
			for i, event in ipairs(scoreIn) do
				if event[1] == 'volume_change' then
					local value = event[4]
					assert(value >= 0.0 and value <= 1.0)

					event = { 'volume_change', event[2], event[3], self.round(value * 127) }
					table.insert(score, event)
				elseif event[1] == 'panpot_change' then
					local value = event[4]
					assert(value >= 0.0 and value <= 1.0)

					event = { 'panpot_change', event[2], event[3], self.round(value * 126) + 1 }
					table.insert(score, event)
				elseif event[1] == 'pitch_wheel_change' then
					local value = event[4]
					event = { 'pitch_wheel_change', event[2], event[3], self.round(100 * value) }
					table.insert(score, event)
				elseif event[1] == 'patch_change' then
					patchType = event[5]
					table.insert(score, event)
				elseif event[1] == 'note_on' then
					event = { 'note_on', event[2], event[3], self:getFlMMLNoteNumber(event[4], patchType), event[5] }
					table.insert(score, event)
				elseif event[1] == 'note_off' then
					event = { 'note_off', event[2], event[3], self:getFlMMLNoteNumber(event[4], patchType), event[5] }
					table.insert(score, event)
				elseif event[1] == 'absolute_pitch_change' then
					error("'absolute_pitch_change' need to be converted before scoreConvertToFlMML.")
				else
					table.insert(score, event)
				end
			end
			return score
		end;

		-- score manipulation: convert to MIDI compatible event
		-- @param score manipulation target
		scoreConvertToMidi = function(self, scoreIn)
			local score = {}
			for i, event in ipairs(scoreIn) do
				if event[1] == 'patch_change' then
					local patchEvents = self:eventPatchToMidi(event)
					for j, patchEvent in ipairs(patchEvents) do
						table.insert(score, patchEvent)
					end
				elseif event[1] == 'volume_change' then
					local value = event[4]
					assert(value >= 0.0 and value <= 1.0)

					if not self.MIDI_LINEAR_CONVERSION then
						-- gain[dB] = 40 * log10(cc7/127) 
						value = math.sqrt(value)
					end

					event = { 'control_change', event[2], event[3], 7, self.round(value * 127) }
					table.insert(score, event)
				elseif event[1] == 'panpot_change' then
					local value = event[4]
					assert(value >= 0.0 and value <= 1.0)

					-- TODO: decent panpot curve
					if not self.MIDI_LINEAR_CONVERSION then
						-- GM2 recommended formula:
						-- Left Channel Gain [dB] = 20*log(cos(PI/2*max(0,cc#10-1)/126)) 
						-- Right Channel Gain [dB] = 20*log(sin(PI/2*max(0,cc#10-1)/126))
					end

					event = { 'control_change', event[2], event[3], 10, self.round(value * 126) + 1 }
					table.insert(score, event)
				elseif event[1] == 'pitch_wheel_change' then
					local value = event[4]

					if value < -self.MIDI_PITCHBEND_RANGE or value > self.MIDI_PITCHBEND_RANGE then
						print(string.format("Warning: pitch bend range overflow <%f> cent at tick <%d> channel <%d>.", value * 100, event[2], event[3]))
						value = math.min(self.MIDI_PITCHBEND_RANGE, math.max(-self.MIDI_PITCHBEND_RANGE, value))
					end

					event = { 'pitch_wheel_change', event[2], event[3], math.min(self.round(value / self.MIDI_PITCHBEND_RANGE * 8192), 8191) }
					table.insert(score, event)
				elseif event[1] == 'note_off' then
					event = { 'note_on', event[2], event[3], event[4], 0 }
					table.insert(score, event)
				elseif event[1] == 'absolute_pitch_change' then
					error("'absolute_pitch_change' need to be converted before scoreConvertToMidi.")
				else
					table.insert(score, event)
				end
			end
			return score
		end;

		-- static gbNoiseFreqRegToNote
		-- @param number noise frequency (Hz)
		-- @return number FlMML compatible noise note number
		gbNoiseFreqRegToNote = function(freq)
			local flmmlGbNoiseLookup = {
				0x000002, 0x000004, 0x000008, 0x00000c, 0x000010, 0x000014, 0x000018, 0x00001c,
				0x000020, 0x000028, 0x000030, 0x000038, 0x000040, 0x000050, 0x000060, 0x000070,
				0x000080, 0x0000a0, 0x0000c0, 0x0000e0, 0x000100, 0x000140, 0x000180, 0x0001c0,
				0x000200, 0x000280, 0x000300, 0x000380, 0x000400, 0x000500, 0x000600, 0x000700,
				0x000800, 0x000a00, 0x000c00, 0x000e00, 0x001000, 0x001400, 0x001800, 0x001c00,
				0x002000, 0x002800, 0x003000, 0x003800, 0x004000, 0x005000, 0x006000, 0x007000,
				0x008000, 0x00a000, 0x00c000, 0x00e000, 0x010000, 0x014000, 0x018000, 0x01c000,
				0x020000, 0x028000, 0x030000, 0x038000, 0x040000, 0x050000, 0x060000, 0x070000
			}

			-- search in table
			for index, targetFreq in ipairs(flmmlGbNoiseLookup) do
				if freq == targetFreq then
					return index - 1
				end
			end

			error(string.format("illegal gameboy noise frequency value 0x%06x", freq))
		end;

		-- static nesNoiseFreqToNote
		-- @param number noise frequency (Hz)
		-- @return number FlMML compatible noise note number
		nesNoiseFreqToNote = function(freq)
			local flmmlNESNoiseLookup = {
				0x002, 0x004, 0x008, 0x010, 0x020, 0x030, 0x040, 0x050,
				0x065, 0x07f, 0x0be, 0x0fe, 0x17d, 0x1fc, 0x3f9, 0x7f2
			}

			-- search in table (search the nearest one)
			local bestDiff = math.huge
			local bestIndex = 1
			for index, targetFreqReg in ipairs(flmmlNESNoiseLookup) do
				local targetFreq = 1789772.5 / targetFreqReg
				local diff = math.abs(freq - targetFreq)
				if diff < bestDiff then
					bestIndex = index
					bestDiff = diff
				else
					break
				end
			end

			return bestIndex - 1
		end;

		-- static gbNoiseFreqToNote
		-- @param number noise frequency register value
		-- @return number FlMML compatible noise note number
		gbNoiseFreqToNote = function(freq)
			local flmmlGbNoiseLookup = {
				0x000002, 0x000004, 0x000008, 0x00000c, 0x000010, 0x000014, 0x000018, 0x00001c,
				0x000020, 0x000028, 0x000030, 0x000038, 0x000040, 0x000050, 0x000060, 0x000070,
				0x000080, 0x0000a0, 0x0000c0, 0x0000e0, 0x000100, 0x000140, 0x000180, 0x0001c0,
				0x000200, 0x000280, 0x000300, 0x000380, 0x000400, 0x000500, 0x000600, 0x000700,
				0x000800, 0x000a00, 0x000c00, 0x000e00, 0x001000, 0x001400, 0x001800, 0x001c00,
				0x002000, 0x002800, 0x003000, 0x003800, 0x004000, 0x005000, 0x006000, 0x007000,
				0x008000, 0x00a000, 0x00c000, 0x00e000, 0x010000, 0x014000, 0x018000, 0x01c000,
				0x020000, 0x028000, 0x030000, 0x038000, 0x040000, 0x050000, 0x060000, 0x070000
			}

			-- search in table (search the nearest one)
			local bestDiff = math.huge
			local bestIndex = 1
			for index, targetFreqReg in ipairs(flmmlGbNoiseLookup) do
				local targetFreq = 1048576.0 / targetFreqReg
				local diff = math.abs(freq - targetFreq)
				if diff < bestDiff then
					bestIndex = index
					bestDiff = diff
				else
					break
				end
			end

			return bestIndex - 1
		end;
	}

	self:clear()
	return self
end
