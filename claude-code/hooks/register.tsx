import { atom, read, update } from 'claude-code'
import type { EngineInterface, Register } from 'claude-code'

import type { Action, Busy, Target, View } from '../types'

// Shows whether the session's folder and branch are running under Runbranch,
// and starts, stops or opens it. Reads the session's folder and nothing else:
// no prompt, turn or tool hooks. Every fact comes from the runbranch engine.

const view = atom({ plugin: 'runbranch', key: 'view' } as const, null)
const busy = atom({ plugin: 'runbranch', key: 'busy' } as const, null)
const pending = atom({ plugin: 'runbranch', key: 'pending' } as const, null)
const isExpanded = atom({ plugin: 'runbranch', key: 'isExpanded' } as const, false)

const POLL_MS = 5000
const DRAIN_MS = 500

type Ctx = {
  rb: string
  isWindows: boolean
  root: string
  commonDir: string
  branch: string
  project: string | null
  isInPlace: boolean
}

const norm = (path: string, isWindows: boolean) => {
  const p = path.trim().replace(/\\/g, '/').replace(/\/+$/, '')

  return isWindows ? p.toLowerCase() : p
}

const lines = (text: string) => text.split(/\r?\n/).filter(line => line.trim() !== '')

function upFor(epoch: number, now: number) {
  if (!epoch) {
    return ''
  }
  const minutes = Math.max(0, Math.floor((now / 1000 - epoch) / 60))
  return minutes < 60 ? `${minutes}m` : `${Math.floor(minutes / 60)}h ${minutes % 60}m`
}

const lastLine = (text: string) => lines(text).pop() ?? ''

// Module variables start over on a reload; the poll fills them again.
let rbPath: string | null | undefined
let isProbing = false
let isDraining = false
let ctx: Ctx | null = null

function run($: EngineInterface, argv: string[], init: { cwd?: string; timeoutMs?: number } = {}) {
  return $.process.run(argv, { timeoutMs: 15000, ...init })
}

async function findRunbranch($: EngineInterface, isWindows: boolean) {
  const candidates: string[] = []
  if (isWindows) {
    const local = await run($, ['cmd', '/c', 'echo', '%LOCALAPPDATA%'])
    candidates.push(`${local.stdout.trim()}\\Programs\\Runbranch\\bin\\runbranch.exe`)
  } else {
    candidates.push('/Applications/Runbranch.app/Contents/Helpers/runbranch')
  }
  for (const path of candidates) {
    const found = await $.fs.stat(path).then(() => true, () => false)
    if (found) {
      return path
    }
  }
  const onPath = await run($, [isWindows ? 'where' : 'which', 'runbranch']).catch(() => null)

  return onPath && onPath.exitCode === 0 ? lines(onPath.stdout)[0] ?? null : null
}

async function probe($: EngineInterface): Promise<View | null> {
  const cwd = await $.session.cwd()
  const isWindows = /^[A-Za-z]:[\\/]/.test(cwd)

  const git = await run($, [
    'git', 'rev-parse', '--path-format=absolute', '--show-toplevel', '--git-common-dir', '--abbrev-ref', 'HEAD',
  ], { cwd }).catch(() => null)
  if (!git || git.exitCode !== 0) {
    ctx = null
    return null
  }
  const [root, commonDir, branch] = lines(git.stdout)
  if (!root || !commonDir || !branch) {
    ctx = null
    return null
  }

  if (rbPath === undefined) {
    rbPath = await findRunbranch($, isWindows)
  }
  if (!rbPath) {
    ctx = null
    return { kind: 'unavailable', reason: 'Runbranch not installed' }
  }
  const rb = rbPath

  const projects = await run($, [rb, 'projects'])
  let project: string | null = null
  let isInPlace = false
  for (const row of lines(projects.stdout)) {
    const [id, , repo] = row.split('\t')
    if (!id || !repo) {
      continue
    }
    if (norm(repo, isWindows) === norm(root, isWindows)) {
      project = id
      isInPlace = true
      break
    }
    if (`${norm(repo, isWindows)}/.git` === norm(commonDir, isWindows)) {
      project = id
    }
  }
  ctx = { rb, isWindows, root, commonDir, branch, project, isInPlace }

  if (!project) {
    return { kind: 'none', root }
  }

  const state = await run($, [rb, 'state', project])
  const rows = lines(state.stdout).map(line => line.split('\t'))
  const runRow = rows.find(row => row[0] === 'run')
  if (runRow) {
    const targets: Target[] = rows
      .filter(row => row[0] === 'target')
      .map(row => ({ name: row[1] ?? '', port: Number(row[2]), isAlive: row[5] === '1' }))
    const ref = runRow[1] ?? ''

    return {
      kind: 'running',
      project,
      branch,
      ref,
      isThisBranch: ref === branch,
      isInPlace: runRow[6] === '1',
      upFor: upFor(Number(runRow[4]), await $.clock.now()),
      targets,
    }
  }

  const ports = await run($, [rb, 'ports'])
  const taken = lines(ports.stdout)
    .map(line => line.split('\t'))
    .find(row => row[0] === project && row[3] !== 'free')
  if (taken) {
    // `what` is "<pid> <command line>": the program's file name is enough.
    const rest = (taken[7] ?? '').replace(/^\d+\s+/, '')
    const command = rest.match(/^"([^"]+)"/)?.[1] ?? rest.split(/\s/)[0] ?? ''
    const what = command.split(/[\\/]/).pop() || taken[4] || 'another process'
    return { kind: 'blocked', project, branch, port: Number(taken[2]), pid: Number(taken[6]), what }
  }

  return { kind: 'stopped', project, branch }
}

