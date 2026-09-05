// picker.js -- the branch chooser, as a real Cocoa window.
//
// Run by frankly-launcher.sh:  osascript -l JavaScript picker.js <datafile>
//
// Why this exists rather than `choose from list`: the stock picker is a single
// column of text in a proportional font. It cannot do section headings, a
// right-aligned "last updated" column, or checkboxes -- and without those, a
// repo with 500+ remote branches is a haystack rather than a picker.
//
// <datafile> is pipe-delimited, one branch per line:
//     ref | group | age | meta | merged
// where group is default|mine|other, age is a short relative string ("5m"),
// meta is a hint shown dimmed ("ready", "open in Studio"), and merged is 1
// when the branch is already merged into development.
//
// Prints one pipe-delimited line:  action|ref|includeMerged|showAll
// action is choose, fetch or cancel.

ObjC.import('AppKit');

var W = 560;          // accessory width
var ROW_H = 22;
var HEAD_H = 24;
var GAP = 14;
var LIST_H = 300;     // fixed: toggling a section scrolls, never resizes

function readLines(path) {
  var s = $.NSString.stringWithContentsOfFileEncodingError(path, $.NSUTF8StringEncoding, null);
  if (!s || s.isNil()) return [];
  return ObjC.unwrap(s).split('\n').filter(function (l) { return l.length > 0; });
}

function parse(path) {
  return readLines(path).map(function (line) {
    var p = line.split('|');
    return { ref: p[0], group: p[1], age: p[2] || '', meta: p[3] || '', merged: p[4] === '1' };
  });
}

function label(text, x, y, w, o) {
  o = o || {};
  var f = $.NSTextField.alloc.initWithFrame($.NSMakeRect(x, y, w, 16));
  f.stringValue = text;
  f.bezeled = false; f.drawsBackground = false; f.editable = false; f.selectable = false;
  f.font = o.bold ? $.NSFont.boldSystemFontOfSize(10) : $.NSFont.systemFontOfSize(11);
  f.textColor = o.primary ? $.NSColor.labelColor : $.NSColor.secondaryLabelColor;
  if (o.right) f.alignment = $.NSTextAlignmentRight;
  f.cell.lineBreakMode = $.NSLineBreakByTruncatingTail;
  return f;
}

// Columns: name (ellipsed, grows) | meta (dim) | age (dim, right-aligned).
var META_X = W - 216, META_W = 150;
var AGE_X = W - 60, AGE_W = 56;

function buildSections(all, flags) {
  // development is the default and always listed, merged or not -- it is
  // merged into itself by definition.
  var keep = function (b) {
    if (b.group === 'default') return true;
    return flags.includeMerged || !b.merged;
  };
  var sections = [];
  var def = all.filter(function (b) { return b.group === 'default' && keep(b); });
  var mine = all.filter(function (b) { return b.group === 'mine' && keep(b); });
  if (def.length) sections.push({ title: 'Default', right: 'Last updated', rows: def });
  sections.push({ title: 'My branches', right: def.length ? '' : 'Last updated', rows: mine });
  if (flags.showAll) {
    var other = all.filter(function (b) { return b.group === 'other' && keep(b); });
    sections.push({ title: 'Everyone else · most recent', right: '', rows: other });
  }
  return sections;
}

// Returns {view, radios:[{button, ref}]}
function buildList(all, flags, selectedRef) {
  var sections = buildSections(all, flags);
  var h = 0;
  sections.forEach(function (s, i) {
    h += HEAD_H + (s.rows.length ? s.rows.length * ROW_H : ROW_H);
    if (i < sections.length - 1) h += GAP;
  });
  if (h < LIST_H) h = LIST_H;

  var view = $.NSView.alloc.initWithFrame($.NSMakeRect(0, 0, W, h));
  var radios = [];
  var y = h;

  sections.forEach(function (s, si) {
    y -= HEAD_H;
    view.addSubview(label(s.title, 4, y, 260, { bold: true }));
    if (s.right) view.addSubview(label(s.right, AGE_X - 100, y, 100 + AGE_W, { bold: true, right: true }));

    if (!s.rows.length) {
      y -= ROW_H;
      view.addSubview(label('none', 22, y + 2, 200, {}));
    }

    s.rows.forEach(function (b) {
      y -= ROW_H;
      var btn = $.NSButton.alloc.initWithFrame($.NSMakeRect(2, y, META_X - 10, ROW_H - 2));
      btn.setButtonType($.NSButtonTypeRadio);
      btn.title = b.ref;
      btn.font = $.NSFont.systemFontOfSize(12);
      btn.cell.lineBreakMode = $.NSLineBreakByTruncatingTail;
      btn.contentTintColor = $.NSColor.labelColor;
      if (b.ref === selectedRef) btn.state = $.NSControlStateValueOn;
      view.addSubview(btn);
      radios.push({ button: btn, ref: b.ref });

      if (b.meta) view.addSubview(label(b.meta, META_X, y + 3, META_W, { right: true }));
      view.addSubview(label(b.age, AGE_X, y + 3, AGE_W, { right: true }));
    });

    if (si < sections.length - 1) y -= GAP;
  });

  if (radios.length && !radios.some(function (r) { return r.ref === selectedRef; })) {
    radios[0].button.state = $.NSControlStateValueOn;
  }
  return { view: view, radios: radios };
}

