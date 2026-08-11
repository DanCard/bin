#!/usr/bin/env python3
"""Measure the latency offset between ch0 (remote) and ch1 (mic) of a recording.

record-call.sh compensates for a fixed capture-pipeline latency: the speaker
monitor arrives ~493 ms later than the mic, so the mic is held back by
MIC_DELAY_MS to line the channels up. Re-run this if the mic or output device
changes, and update MIC_DELAY_MS in record-call.sh to match.

A correctly compensated recording reports an offset near 0 ms.

Needs some speaker sound leaking into the mic to correlate against, so run it on
a recording made with speakers (not headphones) and with the far end talking.

Usage: measure-offset.py RECORDING
"""

import subprocess
import sys
import tempfile
from pathlib import Path

import numpy as np
import scipy.io.wavfile as wavfile
from scipy.signal import butter, coherence, sosfiltfilt


def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    src = sys.argv[1]

    with tempfile.NamedTemporaryFile(suffix=".wav", delete=False) as t:
        tmp = t.name
    subprocess.run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-y", "-i", src,
                    "-ar", "16000", "-ac", "2", "-c:a", "pcm_s16le", tmp], check=True)
    sr, d = wavfile.read(tmp)
    Path(tmp).unlink(missing_ok=True)
    if d.ndim != 2 or d.shape[1] != 2:
        sys.exit("ERROR: need a 2-channel recording (ch0=remote, ch1=mic).")

    d = d.astype(np.float64) / 32768.0
    sos = butter(4, 80 / (sr / 2), btype="high", output="sos")
    a, b = sosfiltfilt(sos, d[:, 0]), sosfiltfilt(sos, d[:, 1])
    n = min(len(a), len(b))
    a, b = a[:n], b[:n]

    N = 1 << int(np.ceil(np.log2(2 * n)))
    c = np.fft.irfft(np.conj(np.fft.rfft(a, N)) * np.fft.rfft(b, N), n=N)
    lags = np.arange(-sr, sr + 1)
    v = np.array([c[l % N] for l in lags]) / (np.linalg.norm(a) * np.linalg.norm(b) + 1e-12)
    off_ms = 1000 * lags[v.argmax()] / sr
    peak = v.max()

    print(f"offset: {off_ms:+.0f} ms   (correlation {peak:.3f})")
    if peak < 0.05:
        print("  correlation too weak to trust -- was this recorded on headphones,")
        print("  or with no far-end speech? Nothing leaked into the mic to measure.")
        return
    if abs(off_ms) < 20:
        print("  channels are aligned; no change needed.")
    else:
        print(f"  channels are misaligned. Set MIC_DELAY_MS={-off_ms:.0f} in record-call.sh")
        print(f"  (a negative offset means the mic runs ahead and must be held back)")

    # How much of the mic is linearly predictable from the speaker signal --
    # i.e. the hard ceiling on any echo canceller. Only meaningful once the
    # channels line up; on a misaligned file it just measures the misalignment.
    if abs(off_ms) >= 20:
        print("\n(skipping coherence: fix the alignment first, then re-run)")
        return

    hop = sr // 10
    k = n // hop
    es = np.sqrt((a[:k * hop] ** 2).reshape(k, -1).mean(1))
    loud = np.repeat(es > np.percentile(es, 60), hop)[:n]
    if loud.sum() > sr:
        f, cxy = coherence(a[:len(loud)][loud], b[:len(loud)][loud], fs=sr, nperseg=4096)
        mc = cxy[(f > 200) & (f < 4000)].mean()
        print(f"\ncoherence 200-4000 Hz: {mc:.3f} "
              f"-> max possible echo cancellation {-10*np.log10(max(1-mc,1e-3)):.1f} dB")
        if mc < 0.5:
            print("  Too low for echo cancellation to be worth doing. The speaker->mic")
            print("  path is not linearly predictable (typically a mic with hardware")
            print("  AGC/noise suppression). Use headphones to remove the path instead.")


if __name__ == "__main__":
    main()
