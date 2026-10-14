"""Original score for Nori core-capabilities highlight: 59.52 s, 125 BPM, C major.
Bright, optimistic, "Microsoft-style" product-launch feel.
Major piano/marimba, airy strings pad, crisp claps/hats, light bass, data blips.
Usage: python3 score-core.py assets/music.wav
"""
import array, math, random, sys, wave

RATE = 48000
BPM = 125
BEAT = 60 / BPM
BAR = BEAT * 4
S16 = BEAT / 4
DURATION = 59.52
N = int(RATE * DURATION)
L = array.array('f', [0.0]) * N
R = array.array('f', [0.0]) * N
rng = random.Random(20261006)
TAU = 2 * math.pi
sin, exp = math.sin, math.exp


def hz(n):
    return 440 * 2 ** ((n - 69) / 12)


def add(off, j, v, pan):
    i = off + j
    if 0 <= i < N:
        L[i] += v * math.sqrt((1 - pan) / 2)
        R[i] += v * math.sqrt((1 + pan) / 2)


TAIL = {
    'pad': 0.4, 'keys': 1.0, 'piano': 1.2, 'pluck': 0.8, 'marimba': 0.6,
    'bell': 1.6, 'sq': 0.12, 'saw': 0.06, 'bass': 0.2, 'stab': 0.25, 'blip': 0.05,
}


def note(start, dur, n, amp, kind='keys', pan=0.0, bright=1.0):
    off = int(start * RATE)
    f = hz(n)
    length = int((dur + TAIL.get(kind, 0.2)) * RATE)
    for j in range(min(length, N - off)):
        t = j / RATE
        p = TAU * f * t
        if kind == 'pad':
            env = min(1, t / 0.4) * max(0.0, min(1.0, (dur + 0.2 - t) / 0.2))
            v = (sin(p) + 0.38 * sin(p * 1.003 + 1) + 0.2 * sin(2 * p)) * env * 0.85
        elif kind == 'keys':
            env = min(1, t / 0.005) * exp(-3.5 * t) * (1 if t < dur else exp(-9 * (t - dur)))
            v = (sin(p + 0.5 * sin(p) * exp(-6 * t)) + 0.12 * sin(2 * p) * exp(-5 * t)) * env
        elif kind == 'piano':
            env = min(1, t / 0.004) * exp(-4.0 * t) * (1 if t < dur else exp(-10 * (t - dur)))
            v = (sin(p) + 0.35 * sin(2 * p) * exp(-3 * t) + 0.12 * sin(3 * p) * exp(-5 * t)) * env
        elif kind == 'pluck':
            env = min(1, t / 0.003) * exp(-8 * t)
            v = sin(p) * env
        elif kind == 'marimba':
            env = min(1, t / 0.002) * exp(-10 * t)
            v = (sin(p) + 0.25 * sin(2 * p) * exp(-4 * t)) * env
        elif kind == 'bell':
            env = min(1, t / 0.003) * exp(-2.8 * t)
            v = (sin(p) + 0.4 * sin(2.76 * p) * exp(-4 * t) + 0.15 * sin(5.4 * p) * exp(-8 * t)) * env
        elif kind == 'sq':
            env = min(1, t / 0.002) * exp(-14 * t)
            c = bright * exp(-22 * t)
            v = (sin(p) + c * sin(3 * p) / 3 + c * c * sin(5 * p) / 5 + c * c * c * sin(7 * p) / 7) * env
        elif kind == 'saw':
            env = min(1, t / 0.004) * exp(-9 * t) * (1 if t < dur else exp(-40 * (t - dur)))
            c = exp(-28 * t)
            v = (sin(p) + 0.5 * sin(2 * p) * (0.3 + 0.7 * c) + 0.33 * sin(3 * p) * c + 0.25 * sin(4 * p) * c * c) * env
        elif kind == 'bass':
            env = min(1, t / 0.004) * exp(-10 * t) * (1 if t < dur else exp(-30 * (t - dur)))
            v = (sin(p) + 0.3 * sin(2 * p)) * env
        elif kind == 'stab':
            env = min(1, t / 0.003) * exp(-10 * t)
            c = exp(-18 * t)
            v = (sin(p) + c * sin(3 * p) / 3 + c * sin(2 * p + 1) * 0.4) * env
        elif kind == 'blip':
            env = min(1, t / 0.001) * exp(-55 * t)
            v = sin(p + 2.2 * sin(p * 2.01) * exp(-40 * t)) * env
        else:
            env = min(1, t / 0.005) * exp(-5 * t)
            v = sin(p) * env
        add(off, j, v * amp, pan)


