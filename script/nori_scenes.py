"""Code-native SVG scenes, all sharing Nori's approved body.

Active states use centered squash/stretch and abstract loading accents. Their
rhythms differ without depicting the task's tools. Working keeps its signature
orbit; results and idle companion scenes keep their existing artwork.
"""

SCENE_LABELS = {
    'typing': '跃动', 'agent': '摇摆', 'disk': '浮动', 'apps': '呼吸', 'tidying': '脉动',
    'coffee': '喝咖啡', 'doze': '打盹', 'humming': '哼歌', 'bubble': '吹泡泡',
}

_TRICOLOR = ('ribbonBlue', 'ribbonGold', 'ribbonLilac')

# (dx, peak dy, fall dy, turn, color, round piece)
CONFETTI = (
    (-100, -36, 70, -160, 'ribbonBlue', False), (-68, -50, 64, 120, 'ribbonGold', True),
    (-34, -58, 76, -90, 'ribbonLilac', False), (2, -62, 70, 140, 'ribbonBlue', True),
    (36, -58, 80, -130, 'ribbonGold', False), (70, -50, 66, 100, 'ribbonLilac', True),
    (102, -36, 74, -150, 'ribbonBlue', False), (-86, -18, 90, 80, 'ribbonLilac', True),
    (88, -20, 88, -70, 'ribbonGold', True),
)
_BASE_CSS = '''
.chase{transform-box:fill-box;transform-origin:center}
.rise{transform-box:fill-box;transform-origin:50% 100%}
@keyframes nori-orbit {to{transform:rotate(360deg)}}
.orbit-spin{animation:nori-orbit 1.8s linear infinite;transform-origin:0 0}
@keyframes nori-lookBubble {0%,100%{transform:translate(5px,-4px)}50%{transform:translate(7px,-5px)}}
@keyframes nori-sway {0%,100%{transform:rotate(-3.5deg)}50%{transform:rotate(3.5deg)}}
@keyframes nori-content {0%,100%{transform:scaleY(.45)}}
@keyframes nori-note {0%{opacity:0;transform:translate(0,8px)}20%{opacity:1}100%{opacity:0;transform:translate(14px,-46px)}}
@keyframes breathe {0%,100%{transform:scale(1)}50%{transform:scale(1.012,.988)}}
@keyframes nori-sleepBreath {0%,100%{transform:scale(1,1)}50%{transform:scale(1.025,.975)}}
@keyframes nori-closed {0%,100%{transform:scaleY(.1)}}
@keyframes nori-z {0%{opacity:0;transform:translate(0,6px) scale(.7)}25%{opacity:1}100%{opacity:0;transform:translate(18px,-40px) scale(1.1)}}
@keyframes nori-bubbleRise {0%{transform:translate(0,0) scale(.3);opacity:0}12%{opacity:1}78%{transform:translate(18px,-120px) scale(1);opacity:1}86%{transform:translate(20px,-128px) scale(1.25);opacity:0}100%{transform:translate(20px,-128px) scale(1.25);opacity:0}}
@keyframes nori-bubbleGaze {0%,100%{transform:translate(-6px,6px)}78%{transform:translate(2px,-6px)}86%{transform:translate(2px,-6px)}}
@keyframes nori-happy {0%,100%{transform:scaleY(1)}20%,80%{transform:scaleY(.42)}}
@keyframes nori-badgePop {0%,8%{transform:scale(0) rotate(-20deg)}22%{transform:scale(1.18) rotate(6deg)}32%{transform:scale(.94) rotate(-3deg)}42%,100%{transform:scale(1) rotate(0deg)}}
@keyframes nori-sad {0%,100%{transform:translateY(0) scale(1,1)}30%,90%{transform:translateY(3px) scale(1.025,.965)}}
@keyframes nori-lookBadge {0%,14%{transform:translate(0,0)}30%,100%{transform:translate(6px,5px)}}
@keyframes nori-sip {0%,22%,100%{transform:translate(0,0) rotate(0deg)}46%,62%{transform:translate(-14px,-10px) rotate(-8deg)}}
@keyframes nori-sipBody {0%,22%,100%{transform:rotate(0deg) scale(1)}46%,62%{transform:rotate(2deg) scale(1.02,.98)}}
@keyframes nori-contented {0%,30%,74%,100%{transform:scaleY(1)}44%,62%{transform:scaleY(.14)}}
@keyframes nori-steam {0%{opacity:0;transform:translateY(3px)}25%{opacity:.6}100%{opacity:0;transform:translate(3px,-14px)}}
.cup-lift{transform-origin:184px 176px}
'''