function run(argv) {
  var all = parse(argv[0]);
  var app = $.NSApplication.sharedApplication;
  app.setActivationPolicy($.NSApplicationActivationPolicyRegular);

  var flags = { includeMerged: false, showAll: false };
  var selected = null;
  var first = all.filter(function (b) { return b.group === 'mine' && !b.merged; })[0]
           || all.filter(function (b) { return b.group === 'default'; })[0];
  if (first) selected = first.ref;

  // The checkboxes re-filter the list in place. The list lives in a
  // fixed-height scroll view, so showing another section scrolls rather than
  // resizing the window under the pointer.
  var scroll = $.NSScrollView.alloc.initWithFrame($.NSMakeRect(0, 56, W, LIST_H));
  scroll.hasVerticalScroller = true;
  scroll.drawsBackground = false;
  scroll.autohidesScrollers = true;

  var built = buildList(all, flags, selected);
  scroll.setDocumentView(built.view);

  var container = $.NSView.alloc.initWithFrame($.NSMakeRect(0, 0, W, LIST_H + 56));
  container.addSubview(scroll);

  var rerender = function () {
    // Keep whatever is currently selected across a re-filter.
    built.radios.forEach(function (r) {
      if (r.button.state === $.NSControlStateValueOn) selected = r.ref;
    });
    built = buildList(all, flags, selected);
    scroll.setDocumentView(built.view);
    scroll.contentView.scrollToPoint($.NSMakePoint(0, Math.max(0, built.view.frame.size.height - LIST_H)));
    scroll.reflectScrolledClipView(scroll.contentView);
  };

  ObjC.registerSubclass({
    name: 'FLPickerTarget',
    superclass: 'NSObject',
    methods: {
      'merged:': {
        types: ['void', ['id']],
        implementation: function (sender) {
          flags.includeMerged = sender.state === $.NSControlStateValueOn;
          rerender();
        },
      },
      'all:': {
        types: ['void', ['id']],
        implementation: function (sender) {
          flags.showAll = sender.state === $.NSControlStateValueOn;
          rerender();
        },
      },
    },
  });
  var target = $.FLPickerTarget.alloc.init;

  var cbMerged = $.NSButton.alloc.initWithFrame($.NSMakeRect(2, 28, 300, 20));
  cbMerged.setButtonType($.NSButtonTypeSwitch);
  cbMerged.title = 'Include branches whose PR is merged';
  cbMerged.font = $.NSFont.systemFontOfSize(12);
  cbMerged.target = target; cbMerged.action = 'merged:';
  container.addSubview(cbMerged);

  var cbAll = $.NSButton.alloc.initWithFrame($.NSMakeRect(2, 4, 300, 20));
  cbAll.setButtonType($.NSButtonTypeSwitch);
  cbAll.title = 'Show everyone else’s branches';
  cbAll.font = $.NSFont.systemFontOfSize(12);
  cbAll.target = target; cbAll.action = 'all:';
  container.addSubview(cbAll);

  var alert = $.NSAlert.alloc.init;
  alert.messageText = 'Which branch?';
  alert.informativeText = 'The demo runs from a throwaway worktree. Your Studio checkout is never touched.';
  alert.setAccessoryView(container);
  alert.addButtonWithTitle('Choose');   // 1000
  alert.addButtonWithTitle('Cancel');   // 1001
  alert.addButtonWithTitle('Fetch');    // 1002
  app.activateIgnoringOtherApps(true);

  var code = alert.runModal;

  built.radios.forEach(function (r) {
    if (r.button.state === $.NSControlStateValueOn) selected = r.ref;
  });

  var action = code === 1000 ? 'choose' : (code === 1002 ? 'fetch' : 'cancel');
  return [action, selected || '', flags.includeMerged ? 1 : 0, flags.showAll ? 1 : 0].join('|');
}
