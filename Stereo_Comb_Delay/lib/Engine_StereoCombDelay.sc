Engine_StereoCombDelay : CroneEngine {
    var synth;

    *new { arg context, doneCallback;
        ^super.new(context, doneCallback);
    }

    alloc {
        SynthDef(\stereoCombDelayNorns, {
            arg inL, inR, out,
                delayL = 0.008, delayR = 0.008,
                feedbackL = 0.55, feedbackR = 0.55,
                modDepthL = 0.0, modDepthR = 0.0,
                modRateL = 0.20, modRateR = 0.30,
                modWave = 0,
                toneL = 0.0, toneR = 0.0,
                mix = 0.5, output = 0.85;

            var inputL, inputR;
            var dL, dR;
            var depthL, depthR;
            var rateL, rateR;
            var excL, excR;
            var lfoL, lfoR;
            var waveL, waveR;
            var timeL, timeR;
            var fbAbsL, fbAbsR;
            var decayL, decayR;
            var wetL, wetR;
            var lpFcL, lpFcR, hpFcL, hpFcR;
            var lpL, lpR, hpL, hpR;
            var toneMixL, toneMixR;
            var dryGain, wetGain;
            var sigL, sigR;

            inputL = In.ar(inL, 1);
            inputR = In.ar(inR, 1);

            dL = Lag.kr(delayL.clip(0.0005, 0.12), 0.05);
            dR = Lag.kr(delayR.clip(0.0005, 0.12), 0.05);

            depthL = Lag.kr(modDepthL.clip(0, 1), 0.05);
            depthR = Lag.kr(modDepthR.clip(0, 1), 0.05);

            rateL = Lag.kr(modRateL.clip(0.1, 2000), 0.05);
            rateR = Lag.kr(modRateR.clip(0.1, 2000), 0.05);

            excL = ((dL - 0.0005).min(0.12 - dL)).max(0) * depthL;
            excR = ((dR - 0.0005).min(0.12 - dR)).max(0) * depthR;

            // Six selectable audio-rate modulation shapes.
            // SAW is descending; RAMP is ascending.
            // Random generators are instantiated separately for L/R so the
            // stereo channels remain independent.
            waveL = [
                SinOsc.ar(rateL, 0),
                LFSaw.ar(rateL, 0).neg,
                LFSaw.ar(rateL, 0),
                LFPulse.ar(rateL, 0, 0.5).range(-1, 1),
                LFDNoise0.ar(rateL),
                LFDNoise1.ar(rateL)
            ];

            waveR = [
                SinOsc.ar(rateR, 1.57079632679),
                LFSaw.ar(rateR, 1).neg,
                LFSaw.ar(rateR, 1),
                LFPulse.ar(rateR, 0.25, 0.5).range(-1, 1),
                LFDNoise0.ar(rateR),
                LFDNoise1.ar(rateR)
            ];

            lfoL = Select.ar(modWave.clip(0, 5), waveL);
            lfoR = Select.ar(modWave.clip(0, 5), waveR);

            timeL = dL + (lfoL * excL);
            timeR = dR + (lfoR * excR);

            // exact hard bypass at zero depth
            timeL = Select.ar(modDepthL <= 0.00001, [timeL, K2A.ar(dL)]);
            timeR = Select.ar(modDepthR <= 0.00001, [timeR, K2A.ar(dR)]);

            timeL = timeL.clip(0.0005, 0.12);
            timeR = timeR.clip(0.0005, 0.12);

            fbAbsL = feedbackL.abs.clip(0.0001, 0.97);
            fbAbsR = feedbackR.abs.clip(0.0001, 0.97);

            decayL = dL * (-6.90775527898 / log(fbAbsL));
            decayR = dR * (-6.90775527898 / log(fbAbsR));

            decayL = decayL * feedbackL.sign;
            decayR = decayR * feedbackR.sign;

            decayL = Select.kr(feedbackL.abs < 0.0001, [decayL, 0.000001]);
            decayR = Select.kr(feedbackR.abs < 0.0001, [decayR, 0.000001]);

            wetL = CombC.ar(inputL, 0.12, timeL, decayL);
            wetR = CombC.ar(inputR, 0.12, timeR, decayR);

            lpFcL = 18000 * ((120 / 18000) ** toneL.abs.clip(0, 1));
            lpFcR = 18000 * ((120 / 18000) ** toneR.abs.clip(0, 1));
            hpFcL = 20 * ((8000 / 20) ** toneL.abs.clip(0, 1));
            hpFcR = 20 * ((8000 / 20) ** toneR.abs.clip(0, 1));

            lpL = LPF.ar(wetL, lpFcL);
            lpR = LPF.ar(wetR, lpFcR);
            hpL = HPF.ar(wetL, hpFcL);
            hpR = HPF.ar(wetR, hpFcR);

            toneMixL = SelectX.ar((toneL + 1).clip(0, 2), [lpL, wetL, hpL]);
            toneMixR = SelectX.ar((toneR + 1).clip(0, 2), [lpR, wetR, hpR]);

            dryGain = cos(Lag.kr(mix.clip(0, 1), 0.02) * 1.57079632679);
            wetGain = sin(Lag.kr(mix.clip(0, 1), 0.02) * 1.57079632679);

            sigL = (inputL * dryGain) + (toneMixL * wetGain);
            sigR = (inputR * dryGain) + (toneMixR * wetGain);

            sigL = Limiter.ar(LeakDC.ar(sigL) * Lag.kr(output.clip(0, 1.25), 0.02), 0.99, 0.005);
            sigR = Limiter.ar(LeakDC.ar(sigR) * Lag.kr(output.clip(0, 1.25), 0.02), 0.99, 0.005);

            Out.ar(out, [sigL, sigR]);
        }).add;

        context.server.sync;

        synth = Synth(
            \stereoCombDelayNorns,
            [
                \inL, context.in_b[0].index,
                \inR, context.in_b[1].index,
                \out, context.out_b.index
            ],
            context.xg
        );

        this.addCommand("delayL", "f", { arg msg; synth.set(\delayL, msg[1]); });
        this.addCommand("delayR", "f", { arg msg; synth.set(\delayR, msg[1]); });
        this.addCommand("feedbackL", "f", { arg msg; synth.set(\feedbackL, msg[1]); });
        this.addCommand("feedbackR", "f", { arg msg; synth.set(\feedbackR, msg[1]); });
        this.addCommand("modDepthL", "f", { arg msg; synth.set(\modDepthL, msg[1]); });
        this.addCommand("modDepthR", "f", { arg msg; synth.set(\modDepthR, msg[1]); });
        this.addCommand("modRateL", "f", { arg msg; synth.set(\modRateL, msg[1]); });
        this.addCommand("modRateR", "f", { arg msg; synth.set(\modRateR, msg[1]); });
        this.addCommand("modWave", "f", { arg msg; synth.set(\modWave, msg[1]); });
        this.addCommand("toneL", "f", { arg msg; synth.set(\toneL, msg[1]); });
        this.addCommand("toneR", "f", { arg msg; synth.set(\toneR, msg[1]); });
        this.addCommand("mix", "f", { arg msg; synth.set(\mix, msg[1]); });
        this.addCommand("output", "f", { arg msg; synth.set(\output, msg[1]); });
    }

    free {
        if(synth.notNil, { synth.free; });
    }
}