_BUSY_CSS = '''
@keyframes nori-hop {0%,86%,100%{transform:translateY(0) scale(1,1)}14%{transform:translateY(0) scale(1.09,.91)}30%{transform:translateY(-13px) scale(.94,1.06)}45%{transform:translateY(0) scale(1.07,.93)}60%{transform:translateY(-6px) scale(.965,1.035)}73%{transform:translateY(0) scale(1.035,.965)}}
@keyframes nori-hopGaze {0%,45%,86%,100%{transform:translateY(0)}30%{transform:translateY(-4px)}60%{transform:translateY(-2px)}}
@keyframes nori-rock {0%,50%,100%{transform:translateY(0) rotate(0deg) scale(1,1)}25%{transform:translateY(-3px) rotate(-4deg) scale(1.055,.945)}75%{transform:translateY(-3px) rotate(4deg) scale(.965,1.035)}}
@keyframes nori-rockGaze {0%,50%,100%{transform:translateX(0)}25%{transform:translateX(-5px)}75%{transform:translateX(5px)}}
@keyframes nori-bob {0%,100%{transform:translateY(0) scale(1,1)}15%{transform:translateY(0) scale(1.075,.925)}48%{transform:translateY(-11px) scale(.95,1.05)}76%{transform:translateY(0) scale(1.04,.96)}}
@keyframes nori-bobGaze {0%,100%{transform:translateY(0)}48%{transform:translateY(-3px)}}
@keyframes nori-inflate {0%,100%{transform:translateY(0) scale(1,1)}25%{transform:translateY(0) scale(1.06,.94)}60%{transform:translateY(-4px) scale(.945,1.055)}}
@keyframes nori-pulse {0%,100%{transform:translateY(0) scale(1,1)}22%{transform:translateY(0) scale(1.085,.915)}48%{transform:translateY(-6px) scale(.945,1.055)}72%{transform:translateY(0) scale(1.04,.96)}}
@keyframes nori-dotBeat {0%,60%,100%{transform:translateY(0) scale(.8);opacity:.28}25%{transform:translateY(-5px) scale(1);opacity:1}}
@keyframes nori-dotChase {0%,65%,100%{transform:scale(.8);opacity:.25}28%{transform:scale(1.16);opacity:1}}
@keyframes nori-dotWave {0%,65%,100%{transform:translateY(0);opacity:.3}24%{transform:translateY(-4px);opacity:1}}
@keyframes nori-ripple {0%{transform:scale(.55,.75);opacity:0}18%{opacity:.65}100%{transform:scale(1.35,1.6);opacity:0}}
@keyframes nori-halo {0%,100%{transform:scale(.98,1);opacity:.25}60%{transform:scale(1.05,1.025);opacity:.9}}
.busy-dot,.ripple{transform-origin:0 0}
.busy-halo{transform-origin:128px 128px}
'''


def _confetti_css():
    rules = []
    for index, (dx, peak, fall, turn, _, _) in enumerate(CONFETTI):
        rules.append(
            f'@keyframes nori-confetti{index} {{0%{{opacity:0;transform:translate(0,0) rotate(0deg)}}'
            f'8%,72%{{opacity:1}}45%{{transform:translate({dx * .7:g}px,{peak}px) rotate({turn * .5:g}deg)}}'
            f'100%{{opacity:0;transform:translate({dx}px,{peak + fall}px) rotate({turn}deg)}}}}'
            f'.confetti{index}{{animation:nori-confetti{index} 1.6s cubic-bezier(.2,.6,.4,1) 1 both}}')
    return '\n'.join(rules)


