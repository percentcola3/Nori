"""Write plan.audio.cues from shot actions. Landmarks measured with scripts/sfx_landmarks.py:
clicks/pops/toggles align their onset to the action; whooshes align their peak to the cut.
Usage: python3 audio/cues.py
"""
import json
from pathlib import Path

LANDMARK = {  # file: (onset, peak) in seconds
    'click': (.001, .008), 'click-alt': (.001, .007), 'pop': (.001, .006), 'toggle': (.001, .080),
    'whoosh': (.071, .202), 'success': (.003, .213), 'resolve': (.003, .232), 'ding-dong': (.002, .206),
    'sweep': (.135, .342), 'error': (.002, .111),
}
SFX = {  # actionId: (file, landmark, gain)
    'hook-fill': ('pop', 'onset', 2.0), 'hook-seg2': ('pop', 'onset', 1.5), 'hook-seg3': ('pop', 'onset', 1.6),
    'hook-seg4': ('pop', 'onset', 1.5), 'hook-seg5': ('pop', 'onset', 1.7), 'hook-seg6': ('pop', 'onset', 1.8),
    'hook-warn': ('error', 'onset', 1.1),
    'brand-wipe': ('whoosh', 'peak', 4.0), 'brand-title': ('resolve', 'onset', 1.6),
    'agents-wall': ('pop', 'onset', 1.8), 'agents-tick1': ('toggle', 'onset', 4.0),
    'agents-tick2': ('toggle', 'onset', 3.4), 'agents-tick3': ('toggle', 'onset', 3.4),
    'agents-warn': ('ding-dong', 'onset', 1.2),
    'dev-wall': ('pop', 'onset', 1.8), 'dev-click': ('click', 'onset', 3.6), 'dev-success': ('success', 'onset', 2.0),
    'devenv-wipe': ('whoosh', 'peak', 4.0), 'devenv-shell': ('pop', 'onset', 2.0),
    'devenv-hosts': ('click-alt', 'onset', 3.6), 'devenv-runtime': ('click', 'onset', 3.4),
    'devenv-path': ('toggle', 'onset', 3.4),
    'ports-click': ('click', 'onset', 3.6), 'ports-confirm': ('click-alt', 'onset', 3.8),
    'shot-wipe': ('whoosh', 'peak', 4.0), 'shot-rect': ('click-alt', 'onset', 3.2),
    'shot-arrow': ('click-alt', 'onset', 3.0), 'shot-mosaic': ('pop', 'onset', 2.0),
    'shot-preset1': ('click', 'onset', 3.4), 'shot-preset2': ('click', 'onset', 3.0), 'shot-preset3': ('click', 'onset', 3.0),
    'clip-cards': ('pop', 'onset', 1.8), 'clip-filter1': ('click', 'onset', 3.4),
    'clip-filter2': ('click', 'onset', 3.0), 'clip-filter3': ('click', 'onset', 3.0), 'clip-pin': ('toggle', 'onset', 3.6),
    'sched-preview': ('click', 'onset', 3.6), 'sched-on': ('toggle', 'onset', 4.0),
    'dup-scan': ('click-alt', 'onset', 3.0), 'dup-found': ('pop', 'onset', 2.0),
    'dup-tick1': ('toggle', 'onset', 3.6), 'dup-tick2': ('toggle', 'onset', 3.2),
    'montage-in': ('pop', 'onset', 1.8),
    'close-converge': ('sweep', 'onset', 3.6), 'close-title': ('ding-dong', 'onset', 1.8),
}
path = Path('plan.json')
plan = json.loads(path.read_text())
cues = []
for s in plan['shots']:
    for a in s['actions']:
        if a['id'] not in SFX:
            continue
        name, mark, gain = SFX[a['id']]
        offset = LANDMARK[name][0 if mark == 'onset' else 1]
        cues.append({'at': round(s['start'] + a['at'] - offset, 4), 'actionId': a['id'], 'file': f'assets/sfx/{name}.wav',
                     'syncOffset': offset, 'gain': gain, 'role': 'sfx', 'kind': name})
plan['audio']['cues'] = cues
path.write_text(json.dumps(plan, ensure_ascii=False, indent=2) + '\n')
print(len(cues), 'cues')