def kick(start, amp=0.13):
    off = int(start * RATE)
    for j in range(int(0.15 * RATE)):
        t = j / RATE
        ph = TAU * (58 * t + 110 * 0.018 * (1 - exp(-t / 0.018)))
        add(off, j, amp * sin(ph) * exp(-22 * t) * min(1, t / 0.0008), 0)


def hat(start, amp=0.018, pan=0, open_=False):
    off = int(start * RATE)
    prev = 0
    d = 16 if open_ else 110
    for j in range(int((0.22 if open_ else 0.05) * RATE)):
        t = j / RATE
        x = rng.uniform(-1, 1)
        metal = sin(TAU * 6200 * t) * sin(TAU * 8900 * t)
        add(off, j, ((x - prev) * 0.8 + metal * 0.35) * amp * exp(-d * t) * min(1, t / 0.0015), pan)
        prev = x


def clap(start, amp=0.05):
    off = int(start * RATE)
    for j in range(int(0.14 * RATE)):
        t = j / RATE
        burst = sum(exp(-((t - d) * 280) ** 2) for d in (0, 0.007, 0.015)) * 0.4 + exp(-30 * t)
        add(off, j, rng.uniform(-1, 1) * amp * burst, rng.uniform(-0.25, 0.25))


def rim(start, amp=0.04, pan=0.15):
    off = int(start * RATE)
    for j in range(int(0.06 * RATE)):
        t = j / RATE
        add(off, j, (0.6 * sin(TAU * 1750 * t) + 0.4 * rng.uniform(-1, 1)) * exp(-75 * t) * amp, pan)


def riser(start, dur, amp=0.05):
    off = int(start * RATE)
    lp = 0
    for j in range(int(dur * RATE)):
        t = j / RATE
        u = t / dur
        lp += (0.02 + 0.5 * u * u) * (rng.uniform(-1, 1) - lp)
        tone = sin(TAU * (400 + 2400 * u * u) * t) * 0.25
        add(off, j, (lp + tone * u) * amp * u * u * 3, sin(u * 7) * 0.45)


def bloom(start, amp=0.1):
    off = int(start * RATE)
    for j in range(int(0.9 * RATE)):
        t = j / RATE
        add(off, j, amp * sin(TAU * (52 * t + 26 * 0.06 * (1 - exp(-t / 0.06)))) * exp(-4.5 * t) * min(1, t / 0.004), 0)


def stutter(t_end, n=6, amp=0.035):
    step = S16 / 2
    for k in range(n):
        note(t_end - (n - k) * step, 0.01, 88 + k * 2, amp * (0.5 + 0.5 * k / n), 'blip', (-0.5, 0.5)[k % 2])


# C major, bright I-IV-vi-V progression
Cmaj9 = [48, 52, 55, 59, 62, 64]
Fmaj9 = [53, 57, 60, 64, 67, 69]
Am9 = [45, 48, 52, 55, 59, 60]
Gmaj9 = [55, 59, 62, 66, 69, 71]
PROG = [Cmaj9, Fmaj9, Am9, Gmaj9]
MOTIF = [72, 76, 79]  # C E G
ARP = [0, 2, 4, 2, 1, 3, 4, 3]


def bar_t(b):
    return b * BAR


def chord(b):
    return PROG[b % 4]


def arp(b, amp=0.03, octave=24, rate=1, bright=None):
    ch = chord(b)[1:]
    steps = 16 * rate
    for k in range(steps):
        idx = ARP[k % 8] % len(ch)
        n = ch[idx] + octave + (12 if k % 16 in (6, 14) else 0)
        br = bright if bright is not None else 0.35 + 0.65 * (0.5 - 0.5 * math.cos(TAU * (b * steps + k) / (steps * 4)))
        note(bar_t(b) + k * S16 / rate, 0.04, n, amp * (1.15 if k % 4 == 0 else 1), 'marimba', (-0.4, 0.4)[k % 2], br)


def hats(b, amp=0.016, opens=False):
    for k in range(16):
        hat(bar_t(b) + k * S16, amp * (1.5 if k % 4 == 2 else 0.8), (-0.3, 0.3)[k % 2])
    if opens:
        for beat in range(4):
            hat(bar_t(b) + beat * BEAT + BEAT / 2, amp * 1.1, 0.2, True)


def blips(b, amp=0.016, density=3):
    for _ in range(density):
        k = rng.randrange(16)
        note(bar_t(b) + k * S16, 0.01, rng.choice([88, 90, 92, 95, 97]), amp, 'blip', rng.uniform(-0.6, 0.6))


def piano_stab(b, amp=0.04):
    t0 = bar_t(b)
    ch = chord(b)
    for i, n in enumerate(ch[1:4]):
        note(t0, 0.25, n + 12, amp, 'piano', (i - 1) * 0.3)