SCENE_CSS = _BASE_CSS + _BUSY_CSS + _confetti_css() + '\n'

SCENE_RULES = {
    'typing': '.jelly{animation:nori-hop 1.65s ease-in-out infinite}.gaze{animation:nori-hopGaze 1.65s ease-in-out infinite}.eyelid{animation:blink 5.4s ease-in-out infinite}.busy-dot{animation:nori-dotBeat 1.65s ease-in-out infinite}',
    'agent': '.jelly{animation:nori-rock 1.8s ease-in-out infinite}.gaze{animation:nori-rockGaze 1.8s ease-in-out infinite}.eyelid{animation:blink 5.4s ease-in-out infinite}.busy-dot{animation:nori-dotChase 1.8s ease-in-out infinite}',
    'tidying': '.jelly{animation:nori-pulse 1.4s ease-in-out infinite}.gaze{animation:nori-bobGaze 1.4s ease-in-out infinite}.eyelid{animation:blink 5.4s ease-in-out infinite}.busy-dot{animation:nori-dotWave 1.4s ease-in-out infinite}',
    'disk': '.jelly{animation:nori-bob 2s ease-in-out infinite}.gaze{animation:nori-bobGaze 2s ease-in-out infinite}.eyelid{animation:blink 5.4s ease-in-out infinite}.ripple{animation:nori-ripple 2s ease-out infinite}',
    'apps': '.jelly{animation:nori-inflate 2.2s ease-in-out infinite}.gaze{animation:nori-bobGaze 2.2s ease-in-out infinite}.eyelid{animation:blink 5.4s ease-in-out infinite}.busy-halo{animation:nori-halo 2.2s ease-in-out infinite}',
    'coffee': '.jelly{animation:nori-sipBody 3.2s ease-in-out infinite}.eyelid{animation:nori-contented 3.2s ease-in-out infinite}.cup-lift{animation:nori-sip 3.2s ease-in-out infinite}.steam{animation:nori-steam 2.2s ease-out infinite}',
    'doze': '.jelly{animation:nori-sleepBreath 4s ease-in-out infinite}.eyelid{animation:nori-closed 1s infinite}.z{animation:nori-z 3s ease-out infinite}',
    'humming': '.jelly{animation:nori-sway 2.4s ease-in-out infinite}.eyelid{animation:nori-content 1s infinite}.note{animation:nori-note 2.4s ease-out infinite}',
    'bubble': '.jelly{animation:breathe 4s ease-in-out infinite}.gaze{animation:nori-bubbleGaze 4s ease-in-out infinite}.eyelid{animation:blink 6s ease-in-out infinite}.bubble{animation:nori-bubbleRise 4s ease-out infinite}',
}


def scene_css(colors):
    return SCENE_CSS


def _place(figure, x, y, scale=.78):
    return f'<g transform="translate({x} {y}) scale({scale})">{figure}</g>'


def working_scene(figure, colors):
    # The signature orbit: two clipped copies put the rear arc behind Nori.
    orbit = f'''<g transform="translate(128 139) rotate(-12) scale(1 .38)"><g class="orbit-spin" fill="none" stroke-width="11" stroke-linecap="round">
<circle r="111" stroke="#{colors['ribbonBlue']}" stroke-dasharray="168 530"/>
<circle r="111" stroke="#{colors['ribbonGold']}" stroke-dasharray="100 598" stroke-dashoffset="-245"/>
<circle r="111" stroke="#{colors['ribbonLilac']}" stroke-dasharray="126 572" stroke-dashoffset="-442"/>
</g></g>'''
    return f'''<defs>
<clipPath id="nori-working-rear"><path d="M0 0H256V112L0 166Z"/></clipPath>
<clipPath id="nori-working-front"><path d="M0 166L256 112V256H0Z"/></clipPath>
</defs>
<g class="orbit-prop" clip-path="url(#nori-working-rear)">{orbit}</g>
{_place(figure, 24, 30)}
<g class="orbit-prop" clip-path="url(#nori-working-front)">{orbit}</g>'''


