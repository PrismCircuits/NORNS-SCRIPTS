// Engine_Loam
// 8 tracks of pure-synthesis drums, subtractive synth, 2-op fm and sample playback.
// every voice -> its track bus -> track insert fx (drive, crush, dj filter, pan, sends)
// -> master bus -> delay + reverb returns -> dj filter -> compressor -> limiter -> out

Engine_Loam : CroneEngine {
	var mixBus, dlyBus, revBus, trackBus;
	var voiceGroup, fxGroup, trackGroups, chokeGroups, chokeSub;
	var trackFx, master, returns, colorGroup, colorFx, fxState, returnsOff;
	var trackParams, voiceDefs, buffers, voices;
	classvar maxVoices = 6;   // per track; the oldest voice fades out when a 7th starts

	*new { arg context, doneCallback;
		^super.new(context, doneCallback);
	}

	alloc {
		var s = context.server;

		// shared voice output: choke gate + velocity, mono voices go to both channels
		var finish = { |sig|
			var c = EnvGen.ar(Env.asr(0, 1, 0.015, \sin), \gate.kr(1), doneAction: 2);
			Out.ar(\out.kr(0), (sig * \vel.kr(1) * c) ! 2);
		};
		// drums: decays follow their knobs live, so free the voice when it falls silent
		var finishDrum = { |sig|
			DetectSilence.ar(sig, 0.0001, 0.05, doneAction: 2);
			finish.(sig);
		};
		// seconds since the voice started, and a live exponential decay (-60 dB at `dec` seconds)
		var age = { Sweep.ar(0, 1) };
		var expDec = { |dec, t| exp((t * -6.9) / dec.max(0.001)) };
		var attack = { |a, t| (t / a).min(1) };
		var finishStereo = { |sig|
			var c = EnvGen.ar(Env.asr(0, 1, 0.015, \sin), \gate.kr(1), doneAction: 2);
			Out.ar(\out.kr(0), sig * \vel.kr(1) * c);
		};
		// `type` is a plain integer: each synth/sample SynthDef is built once per filter type,
		// so a voice runs only the one filter it needs (much lighter on the norns CPU)
		var oneFilter = { |sig, type, cutoff, res|
			var rq = (1 - (res * 0.95)).max(0.05);
			var cf = cutoff.clip(20, 18000);
			[RLPF, RHPF, BPF, BRF][type].ar(sig, cf, rq);
		};

		// ---------------------------------------------------------------- drums

		SynthDef(\loam_kick, { |kick_tune=48, kick_sweep=0.5, kick_stime=0.05, kick_decay=0.5, kick_click=0.3, kick_drive=0.2|
			var t = age.();
			var penv = exp((t * -4.6) / kick_stime.max(0.001));
			var freq = kick_tune * (1 + (kick_sweep * 7 * penv));
			var body = SinOsc.ar(freq, 0.5pi) * attack.(0.002, t) * expDec.(kick_decay, t);
			var click = HPF.ar(WhiteNoise.ar, 3000) * EnvGen.ar(Env.perc(0.0005, 0.008)) * kick_click;
			var sig = body + click;
			sig = XFade2.ar(sig, (sig * (1 + (kick_drive * 10))).tanh, (kick_drive * 2) - 1);
			finishDrum.(sig);
		}).add;

		SynthDef(\loam_snare, { |snare_tune=185, snare_decay=0.15, snare_snappy=0.7, snare_sdecay=0.22, snare_color=2500|
			var t = age.();
			var pe = EnvGen.kr(Env([1.25, 1], [0.03]));
			var body = (LFTri.ar(snare_tune * pe) + (LFTri.ar(snare_tune * 1.84 * pe) * 0.5));
			var nz = HPF.ar(WhiteNoise.ar, snare_color);
			var sig;
			body = body * attack.(0.001, t) * expDec.(snare_decay, t) * (1 - (snare_snappy * 0.4));
			nz = nz * attack.(0.001, t) * expDec.(snare_sdecay, t) * snare_snappy;
			sig = (body * 0.7) + nz;
			finishDrum.(sig);
		}).add;

		SynthDef(\loam_clap, { |clap_tone=1200, clap_spread=0.011, clap_decay=0.25|
			var t = age.();
			var sp = clap_spread * 0.95;
			// the three hand claps are timed at the hit; the tail decay follows its knob live
			var bursts = EnvGen.ar(Env(
				[0, 1, 0.05, 1, 0.05, 1, 0.05, 0],
				[0.0005, sp, 0.0005, sp, 0.0005, sp, 0.0005],
				[0, -4, 0, -4, 0, -4, 0]));
			var tailStart = clap_spread * 3;
			var tail = (t >= tailStart) * 0.8 * expDec.(clap_decay, (t - tailStart).max(0));
			var sig = HPF.ar(BPF.ar(WhiteNoise.ar, clap_tone, 0.6), 400) * 2.5 * (bursts + tail);
			finishDrum.(sig);
		}).add;

		SynthDef(\loam_hat, { |hat_tune=40, hat_color=10000, hat_decay=0.06, hat_noise=0.2|
			var t = age.();
			var ratios = [2, 3, 4.16, 5.43, 6.79, 8.21];
			var metal = Mix(ratios.collect({ |r| Pulse.ar(hat_tune * r) })) * 0.2;
			var sig = metal + (WhiteNoise.ar * hat_noise * 0.5);
			sig = HPF.ar(BPF.ar(sig, hat_color, 0.8), hat_color * 0.7) * 12;
			sig = sig * attack.(0.001, t) * expDec.(hat_decay, t);
			finishDrum.(sig);
		}).add;

		SynthDef(\loam_tom, { |tom_tune=110, tom_sweep=0.5, tom_decay=0.45, tom_noise=0.15|
			var t = age.();
			var penv = exp((t * -3) / (tom_decay * 0.6).max(0.001));
			var freq = tom_tune * (1 + (tom_sweep * penv));
			var sig = SinOsc.ar(freq) * attack.(0.002, t) * expDec.(tom_decay, t);
			sig = sig + (LPF.ar(WhiteNoise.ar, tom_tune * 4) * EnvGen.ar(Env.perc(0.001, 0.04)) * tom_noise);
			finishDrum.(sig);
		}).add;

		SynthDef(\loam_rim, { |rim_tune=1700, rim_decay=0.035, rim_body=0.5|
			var t = age.();
			var sig = LFTri.ar(rim_tune) + (Pulse.ar(rim_tune * 0.47) * rim_body * 0.6);
			sig = HPF.ar(sig, 600) * attack.(0.0005, t) * expDec.(rim_decay, t);
			sig = sig + (BPF.ar(WhiteNoise.ar, rim_tune, 0.5) * EnvGen.ar(Env.perc(0.0002, 0.006)) * 1.5);
			finishDrum.(sig * 0.8);
		}).add;

		SynthDef(\loam_bell, { |bell_tune=540, bell_ratio=1.48, bell_tone=2640, bell_decay=0.35|
			var t = age.();
			var sig = (Pulse.ar(bell_tune) + Pulse.ar(bell_tune * bell_ratio)) * 0.3;
			// fast initial drop to 25%, then a tail that follows the DECAY knob live
			var amp = attack.(0.001, t) * ((0.75 * expDec.(0.04, t)) + (0.25 * expDec.(bell_decay, t)));
			sig = BPF.ar(sig, bell_tone, 0.4) * 4 * amp;
			finishDrum.(sig);
		}).add;

		// ---------------------------------------------------------------- synths

		4.do({ |ft|
			SynthDef(("loam_synth_" ++ ft).asSymbol, { |dur=0.2, synth_note=36, synth_wave=2, synth_pw=0.5, synth_det=7,
				synth_osc2=0.5, synth_sub=0.3, synth_ftype=0, synth_cutoff=800, synth_res=0.3,
				synth_fenv=0.5, synth_fdec=0.25, synth_atk=0.003, synth_dec=0.2, synth_sus=0.5,
				synth_rel=0.2, synth_lrate=3, synth_ldepth=0, synth_lshape=0, synth_ldest=1|
				var gateSig = Trig1.kr(Impulse.kr(0), dur);
				var lfo = Select.kr(synth_lshape, [
					SinOsc.kr(synth_lrate), LFTri.kr(synth_lrate), LFSaw.kr(synth_lrate),
					(LFPulse.kr(synth_lrate) * 2) - 1, LFNoise0.kr(synth_lrate)]) * synth_ldepth;
				var lPitch = lfo * (synth_ldest < 0.5);
				var lCut = lfo * ((synth_ldest > 0.5) * (synth_ldest < 1.5));
				var lAmp = lfo * ((synth_ldest > 1.5) * (synth_ldest < 2.5));
				var lPan = lfo * (synth_ldest > 2.5);
				var freq = (synth_note + (lPitch * 12)).midicps;
				var f2 = freq * (synth_det / 100).midiratio;
				var o1 = Select.ar(synth_wave, [SinOsc.ar(freq), LFTri.ar(freq), Saw.ar(freq), Pulse.ar(freq, synth_pw), WhiteNoise.ar]);
				var o2 = Select.ar(synth_wave, [SinOsc.ar(f2), LFTri.ar(f2), Saw.ar(f2), Pulse.ar(f2, synth_pw), WhiteNoise.ar]);
				var sub = Pulse.ar(freq * 0.5) * synth_sub;
				// attack/release envelope x a decay toward the live SUSTAIN level
				var arEnv = EnvGen.ar(Env.asr(synth_atk, 1, synth_rel, -4), gateSig, doneAction: 2);
				var decEnv = EnvGen.ar(Env([1, 1, 0], [synth_atk, synth_dec], [0, -4]));
				var aenv = arEnv * (synth_sus + ((1 - synth_sus) * decEnv));
				var fenv = EnvGen.kr(Env.perc(0.002, synth_fdec));
				var cf = synth_cutoff * (2 ** ((fenv * synth_fenv * 5) + (lCut * 3)));
				var sig = (o1 + (o2 * synth_osc2) + sub) * 0.7;
				sig = oneFilter.(sig, ft, cf, synth_res);
				sig = sig * aenv * (1 + lAmp).max(0);
				finishStereo.(Pan2.ar(sig, lPan.clip(-1, 1)));
			}).add;
		});

		SynthDef(\loam_fm, { |fm_note=60, fm_ratio=2, fm_index=2, fm_ienv=0.5, fm_fb=0, fm_atk=0.002, fm_decay=0.6|
			var t = age.();
			var freq = fm_note.midicps;
			var ienv = attack.(0.001, t) * expDec.((fm_decay * fm_ienv).max(0.005), t);
			var mod = SinOscFB.ar(freq * fm_ratio, fm_fb) * freq * fm_ratio * fm_index * ienv;
			var env = attack.(fm_atk.max(0.0005), t) * expDec.(fm_decay, t);
			finishDrum.(SinOsc.ar(freq + mod) * env * 0.6);
		}).add;

		4.do({ |ft|
			SynthDef(("loam_sample_" ++ ft).asSymbol, { |buf=0, dur=0.2, smp_pitch=0, smp_start=0, smp_end=1, smp_rev=0, smp_mode=0,
				smp_atk=0.002, smp_rel=0.05, smp_ftype=0, smp_cutoff=18000, smp_res=0.1|
				var frames = BufFrames.kr(buf);
				var bufSR = BufSampleRate.kr(buf);
				var s0 = min(smp_start, smp_end) * frames;
				var s1 = max(smp_start, smp_end) * frames;
				var ratio = smp_pitch.midiratio;
				var dir = 1 - (smp_rev * 2);
				var startPos = Select.kr(smp_rev, [s0, s1]);
				// plain buffer player; PITCH follows its knob live
				var raw = PlayBuf.ar(1, buf, BufRateScale.kr(buf) * ratio * dir, 1, startPos, 0);
				// play position, only used to know when END is reached (END is live too)
				var pos = startPos + Sweep.ar(0, bufSR * ratio * dir);
				var remain = Select.ar(smp_rev, [K2A.ar(s1) - pos, pos - K2A.ar(s0)]);
				// ZERO-CROSSING GATE: no fades on the sound itself.
				// a hit opens at the first zero crossing, and closes at the first zero crossing after
				// it reaches END or is cut (choke / voice limit). 30 ms safety cut if it never crosses zero.
				var zc = ((HPZ1.ar(raw >= 0).abs > 0) + (raw.abs < 0.0005)) > 0;
				var stopReq = ((remain <= 0) + (1 - \gate.kr(1))) > 0;
				var stopNow = ((stopReq * zc) + DelayN.ar(stopReq, 0.03, 0.03)) > 0;
				var opened = SetResetFF.ar(zc, 0);
				var closed = SetResetFF.ar(stopNow, 0);
				// your ATTACK / RELEASE: GATE mode releases as a tail after the gate;
				// ONESHOT fades out over RELEASE so it reaches silence at END
				var gateSig = Select.kr(smp_mode, [DC.kr(1), Trig1.kr(Impulse.kr(0), dur)]);
				var env = EnvGen.ar(Env([0, 1, 0], [smp_atk, smp_rel], [0, -4], 1), gateSig, doneAction: 2);
				// slew-limited so moving END behind the play position can't make it jump: the gate closes it instead
				var endFade = Slew.ar(Select.ar(smp_mode, [((remain / (bufSR * ratio)) / smp_rel.max(0.001)).clip(0, 1), DC.ar(1)]), 1000, 50);
				var sig = raw * opened * (1 - closed) * endFade;
				FreeSelf.kr(DelayN.kr(A2K.kr(closed), 0.05, 0.05));
				sig = oneFilter.(sig, ft, smp_cutoff, smp_res);
				Out.ar(\out.kr(0), (sig * env * \vel.kr(1)) ! 2);
			}).add;
		});

		// ---------------------------------------------------------------- fx

		// optional per-track colour insert: only exists while DRIVE / BITS / S.RATE / FILTER are away from neutral
		SynthDef(\loam_trackcolor, { |bus=0, drive=0, bits=16, srate=48000, filter=0|
			var sig = In.ar(bus, 2);
			var f = Lag.kr(filter, 0.05);
			sig = XFade2.ar(sig, (sig * (1 + (drive * 20))).tanh * 0.7, (drive * 2) - 1);
			// rate reduction; bypassed at full rate (an Impulse at the sample rate never fires)
			sig = Select.ar(srate < (SampleRate.ir * 0.99), [sig, Latch.ar(sig, Impulse.ar(srate))]);
			sig = sig.round(0.5 ** (bits - 1));
			sig = LPF.ar(sig, (20000 * (2 ** (f.min(0) * 9))).clip(20, 20000));
			sig = HPF.ar(sig, (20 * (2 ** (f.max(0) * 9))).clip(20, 20000));
			ReplaceOut.ar(bus, sig);
		}).add;

		// always-on track strip: just level, mute, pan and the two sends (very light)
		SynthDef(\loam_trackfx, { |in=0, out=0, dlyBus=0, revBus=0, level=0.8, pan=0, mute=0, dly=0, rev=0|
			var sig = In.ar(in, 2);
			var amp = Lag.kr(level * (1 - mute), 0.02);
			sig = Balance2.ar(sig[0], sig[1], pan) * amp;
			Out.ar(out, sig);
			Out.ar(dlyBus, sig * dly);
			Out.ar(revBus, sig * rev);
		}).add;

		// delay + reverb returns: paused whenever no track sends to them (after the tails ring out)
		SynthDef(\loam_returns, { |dlyBus=0, revBus=0, out=0, dtime=0.375, dfb=0.45, dtone=4000, dlvl=0.7,
			rsize=0.8, rdamp=0.5, rlvl=0.7|
			var dIn = In.ar(dlyBus, 2);
			var rIn = In.ar(revBus, 2);
			var fb = LocalIn.ar(2);
			var d, rev;
			d = DelayC.ar(dIn + (fb * dfb), 2, Lag.kr(dtime, 0.2));
			d = LPF.ar(d, dtone);
			LocalOut.ar(d.reverse);
			rev = FreeVerb2.ar(rIn[0], rIn[1], 1, rsize, rdamp);
			Out.ar(out, (d * dlvl) + (rev * rlvl));
		}).add;

		// master bus: dj filter -> compressor -> limiter
		SynthDef(\loam_master, { |in=0, out=0, mfilter=0, cthresh=(-12), cratio=4, catk=0.01, crel=0.15, cgain=3, vol=0.8|
			var sig = In.ar(in, 2);
			var f = Lag.kr(mfilter, 0.05);
			sig = LPF.ar(sig, (20000 * (2 ** (f.min(0) * 9))).clip(20, 20000));
			sig = HPF.ar(sig, (20 * (2 ** (f.max(0) * 9))).clip(20, 20000));
			sig = Compander.ar(sig, sig, cthresh.dbamp, 1, 1 / cratio, catk, crel) * cgain.dbamp;
			sig = Limiter.ar(sig * vol, 0.97);
			Out.ar(out, sig);
		}).add;

		s.sync;

		mixBus = Bus.audio(s, 2);
		dlyBus = Bus.audio(s, 2);
		revBus = Bus.audio(s, 2);
		trackBus = Array.fill(8, { Bus.audio(s, 2) });

		voiceGroup = Group.head(context.xg);
		trackGroups = Array.fill(8, { Group.tail(voiceGroup) });
		chokeGroups = Array.fill(4, { Group.tail(voiceGroup) });
		// one sub-group per track inside each choke group, so live knob changes reach only that track
		chokeSub = Array.fill(4, { |c| Array.fill(8, { Group.tail(chokeGroups[c]) }) });
		colorGroup = Group.after(voiceGroup);
		fxGroup = Group.after(colorGroup);
		colorFx = Array.newClear(8);
		fxState = Array.fill(8, { (drive: 0, bits: 16, srate: 48000, filter: 0, dly: 0, rev: 0) });

		trackFx = Array.fill(8, { |i|
			Synth(\loam_trackfx, [\in, trackBus[i], \out, mixBus, \dlyBus, dlyBus, \revBus, revBus], fxGroup)
		});
		returns = Synth.after(fxGroup, \loam_returns, [\dlyBus, dlyBus, \revBus, revBus, \out, mixBus]);
		master = Synth.after(returns, \loam_master, [\in, mixBus, \out, context.out_b]);
		returns.run(false);

		trackParams = Array.fill(8, { IdentityDictionary.new });
		voiceDefs = Array.fill(8, { \loam_kick });
		buffers = Array.newClear(8);
		voices = Array.fill(8, { List.new });

		// ---------------------------------------------------------------- commands

		// p(track, key, value): store a voice parameter AND apply it to the track's sounding voices
		this.addCommand("p", "isf", { |msg|
			var t = msg[1].asInteger - 1;
			var k = msg[2].asSymbol;
			trackParams[t].put(k, msg[3]);
			trackGroups[t].set(k, msg[3]);
			chokeSub.do({ |g| g[t].set(k, msg[3]) });
		});

		// ps(track, key, value): store only (per-step locks: the next voice reads it, sounding voices keep theirs)
		this.addCommand("ps", "isf", { |msg|
			trackParams[msg[1].asInteger - 1].put(msg[2].asSymbol, msg[3]);
		});

		// voice(track, synthdef)
		this.addCommand("voice", "is", { |msg|
			voiceDefs[msg[1].asInteger - 1] = msg[2].asSymbol;
		});

		// trig(track, velocity, gate seconds, choke) choke: 0 off, 1 mono, 2-5 groups A-D
		this.addCommand("trig", "iffi", { |msg|
			var t = msg[1].asInteger - 1;
			var choke = msg[4].asInteger;
			var def = voiceDefs[t];
			var target = trackGroups[t];
			var args, synth, ftKey;
			if((def != \loam_sample) || buffers[t].notNil, {
				if(choke == 1, { trackGroups[t].set(\gate, 0) });
				if(choke > 1, { chokeGroups[choke - 2].set(\gate, 0); target = chokeSub[choke - 2][t] });
				args = trackParams[t].asKeyValuePairs ++ [\out, trackBus[t].index, \vel, msg[2], \dur, msg[3]];
				if(def == \loam_sample, { args = args ++ [\buf, buffers[t].bufnum] });
				// synth + sample come in one SynthDef per filter type
				ftKey = (loam_sample: \smp_ftype, loam_synth: \synth_ftype)[def];
				if(ftKey.notNil, { def = (def ++ "_" ++ (trackParams[t][ftKey] ? 0).asInteger.clip(0, 3)).asSymbol });
				synth = Synth(def, args, target);
				voices[t].add(synth);
				synth.onFree({ voices[t].remove(synth) });
				if(voices[t].size > maxVoices, {
					voices[t][0].set(\gate, 0);
					voices[t].removeAt(0);
				});
			});
		});

		// fx(track, key, value): track insert / mixer
		// fx(track, key, value): track strip, or the optional colour insert
		this.addCommand("fx", "isf", { |msg|
			var t = msg[1].asInteger - 1;
			var k = msg[2].asSymbol;
			var v = msg[3];
			if([\drive, \bits, \srate, \filter].includes(k), {
				fxState[t].put(k, v);
				this.updateColor(t);
			}, {
				if([\dly, \rev].includes(k), { fxState[t].put(k, v) });
				trackFx[t].set(k, v);
				if([\dly, \rev].includes(k), { this.updateReturns });
			});
		});

		// mfx(key, value): master bus (delay/reverb keys go to the returns)
		this.addCommand("mfx", "sf", { |msg|
			var k = msg[1].asSymbol;
			if([\dtime, \dfb, \dtone, \dlvl, \rsize, \rdamp, \rlvl].includes(k), {
				returns.set(k, msg[2]);
			}, {
				master.set(k, msg[2]);
			});
		});

		// sload(track, path): read channel 1 of a sound file into the track's buffer
		this.addCommand("sload", "is", { |msg|
			var t = msg[1].asInteger - 1;
			var path = msg[2].asString;
			if(File.exists(path), {
				Buffer.readChannel(s, path, channels: [0], action: { |b|
					var old = buffers[t];
					// NORMALIZE (on unless the track says off): loudest point to 0.9 (about -1 dB), done on the server
					if((trackParams[t][\smp_norm] ? 1) > 0.5, { b.normalize(0.9) });
					buffers[t] = b;
					if(old.notNil, { old.free });
				});
			});
		});

		// sclear(track): drop the track's sample
		this.addCommand("sclear", "i", { |msg|
			var t = msg[1].asInteger - 1;
			if(buffers[t].notNil, { buffers[t].free; buffers[t] = nil });
		});
	}

	// create / update / remove a track's colour insert depending on whether any colour knob is in use
	updateColor { |t|
		var st = fxState[t];
		var neutral = (st[\drive] <= 0.0001) && (st[\bits] >= 16) && (st[\srate] >= 47999) && (st[\filter].abs < 0.001);
		var args = [\drive, st[\drive], \bits, st[\bits], \srate, st[\srate], \filter, st[\filter]];
		if(neutral, {
			if(colorFx[t].notNil, { colorFx[t].free; colorFx[t] = nil });
		}, {
			if(colorFx[t].isNil, {
				colorFx[t] = Synth(\loam_trackcolor, [\bus, trackBus[t].index] ++ args, colorGroup);
			}, {
				colorFx[t].set(*args);
			});
		});
	}

	// run delay + reverb only while some track sends to them; pause 12 s after the last send closes
	updateReturns {
		var any = fxState.any({ |st| (st[\dly] > 0) || (st[\rev] > 0) });
		if(any, {
			if(returnsOff.notNil, { returnsOff.stop; returnsOff = nil });
			returns.run(true);
		}, {
			if(returnsOff.isNil, {
				returnsOff = Routine({ 12.wait; returns.run(false); returnsOff = nil }).play(SystemClock);
			});
		});
	}

	free {
		if(returnsOff.notNil, { returnsOff.stop });
		voiceGroup.free;
		colorGroup.free;
		fxGroup.free;
		returns.free;
		master.free;
		buffers.do({ |b| if(b.notNil, { b.free }) });
		trackBus.do({ |b| b.free });
		mixBus.free;
		dlyBus.free;
		revBus.free;
	}
}
