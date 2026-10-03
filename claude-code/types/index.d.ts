export type Target = { name: string; port: number; isAlive: boolean }

export type View =
  | { kind: 'unavailable'; reason: string }
  | { kind: 'none'; root: string }
  | { kind: 'stopped'; project: string; branch: string }
  | { kind: 'blocked'; project: string; branch: string; port: number; pid: number; what: string }
  | {
      kind: 'running'
      project: string
      branch: string
      ref: string
      isThisBranch: boolean
      isInPlace: boolean
      // How long it has been up, `14m` or `2h 5m`; empty when the engine did not say.
      upFor: string
      targets: Target[]
    }

// What the band is waiting on. The poll clears it once the engine reports one
// of `settles` (or `until` passes), so a lost reply can never leave it stuck.
export type Busy = { label: string; until: number; settles: View['kind'][] }

// What a press asked for. A press only queues it; the session's own timer runs
// it, so the press's time budget cannot cut the work off.
export type Action =
  | { kind: 'start' }
  | { kind: 'stop'; project: string }
  | { kind: 'free'; pid: number }
  | { kind: 'generate'; root: string }

declare module 'claude-code' {
  interface PluginState {
    'runbranch': {
      view: View | null
      busy: Busy | null
      pending: Action | null
      isExpanded: boolean
    }
  }
}
