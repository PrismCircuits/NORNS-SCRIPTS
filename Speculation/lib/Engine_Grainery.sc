// Engine_Grainery
// clean-room polyphonic granular engine for the grainery norns script.
// feature set modeled on the GR-1's public controls; DSP is original.

Engine_Grainery : CroneEngine {
	var buf, envBufs, envBase;
	var voiceGroup, globalSynth, fxSynth, recSynth;
	var fxBus, scanBus, lfoBus, ctlBus, frameBus;
	var voices, voiceOrder, pv, maxPoly = 8;
	var luaAddr, posFunc, grainFunc, inL, inR;
	var recBuf, recLoop = 0, recStarting = false, stopPending = false;

	*new { arg context, doneCallback;
		^super.new(context, doneCallback);
	}

	alloc {
		var server = context.server;
		var lfoFn, sides, tilts;

		luaAddr = NetAddr("127.0.0.1", 10111);
		voices = Dictionary.new;
		voiceOrder = List.new;
		pv = Dictionary.new;

		// input buses (handle either a stereo Bus or an array of mono Buses)
		if(context.in_b.isKindOf(Bus)) {
			inL = context.in_b.index; inR = inL + 1;
		} {
			inL = context.in_b[0].index; inR = context.in_b[1].index;
		};

		fxBus = Bus.audio(server, 2);
		scanBus = Bus.control(server, 1);
		lfoBus = Bus.control(server, 2);
		ctlBus = Bus.control(server, 4); // modwheel, aftertouch, cv1, cv2
		frameBus = Bus.control(server, 1); // frames written by the current take
		buf = Buffer.alloc(server, server.sampleRate.asInteger, 1);

		// grain window bank: 8 'sides' (edge steepness) x 9 'tilt' (peak position)
		sides = [0.05, 0.15, 0.3, 0.45, 0.6, 0.75, 0.9, 1.0];
		tilts = (-4..4) / 4;
		envBufs = Buffer.allocConsecutive(72, server, 1024, 1);
		server.sync;
		envBase = envBufs[0].bufnum;
		sides.do { |s, i|
			tilts.do { |t, j|
				var p = 0.5 + (t * 0.48);
				var a = max(s * p, 0.005), r = max(s * (1 - p), 0.005);
				var data = Array.fill(1024, { |k|
					var x = k / 1023;
					case
					{ x < a } { 0.5 - (0.5 * cos(pi * x / a)) }
					{ x > (1 - r) } { 0.5 - (0.5 * cos(pi * (1 - x) / r)) }
					{ 1.0 }
				});
				envBufs[(i * 9) + j].setn(0, data);
			};
		};

		// shared LFO: sine, tri, saw, square, random (S&H)
		lfoFn = { |shape, rate|
			var ph = Phasor.kr(0, rate * ControlDur.ir, 0, 1);
			var wrapTrig = ph < Delay1.kr(ph);
			Select.kr(shape, [
				SinOsc.kr(0, ph * 2pi),
				1 - (4 * (ph - 0.5).abs),
				(ph * 2) - 1,
				((ph < 0.5) * 2) - 1,
				Latch.kr(WhiteNoise.kr, wrapTrig + Impulse.kr(0))
			]);
		};

		// free-running scan phase + free-running LFOs (used when key sync is off)
		SynthDef(\grainery_global, { |scanBus, lfoBus, buf, scan=0,
			l1shape=0, l1rate=1, l2shape=0, l2rate=0.5, l12x=0|
			var bufDur = BufDur.kr(buf).max(0.001);
			var l1 = lfoFn.(l1shape, l1rate);
			var l2 = lfoFn.(l2shape, l2rate * (2 ** (l1 * l12x * 2)));
			Out.kr(scanBus, Phasor.kr(0, scan / bufDur * ControlDur.ir, 0, 2));
			Out.kr(lfoBus, [l1, l2]);
		}).add;

		SynthDef(\grainery_voice, {
			arg out=0, buf=0, envBase=0, scanBus=0, lfoBus=0, ctlBus=0,
			gate=1, id=0, note=60, vel=1, pitchOff=0, posOff=0, keyPos=0, ktrack=1,
			pos=0, scan=0, spray=0.05, size=0.15, dens=6, pspr=0, sides=0.7, tilt=0,
			spawnRand=0, scanMode=0, scanSync=0, panSpr=0.4, pan=0,
			tune=0, fine=0, glide=0, bend=0, sub=0, amp=0.5, velSens=0.5,
			atk=0.05, dec=0.3, sus=1, rel=1.5,
			fmode=0, cutoff=12000, res=0.1, fenv=0, fatk=0.01, fdec=0.5, fsus=0.5, frel=1,
			l1shape=0, l1rate=1, l1sync=0, l2shape=0, l2rate=0.5, l2sync=0, l12x=0;

			var aenv = EnvGen.kr(Env.adsr(atk, dec, sus, rel), gate, doneAction: 2);
			var fenvSig = EnvGen.kr(Env.adsr(fatk, fdec, fsus, frel), gate);
			var glfo = In.kr(lfoBus, 2);
			var vl1 = lfoFn.(l1shape, l1rate);
			var vl2 = lfoFn.(l2shape, l2rate * (2 ** (vl1 * l12x * 2)));
			var l1 = Select.kr(l1sync, [glfo[0], vl1]);
			var l2 = Select.kr(l2sync, [glfo[1], vl2]);
			var ctl = In.kr(ctlBus, 4);
			// mod sources: none, lfo1, lfo2, amp env, filt env, velocity,
			// modwheel, aftertouch, cv1, cv2, keytrack, random-per-note
			var srcs = [DC.kr(0), l1, l2, aenv, fenvSig, vel, ctl[0], ctl[1], ctl[2], ctl[3],
				(note - 60) / 60, Rand(-1.0, 1.0)];
			// mod dests: 1 pos, 2 scan, 3 spray, 4 size, 5 dens, 6 pitch,
			// 7 pitch spray, 8 cutoff, 9 res, 10 pan, 11 amp, 12 spawn random
			var mods = Array.fill(13, { 0 });
			var bufDur, semis, rateBase, gsize, gdens, trate, trig, scanPh, center;
			var gpos, grate, gpan, envIdx, sig, subSig, cf, rq, velAmp, psemi, reportTrig, jit;

			8.do { |i|
				var src = Select.kr(("msrc" ++ i).asSymbol.kr(0), srcs);
				var dst = ("mdst" ++ i).asSymbol.kr(0);
				var amt = ("mamt" ++ i).asSymbol.kr(0);
				(1..12).do { |j|
					mods[j] = mods[j] + (src * amt * BinaryOpUGen('==', dst, j));
				};
			};

			bufDur = BufDur.kr(buf).max(0.001);
			semis = ((note - 60) * ktrack) + tune + fine + pitchOff + bend + (mods[6] * 12);
			semis = Lag.kr(semis, glide);
			rateBase = semis.midiratio * BufRateScale.kr(buf);

			gsize = (size * (2 ** (mods[4] * 3))).clip(0.005, 5);
			gdens = (dens * (2 ** (mods[5] * 3))).clip(0.25, 128);
			trate = (gdens / gsize).clip(0.2, 800);
			// spawn timing: each gap between grains blends from even (1/trate) toward
			// a random exponential gap (Poisson, like Dust) as spawnRand goes 0 -> 1.
			// the average rate stays the same, only the timing loosens.
			jit = (spawnRand + (mods[12] * 0.5)).clip(0, 1);
			trig = TDuty.ar((((1 - jit) + (jit * Dwhite(0.0001, 1).log.neg)) / trate).max(0.0002), 0, 1);

			scanPh = Select.kr(scanSync, [
				In.kr(scanBus),
				Sweep.kr(0, (scan + (mods[2] * 2)) / bufDur)
			]);
			center = pos + posOff + (keyPos * (note - 60) / 24) + mods[1] + scanPh;
			gpos = center + (TRand.ar(-1, 1, trig) * (spray + (mods[3] * 0.5)).clip(0, 1) * 0.5);
			gpos = Select.ar(scanMode, [gpos.wrap(0, 1), gpos.fold(0, 1), gpos.clip(0, 1)]);

			psemi = TRand.ar(-1, 1, trig) * (pspr + (mods[7] * 12)).max(0);
			grate = rateBase * psemi.midiratio;
			gpan = (pan + mods[10] + (TRand.ar(-1, 1, trig) * panSpr)).clip(-1, 1);
			envIdx = envBase + ((sides.clip(0, 1) * 7).round * 9) + ((tilt.clip(-1, 1) + 1) * 4).round;

			sig = GrainBuf.ar(2, trig, gsize, buf, grate, gpos, 2, gpan, envIdx, 128);
			sig = sig * gdens.max(1).sqrt.reciprocal;

			subSig = SinOsc.ar((60 + semis).midicps * 0.5) * sub * 0.5;
			sig = sig + subSig;

			cf = (cutoff * (2 ** ((mods[8] * 5) + (fenvSig * fenv * 6)))).clip(20, 18000);
			rq = (1 - (res + mods[9]).clip(0, 0.97)).max(0.03);
			sig = Select.ar(fmode, [RLPF.ar(sig, cf, rq), RHPF.ar(sig, cf, rq), BPF.ar(sig, cf, rq), sig]);

			velAmp = (1 - velSens) + (velSens * vel);
			sig = sig * aenv * velAmp * (1 + mods[11]).max(0) * amp;

			// report grains to lua for display, thinned to ~30/s per voice
			reportTrig = PulseDivider.ar(trig, (trate / 30).ceil.max(1));
			SendReply.ar(reportTrig, '/grainery_grain', [id, gpos, gsize,
				grate * SampleRate.ir / BufFrames.kr(buf).max(1), psemi, gpan]);

			SendReply.kr(Impulse.kr(15), '/grainery_pos', [id,
				Select.kr(scanMode, [center.wrap(0, 1), center.fold(0, 1), center.clip(0, 1)])]);
			Out.ar(out, sig);
		}).add;

		// drive -> reducer -> ping-pong delay -> reverb
		SynthDef(\grainery_fx, { |in=0, out=0, drive=0, crush=0, dtime=0.375, dfb=0.35,
			dmix=0, rsize=0.8, rdamp=0.4, rmix=0.2, level=1|
			var sig = In.ar(in, 2);
			var g = 1 + (drive * 29);
			var sr = crush.linexp(0, 1, 48000, 1500);
			var steps = 2 ** crush.linlin(0, 1, 16, 3);
			var del, rev;
			sig = XFade2.ar(sig, (sig * g).tanh * 0.6, ((drive * 4) - 1).clip(-1, 1));
			sig = XFade2.ar(sig, (Latch.ar(sig, Impulse.ar(sr)) * steps).round / steps,
				((crush * 4) - 1).clip(-1, 1));
			del = DelayC.ar(sig + (LocalIn.ar(2) * dfb), 2.0, Lag.kr(dtime, 0.2));
			LocalOut.ar(LPF.ar(del, 7000).reverse);
			sig = sig + (del * dmix);
			rev = FreeVerb2.ar(sig[0], sig[1], 1, rsize, rdamp);
			sig = sig + (rev * rmix);
			Out.ar(out, Limiter.ar(sig * level, 0.95));
		}).add;

		SynthDef(\grainery_rec, { |inL=0, inR=1, buf=0, loop=0, frameBus=0|
			var sig = (In.ar(inL) + In.ar(inR)) * 0.5;
			RecordBuf.ar(sig, buf, loop: loop, doneAction: 2);
			// running count of frames written, so a take can be trimmed on stop
			Out.kr(frameBus, A2K.kr(Sweep.ar(0, SampleRate.ir)));
		}).add;

		server.sync;

		ctlBus.setn([0, 0, 0, 0]);
		voiceGroup = Group.new(context.xg);
		globalSynth = Synth(\grainery_global,
			[\scanBus, scanBus.index, \lfoBus, lfoBus.index, \buf, buf.bufnum], voiceGroup, \addBefore);
		fxSynth = Synth(\grainery_fx,
			[\in, fxBus.index, \out, context.out_b.index], voiceGroup, \addAfter);

		posFunc = OSCFunc({ |msg|
			luaAddr.sendMsg("/grainery/pos", msg[3].asInteger, msg[4]);
		}, '/grainery_pos', server.addr);

		grainFunc = OSCFunc({ |msg|
			// id, pos (0-1), size (s), speed (buffer fraction / s), pitch spray (st), pan (-1..1)
			luaAddr.sendMsg("/grainery/grain", msg[3].asInteger, msg[4], msg[5], msg[6], msg[7], msg[8]);
		}, '/grainery_grain', server.addr);

		// ---- commands ----

		this.addCommand(\loadSample, "s", { |msg|
			var path = msg[1].asString;
			this.abortRecording;
			Buffer.readChannel(server, path, channels: [0], action: { |b| this.swapBuffer(b) });
		});

		this.addCommand(\noteOn, "iffffff", { |msg|
			var id = msg[1].asInteger, syn;
			if(voices[id].notNil) {
				voices[id].set(\gate, -1.05); voices.removeAt(id); voiceOrder.remove(id);
			};
			while { voiceOrder.size >= maxPoly } {
				var old = voiceOrder.removeAt(0);
				voices[old] !? { |v| v.set(\gate, -1.05) };
				voices.removeAt(old);
			};
			syn = Synth(\grainery_voice, pv.asKeyValuePairs ++ [
				\out, fxBus.index, \buf, buf.bufnum, \envBase, envBase,
				\scanBus, scanBus.index, \lfoBus, lfoBus.index, \ctlBus, ctlBus.index,
				\id, id, \note, msg[2], \vel, msg[3], \pitchOff, msg[4],
				\posOff, msg[5], \keyPos, msg[6], \ktrack, msg[7]
			], voiceGroup);
			voices[id] = syn;
			voiceOrder.add(id);
			syn.onFree({
				if(voices[id] === syn) { voices.removeAt(id); voiceOrder.remove(id) };
			});
		});

		this.addCommand(\noteOff, "i", { |msg|
			var id = msg[1].asInteger;
			voices[id] !? { |v| v.set(\gate, 0) };
			voices.removeAt(id);
			voiceOrder.remove(id);
		});

		this.addCommand(\allOff, "", {
			voiceGroup.set(\gate, 0); voices.clear; voiceOrder.clear;
		});

		// change a control on one playing voice (e.g. retune a drone note in place)
		this.addCommand(\voiceSet, "isf", { |msg|
			voices[msg[1].asInteger] !? { |v| v.set(msg[2].asSymbol, msg[3]) };
		});

		this.addCommand(\poly, "i", { |msg| maxPoly = msg[1].asInteger.max(1) });

		this.addCommand(\param, "sf", { |msg|
			var k = msg[1].asSymbol, v = msg[2];
			pv[k] = v;
			voiceGroup.set(k, v);
			globalSynth.set(k, v);
			fxSynth.set(k, v);
		});

		this.addCommand(\ctl, "if", { |msg|
			ctlBus.subBus(msg[1].asInteger.clip(0, 3)).set(msg[2]);
		});

		this.addCommand(\rec, "iff", { |msg|
			var on = msg[1].asInteger, len = msg[2].max(0.5), loop = msg[3].asInteger;
			if(on == 0) {
				if(recStarting) { stopPending = true } { this.stopRecording };
			};
			if(on == 1 and: { recSynth.isNil } and: { recStarting.not }) {
				recStarting = true; stopPending = false;
				fork {
					var b = Buffer.alloc(server, (server.sampleRate * len).asInteger, 1), syn;
					server.sync;
					frameBus.set(0);
					this.swapBuffer(b);
					syn = Synth(\grainery_rec, [\inL, inL, \inR, inR, \buf, b.bufnum,
						\loop, loop, \frameBus, frameBus.index], voiceGroup, \addBefore);
					recSynth = syn; recBuf = b; recLoop = loop;
					// one-shot take reached rec length on its own
					syn.onFree({ if(recSynth === syn) { this.stopRecording } });
					recStarting = false;
					if(stopPending) { stopPending = false; this.stopRecording };
				};
			};
		});
	}

	// stop the current take, trim it to what was actually recorded, load + save it
	stopRecording {
		var syn = recSynth, b = recBuf, loop = recLoop, server = context.server;
		if(syn.isNil) { ^this };
		recSynth = nil; recBuf = nil;
		fork {
			var n, frames = b.numFrames, out, head, c = Condition.new;
			if(syn.isPlaying) { syn.free };
			server.sync;
			frameBus.get({ |v| n = v; c.unhang });
			c.hang;
			n = n.asInteger;
			if(loop == 0) { n = n.min(frames) };
			if(n <= 0) { n = 1 };
			if(n < frames) {
				// stopped early: keep only the frames that were written
				out = Buffer.alloc(server, n, 1);
				server.sync;
				b.copyData(out, 0, 0, n);
			} {
				// full take, or a looping take that wrapped: rotate so the
				// oldest audio (just after the write head) comes first
				head = n % frames;
				out = Buffer.alloc(server, frames, 1);
				server.sync;
				b.copyData(out, 0, head, frames - head);
				if(head > 0) { b.copyData(out, frames - head, 0, head) };
			};
			server.sync;
			this.swapBuffer(out); // frees the untrimmed take
			this.saveRecording(out);
		};
	}

	// discard the current take without saving (e.g. a sample is being loaded)
	abortRecording {
		var syn = recSynth;
		recSynth = nil; recBuf = nil;
		if(syn.notNil and: { syn.isPlaying }) { syn.free };
	}

	swapBuffer { |newBuf|
		var old = buf;
		buf = newBuf;
		voiceGroup.set(\buf, buf.bufnum);
		globalSynth.set(\buf, buf.bufnum);
		if(old.notNil) { SystemClock.sched(2, { old.free; nil }) };
	}

	saveRecording { |b|
		var path = "/home/we/dust/audio/grainery/rec_" ++ Date.getDate.stamp ++ ".wav";
		fork {
			b.write(path, "wav", "int24");
			context.server.sync;
			luaAddr.sendMsg("/grainery/recdone", path);
		};
	}

	free {
		posFunc.free;
		grainFunc.free;
		if(recSynth.notNil) { recSynth.free };
		frameBus.free;
		voiceGroup.free;
		globalSynth.free;
		fxSynth.free;
		buf.free;
		envBufs.do(_.free);
		fxBus.free; scanBus.free; lfoBus.free; ctlBus.free;
	}
}
