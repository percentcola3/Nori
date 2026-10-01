"""Extra code-native SVG scenes. Props live here; Nori's approved body stays shared."""

SCENE_LABELS = {'typing': '键帽飞舞', 'analyzing': '键帽掉落', 'coffee': '喝咖啡', 'mirror': '照镜子'}
SCENE_RULES = {
    # The typing thumps land on the keycap launch rhythm (0/.6/1.2/1.9s of the
    # shared 2.6s cycle) so the body squash reads as the keystroke impact.
    'typing': '.jelly{animation:nori-typeJelly 2.6s ease-in-out infinite}.eyelid{animation:blink 5s ease-in-out infinite}.gaze{animation:nori-typeGaze 2.6s ease-in-out infinite}.key-fly{animation:nori-keyFly 2.6s ease-in-out infinite}',
    'analyzing': '.jelly{animation:breathe 6s ease-in-out infinite}.eyelid{animation:blink 4.6s ease-in-out infinite}.gaze{transform:translate(0,3px)}.key-drop{animation:nori-keyDrop 2.2s ease-in infinite}',
    'coffee': '.jelly{animation:nori-sipBody 3.2s ease-in-out infinite}.eyelid{animation:nori-contented 3.2s ease-in-out infinite}.cup-lift{animation:nori-sip 3.2s ease-in-out infinite}.steam{animation:nori-steam 2.2s ease-out infinite}.steam.second{animation-delay:-1.1s}',
    'mirror': '.jelly{animation:nori-mirrorPose 6s ease-in-out infinite}.gaze{transform:translate(9px,0)}.eyelid{animation:blink 4.8s ease-in-out infinite}.mirror-reflection{animation:nori-reflect 6s ease-in-out infinite}.mirror-glint{animation:nori-glint 6s ease-in-out infinite}',
}
SCENE_CSS = '''
@keyframes nori-orbit {to{transform:rotate(360deg)}}
.orbit-spin{animation:nori-orbit 1.8s linear infinite;transform-origin:0 0}
@keyframes nori-keyFly {0%{opacity:0;transform:translate(0,10px) rotate(0deg)}12%,78%{opacity:1}100%{opacity:0;transform:translate(var(--dx),var(--dy)) rotate(var(--turn))}}
@keyframes nori-keyDrop {0%{opacity:0;transform:translate(0,-42px) rotate(-8deg)}14%,76%{opacity:1}100%{opacity:0;transform:translate(var(--dx),64px) rotate(var(--turn))}}
.key-fly,.key-drop{opacity:0}
@keyframes nori-typeJelly {0%,100%{transform:translateY(0) rotate(0deg) scale(1,1)}4%{transform:translateY(4px) rotate(-2deg) scale(1.06,.94)}10%{transform:translateY(-3px) rotate(1.4deg) scale(.965,1.035)}16%{transform:translateY(0) rotate(-.5deg) scale(1.02,.98)}27%{transform:translateY(4px) rotate(2deg) scale(1.06,.94)}33%{transform:translateY(-3px) rotate(-1.4deg) scale(.965,1.035)}39%{transform:translateY(0) rotate(.5deg) scale(1.02,.98)}50%{transform:translateY(4px) rotate(-1.5deg) scale(1.055,.945)}56%{transform:translateY(-2.5px) rotate(1deg) scale(.97,1.03)}62%{transform:translateY(0) rotate(0deg) scale(1.01,.99)}77%{transform:translateY(4px) rotate(1.5deg) scale(1.055,.945)}83%{transform:translateY(-2.5px) rotate(-1deg) scale(.97,1.03)}90%{transform:translateY(0) rotate(0deg) scale(1,1)}}
@keyframes nori-typeGaze {0%,6%{transform:translate(-4px,3px)}23%,29%{transform:translate(5px,4px)}46%,52%{transform:translate(2px,3px)}73%,79%{transform:translate(-1px,4px)}100%{transform:translate(-4px,3px)}}
.cup-lift{transform-origin:184px 176px}
@keyframes nori-sip {0%,22%,100%{transform:translate(0,0) rotate(0deg)}46%,62%{transform:translate(-14px,-10px) rotate(-8deg)}}
@keyframes nori-sipBody {0%,22%,100%{transform:rotate(0deg) scale(1)}46%,62%{transform:rotate(2deg) scale(1.02,.98)}}
@keyframes nori-contented {0%,30%,74%,100%{transform:scaleY(1)}44%,62%{transform:scaleY(.14)}}
@keyframes nori-steam {0%{opacity:0;transform:translateY(3px)}25%{opacity:.6}100%{opacity:0;transform:translate(3px,-14px)}}
@keyframes nori-mirrorPose {0%,15%,100%{transform:rotate(0deg)}38%{transform:rotate(4deg)}65%,80%{transform:rotate(-3deg)}}
@keyframes nori-reflect {0%,15%,100%{transform:translate(0,0)}38%{transform:translate(-2px,1px)}65%,80%{transform:translate(2px,-1px)}}
@keyframes nori-glint {0%,15%,65%,100%{opacity:0;transform:translateX(-10px)}25%{opacity:.6}50%{opacity:0;transform:translateX(12px)}}
'''