def _busy_figure(figure):
    # Every abstract activity shares one optical center, scale and baseline.
    return _place(figure, 25, 24)


def _status_dots(colors, period):
    dots = ''.join(
        f'<g transform="translate({108 + index * 20} 221)">'
        f'<circle class="busy-dot" style="animation-delay:{-period + index * period / 3:g}s" '
        f'r="5" fill="#{colors[c]}"/></g>'
        for index, c in enumerate(_TRICOLOR))
    return f'<g class="orbit-prop">{dots}</g>'


def typing_scene(figure, colors):
    return f'{_busy_figure(figure)}{_status_dots(colors, 1.65)}'


def agent_scene(figure, colors):
    return f'{_busy_figure(figure)}{_status_dots(colors, 1.8)}'


def disk_scene(figure, colors):
    ripples = ''.join(
        f'<g transform="translate(128 221)"><ellipse class="ripple" '
        f'style="animation-delay:{-index:g}s" rx="40" ry="6" fill="none" '
        f'stroke="#{colors["ribbonBlue"]}" stroke-width="2.5"/></g>'
        for index in range(2))
    return f'{_busy_figure(figure)}<g class="orbit-prop">{ripples}</g>'


def apps_scene(figure, colors):
    halo = (f'<g class="orbit-prop"><g class="busy-halo" fill="none" '
            f'stroke="#{colors["ribbonBlue"]}" stroke-width="4" stroke-linecap="round">'
            '<path d="M33 69Q10 128 33 187"/><path d="M223 69Q246 128 223 187"/>'
            '</g></g>')
    return f'{halo}{_busy_figure(figure)}'


def tidying_scene(figure, colors):
    return f'{_busy_figure(figure)}{_status_dots(colors, 1.4)}'


def _result_badge(colors, succeeded):
    """The shared result badge pops onto Nori's lower right, overlapping the body;
    only colour and glyph differ. Big enough to read at the 20pt title-bar size."""
    ink, ice = f'#{colors["ink"]}', f'#{colors["body"]}'
    fill = colors['ribbonSuccess' if succeeded else 'ribbonFail']
    glyph = (f'<path d="M-17-1L-5 11L17-12" fill="none" stroke="{ice}" stroke-width="10" '
             'stroke-linecap="round" stroke-linejoin="round"/>' if succeeded else
             f'<rect x="-5.5" y="-22" width="11" height="25" rx="5.5" fill="{ice}"/><circle cy="14" r="6" fill="{ice}"/>')
    return (f'<g class="orbit-prop" transform="translate(198 190)"><g class="badge" style="transform-origin:0 0;'
            f'animation:nori-badgePop 1.9s cubic-bezier(.3,.7,.3,1) 1 both">'
            f'<circle r="42" fill="#{fill}" stroke="{ink}" stroke-width="4"/>{glyph}</g></g>')


def success_scene(figure, colors):
    """Nori hops with a happy squint, a green check pops on, and confetti bursts."""
    pieces = []
    for index, (_, _, _, _, color, rounded) in enumerate(CONFETTI):
        shape = (f'<circle r="7" fill="#{colors[color]}"/>' if rounded
                 else f'<rect x="-4.5" y="-10" width="9" height="20" rx="3" fill="#{colors[color]}"/>')
        pieces.append(f'<g class="confetti{index}">{shape}</g>')
    burst = f'<g class="orbit-prop" transform="translate(128 70)">{"".join(pieces)}</g>'
    return f'{_place(figure, 22, 30)}{burst}{_result_badge(colors, True)}'


