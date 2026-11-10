// Engine_Loam
// 8 tracks of pure-synthesis drums, subtractive synth, 2-op fm and sample playback.
// every voice -> its track bus -> track insert fx (drive, crush, dj filter, pan, sends)
// -> master bus -> delay + reverb returns -> dj filter -> compressor -> limiter -> out

Engine_Loam : CroneEngine {
	var mixBus, dlyBus, revBus, trackBus;
	var voiceGroup, fxGroup, trackGroups, chokeGroups;
	var trackFx, master;
	var trackParams, voiceDefs, buffers;

	*new { arg context, doneCallback;
		^super.new(context, doneCallback);
	}

	alloc {
		var s = context.server;

		// shared voice output: choke gate + velocity, mono voices go to both channels
		var finish = { |sig|
			var c = EnvGen.kr(Env.asr(0, 1, 0.01), \gate.kr(1), doneAction: 2);
			Out.ar(\out.kr(0), (sig * \vel.kr(1) * c) ! 2);
		};
		var finishStereo = { |sig|
			var c = EnvGen.kr(Env.asr(0, 1, 0.01), \gate.kr(1), doneAction: 2);
			Out.ar(\out.kr(0), sig * \vel.kr(1) * c);
		};
		var multiFilter = { |sig, type, cutoff, res|
			var rq = (1 - (res * 0.95)).max(0.05);
			var cf = cutoff.clip(20, 18000);
			Select.ar(type, [RLPF.ar(sig, cf, rq), RHPF.ar(sig, cf, rq), BPF.ar(sig, cf, rq), BRF.ar(sig, cf, rq)]);
		};

		// ---------------------------------------------------------------- drums

		SynthDef(\loam_kick, { |kick_tune=48, kick_sweep=0.5, kick_stime=0.05, kick_decay=0.5, kick_click=0.3, kick_drive=0.2|
			var penv = EnvGen.kr(Env([1, 0], [kick_stime], -4));
			var freq = kick_tune * (1 + (kick_sweep * 7 * penv));
			var body = SinOsc.ar(freq, 0.5pi) * EnvGen.ar(Env.perc(0.002, kick_decay, 1, -4));
			var click = HPF.ar(WhiteNoise.ar, 3000) * EnvGen.ar(Env.perc(0.0005, 0.008)) * kick_click;
			var sig = body + click;
			sig = XFade2.ar(sig, (sig * (1 + (kick_drive * 10))).tanh, (kick_drive * 2) - 1);
			Line.kr(0, 0, kick_decay + 0.05, doneAction: 2);
			finish.(sig);
		}).add;

		SynthDef(\loam_snare, { |snare_tune=185, snare_decay=0.15, snare_snappy=0.7, snare_sdecay=0.22, snare_color=2500|
			var pe = EnvGen.kr(Env([1.25, 1], [0.03]));
			var body = (LFTri.ar(snare_tune * pe) + (LFTri.ar(snare_tune * 1.84 * pe) * 0.5));
			var nz = HPF.ar(WhiteNoise.ar, snare_color);
			var sig;
			body = body * EnvGen.ar(Env.perc(0.001, snare_decay)) * (1 - (snare_snappy * 0.4));
			nz = nz * EnvGen.ar(Env.perc(0.001, snare_sdecay, 1, -4)) * snare_snappy;
			sig = (body * 0.7) + nz;
			Line.kr(0, 0, max(snare_decay, snare_sdecay) + 0.05, doneAction: 2);
			finish.(sig);
		}).add;

		SynthDef(\loam_clap, { |clap_tone=1200, clap_spread=0.011, clap_decay=0.25|
			var sp = clap_spread * 0.95;
			var env = EnvGen.ar(Env(
				[0, 1, 0.05, 1, 0.05, 1, 0.05, 0.8, 0],
				[0.0005, sp, 0.0005, sp, 0.0005, sp, 0.0005, clap_decay],
				[0, -4, 0, -4, 0, -4, 0, -4]));
			var sig = HPF.ar(BPF.ar(WhiteNoise.ar, clap_tone, 0.6), 400) * 2.5 * env;
			Line.kr(0, 0, (clap_spread * 3) + clap_decay + 0.05, doneAction: 2);
			finish.(sig);
		}).add;

		SynthDef(\loam_hat, { |hat_tune=40, hat_color=10000, hat_decay=0.06, hat_noise=0.2|
			var ratios = [2, 3, 4.16, 5.43, 6.79, 8.21];
			var metal = Mix(ratios.collect({ |r| Pulse.ar(hat_tune * r) })) * 0.2;
			var sig = metal + (WhiteNoise.ar * hat_noise * 0.5);
			sig = HPF.ar(BPF.ar(sig, hat_color, 0.8), hat_color * 0.7) * 12;
			sig = sig * EnvGen.ar(Env.perc(0.001, hat_decay, 1, -6));
			Line.kr(0, 0, hat_decay + 0.05, doneAction: 2);
			finish.(sig);
		}).add;

		SynthDef(\loam_tom, { |tom_tune=110, tom_sweep=0.5, tom_decay=0.45, tom_noise=0.15|
			var penv = EnvGen.kr(Env([1, 0], [tom_decay * 0.6], -3));
			var freq = tom_tune * (1 + (tom_sweep * penv));
			var sig = SinOsc.ar(freq) * EnvGen.ar(Env.perc(0.002, tom_decay, 1, -4));
			sig = sig + (LPF.ar(WhiteNoise.ar, tom_tune * 4) * EnvGen.ar(Env.perc(0.001, 0.04)) * tom_noise);
			Line.kr(0, 0, tom_decay + 0.05, doneAction: 2);
			finish.(sig);
		}).add;

		SynthDef(\loam_rim, { |rim_tune=1700, rim_decay=0.035, rim_body=0.5|
			var sig = LFTri.ar(rim_tune) + (Pulse.ar(rim_tune * 0.47) * rim_body * 0.6);
			sig = HPF.ar(sig, 600) * EnvGen.ar(Env.perc(0.0005, rim_decay, 1, -6));
			sig = sig + (BPF.ar(WhiteNoise.ar, rim_tune, 0.5) * EnvGen.ar(Env.perc(0.0002, 0.006)) * 1.5);
			Line.kr(0, 0, rim_decay + 0.05, doneAction: 2);
			finish.(sig * 0.8);
		}).add;

		SynthDef(\loam_bell, { |bell_tune=540, bell_ratio=1.48, bell_tone=2640, bell_decay=0.35|
			var sig = (Pulse.ar(bell_tune) + Pulse.ar(bell_tune * bell_ratio)) * 0.3;
			sig = BPF.ar(sig, bell_tone, 0.4) * 4;
			sig = sig * EnvGen.ar(Env([0, 1, 0.25, 0], [0.001, 0.04, bell_decay], [0, -4, -4]));
			Line.kr(0, 0, bell_decay + 0.1, doneAction: 2);
			finish.(sig);
		}).add;

		// ---------------------------------------------------------------- synths

		SynthDef(\loam_synth, { |dur=0.2, synth_note=36, synth_wave=2, synth_pw=0.5, synth_det=7,
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
			var aenv = EnvGen.ar(Env.adsr(synth_atk, synth_dec, synth_sus, synth_rel), gateSig, doneAction: 2);
			var fenv = EnvGen.kr(Env.perc(0.002, synth_fdec));
			var cf = synth_cutoff * (2 ** ((fenv * synth_fenv * 5) + (lCut * 3)));
			var sig = (o1 + (o2 * synth_osc2) + sub) * 0.7;
			sig = multiFilter.(sig, synth_ftype, cf, synth_res);
			sig = sig * aenv * (1 + lAmp).max(0);
			finishStereo.(Pan2.ar(sig, lPan.clip(-1, 1)));
		}).add;

		SynthDef(\loam_fm, { |fm_note=60, fm_ratio=2, fm_index=2, fm_ienv=0.5, fm_fb=0, fm_atk=0.002, fm_decay=0.6|
			var freq = fm_note.midicps;
			var ienv = EnvGen.kr(Env.perc(0.001, (fm_decay * fm_ienv).max(0.005)));
			var mod = SinOscFB.ar(freq * fm_ratio, fm_fb) * freq * fm_ratio * fm_index * ienv;
			var env = EnvGen.ar(Env.perc(fm_atk, fm_decay, 1, -4), doneAction: 2);
			finish.(SinOsc.ar(freq + mod) * env * 0.6);
		}).add;

		SynthDef(\loam_sample, { |buf=0, dur=0.2, smp_pitch=0, smp_start=0, smp_end=1, smp_rev=0, smp_mode=0,
			smp_atk=0.002, smp_rel=0.05, smp_ftype=0, smp_cutoff=18000, smp_res=0.1|
			var frames = BufFrames.kr(buf);
			var s0 = min(smp_start, smp_end);
			var s1 = max(smp_start, smp_end);
			var ratio = smp_pitch.midiratio;
			var rate = BufRateScale.kr(buf) * ratio * (1 - (smp_rev * 2));
			var startPos = Select.kr(smp_rev, [s0, s1]) * frames;
			var regionDur = ((s1 - s0).max(0.001) * frames / BufSampleRate.kr(buf)) / ratio;
			// ONESHOT: the release fade ends exactly at the END marker (long release = fade across the sample)
			// GATE: hold until the gate ends, then release as a tail while the sample keeps playing
			var relT = Select.kr(smp_mode, [min(smp_rel, (regionDur - smp_atk).max(0.001)), smp_rel]);
			var susT = Select.kr(smp_mode, [(regionDur - smp_atk - relT).max(0), (dur - smp_atk).max(0)]);
			var env = EnvGen.ar(Env([0, 1, 1, 0], [smp_atk, susT, relT]), doneAction: 2);
			// never play past the END marker: short fade there, then free the voice
			var stop = EnvGen.ar(Env([1, 1, 0], [(regionDur - 0.005).max(0), 0.005]), doneAction: 2);
			var sig = PlayBuf.ar(1, buf, rate, 1, startPos, 0) * stop;
			sig = multiFilter.(sig, smp_ftype, smp_cutoff, smp_res);
			finish.(sig * env);
		}).add;

		// ---------------------------------------------------------------- fx

		SynthDef(\loam_trackfx, { |in=0, out=0, dlyBus=0, revBus=0, level=0.8, pan=0, mute=0, drive=0,
			bits=16, srate=48000, filter=0, dly=0, rev=0|
			var sig = In.ar(in, 2);
			var amp = Lag.kr(level * (1 - mute), 0.02);
			var f = Lag.kr(filter, 0.05);
			sig = XFade2.ar(sig, (sig * (1 + (drive * 20))).tanh * 0.7, (drive * 2) - 1);
			// rate reduction; bypassed at full rate (an Impulse at the sample rate never fires)
			sig = Select.ar(srate < (SampleRate.ir * 0.99), [sig, Latch.ar(sig, Impulse.ar(srate))]);
			sig = sig.round(0.5 ** (bits - 1));
			sig = LPF.ar(sig, (20000 * (2 ** (f.min(0) * 9))).clip(20, 20000));
			sig = HPF.ar(sig, (20 * (2 ** (f.max(0) * 9))).clip(20, 20000));
			sig = Balance2.ar(sig[0], sig[1], pan) * amp;
			Out.ar(out, sig);
			Out.ar(dlyBus, sig * dly);
			Out.ar(revBus, sig * rev);
		}).add;

		SynthDef(\loam_master, { |in=0, dlyBus=0, revBus=0, out=0, dtime=0.375, dfb=0.45, dtone=4000, dlvl=0.7,
			rsize=0.8, rdamp=0.5, rlvl=0.7, mfilter=0, cthresh=(-12), cratio=4, catk=0.01, crel=0.15,
			cgain=3, vol=0.8|
			var dry = In.ar(in, 2);
			var dIn = In.ar(dlyBus, 2);
			var rIn = In.ar(revBus, 2);
			var fb = LocalIn.ar(2);
			var f = Lag.kr(mfilter, 0.05);
			var d, rev, sig;
			d = DelayC.ar(dIn + (fb * dfb), 2, Lag.kr(dtime, 0.2));
			d = LPF.ar(d, dtone);
			LocalOut.ar(d.reverse);
			rev = FreeVerb2.ar(rIn[0], rIn[1], 1, rsize, rdamp);
			sig = dry + (d * dlvl) + (rev * rlvl);
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
		fxGroup = Group.after(voiceGroup);

		trackFx = Array.fill(8, { |i|
			Synth(\loam_trackfx, [\in, trackBus[i], \out, mixBus, \dlyBus, dlyBus, \revBus, revBus], fxGroup)
		});
		master = Synth.after(fxGroup, \loam_master,
			[\in, mixBus, \dlyBus, dlyBus, \revBus, revBus, \out, context.out_b]);

		trackParams = Array.fill(8, { IdentityDictionary.new });
		voiceDefs = Array.fill(8, { \loam_kick });
		buffers = Array.newClear(8);

		// ---------------------------------------------------------------- commands

		// p(track, key, value): store a voice parameter, read when the next voice starts
		this.addCommand("p", "isf", { |msg|
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
			var args;
			if((def != \loam_sample) || buffers[t].notNil, {
				if(choke == 1, { trackGroups[t].set(\gate, 0) });
				if(choke > 1, { target = chokeGroups[choke - 2]; target.set(\gate, 0) });
				args = trackParams[t].asKeyValuePairs ++ [\out, trackBus[t].index, \vel, msg[2], \dur, msg[3]];
				if(def == \loam_sample, { args = args ++ [\buf, buffers[t].bufnum] });
				Synth(def, args, target);
			});
		});

		// fx(track, key, value): track insert / mixer
		this.addCommand("fx", "isf", { |msg|
			trackFx[msg[1].asInteger - 1].set(msg[2].asSymbol, msg[3]);
		});

		// mfx(key, value): master bus
		this.addCommand("mfx", "sf", { |msg|
			master.set(msg[1].asSymbol, msg[2]);
		});

		// sload(track, path): read channel 1 of a sound file into the track's buffer
		this.addCommand("sload", "is", { |msg|
			var t = msg[1].asInteger - 1;
			var path = msg[2].asString;
			if(File.exists(path), {
				Buffer.readChannel(s, path, channels: [0], action: { |b|
					var old = buffers[t];
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

	free {
		voiceGroup.free;
		fxGroup.free;
		master.free;
		buffers.do({ |b| if(b.notNil, { b.free }) });
		trackBus.do({ |b| b.free });
		mixBus.free;
		dlyBus.free;
		revBus.free;
	}
}
