"""Original score for the Nori product film: 59.52 s, 125 BPM (bar = 1.92 s), E major / C# minor.
Character: light, nimble, quiet, with a clean electronic edge. Square-wave arpeggio with a filter sweep,
filtered saw bass on 8th-note offbeats, a pumping pad, closed/open hats, digital data blips and glitch
stutters into each cut. The kick is short and the level restrained; nothing sustains in the sub.
Arrangement follows plan.json shot boundaries (all on bar lines):
  bars 0-1   hook        arpeggio alone, filter opening, blips, riser into the brand wipe
  bars 2-3   brand       bloom, Emaj9 stab, three-note ribbon bell motif on the wordmark
  bars 4-11  agents / developer junk     full groove
  bars 12-14 dev environment             groove + counter blips
  bars 15-24 ports / screenshot / clipboard / scheduled cleanup   groove, brighter (clap layer, open hats)
  bars 25-26 duplicates  groove, arpeggio doubles to 32nds during the scan bar
  bars 27-28 montage     a chord stab on every beat, riser into close
  bars 29-30 close       final bloom, bell motif, ring-out
Pure Python standard library, fixed random seed: re-running produces the same file.
Usage: python3 audio/score.py assets/music.wav
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
rng = random.Random(20261003)
TAU = 2 * math.pi
sin, exp = math.sin, math.exp


def hz(n):
    return 440 * 2 ** ((n - 69) / 12)


def add(off, j, v, pan):
    i = off + j
    if 0 <= i < N:
        L[i] += v * math.sqrt((1 - pan) / 2)
        R[i] += v * math.sqrt((1 + pan) / 2)


def pump(t_abs):
    """Sidechain-style duck on every beat."""
    x = (t_abs % BEAT) / BEAT
    return .35 + .65 * min(1, x / .45) ** 1.5


TAIL = {'pad': .2, 'keys': 1.0, 'bell': 1.6, 'sq': .12, 'saw': .06, 'stab': .2, 'blip': .05}


def note(start, dur, n, amp, kind='keys', pan=0.0, bright=1.0):
    off = int(start * RATE)
    f = hz(n)
    length = int((dur + TAIL[kind]) * RATE)
    for j in range(min(length, N - off)):
        t = j / RATE
        p = TAU * f * t
        if kind == 'pad':
            env = min(1, t / .3) * max(0.0, min(1.0, (dur + .15 - t) / .15)) * pump(start + t)
            v = (sin(p) + .45 * sin(p * 1.004 + 1) + .2 * sin(2 * p)) * env
        elif kind == 'keys':
            env = min(1, t / .005) * exp(-3 * t) * (1 if t < dur else exp(-7 * (t - dur)))
            v = (sin(p + .5 * sin(p) * exp(-6 * t)) + .15 * sin(2 * p) * exp(-5 * t)) * env
        elif kind == 'sq':  # square-ish arp voice; odd harmonics fade with a filter envelope
            env = min(1, t / .002) * exp(-14 * t)
            c = bright * exp(-22 * t)
            v = (sin(p) + c * sin(3 * p) / 3 + c * c * sin(5 * p) / 5 + c * c * c * sin(7 * p) / 7) * env
        elif kind == 'saw':  # filtered saw bass
            env = min(1, t / .004) * exp(-9 * t) * (1 if t < dur else exp(-40 * (t - dur)))
            c = exp(-28 * t)
            v = (sin(p) + .5 * sin(2 * p) * (.3 + .7 * c) + .33 * sin(3 * p) * c + .25 * sin(4 * p) * c * c) * env
        elif kind == 'stab':
            env = min(1, t / .003) * exp(-10 * t)
            c = exp(-18 * t)
            v = (sin(p) + c * sin(3 * p) / 3 + c * sin(2 * p + 1) * .4) * env
        elif kind == 'blip':  # short FM data blip
            env = min(1, t / .001) * exp(-55 * t)
            v = sin(p + 2.2 * sin(p * 2.01) * exp(-40 * t)) * env
        else:  # bell
            env = min(1, t / .003) * exp(-2 * t)
            v = (sin(p) + .35 * sin(2.76 * p) * exp(-3.5 * t) + .15 * sin(5.4 * p) * exp(-7 * t)) * env
        add(off, j, v * amp, pan)


def kick(start, amp=.13):
    off = int(start * RATE)
    for j in range(int(.17 * RATE)):
        t = j / RATE
        ph = TAU * (58 * t + 110 * .018 * (1 - exp(-t / .018)))
        add(off, j, amp * sin(ph) * exp(-22 * t) * min(1, t / .0008) + amp * .25 * rng.uniform(-1, 1) * exp(-300 * t), 0)


def hat(start, amp=.02, pan=0, open_=False):
    off = int(start * RATE)
    prev = 0
    d = 16 if open_ else 110
    for j in range(int((.22 if open_ else .05) * RATE)):
        t = j / RATE
        x = rng.uniform(-1, 1)
        metal = sin(TAU * 6200 * t) * sin(TAU * 8900 * t)
        add(off, j, ((x - prev) * .8 + metal * .35) * amp * exp(-d * t) * min(1, t / .0015), pan)
        prev = x


def clap(start, amp=.045):
    off = int(start * RATE)
    for j in range(int(.14 * RATE)):
        t = j / RATE
        burst = sum(exp(-((t - d) * 280) ** 2) for d in (0, .007, .015)) * .4 + exp(-30 * t)
        add(off, j, rng.uniform(-1, 1) * amp * burst, rng.uniform(-.25, .25))


def rim(start, amp=.04, pan=.15):
    off = int(start * RATE)
    for j in range(int(.06 * RATE)):
        t = j / RATE
        add(off, j, (.6 * sin(TAU * 1750 * t) + .4 * rng.uniform(-1, 1)) * exp(-75 * t) * amp, pan)


def riser(start, dur, amp=.05):
    off = int(start * RATE)
    lp = 0
    for j in range(int(dur * RATE)):
        t = j / RATE
        u = t / dur
        lp += (.02 + .5 * u * u) * (rng.uniform(-1, 1) - lp)
        tone = sin(TAU * (400 + 2400 * u * u) * t) * .25
        add(off, j, (lp + tone * u) * amp * u * u * 3, sin(u * 7) * .45)


def bloom(start, amp=.09):
    off = int(start * RATE)
    for j in range(int(.9 * RATE)):
        t = j / RATE
        add(off, j, amp * sin(TAU * (52 * t + 26 * .06 * (1 - exp(-t / .06)))) * exp(-4.5 * t) * min(1, t / .004), 0)


def stutter(t_end, n=6, amp=.035):
    """Glitch: a retriggered blip ramp in the last 32nd notes before a cut."""
    step = S16 / 2
    for k in range(n):
        note(t_end - (n - k) * step, .01, 88 + k * 2, amp * (.5 + .5 * k / n), 'blip', (-.5, .5)[k % 2])


E9 = [40, 52, 56, 59, 63, 66]
Cm9 = [37, 49, 52, 56, 59, 63]
A9 = [45, 52, 56, 59, 61, 64]
B69 = [47, 54, 56, 59, 61, 66]
PROG = [Cm9, A9, E9, B69]   # minor-led loop reads more "tech" than the bright I-vi
MOTIF = [71, 76, 80]
ARP = [0, 2, 4, 2, 1, 3, 4, 3]


def bar_t(b):
    return b * BAR


def chord(b):
    if b < 2:
        return [Cm9, A9][b]
    if b >= 29:
        return E9
    return PROG[(b - 2) % 4]


# ---- pumping pad bed ----
for b in range(31):
    for i, n in enumerate(chord(b)[2:]):
        note(bar_t(b), BAR + .02, n + 12, .0055, 'pad', (i - 1.5) * .35)


def arp(b, amp=.03, octave=24, rate=1, bright=None):
    ch = chord(b)[1:]
    steps = 16 * rate
    for k in range(steps):
        idx = ARP[k % 8] % len(ch)
        n = ch[idx] + octave + (12 if k % 16 in (6, 14) else 0)
        br = bright if bright is not None else .35 + .65 * (.5 - .5 * math.cos(TAU * (b * steps + k) / (steps * 4)))
        note(bar_t(b) + k * S16 / rate, .04, n, amp * (1.2 if k % 4 == 0 else 1), 'sq', (-.4, .4)[k % 2], br)


def hats(b, amp=.016, opens=False):
    for k in range(16):
        hat(bar_t(b) + k * S16, amp * (1.5 if k % 4 == 2 else .8), (-.3, .3)[k % 2])
    if opens:
        for beat in range(4):
            hat(bar_t(b) + beat * BEAT + BEAT / 2, amp * 1.1, .2, True)


def blips(b, amp=.016, density=3):
    for _ in range(density):
        k = rng.randrange(16)
        note(bar_t(b) + k * S16, .01, rng.choice([88, 90, 92, 95, 97]), amp, 'blip', rng.uniform(-.6, .6))


def groove(b, bright=False, counter=False, rate=1):
    t0 = bar_t(b)
    ch = chord(b)
    for beat in range(4):
        kick(t0 + beat * BEAT, .13 if beat % 2 == 0 else .1)
        if beat in (1, 3):
            rim(t0 + beat * BEAT, .035)
            if bright:
                clap(t0 + beat * BEAT, .04)
    for k in range(8):   # offbeat-led 8th bass: rest on the downbeat, let the kick speak
        if k % 2 == 1 or k == 6:
            note(t0 + k * BEAT / 2, BEAT * .3, ch[0] + 12 * (k == 7), .055, 'saw')
    arp(b, .028, 24, rate)
    hats(b, opens=bright)
    blips(b, .014, 4 if counter else 2)


# ---- hook: arp alone with the filter opening, blips, riser into the brand wipe ----
for b in (0, 1):
    arp(b, .024, 24, 1, .15 + .4 * b)
    blips(b, .012, 3)
    for k in range(8):
        hat(bar_t(b) + k * BEAT / 2, .011, (-.3, .3)[k % 2])
riser(2.4, 1.44, .05)
stutter(3.84)

# ---- brand ----
bloom(3.84)
for i, n in enumerate(E9[1:]):
    note(3.84 + i * .015, .5, n + 12, .035, 'stab', (i - 2) * .25)
for i, n in enumerate(MOTIF):
    note(4.8 + i * S16 * 2, .3, n + 12, .065, 'bell', (-.4, 0, .4)[i])
for b in (2, 3):
    arp(b, .024, 24, 1, .6)
    hats(b, .012)
    rim(bar_t(b) + BEAT, .03); rim(bar_t(b) + 3 * BEAT, .03)
stutter(bar_t(4))

# ---- body ----
for b in range(4, 27):
    groove(b, bright=15 <= b, counter=12 <= b < 15, rate=2 if b == 25 else 1)
for b in (8, 12, 15, 17, 20, 23, 25, 27):   # every cut gets a glitch lead-in
    stutter(bar_t(b))

# ---- montage: one stab per beat ----
for b in (27, 28):
    t0 = bar_t(b)
    ch = chord(b)
    for beat in range(4):
        kick(t0 + beat * BEAT, .12)
        for i, n in enumerate(ch[1:4]):
            note(t0 + beat * BEAT, .1, n + 12, .028, 'stab', (i - 1) * .4)
        note(t0 + beat * BEAT, .01, 92 + beat, .015, 'blip', (-.5, .5)[beat % 2])
    arp(b, .026, 24, 1, .9)
    hats(b, .017, True)
    rim(t0 + BEAT, .04); rim(t0 + 3 * BEAT, .04)
riser(bar_t(28), BAR, .045)
stutter(bar_t(29), 8)

# ---- close ----
bloom(55.68)
for i, n in enumerate(E9):
    note(55.68 + i * .03, 2.8, n + 12, .04 if i else .05, 'keys' if i else 'saw', (i - 3) * .2)
for i, n in enumerate(MOTIF + [83]):
    note(56.64 + i * S16 * 2, .4, n + 12, .06, 'bell', (-.45, -.15, .15, .45)[i])
for k in range(16):
    note(55.68 + k * S16 * 2, .04, E9[1 + ARP[k % 8] % 5] + 24, .02 * (1 - k / 16), 'sq', (-.4, .4)[k % 2], .4)

# ---- fades, gentle saturation, write ----
peak = max(max(abs(x) for x in L), max(abs(x) for x in R)) or 1
out = array.array('h')
for i in range(N):
    t = i / RATE
    g = min(1, t / .1) * min(1, (DURATION - t) / 1.8)
    for ch in (L, R):
        v = math.tanh(ch[i] / peak * 1.4) / math.tanh(1.4) * .7 * g
        out.append(int(max(-1, min(1, v)) * 32767))
with wave.open(sys.argv[1], 'wb') as w:
    w.setnchannels(2); w.setsampwidth(2); w.setframerate(RATE); w.writeframes(out.tobytes())
print(sys.argv[1], DURATION, 's')