def failure_scene(figure, colors):
    """Nori sinks a little and a coral exclamation badge pops on."""
    return f'{_place(figure, 22, 30)}{_result_badge(colors, False)}'


def coffee_scene(figure, colors):
    """Nori lifts a plain, handle-less cup for a sip while two wisps of steam rise."""
    ink, blue, ice = (f'#{colors[c]}' for c in ['ink', 'ribbonBlue', 'body'])
    steam = ''.join(
        f'<path class="steam" style="animation-delay:{-index * 1.1:g}s" d="M{x} 146C{x - 10} 138 {x + 10} 134 {x} 125" '
        f'fill="none" stroke="{blue}" stroke-width="4" stroke-linecap="round"/>'
        for index, x in enumerate((168, 186)))
    cup = (f'<path d="M155 155H203V186Q203 200 190 200H168Q155 200 155 186Z" fill="{ice}" stroke="{ink}" '
           f'stroke-width="3" stroke-linejoin="round"/>'
           f'<ellipse cx="179" cy="155" rx="24" ry="5.5" fill="{ink}"/>'
           f'<path d="M164 176H194" stroke="{blue}" stroke-width="5" stroke-linecap="round"/>')
    return f'{_place(figure, 7, 24, .81)}<g class="orbit-prop"><g class="cup-lift">{steam}{cup}</g></g>'


def doze_scene(figure, colors):
    lilac = f'#{colors["ribbonLilac"]}'
    zs = ''.join(
        f'<g transform="translate({x} {y}) scale({s})"><path class="z" style="animation-delay:{-index:g}s" '
        f'd="M-7-7H7L-7 7H7" fill="none" stroke="{lilac}" stroke-width="4" stroke-linecap="round" stroke-linejoin="round"/></g>'
        for index, (x, y, s) in enumerate(((196, 70, 1), (210, 52, 1.2), (222, 34, 1.45))))
    return f'{_place(figure, 12, 44)}<g class="orbit-prop">{zs}</g>'


def humming_scene(figure, colors):
    note = 'M0 0V-22L14-26V-6'
    notes = ''.join(
        f'<g transform="translate({x} {y})"><g class="note" style="animation-delay:{-index * .8:g}s">'
        f'<path d="{note}" fill="none" stroke="#{colors[c]}" stroke-width="4" stroke-linecap="round" stroke-linejoin="round"/>'
        f'<ellipse cx="-4" cy="1" rx="6" ry="4.6" fill="#{colors[c]}"/><ellipse cx="10" cy="-5" rx="6" ry="4.6" fill="#{colors[c]}"/></g></g>'
        for index, (x, y, c) in enumerate(((200, 104, 'ribbonBlue'), (214, 86, 'ribbonGold'), (192, 80, 'ribbonLilac'))))
    return f'{_place(figure, 12, 40)}<g class="orbit-prop">{notes}</g>'


def bubble_scene(figure, colors):
    blue = f'#{colors["ribbonBlue"]}'
    bubble = (f'<g class="orbit-prop" transform="translate(52 214)"><g class="bubble chase">'
              f'<circle r="15" fill="{blue}" fill-opacity=".14" stroke="{blue}" stroke-width="3"/>'
              f'<path d="M-7-4A8 8 0 0 1-2-9" fill="none" stroke="#{colors["body"]}" stroke-width="3" stroke-linecap="round"/>'
              '</g></g>')
    return f'{_place(figure, 52, 40)}{bubble}'


_SCENES = {
    'typing': typing_scene, 'agent': agent_scene, 'disk': disk_scene, 'apps': apps_scene,
    'tidying': tidying_scene,
    'success': success_scene, 'attention': failure_scene,
    'coffee': coffee_scene, 'doze': doze_scene, 'humming': humming_scene, 'bubble': bubble_scene,
}


def extra_scene(name, figure, colors, body, eyes):
    scene = _SCENES.get(name)
    return scene(figure, colors) if scene else figure
