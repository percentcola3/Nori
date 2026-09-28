"""Extra code-native SVG scenes. Props live here; Nori's approved body stays shared."""

SCENE_LABELS = {'typing': '敲键盘', 'coffee': '喝咖啡', 'mirror': '照镜子'}
SCENE_RULES = {
    'typing': '.jelly{animation:nori-typeBody .56s ease-in-out infinite}.gaze{transform:translate(0,8px)}.eyelid{animation:blink 5s ease-in-out infinite}.hand-left{animation:nori-tap .28s ease-in-out infinite alternate}.hand-right{animation:nori-tap .28s ease-in-out -.28s infinite alternate}.key-hit{animation:nori-key .56s steps(1) infinite}.key-hit.second{animation-delay:-.28s}',
    'coffee': '.jelly{animation:nori-sipBody 6s ease-in-out infinite}.eyelid{animation:nori-contented 6s ease-in-out infinite}.cup-lift{animation:nori-sip 6s ease-in-out infinite}.steam{animation:nori-steam 2.4s ease-out infinite}.steam.second{animation-delay:-1.2s}',
    'mirror': '.jelly{animation:nori-mirrorPose 6s ease-in-out infinite}.gaze{transform:translate(9px,0)}.eyelid{animation:blink 4.8s ease-in-out infinite}.mirror-reflection{animation:nori-reflect 6s ease-in-out infinite}.mirror-glint{animation:nori-glint 6s ease-in-out infinite}',
}
SCENE_CSS = '''
@keyframes nori-orbit {to{transform:rotate(360deg)}}
.orbit-spin{animation:nori-orbit 1.8s linear infinite;transform-origin:0 0}
@keyframes nori-typeBody {0%,100%{transform:scale(1,1)}50%{transform:scale(1.025,.975)}}
@keyframes nori-tap {from{transform:translateY(-4px) rotate(-3deg)}to{transform:translateY(5px) rotate(3deg)}}
.hand-left{transform-origin:95px 182px}.hand-right{transform-origin:147px 182px}
@keyframes nori-key {0%,49%{fill:#F2C66D}50%,100%{fill:#69C7DD}}
.cup-lift{transform-origin:184px 176px}
@keyframes nori-sip {0%,16%,78%,100%{transform:translate(0,0) rotate(0deg)}34%,60%{transform:translate(-32px,-24px) rotate(-12deg)}68%{transform:translate(-12px,-8px) rotate(-4deg)}}
@keyframes nori-sipBody {0%,18%,78%,100%{transform:rotate(0deg) scale(1)}38%,60%{transform:rotate(3deg) scale(1.025,.975)}}
@keyframes nori-contented {0%,24%,70%,100%{transform:scaleY(1)}35%,60%{transform:scaleY(.12)}}
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


def extra_scene(name, figure, colors, body, eyes):
    ink, blue, ice = (f'#{colors[c]}' for c in ['ink', 'ribbonBlue', 'body'])
    if name == 'typing':
        keys = ''.join(f'<rect x="{59+col*22}" y="{196+row*11}" width="16" height="6" rx="2" fill="{blue}" class="{"key-hit" if (row,col)==(0,2) else "key-hit second" if (row,col)==(1,4) else "key"}"/>' for row in range(2) for col in range(6))
        return f'''<g transform="translate(15 16) scale(.8)">{figure}</g>
<g aria-hidden="true"><path d="M54 186H201L217 225Q219 231 211 231H43Q35 231 38 224Z" fill="{ink}" stroke="{blue}" stroke-width="3" stroke-linejoin="round"/>
{keys}<rect x="90" y="218" width="68" height="5" rx="2.5" fill="{blue}"/>
<g class="hand-left"><ellipse cx="96" cy="182" rx="17" ry="10" fill="{ice}" stroke="{ink}" stroke-width="3"/></g>
<g class="hand-right"><ellipse cx="148" cy="182" rx="17" ry="10" fill="{ice}" stroke="{ink}" stroke-width="3"/></g></g>'''
    if name == 'coffee':
        return f'''<g transform="translate(7 24) scale(.81)">{figure}</g>
<g class="cup-lift" aria-hidden="true">
<path class="steam" d="M165 147C155 139 175 135 165 126" fill="none" stroke="{blue}" stroke-width="4" stroke-linecap="round"/>
<path class="steam second" d="M184 146C174 138 194 132 185 124" fill="none" stroke="{blue}" stroke-width="4" stroke-linecap="round"/>
<path d="M202 161H211C229 161 229 187 210 187H200" fill="none" stroke="{blue}" stroke-width="8"/>
<path d="M153 155H204V187Q204 201 191 201H167Q153 201 153 187Z" fill="{ice}" stroke="{ink}" stroke-width="3"/>
<ellipse cx="178.5" cy="155" rx="25.5" ry="6" fill="{ink}" stroke="{blue}" stroke-width="3"/>
<path d="M163 179H192" stroke="{blue}" stroke-width="5" stroke-linecap="round"/>
<ellipse cx="151" cy="185" rx="13" ry="10" fill="{ice}" stroke="{ink}" stroke-width="3"/>
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