async function refresh($: EngineInterface) {
  if (isProbing) {
    return
  }
  isProbing = true
  try {
    const next = await probe($)
    await update($, view, () => next)
    const waiting = await read($, busy)
    if (waiting && (isSettled(waiting, next) || (await $.clock.now()) > waiting.until)) {
      await update($, busy, () => null)
    }
  } catch (error) {
    $.ui.log(`runbranch: ${String(error)}`, { to: 'debug' })
  } finally {
    isProbing = false
  }
}

function isSettled(waiting: Busy, next: View | null) {
  if (!next || !waiting.settles.includes(next.kind)) {
    return false
  }
  // Started means up on this branch with every target alive, not merely "a run exists".
  return next.kind !== 'running' || (next.isThisBranch && next.targets.every(t => t.isAlive))
}

// Runs one engine command with the band showing `label` meanwhile, then
// re-reads the state. The engine says what went wrong on its last line.
async function act(
  $: EngineInterface,
  label: string,
  argv: string[],
  settles: View['kind'][],
  timeoutMs = 60000,
) {
  if (await read($, busy)) {
    return
  }
  const until = (await $.clock.now()) + timeoutMs + POLL_MS
  await update($, busy, () => ({ label, until, settles }))
  try {
    const result = await run($, argv, { timeoutMs, cwd: ctx?.root })
    if (result.exitCode !== 0) {
      $.ui.toast(lastLine(result.stderr) || lastLine(result.stdout) || `${label} failed`)
    }
  } catch (error) {
    $.ui.toast(`${label} failed: ${String(error)}`)
  } finally {
    await update($, busy, () => null)
    await refresh($)
  }
}

async function start($: EngineInterface) {
  if (!ctx?.project) {
    return
  }
  const { rb, project, branch, isInPlace } = ctx
  // The widest preset: `all` by default, or the custom one naming the most
  // targets (Studio's `full=web,admin`).
  const presets = lines((await run($, [rb, 'presets', project])).stdout)
  const declared = lines((await run($, [rb, 'get', project])).stdout)
    .find(line => line.startsWith('PRESETS\t'))
    ?.slice('PRESETS\t'.length) ?? ''
  const width = (name: string) =>
    declared.split(/\s+/).find(entry => entry.startsWith(`${name}=`))?.split(',').length ?? 0
  const preset = presets.includes('all')
    ? 'all'
    : [...presets].sort((a, b) => width(b) - width(a))[0] ?? 'all'
  const argv = [rb, 'run', project, branch, preset, ...(isInPlace ? ['--in-place'] : [])]
  // A worktree run installs dependencies first, which can take minutes.
  await act($, 'Starting…', argv, ['running'], 600000)
}

async function perform($: EngineInterface, action: Action) {
  const rb = ctx?.rb ?? 'runbranch'
  if (action.kind === 'start') {
    await start($)
  } else if (action.kind === 'stop') {
    await act($, 'Stopping…', [rb, 'stop', action.project], ['stopped', 'blocked', 'none'])
  } else if (action.kind === 'free') {
    await act($, 'Freeing port…', [rb, 'kill-port', String(action.pid)], ['stopped', 'running', 'none'])
  } else {
    await act($, 'Generating config…', [rb, 'add', action.root], ['stopped', 'running', 'blocked'], 120000)
  }
}

// Runs what a press queued, from the session's timer.
async function drain($: EngineInterface) {
  if (isDraining) {
    return
  }
  isDraining = true
  try {
    const action = await read($, pending)
    if (action) {
      await update($, pending, () => null)
      await perform($, action)
    }
  } finally {
    isDraining = false
  }
}

