// Map every plan.json shot id to a view and a builder. Builders receive the master timeline.
import {HookView, buildHook, BrandView, buildBrand, CloseView, buildClose} from './intro.jsx';
import {AgentsView, buildAgents, DevjunkView, buildDevjunk, DevenvView, buildDevenv, PortsView, buildPorts} from './features.jsx';
import {ScreenshotView, buildScreenshot, ClipboardView, buildClipboard, ScheduleView, buildSchedule, DuplicatesView, buildDuplicates, MontageView, buildMontage} from './more.jsx';
export const SHOT_VIEWS = {hook: HookView, brand: BrandView, agents: AgentsView, devjunk: DevjunkView, devenv: DevenvView, ports: PortsView,
  screenshot: ScreenshotView, clipboard: ClipboardView, schedule: ScheduleView, duplicates: DuplicatesView, montage: MontageView, close: CloseView};
export const SHOT_BUILDERS = {hook: buildHook, brand: buildBrand, agents: buildAgents, devjunk: buildDevjunk, devenv: buildDevenv, ports: buildPorts,
  screenshot: buildScreenshot, clipboard: buildClipboard, schedule: buildSchedule, duplicates: buildDuplicates, montage: buildMontage, close: buildClose};
