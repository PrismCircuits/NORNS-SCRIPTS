// Engine_PanSpectra.sc
// spectral resynthesis engine for norns, inspired by the Rossum Panharmonium.
//
// the server runs an FFT on the input. every "slice", sclang pulls the latest
// FFT frame, finds spectral peaks inside a frequency window, and TRACKS them:
// each peak is matched to the voice already playing (or still releasing)
// nearest to it, sounding partials get a ranking bonus so they don't flicker,
// and only genuinely new partials are given a free voice. a 33-voice
// wavetable bank with per-voice attack/release plays the result, followed by
// a resonant multimode filter.
//
// mod matrix: 10 LFOs run on the server at control rate. synth-side
// destinations read them from a control bus (perfectly smooth); analysis-side
// destinations get them via SendReply and apply them on each re-pick.
//
// destination index (0 = none):
//  1 center   2 width     3 pitch      4 shift      5 wave      6 flatten
//  7 voices   8 slice     9 stability 10 threshold 11 blur     12 glide
// 13 spread  14 feedback 15 mix       16 level     17 input_gain
// 18 cutoff  19 resonance 20 attack   21 release   22 fade

Engine_PanSpectra : CroneEngine {
	classvar maxVoices = 33;
	classvar fftSize = 4096;
	classvar numSlots = 10;
	classvar numDests = 23;

	var fftBuf, waveBufs, fbBus, modBus;
	var anaSynth, bankSynth, modSynth, modResp, task, refreshTask, luaAddr;
	var smooth, trackF, trackA, trackOn, relUntil, refAmp = 0.001;
	var modOff, slotVals;

	var numVoices = 12, sliceRate = 12, frozen = false, captureReq = false, dirty = false;
	var center = 800, width = 8, pitch = 0, shift = 0;
	var blur = 0, threshDb = -60;
	var glide = 0.05, stability = 0.6;
	var attack = 0.5, release = 1.0, fade = 0.3;

	*new { arg context, doneCallback;
		^super.new(context, doneCallback);
	}

	alloc {
		var s = context.server;

		// matron listens for OSC on 10111 -> osc.event in the lua script
		luaAddr = NetAddr("127.0.0.1", 10111);
		smooth = Array.fill(fftSize.div(4), 0); // 1024 bins, up to ~12 kHz
		trackF = Array.fill(maxVoices, { |i| 110 * (i + 1) });
		trackA = Array.fill(maxVoices, 0);
		trackOn = Array.fill(maxVoices, false);
		relUntil = Array.fill(maxVoices, 0);
		modOff = Array.fill(numDests, 0);
		slotVals = IdentityDictionary[
			\shapes -> Array.fill(numSlots, 0),
			\rates -> Array.fill(numSlots, 1),
			\pws -> Array.fill(numSlots, 0.5),
			\dsts -> Array.fill(numSlots, 0),
			\amts -> Array.fill(numSlots, 0)
		];

		fftBuf = Buffer.alloc(s, fftSize);
		waveBufs = Buffer.allocConsecutive(4, s, 2048, 1);
		fbBus = Bus.audio(s, 2);
		modBus = Bus.control(s, numDests);
		s.sync;
		this.fillWaves;

		SynthDef(\panspectra_mod, { |out|
			var shapes = NamedControl.kr(\shapes, Array.fill(numSlots, 0));
			var rates = NamedControl.kr(\rates, Array.fill(numSlots, 1));
			var pws = NamedControl.kr(\pws, Array.fill(numSlots, 0.5));
			var dsts = NamedControl.kr(\dsts, Array.fill(numSlots, 0));
			var amts = NamedControl.kr(\amts, Array.fill(numSlots, 0));
			var lfos, sums;
			lfos = Array.fill(numSlots, { |i|
				var ph = Phasor.kr(0, rates[i] * ControlDur.ir, 0, 1);
				Select.kr(shapes[i], [
					DC.kr(0),                    // off
					sin(ph * 2pi),               // sine
					1 - (4 * (ph - 0.5).abs),    // triangle
					1 - (2 * ph),                // saw (falling)
					(2 * ph) - 1,                // ramp (rising)
					((ph < pws[i]) * 2) - 1      // square / pulse
				])
			});
			sums = Array.fill(numDests, { |d|
				if(d == 0) { DC.kr(0) } {
					Mix(Array.fill(numSlots, { |i| lfos[i] * amts[i] * ((dsts[i] - d).abs < 0.5) }))
				}
			});
			Out.kr(out, sums);
			SendReply.kr(Impulse.kr(30), '/panspectra/mod', sums ++ lfos);
		}).add;

		SynthDef(\panspectra_analysis, { |inL, inR, fb_bus, buf, mbus, gain = 0, fb = 0|
			var g = (gain + (In.kr(mbus + 17) * 48)).clip(-24, 24).dbamp;
			var f = (fb + In.kr(mbus + 14)).clip(0, 1);
			var sig = (In.ar(inL) + In.ar(inR)) * 0.5 * g;
			sig = sig + (Mix(InFeedback.ar(fb_bus, 2)) * 0.5 * f);
			FFT(buf, sig, 0.25, 1); // 75% overlap so the latest frame is always fresh, hann window
		}).add;

		SynthDef(\panspectra_bank, { |out, fb_bus, inL, inR, wbuf, mbus, wave = 0, alag = 0.05,
			level = 0.5, spread = 0.7, mix = 1, pitch = 0, shift = 0, flatten = 0, scale = 0.3,
			attack = 0.5, release = 1.0, fade = 0.3, ftype = 0, cutoff = 18000, res = 0.2|
			var freqs = NamedControl.kr(\freqs, Array.fill(maxVoices, 220));
			var rels = NamedControl.kr(\rels, Array.fill(maxVoices, 0));
			var lags = NamedControl.kr(\lags, Array.fill(maxVoices, 0.05));
			var pit = (Lag.kr(pitch, 0.03) + (In.kr(mbus + 3) * 72)).clip(-36, 36);
			var shf = (Lag.kr(shift, 0.03) + (In.kr(mbus + 4) * 1000)).clip(-500, 500);
			var pos = (Lag.kr(wave, 0.05) + (In.kr(mbus + 5) * 3)).clip(0, 2.999);
			var flat = (Lag.kr(flatten, 0.05) + In.kr(mbus + 6)).clip(0, 1);
			var spr = (Lag.kr(spread, 0.05) + In.kr(mbus + 13)).clip(0, 1);
			var mx = (Lag.kr(mix, 0.05) + In.kr(mbus + 15)).clip(0, 1);
			var lvl = (Lag.kr(level, 0.05) + In.kr(mbus + 16)).clip(0, 1);
			var cut = (Lag.kr(cutoff, 0.05) * (900 ** In.kr(mbus + 18))).clip(20, 18000);
			var rq = 1 - ((Lag.kr(res, 0.05) + In.kr(mbus + 19)).clip(0, 1) * 0.95);
			// envelope times never go below the slice-smoothing time
			var atk = (attack * (2000 ** In.kr(mbus + 20))).clip(0.005, 10).max(alag);
			var rel = (release * (2000 ** In.kr(mbus + 21))).clip(0.005, 10).max(alag);
			var fd = (Lag.kr(fade, 0.05) * (10000 ** In.kr(mbus + 22))).clip(0.001, 10);
			var amps, sigs, wet, dry;
			freqs = Lag.kr(freqs, lags); // per-voice: 0 for newborn voices, glide otherwise
			freqs = ((freqs * pit.midiratio) + shf).clip(20, 18000);
			amps = (rels > 0) * rels.max(1e-6).pow(1 - flat) * scale;
			// per-band volume envelope: 3-stage (S-curve) attack/release so fades
			// start gently, then a symmetric "fade" that blends all band volumes
			amps = Lag3UD.kr(amps, atk, rel);
			amps = Lag2.kr(amps, fd * 0.5);
			sigs = VOsc.ar(wbuf + pos, freqs, 0, amps);
			wet = Mix(sigs.collect { |sig, i|
				Pan2.ar(sig, ((i * 0.618034).frac * 2 - 1) * spr)
			});
			wet = LeakDC.ar(wet);
			// resonant multimode filter: 0 off, 1 lowpass, 2 bandpass, 3 highpass
			wet = wet.collect { |ch|
				Select.ar(ftype.clip(0, 3), [
					ch,
					RLPF.ar(ch, cut, rq),
					BPF.ar(ch, cut, rq) * 2,
					RHPF.ar(ch, cut, rq)
				])
			};
			wet = Limiter.ar(wet * lvl, 0.95, 0.01);
			dry = [In.ar(inL), In.ar(inR)];
			Out.ar(fb_bus, wet); // feedback is always the resynthesized signal only
			Out.ar(out, XFade2.ar(dry, wet, mx * 2 - 1)); // equal-power
		}).add;

		s.sync;

		modSynth = Synth.new(\panspectra_mod, [\out, modBus.index], context.xg, \addToHead);

		anaSynth = Synth.after(modSynth, \panspectra_analysis, [
			\inL, context.in_b[0].index,
			\inR, context.in_b[1].index,
			\fb_bus, fbBus.index,
			\buf, fftBuf.bufnum,
			\mbus, modBus.index
		]);

		bankSynth = Synth.new(\panspectra_bank, [
			\out, context.out_b.index,
			\fb_bus, fbBus.index,
			\inL, context.in_b[0].index,
			\inR, context.in_b[1].index,
			\wbuf, waveBufs[0].bufnum,
			\mbus, modBus.index,
			\alag, this.ampLag
		], context.xg, \addToTail);

		modResp = OSCFunc({ |msg| this.onMod(msg.drop(3)) }, '/panspectra/mod', s.addr);

		// slice clock: grab an FFT frame (two chunks to stay under OSC size limits)
		task = Routine {
			loop {
				if(frozen.not or: { captureReq }) {
					var snap = captureReq;
					captureReq = false;
					fftBuf.getn(0, 1024, { |a|
						fftBuf.getn(1024, 1024, { |b| this.analyze(a ++ b, snap) });
					});
				};
				bankSynth.set(\alag, this.ampLag);
				this.effRate.reciprocal.wait;
			}
		}.play(SystemClock);

		// while frozen, re-pick partials after param/mod changes, at most 30x/sec
		refreshTask = Routine {
			loop {
				if(dirty) {
					dirty = false;
					if(frozen) { this.resynth };
				};
				(1/30).wait;
			}
		}.play(SystemClock);

		this.addCommand("voices", "i", { |msg| numVoices = msg[1].asInteger.clip(1, maxVoices); dirty = true });
		this.addCommand("slice_rate", "f", { |msg| sliceRate = msg[1].clip(0.5, 40) });
		this.addCommand("freeze", "i", { |msg| frozen = msg[1] > 0 });
		this.addCommand("capture", "i", { |msg| captureReq = true });
		this.addCommand("center", "f", { |msg| center = msg[1]; dirty = true });
		this.addCommand("width", "f", { |msg| width = msg[1]; dirty = true });
		this.addCommand("pitch", "f", { |msg| pitch = msg[1]; bankSynth.set(\pitch, pitch); dirty = true });
		this.addCommand("shift", "f", { |msg| shift = msg[1]; bankSynth.set(\shift, shift); dirty = true });
		this.addCommand("flatten", "f", { |msg| bankSynth.set(\flatten, msg[1]) });
		this.addCommand("threshold", "f", { |msg| threshDb = msg[1]; dirty = true });
		this.addCommand("stability", "f", { |msg| stability = msg[1].clip(0, 1) });
		this.addCommand("glide", "f", { |msg| glide = msg[1] });
		this.addCommand("blur", "f", { |msg| blur = msg[1].clip(0, 0.99) });
		this.addCommand("wave", "f", { |msg| bankSynth.set(\wave, msg[1]) });
		this.addCommand("level", "f", { |msg| bankSynth.set(\level, msg[1]) });
		this.addCommand("mix", "f", { |msg| bankSynth.set(\mix, msg[1].clip(0, 1)) });
		this.addCommand("spread", "f", { |msg| bankSynth.set(\spread, msg[1]) });
		this.addCommand("feedback", "f", { |msg| anaSynth.set(\fb, msg[1]) });
		this.addCommand("input_gain", "f", { |msg| anaSynth.set(\gain, msg[1]) });
		this.addCommand("attack", "f", { |msg| attack = msg[1]; bankSynth.set(\attack, attack) });
		this.addCommand("release", "f", { |msg| release = msg[1]; bankSynth.set(\release, release) });
		this.addCommand("fade", "f", { |msg| fade = msg[1]; bankSynth.set(\fade, fade) });
		this.addCommand("filter_type", "i", { |msg| bankSynth.set(\ftype, msg[1].asInteger.clip(0, 3)) });
		this.addCommand("cutoff", "f", { |msg| bankSynth.set(\cutoff, msg[1]) });
		this.addCommand("resonance", "f", { |msg| bankSynth.set(\res, msg[1]) });

		// mod slots: (slot 1-10, value)
		this.addCommand("mod_src", "if", { |msg| this.setSlot(\shapes, msg[1], msg[2].asInteger.clip(0, 5)) });
		this.addCommand("mod_rate", "if", { |msg| this.setSlot(\rates, msg[1], msg[2]) });
		this.addCommand("mod_pw", "if", { |msg| this.setSlot(\pws, msg[1], msg[2]) });
		this.addCommand("mod_dst", "if", { |msg| this.setSlot(\dsts, msg[1], msg[2].asInteger.clip(0, numDests - 1)) });
		this.addCommand("mod_amt", "if", { |msg| this.setSlot(\amts, msg[1], msg[2]) });
	}

	setSlot { |key, slot, val|
		var arr = slotVals[key];
		arr[(slot.asInteger - 1).clip(0, numSlots - 1)] = val;
		modSynth.setn(key, arr);
	}

	// modulation values arriving from the server (30x/sec)
	onMod { |vals|
		var sums = vals.copyRange(0, numDests - 1);
		var lfos = vals.copyRange(numDests, numDests + numSlots - 1);
		// analysis-side destinations that change which partials get picked
		[1, 2, 3, 4, 7, 10].do { |d|
			if((sums[d] - modOff[d]).abs > 1e-4) { dirty = true };
		};
		modOff = sums;
		luaAddr.sendMsg('/panspectra/lfo', *lfos);
	}

	// effective (base + modulation) values for analysis-side params
	effCenter { ^(center * (300 ** modOff[1])).clip(40, 12000) }
	effWidth { ^(width + (modOff[2] * 8.9)).clip(0.1, 9) }
	effPitch { ^(pitch + (modOff[3] * 72)).clip(-36, 36) }
	effShift { ^(shift + (modOff[4] * 1000)).clip(-500, 500) }
	effVoices { ^(numVoices + (modOff[7] * 32)).round.asInteger.clip(1, maxVoices) }
	effRate { ^(sliceRate * (80 ** modOff[8])).clip(0.5, 40) }
	effStability { ^(stability + modOff[9]).clip(0, 1) }
	effThresh { ^(threshDb + (modOff[10] * 70)).clip(-90, -20) }
	effBlur { ^(blur + (modOff[11] * 0.99)).clip(0, 0.99) }
	effGlide { ^(glide * (5000 ** modOff[12])).clip(0.001, 5) }
	effRelease {
		var r = (release * (2000 ** modOff[21])).clip(0.005, 10).max(this.ampLag);
		var f = (fade * (10000 ** modOff[22])).clip(0.001, 10);
		^(r + f) * 2.5 // allow for the S-curve tails
	}

	binHz { ^(context.server.sampleRate ? 48000) / fftSize }

	// amplitude smoothing spans roughly half a slice so levels don't step
	ampLag { ^(0.6 / this.effRate).clip(0.01, 0.25) }

	fillWaves {
		var h = 24;
		waveBufs[0].sine1([1]);
		waveBufs[1].sine1(Array.fill(h, { |i|
			var n = i + 1;
			var sign = if((n - 1).div(2).odd) { -1 } { 1 };
			if(n.odd) { sign / (n * n) } { 0 }
		}));
		waveBufs[2].sine1(Array.fill(h, { |i| 1 / (i + 1) }));
		waveBufs[3].sine1(Array.fill(h, { |i|
			var n = i + 1;
			if(n.odd) { 1 / n } { 0 }
		}));
	}

	// data is the raw FFT frame: [dc, nyquist, re1, im1, re2, im2, ...]
	analyze { |data, snap = false|
		var nb = data.size.div(2);
		var norm = fftSize * 0.25; // hann-windowed sine of amp A -> |X| ~ A * N/4
		var b = this.effBlur;
		var mags = Array.fill(nb, { |k|
			if(k == 0) { 0 } { data[2 * k].hypot(data[2 * k + 1]) / norm }
		});
		if(snap or: { b <= 0 }) {
			smooth = mags;
		} {
			smooth = (smooth * b) + (mags * (1 - b));
		};
		this.sendSpectrum;
		this.resynth;
	}

	// parabolic interpolation on log magnitude -> [freq, amp]
	interp { |k, hz|
		var a = log(smooth[k - 1].max(1e-9));
		var b = log(smooth[k].max(1e-9));
		var c = log(smooth[k + 1].max(1e-9));
		var denom = (a - (2 * b)) + c;
		var p = if(denom.abs > 1e-9) { (0.5 * (a - c) / denom).clip(-0.5, 0.5) } { 0 };
		^[(k + p) * hz, exp(b - (0.25 * (a - c) * p))]
	}

	// pick a voice for a new partial: prefer fully silent voices, then nearest
	// pitch; avoid voices that just stopped or are still in their release tail
	freeVoice { |f, newOn, oldOn, now|
		var best, bestD = inf;
		maxVoices.do { |v|
			if(newOn[v].not) {
				var d = log(f / trackF[v]).abs;
				if(oldOn[v]) { d = d + 100 };
				if(relUntil[v] > now) { d = d + 50 };
				if(d < bestD) { bestD = d; best = v };
			};
		};
		^best
	}

	resynth {
		var hz = this.binHz;
		var nb = smooth.size;
		var now = Main.elapsedTime;
		var cen = this.effCenter, wid = this.effWidth;
		var lo = (cen * (2 ** (wid * -0.5)) / hz).floor.asInteger.clip(3, nb - 4);
		var hi = (cen * (2 ** (wid * 0.5)) / hz).ceil.asInteger.clip(lo, nb - 4);
		var th = this.effThresh.dbamp;
		var nv = this.effVoices;
		var stab = this.effStability;
		var ks = List.new;
		var cands, pairs, candVoice, taken, scores, order, bonus, keep;
		var oldOn, newOn, born, maxA, count, ratio, sh, baseLag;
		var outF, rels, lags, msg;

		// 1. local maxima above threshold with a real dip on at least one side
		(lo..hi).do { |k|
			var m = smooth[k];
			if((m > th) and: {
				(m > smooth[k - 1]) and: {
					(m >= smooth[k + 1]) and: { m > (smooth[k - 3].min(smooth[k + 3]) * 2) }
				}
			}) { ks.add(k) };
		};
		ks = ks.asArray.sort({ |a, b| smooth[a] > smooth[b] });
		if(ks.size > 64) { ks = ks.copyRange(0, 63) };
		cands = ks.collect { |k| this.interp(k, hz) };

		// 2. match candidates to sounding OR still-releasing voices
		//    (nearest within ~60 cents / 1.5 bins) so returning partials revive
		pairs = List.new;
		maxVoices.do { |v|
			if(trackOn[v] or: { relUntil[v] > now }) {
				var tol = (trackF[v] * 0.035).max(hz * 1.5);
				cands.do { |c, ci|
					var d = (c[0] - trackF[v]).abs;
					if(d < tol) { pairs.add([d / tol, v, ci]) };
				};
			};
		};
		pairs = pairs.asArray.sort({ |a, b| a[0] < b[0] });
		candVoice = Array.fill(cands.size, -1);
		taken = Array.fill(maxVoices, false);
		pairs.do { |p|
			if(taken[p[1]].not and: { candVoice[p[2]] < 0 }) {
				taken[p[1]] = true;
				candVoice[p[2]] = p[1];
			};
		};

		// 3. rank, giving existing voices a bonus (hysteresis, up to ~18 dB)
		bonus = 1 + (stab * 7);
		scores = cands.collect { |c, ci| c[1] * if(candVoice[ci] >= 0) { bonus } { 1 } };
		order = Array.series(cands.size).sort({ |a, b| scores[a] > scores[b] });
		if(order.size > nv) { order = order.copyRange(0, nv - 1) };

		// 4. continuing/revived voices keep their voice (with pitch smoothing),
		//    new partials take a free voice and snap to pitch (fade in via attack)
		oldOn = trackOn.copy;
		newOn = Array.fill(maxVoices, false);
		born = Array.fill(maxVoices, false);
		keep = stab * 0.85;
		order.do { |ci|
			var v = candVoice[ci];
			if(v >= 0) {
				var c = cands[ci];
				newOn[v] = true;
				trackF[v] = exp((log(trackF[v]) * keep) + (log(c[0]) * (1 - keep)));
				trackA[v] = c[1];
			};
		};
		order.do { |ci|
			if(candVoice[ci] < 0) {
				var c = cands[ci];
				var v = this.freeVoice(c[0], newOn, oldOn, now);
				if(v.notNil) {
					newOn[v] = true;
					born[v] = true;
					trackF[v] = c[0];
					trackA[v] = c[1];
				};
			};
		};
		// voices that just stopped enter their release tail
		maxVoices.do { |v|
			if(oldOn[v] and: { newOn[v].not }) { relUntil[v] = now + this.effRelease };
		};
		trackOn = newOn;

		// 5. levels, normalized against a slowly decaying reference (no pumping)
		maxA = 0;
		maxVoices.do { |v| if(trackOn[v]) { maxA = maxA.max(trackA[v]) } };
		refAmp = maxA.max(refAmp * (0.5 ** (1 / (this.effRate * 1.5)))).max(1e-6);
		count = trackOn.occurrencesOf(true);
		baseLag = this.effGlide.max(0.5 / this.effRate);

		// source freqs + relative levels; pitch/shift/flatten are applied in the synth
		outF = Array.fill(maxVoices, { |v| trackF[v].clip(20, 18000) });
		rels = Array.fill(maxVoices, { |v| if(trackOn[v]) { (trackA[v] / refAmp).min(1) } { 0 } });
		lags = Array.fill(maxVoices, { |v| if(born[v]) { 0 } { baseLag } });

		bankSynth.setn(\freqs, outF, \rels, rels, \lags, lags);
		bankSynth.set(\scale, count.max(1).sqrt.reciprocal);

		// display: send the transposed frequencies
		ratio = this.effPitch.midiratio;
		sh = this.effShift;
		msg = [count];
		maxVoices.do { |v|
			if(trackOn[v]) {
				msg = msg ++ [((trackF[v] * ratio) + sh).clip(20, 18000), rels[v]];
			};
		};
		luaAddr.sendMsg('/panspectra/peaks', *msg);
	}

	// 48 log-spaced bands, 40 Hz - 12 kHz, normalized 0..1 for the screen
	sendSpectrum {
		var hz = this.binHz;
		var nb = smooth.size;
		var bands = Array.fill(48, { |j|
			var k0 = (40 * (300 ** (j / 48)) / hz).floor.asInteger.clip(1, nb - 1);
			var k1 = (40 * (300 ** ((j + 1) / 48)) / hz).ceil.asInteger.clip(k0, nb - 1);
			smooth.copyRange(k0, k1).maxItem.max(1e-6).ampdb.linlin(-80, 0, 0, 1)
		});
		luaAddr.sendMsg('/panspectra/spec', *bands);
	}

	free {
		task.stop;
		refreshTask.stop;
		modResp.free;
		modSynth.free;
		anaSynth.free;
		bankSynth.free;
		fftBuf.free;
		waveBufs.do(_.free);
		fbBus.free;
		modBus.free;
	}
}