def working_scene(figure, colors):
    # Two copies of the same orbit are clipped into rear/front halves. The
    # mascot occludes the rear arc while the front arc passes over its body.
    orbit = f'''<g transform="translate(128 139) rotate(-12) scale(1 .38)"><g class="orbit-spin" fill="none" stroke-width="11" stroke-linecap="round">
<circle r="111" stroke="#{colors['ribbonBlue']}" stroke-dasharray="168 530"/>
<circle r="111" stroke="#{colors['ribbonGold']}" stroke-dasharray="100 598" stroke-dashoffset="-245"/>
<circle r="111" stroke="#{colors['ribbonLilac']}" stroke-dasharray="126 572" stroke-dashoffset="-442"/>
</g></g>'''
    return f'''<defs>
<clipPath id="nori-working-rear"><path d="M0 0H256V112L0 166Z"/></clipPath>
<clipPath id="nori-working-front"><path d="M0 166L256 112V256H0Z"/></clipPath>
</defs>
<g clip-path="url(#nori-working-rear)">{orbit}</g>
<g transform="translate(24 30) scale(.78)">{figure}</g>
<g clip-path="url(#nori-working-front)">{orbit}</g>'''


_KEY_LEGENDS = (
    'M-7 5L0-7L7 5M-4 1.2H4',
    'M-6-1.5H6M-6 4.5H6',
    'M0-6.5V6.5M-6.5 0H6.5',
    'M-7 3H3V-6',
)


def _keycaps(items, klass, colors):
    ink = f'#{colors["ink"]}'
    parts = []
    for index, (x, y, dx, dy, turn, delay, color) in enumerate(items):
        fill = f'#{colors[color]}'
        legend = _KEY_LEGENDS[index % len(_KEY_LEGENDS)]
        parts.append(
            f'<g transform="translate({x} {y})"><g class="{klass}" style="--dx:{dx}px;--dy:{dy}px;--turn:{turn}deg;animation-delay:{delay}s">'
            f'<rect x="-18" y="-6" width="36" height="24" rx="7" fill="{ink}"/>'
            f'<rect x="-18" y="-13" width="36" height="20" rx="7" fill="{fill}" stroke="{ink}" stroke-width="2.6"/>'
            f'<path d="{legend}" fill="none" stroke="{ink}" stroke-width="2.4" stroke-linecap="round" stroke-linejoin="round"/>'
            f'</g></g>'
        )
    return ''.join(parts)


