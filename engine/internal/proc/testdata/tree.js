// A dev server's process tree, for proc's tests.
//
//   node tree.js <port> tree     parent listens on port and starts a child on
//                                port+1; both exit cleanly on SIGBREAK
//   node tree.js <port> watcher  a watcher that restarts its child (listening
//                                on port) whenever it dies; both ignore
//                                SIGBREAK, so only a forced stop clears them
const http = require('http');
const { spawn } = require('child_process');

const port = Number(process.argv[2]);
const mode = process.argv[3];
const role = process.argv[4] || 'parent';
const say = (msg) => console.log(`${role} ${process.pid} ${msg}`);

process.on('SIGBREAK', () => {
  if (mode === 'watcher') return say('ignored SIGBREAK');
  say('got SIGBREAK');
  process.exit(0);
});

function listen(p) {
  http.createServer((q, r) => r.end(role)).listen(p, () => say(`listening ${p}`));
}

if (role === 'child') {
  listen(port);
} else if (mode === 'tree') {
  listen(port);
  spawn(process.execPath, [__filename, port + 1, mode, 'child'], { stdio: 'inherit' });
} else {
  let starts = 0;
  const run = () => {
    const c = spawn(process.execPath, [__filename, port, mode, 'child'], { stdio: 'inherit' });
    say(`started child ${c.pid} (#${++starts})`);
    c.on('exit', () => { say('child died, respawning'); setTimeout(run, 100); });
  };
  run();
  setInterval(() => {}, 1 << 30);
}
