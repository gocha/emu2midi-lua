emu2midi-lua
============

EmuLua scripts for recording retro game sound to MIDI file and/or [FlMML](http://flmml.codeplex.com/).

Lineups
-------

- gb2midi: Gameboy sound. Use [VBA-RR](https://code.google.com/p/vba-rerecording/) *V23* (V24 does not work) to run.
- nes2midi: NES sound (no extra chip support). Use [FCEUX](http://www.fceux.com) to run.
- pce2midi: PC-Engine (TurboGrafx-16) sound. Use [PCEjin](https://code.google.com/p/pcejin/) to run.

Limitations
-----------

- Time resolution of conversion is 1/60 seconds. Some sound effects may sound strange because of it.