def _keyboard(colors):
    # The typing anchor prop: a small tilted tray under the mascot so the
    # flying keycaps have a launch surface to pop from.
    ink, ice = (f'#{colors[c]}' for c in ['ink', 'body'])
    row = ''.join(
        f'<rect x="{x}" y="206" width="15" height="10" rx="3" fill="#{colors[c]}"/>'
        for x, c in zip(range(50, 191, 20), ['ribbonBlue', 'ribbonGold', 'ribbonLilac'] * 3))
    return (
        f'<g aria-hidden="true" transform="rotate(-1.2 128 217)">'
        f'<rect x="30" y="199" width="196" height="37" rx="11" fill="{ice}" stroke="{ink}" stroke-width="3"/>'
        f'{row}'
        f'<rect x="70" y="221" width="116" height="8" rx="4" fill="{ink}" opacity=".85"/>'
        '</g>')


def extra_scene(name, figure, colors, body, eyes):
    ink, blue, ice = (f'#{colors[c]}' for c in ['ink', 'ribbonBlue', 'body'])
    if name in ('typing', 'analyzing'):
        flying = [
            (62, 192, -34, -58, -16, 0, 'ribbonBlue'),
            (108, 188, -8, -66, 10, -0.7, 'ribbonGold'),
            (158, 190, 14, -62, -12, -1.4, 'ribbonLilac'),
            (198, 194, 30, -50, 18, -2.0, 'body'),
        ]
        falling = [
            (44, 36, -6, 0, 10, 0, 'ribbonBlue'),
            (112, 22, 2, 0, -8, -0.55, 'ribbonGold'),
            (178, 30, 4, 0, 12, -1.1, 'ribbonLilac'),
            (214, 78, 10, 0, -10, -1.65, 'body'),
        ]
        klass = 'key-fly' if name == 'typing' else 'key-drop'
        keys = _keycaps(flying if name == 'typing' else falling, klass, colors)
        deck = _keyboard(colors) if name == 'typing' else ''
        return f'<g transform="translate(28 40) scale(.74)">{figure}</g>{deck}<g aria-hidden="true">{keys}</g>'
    if name == 'coffee':
        return f'''<g transform="translate(7 24) scale(.81)">{figure}</g>
<g class="cup-lift" aria-hidden="true">
<path class="steam" d="M165 147C155 139 175 135 165 126" fill="none" stroke="{blue}" stroke-width="4" stroke-linecap="round"/>
<path class="steam second" d="M184 146C174 138 194 132 185 124" fill="none" stroke="{blue}" stroke-width="4" stroke-linecap="round"/>
<path d="M202 161H211C229 161 229 187 210 187H200" fill="none" stroke="{blue}" stroke-width="8"/>
<path d="M153 155H204V187Q204 201 191 201H167Q153 201 153 187Z" fill="{ice}" stroke="{ink}" stroke-width="3"/>
<ellipse cx="178.5" cy="155" rx="25.5" ry="6" fill="{ink}" stroke="{blue}" stroke-width="3"/>
<path d="M163 179H192" stroke="{blue}" stroke-width="5" stroke-linecap="round"/>
</g>'''
    if name == 'mirror':
        return f'''<defs><clipPath id="nori-mirror-glass"><ellipse cx="203" cy="108" rx="31" ry="43"/></clipPath></defs>
<g transform="translate(-1 31) scale(.73)">{figure}</g>
<g aria-hidden="true"><path d="M201 150L191 207" stroke="{ink}" stroke-width="16" stroke-linecap="round"/><path d="M201 150L191 207" stroke="{blue}" stroke-width="9" stroke-linecap="round"/>
<ellipse cx="203" cy="108" rx="35" ry="47" fill="{ink}" stroke="{blue}" stroke-width="4"/>
<g clip-path="url(#nori-mirror-glass)"><ellipse cx="203" cy="108" rx="31" ry="43" fill="#264B60"/>
<g class="mirror-reflection"><g transform="translate(230 81) scale(-.25 .25)">{body}{eyes}</g></g>
<path class="mirror-glint" d="M172 130L218 69M182 138L228 77" stroke="{ice}" stroke-width="6" opacity="0"/>
</g><ellipse cx="185" cy="177" rx="12" ry="9" fill="{ice}" stroke="{ink}" stroke-width="3"/></g>'''
    return figure
