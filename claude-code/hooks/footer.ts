import type { Busy, Target, View } from '../types'

// What the footer below the prompt shows, as plain data so it can be tested
// without drawing. At most two items, as symbols: the desktop app gives every
// mod's footer buttons one short width between them (anthropics/claude-code
// #100116), and Next Up's sit there too. Nothing shows where there is nothing
// to do, so a folder with no config shows nothing.

export type Does = 'start' | 'stop' | 'open'

export type Item =
  | { kind: 'label'; text: string }
  | { kind: 'button'; label: string; does: Does }

const RUN: Item = { kind: 'button', label: '↑', does: 'start' }
// With nothing of the project's running, Run is alone in the footer and
// there is room to say what it does: a bare arrow there reads as ambiguous.
const RUN_ALONE: Item = { kind: 'button', label: 'Run ↑', does: 'start' }
const OPEN: Item = { kind: 'button', label: '⛶', does: 'open' }
const STOP: Item = { kind: 'button', label: '✕', does: 'stop' }

export function footerItems(view: View | null, busy: Busy | null): Item[] {
  // Starting or stopping: an ellipsis, no words (the label is for toasts).
  if (busy) {
    return [{ kind: 'label', text: '…' }]
  }
  if (!view || view.kind === 'unavailable' || view.kind === 'none') {
    return []
  }
  if (view.kind === 'stopped') {
    return [RUN_ALONE]
  }
  if (view.kind === 'blocked') {
    return [{ kind: 'label', text: `:${view.port} busy` }]
  }
  // Running another branch: Run restarts it on this one.
  return view.isThisBranch ? [OPEN, STOP] : [RUN, STOP]
}

// The target Open goes to: `web` where there is one, else the first declared.
export function primaryTarget(targets: Target[]): Target | undefined {
  return targets.find(t => t.name === 'web') ?? targets[0]
}