function open($: EngineInterface, port: number) {
  const url = `http://localhost:${port}`
  const argv = ctx?.isWindows === false
    ? ['open', url]
    : ['rundll32', 'url.dll,FileProtocolHandler', url]
  void run($, argv).catch(() => $.ui.toast(`Couldn't open ${url}`))
}

export const register: Register = on => {
  on('session.start', async ($, e, next) => {
    const started = await next(e)
    void refresh($)
    $.clock.every(POLL_MS, () => void refresh($))
    $.clock.every(DRAIN_MS, () => void drain($))

    return started
  })

  on('ui.render', { component: 'AbovePrompt' }, async ($, e, next) => {
    const current = await read($, view)
    if (e.props.hasSurvey || current === null) {
      return next(e)
    }
    const working = await read($, busy)
    const expanded = await read($, isExpanded)
    const { Box, Button, Text } = $.ui.resolve(e)
    const queue = (action: Action) => void update($, pending, () => action)

    // One row in every state: what is going on at the left, the one thing to
    // do about it pinned to the right edge.
    const row = (left: JSX.Element[], right: JSX.Element[]) => (
      <Box flexDirection="row" justifyContent="space-between" alignItems="center" width="100%">
        <Box flexDirection="row" alignItems="center" gap={1} flexShrink={1}>
          {left}
        </Box>
        <Box flexDirection="row" alignItems="center" gap={1}>
          {right}
        </Box>
      </Box>
    )
    const dot = (color: string, key: string) => <Text key={key} color={color}>●</Text>

    if (working) {
      return row([<Text key="busy" dimColor>{working.label}</Text>], [])
    }

    if (current.kind === 'unavailable') {
      return row([<Text key="why" dimColor>{current.reason}</Text>], [])
    }

    if (current.kind === 'none') {
      return row(
        [<Text key="why" dimColor>No Runbranch config for this folder</Text>],
        [<Button key="generate" label="Generate config" onPress={() => queue({ kind: 'generate', root: current.root })} />],
      )
    }

    if (current.kind === 'stopped') {
      return row(
        [<Text key="dot" dimColor>○</Text>, <Text key="why" dimColor>Not running</Text>],
        [<Button key="start" label="Start" variant="primary" onPress={() => queue({ kind: 'start' })} />],
      )
    }

    if (current.kind === 'blocked') {
      return row(
        [dot('red', 'dot'), <Text key="why" dimColor wrap="truncate-end">:{current.port} is taken by {current.what}</Text>],
        [<Button key="free" label="Free port" onPress={() => queue({ kind: 'free', pid: current.pid })} />],
      )
    }

    const stop = <Button key="stop" label="Stop" onPress={() => queue({ kind: 'stop', project: current.project })} />

    if (!current.isThisBranch) {
      return row(
        [dot('yellow', 'dot'), <Text key="why" dimColor wrap="truncate-end">Running {current.ref}, not this branch</Text>],
        [<Button key="restart" label="Restart here" variant="primary" onPress={() => queue({ kind: 'start' })} />, stop],
      )
    }

    const primary = current.targets.find(t => t.name === 'web') ?? current.targets[0]
    const others = current.targets.length - 1
    const detail = [current.isInPlace ? 'in place' : 'worktree', current.upFor && `up ${current.upFor}`]
      .filter(Boolean)
      .join(' · ')
    const toggle = (label: string) => (
      <Button key="toggle" label={label} dimColor onPress={() => void update($, isExpanded, value => !value)} />
    )

    // Collapsed: the main target and how many more. Expanded: every target
    // inline, in the same row, so the band never grows taller.
    const left = expanded && others > 0
      ? [
          ...current.targets.flatMap(t => [
            dot(t.isAlive ? 'green' : 'yellow', `dot-${t.name}`),
            <Text key={`name-${t.name}`} dimColor>{t.name}</Text>,
            <Button key={`open-${t.name}`} label={`:${t.port} ↗`} onPress={() => open($, t.port)} />,
          ]),
          toggle('‹'),
        ]
      : [
          dot(current.targets.every(t => t.isAlive) ? 'green' : 'yellow', 'dot'),
          ...(primary
            ? [<Button key="open" label={`localhost:${primary.port} ↗`} onPress={() => open($, primary.port)} />]
            : []),
          ...(others > 0 ? [toggle(`+${others}`)] : []),
        ]

    return row(left, [<Text key="detail" dimColor>{detail}</Text>, stop])
  })
}
