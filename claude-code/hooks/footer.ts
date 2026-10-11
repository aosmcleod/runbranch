import type { Busy, Target, View } from '../types'

// What the footer below the prompt shows, as plain data so it can be tested
// without drawing. At most two items: a dim label while there is nothing to
// press, otherwise the one or two things worth doing.

export type Does = 'start' | 'stop' | 'open'

export type Item =
  | { kind: 'label'; text: string }
  | { kind: 'button'; label: string; does: Does }

const RUN: Item = { kind: 'button', label: 'Run ↑', does: 'start' }
const OPEN: Item = { kind: 'button', label: 'Open ⛶', does: 'open' }
const STOP: Item = { kind: 'button', label: 'Stop ✕', does: 'stop' }

export function footerItems(view: View | null, busy: Busy | null): Item[] {
  if (busy) {
    return [{ kind: 'label', text: busy.label }]
  }
  if (!view || view.kind === 'unavailable') {
    return []
  }
  if (view.kind === 'none') {
    return [{ kind: 'label', text: 'No config' }]
  }
  if (view.kind === 'stopped') {
    return [RUN]
  }
  if (view.kind === 'blocked') {
    return [{ kind: 'label', text: `Port ${view.port} busy` }]
  }
  // Running another branch: Run restarts it on this one.
  return view.isThisBranch ? [OPEN, STOP] : [RUN, STOP]
}

// The target Open goes to: `web` where there is one, else the first declared.
export function primaryTarget(targets: Target[]): Target | undefined {
  return targets.find(t => t.name === 'web') ?? targets[0]
}
