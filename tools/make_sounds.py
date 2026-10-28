"""Synthesizes Milo's 14 non-verbal cues as 24 kHz mono WAVs (stdlib only: wave,
math, struct, random). Deterministic: same bytes every run. No sample
libraries, so no licence issue. Run: python tools/make_sounds.py"""
import math, os, random, struct, wave

SR = 24000
OUT = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), 'assets', 'sounds')
random.seed(7)

def env(n, a=.02, r=.15):
    return [min(1.0, i / (n * a + 1)) * min(1.0, (n - i) / (n * r + 1)) for i in range(n)]

def tone(freq, dur, slide=0.0, kind='sine', vib=0.0, vib_rate=6.0):
    n = int(SR * dur); e = env(n); out = []
    f = freq
    for i in range(n):
        t = i / SR
        f = freq * (1 + slide * t / max(dur, 1e-6)) + (math.sin(2 * math.pi * vib_rate * t) * vib if vib else 0)
        ph = 2 * math.pi * f * t
        v = math.sin(ph) if kind == 'sine' else (math.sin(ph) + .3 * math.sin(2 * ph) + .15 * math.sin(3 * ph)) / 1.45
        out.append(v * e[i] * .5)
    return out

def noise(dur, low=400, high=4000):
    n = int(SR * dur); e = env(n); out = []; prev = 0.0
    alpha = low / high
    for i in range(n):
        prev = prev + alpha * (random.uniform(-1, 1) - prev)
        out.append(prev * e[i] * .6)
    return out

def mix(*tracks):
    n = max(len(t) for t in tracks); out = [0.0] * n
    for t in tracks:
        for i, v in enumerate(t): out[i] += v
    peak = max(1e-6, max(abs(v) for v in out))
    return [v / peak * .85 for v in out]

def seq(parts):
    out = []
    for (track, gap) in parts:
        out += track + [0.0] * int(SR * gap)
    return out

def save(name, samples):
    os.makedirs(OUT, exist_ok=True)
    with wave.open(os.path.join(OUT, name + '.wav'), 'wb') as w:
        w.setnchannels(1); w.setsampwidth(2); w.setframerate(SR)
        w.writeframes(struct.pack('<%dh' % len(samples), *[int(max(-1, min(1, v)) * 32767) for v in samples]))

SOUNDS = {
    'wake': mix(tone(523, .18, .3), tone(784, .22, .2)),
    'tap_giggle': seq([(tone(880, .07, .5, 'soft'), .02), (tone(1174, .08, .4, 'soft'), .02), (tone(1318, .1, .3, 'soft'), 0)]),
    'think_hmm': mix(tone(220, .5, -.15, 'soft', vib=8, vib_rate=5)),
    'success': seq([(tone(523, .1), .03), (tone(659, .1), .03), (tone(784, .18, .1), 0)]),
    'soft_error': mix(tone(330, .3, -.4, 'soft')),
    'mic_on': mix(tone(660, .08, .6)),
    'mic_off': mix(tone(660, .1, -.5)),
    'hum': mix(tone(262, .55, 0, 'soft', vib=6, vib_rate=4.5)),
    'yawn': mix(tone(392, .55, -.55, 'soft', vib=10, vib_rate=3)),
    'sprout_boing': mix(tone(180, .35, 2.2, 'soft', vib=60, vib_rate=9)),
    'page': mix(noise(.16, 800, 6000)),
    'whoosh': mix(noise(.3, 300, 2500)),
    'sparkle': seq([(tone(1568, .06), .04), (tone(2093, .06), .04), (tone(2637, .12), 0)]),
    'aww': mix(tone(440, .4, -.25, 'soft', vib=7, vib_rate=4)),
}
for name, s in SOUNDS.items():
    assert len(s) / SR < .6, name
    save(name, s)
print('sounds written:', len(SOUNDS))
