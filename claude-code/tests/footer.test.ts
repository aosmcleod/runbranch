import { describe, expect, test } from 'claude-code/testing'

import type { Target, View } from '../types'
import { footerItems, primaryTarget } from '../hooks/footer'

const web: Target = { name: 'web', port: 3000, isAlive: true }
const api: Target = { name: 'api', port: 4000, isAlive: true }

function running(over: Partial<Extract<View, { kind: 'running' }>> = {}): View {
  return {
    kind: 'running', project: 'studio', branch: 'main', ref: 'main', isThisBranch: true,
    isInPlace: false, upFor: '3m', targets: [api, web], ...over,
  }
}

const labels = (view: View | null, busy: Parameters<typeof footerItems>[1] = null) =>
  footerItems(view, busy).map(item => (item.kind === 'label' ? `(${item.text})` : item.label))

describe('footerItems', () => {
  test('shows nothing until probed, outside git or without Runbranch', () => {
    expect(labels(null)).toEqual([])
    expect(labels({ kind: 'unavailable', reason: 'Runbranch not installed' })).toEqual([])
  })

  test('a folder with no config says so, with nothing to press', () => {
    expect(labels({ kind: 'none', root: 'C:/dev/x' })).toEqual(['(No config)'])
  })

  test('stopped offers Run', () => {
    expect(labels({ kind: 'stopped', project: 'studio', branch: 'main' })).toEqual(['Run ↑'])
  })

  test('a taken port is a label only', () => {
    const blocked: View = { kind: 'blocked', project: 'studio', branch: 'main', port: 3000, pid: 9, what: 'node.exe' }
    expect(labels(blocked)).toEqual(['(Port 3000 busy)'])
  })

  test('running here offers Open and Stop', () => {
    expect(labels(running())).toEqual(['Open ⛶', 'Stop ✕'])
  })

  test('running another branch offers Run (to restart here) and Stop', () => {
    expect(labels(running({ ref: 'feature', isThisBranch: false }))).toEqual(['Run ↑', 'Stop ✕'])
  })

  test('while busy, the busy label replaces every button', () => {
    const busy = { label: 'Starting…', until: 0, settles: ['running' as const] }
    expect(labels(running(), busy)).toEqual(['(Starting…)'])
    expect(labels(null, busy)).toEqual(['(Starting…)'])
  })
})

describe('primaryTarget', () => {
  test('prefers web, else the first target', () => {
    expect(primaryTarget([api, web])).toEqual(web)
    expect(primaryTarget([api])).toEqual(api)
    expect(primaryTarget([])).toBeUndefined()
  })
})
