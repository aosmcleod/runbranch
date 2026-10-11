import { describe, expect, test } from 'claude-code/testing'

import type { On } from 'claude-code'

import type { View } from '../types'

const FOOTER = { component: 'SessionMode', props: { modes: [] } } as const

const running: View = {
  kind: 'running', project: 'studio', branch: 'main', ref: 'main', isThisBranch: true,
  isInPlace: false, upFor: '', targets: [{ name: 'web', port: 3000, isAlive: true }],
}

// Stands in for the session's state: what the poll would have found.
// And for what draws in the footer after this mod (Next Up's buttons).
function probed(on: On, view: View) {
  on('state.get', { plugin: 'runbranch', key: 'view' }, async () => ({ value: { value: view, version: 1 } }))
  on('ui.render', { component: 'SessionMode' }, async ($, e) => {
    const { Text } = $.ui.resolve(e)
    return <Text>Next Up ↗</Text>
  })
}

describe('the footer', () => {
  test('draws its buttons and keeps what another mod draws there', async ($, on) => {
    probed(on, running)
    for (const surface of ['terminal', 'desktop'] as const) {
      const ui = await $.ui.mount({ plugin: 'runbranch', surface, ...FOOTER })
      expect(await ui.find({ key: 'runbranch-open' })).toBeDefined()
      expect(await ui.find({ key: 'runbranch-stop' })).toBeDefined()
      expect(await ui.find({ type: 'Text', text: 'Next Up ↗' })).toBeDefined()
      await ui.unmount()
    }
  })

  test('a folder with no config shows the label and no buttons', async ($, on) => {
    probed(on, { kind: 'none', root: 'C:/dev/x' })
    const ui = await $.ui.mount({ plugin: 'runbranch', surface: 'desktop', ...FOOTER })
    expect(await ui.find({ type: 'Text', text: 'No config' })).toBeDefined()
    expect(await ui.find({ key: 'runbranch-start' })).toBeUndefined()
    await ui.unmount()
  })
})