def groove(b, bright=False, counter=False, rate=1):
    t0 = bar_t(b)
    ch = chord(b)
    for beat in range(4):
        kick(t0 + beat * BEAT, 0.14 if beat % 2 == 0 else 0.11)
        if beat in (1, 3):
            clap(t0 + beat * BEAT, 0.05)
            rim(t0 + beat * BEAT, 0.04)
    for k in range(8):
        if k % 2 == 1 or k == 6:
            note(t0 + k * BEAT / 2, BEAT * 0.3, ch[0] + 12, 0.045, 'bass')
    arp(b, 0.032, 24, rate)
    hats(b, opens=bright)
    blips(b, 0.015, 4 if counter else 2)


# ---- airy string pad bed (all 31 bars) ----
for b in range(31):
    for i, n in enumerate(chord(b)[2:]):
        note(bar_t(b), BAR + 0.02, n + 12, 0.0055, 'pad', (i - 1.5) * 0.35)

# ---- hook: marimba arp builds, blips, riser into brand wipe ----
for b in (0, 1):
    arp(b, 0.028, 24, 1, 0.2 + 0.5 * b)
    blips(b, 0.012, 3)
    for k in range(8):
        hat(bar_t(b) + k * BEAT / 2, 0.011, (-0.3, 0.3)[k % 2])
riser(2.4, 1.44, 0.05)
stutter(3.84)

# ---- brand: bloom, piano stab, bell motif ----
bloom(3.84)
for b in (2, 3):
    groove(b)
    piano_stab(b, 0.045)
for i, n in enumerate(MOTIF):
    note(4.8 + i * S16 * 2, 0.3, n + 12, 0.065, 'bell', (-0.4, 0, 0.4)[i])
stutter(bar_t(4))

# ---- body: feature sections ----
for b in range(4, 27):
    bright = b in (12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 25, 26)
    counter = b in (4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 20, 21, 22)
    rate = 2 if b in (25, 26) else 1
    groove(b, bright=bright, counter=counter, rate=rate)
    piano_stab(b, 0.045 if b in (2, 3, 25, 26) else 0.04)

# glitch lead-ins at every shot cut
for b in (8, 12, 15, 17, 20, 23, 25):
    stutter(bar_t(b))

# screenshot sparkles (bars 17-19)
for b in (17, 18, 19):
    for i, n in enumerate([84, 88, 91]):
        note(bar_t(b) + i * S16 * 2, 0.04, n, 0.018, 'bell', (-0.3 + i * 0.3))

# ---- montage: one chord stab per beat, bright energy ----
for b in (27, 28):
    t0 = bar_t(b)
    ch = chord(b)
    for beat in range(4):
        kick(t0 + beat * BEAT, 0.12)
        for i, n in enumerate(ch[1:4]):
            note(t0 + beat * BEAT, 0.1, n + 12, 0.03, 'stab', (i - 1) * 0.4)
        note(t0 + beat * BEAT, 0.01, 92 + beat, 0.015, 'blip', (-0.5, 0.5)[beat % 2])
    arp(b, 0.03, 24, 1, 0.9)
    hats(b, 0.017, True)
    rim(t0 + BEAT, 0.04)
    rim(t0 + 3 * BEAT, 0.04)
riser(bar_t(28), BAR, 0.045)
stutter(bar_t(29), 8)

# ---- close: final bloom, bell motif, C major ring ----
bloom(bar_t(29))
for i, n in enumerate(Cmaj9):
    note(bar_t(29) + i * 0.03, 2.8, n + 12, 0.04 if i else 0.05, 'piano' if i else 'bass', (i - 3) * 0.2)
for i, n in enumerate(MOTIF + [84]):
    note(bar_t(29) + 0.96 + i * S16 * 2, 0.4, n + 12, 0.06, 'bell', (-0.45, -0.15, 0.15, 0.45)[i])
for k in range(16):
    note(bar_t(29) + k * S16 * 2, 0.04, Cmaj9[1 + ARP[k % 8] % 5] + 24, 0.02 * (1 - k / 16), 'sq', (-0.4, 0.4)[k % 2], 0.4)

# ---- fade, gentle saturation, write ----
peak = max(max(abs(x) for x in L), max(abs(x) for x in R)) or 1
out = array.array('h')
for i in range(N):
    t = i / RATE
    g = min(1, t / 0.1) * min(1, (DURATION - t) / 1.8)
    for ch in (L, R):
        v = math.tanh(ch[i] / peak * 1.4) / math.tanh(1.4) * 0.78 * g
        out.append(int(max(-1, min(1, v)) * 32767))
with wave.open(sys.argv[1], 'wb') as w:
    w.setnchannels(2)
    w.setsampwidth(2)
    w.setframerate(RATE)
    w.writeframes(out.tobytes())
print(sys.argv[1], DURATION, 's')
