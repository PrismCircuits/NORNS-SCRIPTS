// Engine_PanSpectra.sc
// spectral resynthesis engine for norns, inspired by the Rossum Panharmonium.
//
// the server runs an FFT on the input. every "slice", sclang pulls the latest
// FFT frame, finds spectral peaks inside a frequency window, and TRACKS them:
// each peak is matched to the voice already playing nearest to it, sounding
// partials get a ranking bonus so they don't flicker, and only genuinely new
// partials are given a free voice. a 33-voice wavetable bank plays the result.

Engine_PanSpectra : CroneEngine {
	classvar maxVoices = 33;
	classvar fftSize = 4096;

	var fftBuf, waveBufs, fbBus;
	var anaSynth, bankSynth, task, luaAddr;
	var smooth, trackF, trackA, trackOn, refAmp = 0.001;

	var numVoices = 12, sliceRate = 12, frozen = false, captureReq = false;
	var center = 800, width = 8, pitch = 0, shift = 0;
	var blur = 0, flatten = 0, threshDb = -60;
	var glide = 0.05, stability = 0.6;

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

		fftBuf = Buffer.alloc(s, fftSize);
		waveBufs = Buffer.allocConsecutive(4, s, 2048, 1);
		fbBus = Bus.audio(s, 2);
		s.sync;
		this.fillWaves;

		SynthDef(\panspectra_analysis, { |inL, inR, fb_bus, buf, gain = 1, fb = 0|
			var sig = (In.ar(inL) + In.ar(inR)) * 0.5 * gain;
			sig = sig + (Mix(InFeedback.ar(fb_bus, 2)) * 0.5 * fb);
			FFT(buf, sig, 0.25, 1); // 75% overlap so the latest frame is always fresh, hann window
		}).add;

		SynthDef(\panspectra_bank, { |out, fb_bus, inL, inR, wbuf, wave = 0, alag = 0.05, level = 0.5, spread = 0.7, mix = 1,
			cutoff = 20000, res = 0, ftype = 0|
			var freqs = NamedControl.kr(\freqs, Array.fill(maxVoices, 220));
			var amps = NamedControl.kr(\amps, Array.fill(maxVoices, 0));
			var lags = NamedControl.kr(\lags, Array.fill(maxVoices, 0.05));
			var pos = Lag.kr(wave, 0.05).clip(0, 2.999);
			var sigs, wet, dry, fc, rq, fsel;
			freqs = Lag.kr(freqs, lags); // per-voice: 0 for newborn voices, glide otherwise
			amps = Lag.kr(amps, alag);
			sigs = VOsc.ar(wbuf + pos, freqs, 0, amps);
			wet = Mix(sigs.collect { |sig, i|
				Pan2.ar(sig, ((i * 0.618034).frac * 2 - 1) * spread)
			});
			// multimode filter on the wet signal: 0 lowpass, 1 bandpass, 2 highpass
			// (mode changes crossfade briefly so switching doesn't click)
			fc = Lag.kr(cutoff, 0.05).clip(20, 20000);
			rq = Lag.kr(res, 0.05).linexp(0, 1, 1, 0.05);
			fsel = Lag.kr(ftype, 0.05);
			wet = wet.collect { |ch|
				SelectX.ar(fsel, [RLPF.ar(ch, fc, rq), BPF.ar(ch, fc, rq), RHPF.ar(ch, fc, rq)])
			};
			wet = Limiter.ar(LeakDC.ar(wet) * level, 0.95, 0.01);
			dry = [In.ar(inL), In.ar(inR)];
			Out.ar(fb_bus, wet); // feedback is always the resynthesized signal only
			Out.ar(out, XFade2.ar(dry, wet, Lag.kr(mix, 0.05) * 2 - 1)); // equal-power
		}).add;

		s.sync;

		anaSynth = Synth.new(\panspectra_analysis, [
			\inL, context.in_b[0].index,
			\inR, context.in_b[1].index,
			\fb_bus, fbBus.index,
			\buf, fftBuf.bufnum
		], context.xg);

		bankSynth = Synth.new(\panspectra_bank, [
			\out, context.out_b.index,
			\fb_bus, fbBus.index,
			\inL, context.in_b[0].index,
			\inR, context.in_b[1].index,
			\wbuf, waveBufs[0].bufnum,
			\alag, this.ampLag
		], context.xg, \addToTail);

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
				sliceRate.reciprocal.wait;
			}
		}.play(SystemClock);

		this.addCommand("voices", "i", { |msg| numVoices = msg[1].asInteger.clip(1, maxVoices); this.resynth });
		this.addCommand("slice_rate", "f", { |msg|
			sliceRate = msg[1].clip(0.5, 40);
			this.updateAmpLag;
		});
		this.addCommand("freeze", "i", { |msg|
			frozen = msg[1] > 0;
			this.updateAmpLag;
		});
		this.addCommand("capture", "i", { |msg| captureReq = true });
		this.addCommand("center", "f", { |msg| center = msg[1]; this.resynth });
		this.addCommand("width", "f", { |msg| width = msg[1]; this.resynth });
		this.addCommand("pitch", "f", { |msg| pitch = msg[1]; this.resynth });
		this.addCommand("shift", "f", { |msg| shift = msg[1]; this.resynth });
		this.addCommand("flatten", "f", { |msg| flatten = msg[1]; this.resynth });
		this.addCommand("threshold", "f", { |msg| threshDb = msg[1]; this.resynth });
		this.addCommand("stability", "f", { |msg| stability = msg[1].clip(0, 1) });
		this.addCommand("glide", "f", { |msg| glide = msg[1] });
		this.addCommand("blur", "f", { |msg| blur = msg[1].clip(0, 0.99); this.updateAmpLag });
		this.addCommand("wave", "f", { |msg| bankSynth.set(\wave, msg[1]) });
		this.addCommand("cutoff", "f", { |msg| bankSynth.set(\cutoff, msg[1]) });
		this.addCommand("resonance", "f", { |msg| bankSynth.set(\res, msg[1].clip(0, 1)) });
		this.addCommand("filter_type", "i", { |msg| bankSynth.set(\ftype, msg[1].clip(0, 2)) });
		this.addCommand("level", "f", { |msg| bankSynth.set(\level, msg[1]) });
		this.addCommand("mix", "f", { |msg| bankSynth.set(\mix, msg[1].clip(0, 1)) });
		this.addCommand("spread", "f", { |msg| bankSynth.set(\spread, msg[1]) });
		this.addCommand("feedback", "f", { |msg| anaSynth.set(\fb, msg[1]) });
		this.addCommand("input_gain", "f", { |msg| anaSynth.set(\gain, msg[1].dbamp) });
	}

	binHz { ^(context.server.sampleRate ? 48000) / fftSize }

	// amplitude smoothing spans roughly half a slice so levels don't step
	ampLag { ^(0.6 / sliceRate).clip(0.01, 0.25) }

	// while frozen, blur sets the crossfade time between frozen states
	// (0 -> instant, 50% -> 2 s, 99% -> ~7.8 s)
	morphTime { ^(blur * blur * 8).max(this.ampLag) }

	updateAmpLag {
		bankSynth.set(\alag, if(frozen) { this.morphTime } { this.ampLag });
	}

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
		var mags = Array.fill(nb, { |k|
			if(k == 0) { 0 } { data[2 * k].hypot(data[2 * k + 1]) / norm }
		});
		if(snap and: { frozen }) {
			// a capture while frozen is taken exactly; the morph from the
			// previous frozen state happens on the voices (see resynth)
			smooth = mags;
			this.sendSpectrum;
			this.resynth(true);
		} {
			if(blur <= 0) {
				smooth = mags;
			} {
				smooth = (smooth * blur) + (mags * (1 - blur));
			};
			this.sendSpectrum;
			this.resynth;
		};
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

	// pick a voice for a new partial: prefer silent voices, then nearest pitch
	freeVoice { |f, newOn, oldOn|
		var best, bestD = inf;
		maxVoices.do { |v|
			if(newOn[v].not) {
				var d = log(f / trackF[v]).abs + if(oldOn[v]) { 100 } { 0 };
				if(d < bestD) { bestD = d; best = v };
			};
		};
		^best
	}

	// snapshot: a capture while frozen. the new state is matched exactly (no
	// hysteresis or pitch smoothing) and voices glide/fade to it over morphTime
	resynth { |snapshot = false|
		var hz = this.binHz;
		var nb = smooth.size;
		var lo = (center * (2 ** (width * -0.5)) / hz).floor.asInteger.clip(3, nb - 4);
		var hi = (center * (2 ** (width * 0.5)) / hz).ceil.asInteger.clip(lo, nb - 4);
		var th = threshDb.dbamp;
		var ks = List.new;
		var cands, pairs, candVoice, taken, scores, order, bonus, keep;
		var oldOn, newOn, born, maxA, count, scale, ratio, baseLag;
		var outF, outA, lags, msg;

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

		// 2. match candidates to sounding tracks (nearest within ~60 cents / 1.5 bins)
		pairs = List.new;
		maxVoices.do { |v|
			if(trackOn[v]) {
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

		// 3. rank, giving sounding tracks a bonus (hysteresis, up to ~18 dB)
		bonus = if(snapshot) { 1 } { 1 + (stability * 7) };
		scores = cands.collect { |c, ci| c[1] * if(candVoice[ci] >= 0) { bonus } { 1 } };
		order = Array.series(cands.size).sort({ |a, b| scores[a] > scores[b] });
		if(order.size > numVoices) { order = order.copyRange(0, numVoices - 1) };

		// 4. continuing tracks keep their voice (with pitch smoothing),
		//    new partials take a free voice and snap to pitch
		oldOn = trackOn.copy;
		newOn = Array.fill(maxVoices, false);
		born = Array.fill(maxVoices, false);
		keep = if(snapshot) { 0 } { stability * 0.85 };
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
				var v = this.freeVoice(c[0], newOn, oldOn);
				if(v.notNil) {
					newOn[v] = true;
					born[v] = true;
					trackF[v] = c[0];
					trackA[v] = c[1];
				};
			};
		};
		trackOn = newOn;

		// 5. levels, normalized against a slowly decaying reference (no pumping)
		maxA = 0;
		maxVoices.do { |v| if(trackOn[v]) { maxA = maxA.max(trackA[v]) } };
		refAmp = maxA.max(refAmp * 0.85).max(1e-6);
		count = trackOn.occurrencesOf(true);
		scale = count.max(1).sqrt.reciprocal;
		ratio = 2 ** (pitch / 12);
		baseLag = glide.max(0.5 / sliceRate);

		outF = Array.fill(maxVoices, { |v| ((trackF[v] * ratio) + shift).clip(20, 18000) });
		outA = Array.fill(maxVoices, { |v|
			if(trackOn[v]) { ((trackA[v] / refAmp).min(1) ** (1 - flatten)) * scale } { 0 }
		});
		if(snapshot) { baseLag = this.morphTime };
		// newborn voices jump in pitch while silent; one stolen from a sounding
		// partial glides instead, so a frozen morph never clicks
		lags = Array.fill(maxVoices, { |v|
			if(born[v] and: { snapshot.not or: { oldOn[v].not } }) { 0 } { baseLag }
		});

		bankSynth.setn(\freqs, outF, \amps, outA, \lags, lags);

		msg = [count];
		maxVoices.do { |v|
			if(trackOn[v]) { msg = msg ++ [outF[v], (trackA[v] / refAmp).min(1)] };
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
		anaSynth.free;
		bankSynth.free;
		fftBuf.free;
		waveBufs.do(_.free);
		fbBus.free;
	}
}
