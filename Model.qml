import QtQuick
import Quickshell
import Quickshell.Io

// Discovery and diagnosis for both systemd managers.
//
// The contract this file defends: an empty result is not health. `list-units`
// reports units, not manager state, and a `systemctl --user` that cannot reach
// its bus returns nothing at all. A widget that goes green when it fails to
// read is the exact failure it exists to prevent, so a manager that cannot be
// read is its own state and says so.
QtObject {
  id: root

  property var settings: ({})
  property bool watchSystem: true
  property bool watchUser: true
  property int intervalSec: 10
  property int journalLines: 20

  // Per manager: "running" | "degraded" | "starting" | "stopping" |
  // "maintenance" | "initializing" | "offline" | "unknown" | "off"
  property string systemState: "unknown"
  property string userState: "unknown"

  // [{ unit, manager, description, kind: "failed"|"restarting", load, active, sub }]
  property var units: []

  // unit key ("system/foo.service") -> { restarts, result, code, status, since, journal }
  property var details: ({})

  // exit status number -> { name, cls }, from `systemd-analyze exit-status`.
  property var exitTable: ({})

  property bool detailsLoading: false

  readonly property int failedCount: countKind("failed")
  readonly property int restartingCount: countKind("restarting")
  readonly property bool anyDegraded: (watchSystem && systemState === "degraded")
                                   || (watchUser && userState === "degraded")
  readonly property bool anyUnknown: (watchSystem && systemState === "unknown")
                                   || (watchUser && userState === "unknown")
  readonly property bool alerting: failedCount > 0 || restartingCount > 0 || anyDegraded || anyUnknown
  readonly property bool urgent: failedCount > 0 || restartingCount > 0

  function countKind(kind) {
    var n = 0
    for (var i = 0; i < units.length; i++) if (units[i].kind === kind) n++
    return n
  }

  function unitKey(u) { return u.manager + "/" + u.unit }

  function stateLabel(state) {
    if (state === "unknown") return "could not be read"
    if (state === "off") return "not watched"
    return state
  }

  // ---------------------------------------------------------------- discovery
  //
  // One shell round trip per manager emits both readings, so a tick can never
  // pair a fresh unit list with a stale manager state.
  //
  // `is-system-running` deliberately exits non-zero while printing a perfectly
  // valid state: on a degraded machine it prints "degraded" and exits 1. Its
  // exit status is therefore discarded and only its stdout is trusted. The
  // non-zero rule applies to `list-units` alone, whose failure is reported as
  // the literal `null` that this parser turns into "unknown".
  function scanScript(userScope) {
    var sc = userScope ? "--user " : ""
    return 'state=$(systemctl ' + sc + 'is-system-running 2>/dev/null); ' +
           'units=$(systemctl ' + sc + 'list-units --all --state=failed,auto-restart -o json 2>/dev/null) || units=null; ' +
           '[ -n "$units" ] || units=null; ' +
           'printf \'{"state":"%s","units":%s}\' "$state" "$units"'
  }

  readonly property var knownStates: ["running", "degraded", "initializing", "starting",
                                      "stopping", "maintenance", "offline"]

  function parseScan(text, manager) {
    var state = "unknown"
    var list = []
    try {
      var blob = JSON.parse(String(text).trim())
      var s = String(blob.state || "").trim()
      if (knownStates.indexOf(s) >= 0) state = s
      if (blob.units !== null && blob.units !== undefined) {
        for (var i = 0; i < blob.units.length; i++) {
          var u = blob.units[i]
          if (!u || !u.unit) continue
          list.push({
            unit: String(u.unit),
            manager: manager,
            description: String(u.description || ""),
            load: String(u.load || ""),
            active: String(u.active || ""),
            sub: String(u.sub || ""),
            kind: String(u.sub) === "auto-restart" ? "restarting" : "failed"
          })
        }
      } else {
        // list-units itself failed. Do not report the manager as clean.
        state = "unknown"
      }
    } catch (e) {
      state = "unknown"
    }
    return { state: state, units: list }
  }

  function applyScan(manager, parsed) {
    if (manager === "system") systemState = parsed.state
    else userState = parsed.state

    var kept = []
    for (var i = 0; i < units.length; i++) if (units[i].manager !== manager) kept.push(units[i])
    units = kept.concat(parsed.units).sort(function(a, b) {
      if (a.kind !== b.kind) return a.kind === "failed" ? -1 : 1
      if (a.manager !== b.manager) return a.manager === "system" ? -1 : 1
      return a.unit < b.unit ? -1 : 1
    })
  }

  function refresh() {
    if (watchSystem) { systemScan.running = false; systemScan.running = true }
    else { systemState = "off"; applyScan("system", { state: "off", units: [] }) }
    if (watchUser) { userScan.running = false; userScan.running = true }
    else { userState = "off"; applyScan("user", { state: "off", units: [] }) }
  }

  // ------------------------------------------------------------------ details
  //
  // Line oriented rather than JSON: building JSON for an arbitrary number of
  // units in shell means quoting journal text that routinely contains quotes,
  // braces and backslashes. Sentinels cost nothing and cannot be malformed by
  // the log content they wrap.
  function detailScript() {
    var lines = Math.max(1, journalLines)
    var parts = []
    for (var i = 0; i < units.length; i++) {
      var u = units[i]
      var sc = u.manager === "user" ? "--user " : ""
      var jflag = u.manager === "user" ? "--user-unit" : "-u"
      var q = "'" + String(u.unit).replace(/'/g, "'\\''") + "'"
      parts.push(
        'printf "@@UNIT %s %s\\n" ' + (u.manager === "user" ? "user" : "system") + ' ' + q + '; ' +
        'echo "@@PROPS"; ' +
        'systemctl ' + sc + '--timestamp=unix show ' + q +
          ' -p NRestarts,Result,ExecMainCode,ExecMainStatus,InactiveEnterTimestamp,ActiveEnterTimestamp 2>/dev/null; ' +
        'echo "@@JOURNAL"; ' +
        'journalctl ' + (u.manager === "user" ? "--user " : "") + jflag + ' ' + q +
          ' -n ' + lines + ' --no-pager -o cat 2>&1 | tail -n ' + lines
      )
    }
    return parts.join('; ')
  }

  function parseDetails(text) {
    var out = {}
    var current = null
    var mode = ""
    var rows = String(text).split("\n")
    for (var i = 0; i < rows.length; i++) {
      var line = rows[i]
      if (line.indexOf("@@UNIT ") === 0) {
        var rest = line.substring(7)
        var sp = rest.indexOf(" ")
        var manager = rest.substring(0, sp)
        var unit = rest.substring(sp + 1).trim()
        current = { unit: unit, manager: manager, props: {}, journal: [] }
        out[manager + "/" + unit] = current
        mode = ""
        continue
      }
      if (line === "@@PROPS") { mode = "props"; continue }
      if (line === "@@JOURNAL") { mode = "journal"; continue }
      if (!current) continue
      if (mode === "props") {
        var eq = line.indexOf("=")
        if (eq > 0) current.props[line.substring(0, eq)] = line.substring(eq + 1)
      } else if (mode === "journal") {
        current.journal.push(line)
      }
    }

    var shaped = {}
    for (var key in out) {
      var d = out[key]
      while (d.journal.length && d.journal[d.journal.length - 1] === "") d.journal.pop()
      shaped[key] = {
        restarts: parseInt(d.props.NRestarts || "0", 10) || 0,
        result: d.props.Result || "",
        code: parseInt(d.props.ExecMainCode || "0", 10) || 0,
        status: parseInt(d.props.ExecMainStatus || "0", 10) || 0,
        since: unixStamp(d.props.InactiveEnterTimestamp),
        journal: d.journal,
        readable: d.journal.length > 0
      }
    }
    return shaped
  }

  // `--timestamp=unix` renders as "@1787178313". The monotonic properties are
  // microseconds since boot and cannot be compared with Date.now(), so they are
  // deliberately not read here.
  function unixStamp(raw) {
    var s = String(raw || "").trim()
    if (s.indexOf("@") === 0) s = s.substring(1)
    var n = parseInt(s, 10)
    return isNaN(n) || n <= 0 ? 0 : n
  }

  function loadDetails() {
    if (units.length === 0) { details = ({}); return }
    detailsLoading = true
    detailProc.command = ["bash", "-c", detailScript()]
    detailProc.running = false
    detailProc.running = true
  }

  // --------------------------------------------------------------- exit table
  //
  // The canonical table ships with systemd. `exit-status.h` is not installed,
  // so anything hand-typed here would drift from the system it describes.
  function parseExitTable(text) {
    var t = {}
    var rows = String(text).split("\n")
    for (var i = 0; i < rows.length; i++) {
      var cols = rows[i].trim().split(/\s+/)
      if (cols.length < 3) continue
      var n = parseInt(cols[1], 10)
      if (isNaN(n)) continue
      // systemd prints "-" for a status it has no name for, 127 among them.
      // Storing that row would render "- (127), class -" and suppress the
      // convention hint that is the only useful thing to say about it.
      if (cols[0] === "-") continue
      t[n] = { name: cols[0], cls: cols[2] }
    }
    return t
  }

  // What systemd reported. Never a cause.
  //
  // ExecMainStatus holds an exit status only when ExecMainCode is CLD_EXITED
  // (1). For CLD_KILLED (2) and CLD_DUMPED (3) it holds a SIGNAL number, and
  // the low signal numbers collide with named exit statuses: SIGABRT is 6, and
  // exit status 6 is NOTCONFIGURED. Reading one as the other invents a
  // diagnosis, so the code is branched on before the number is interpreted.
  readonly property var signalNames: ({
    1: "SIGHUP", 2: "SIGINT", 3: "SIGQUIT", 4: "SIGILL", 5: "SIGTRAP", 6: "SIGABRT",
    7: "SIGBUS", 8: "SIGFPE", 9: "SIGKILL", 11: "SIGSEGV", 13: "SIGPIPE",
    14: "SIGALRM", 15: "SIGTERM", 24: "SIGXCPU", 25: "SIGXFSZ", 31: "SIGSYS"
  })

  function reported(detail) {
    if (!detail) return ""
    if (detail.code === 2 || detail.code === 3) {
      var sig = signalNames[detail.status] || ("signal " + detail.status)
      return "killed by " + sig + (detail.code === 3 ? ", core dumped" : "")
    }
    // Code 0 means no exit was caught in this sample. A flapping unit spends
    // part of every cycle alive, with Result=success and ExecMainCode=0, so a
    // detail read that lands there would otherwise report "result success" for
    // a service dying every four seconds. Nothing is a truthful answer; the
    // restart count and the journal below carry the story.
    if (detail.code !== 1) return ""
    var known = exitTable[detail.status]
    if (known) return known.name + " (" + detail.status + "), class " + known.cls
    return "exit status " + detail.status
  }

  // Shown only where it can be read as the convention it is, never as this
  // unit's cause: any process may exit 127 deliberately.
  function convention(detail) {
    if (!detail || detail.code !== 1) return ""
    if (exitTable[detail.status]) return ""
    if (detail.status === 127) return "conventionally: command not found"
    if (detail.status === 126) return "conventionally: not executable"
    return ""
  }

  property var systemScan: Process {
    command: ["bash", "-c", root.scanScript(false)]
    running: false
    stdout: StdioCollector {
      onStreamFinished: root.applyScan("system", root.parseScan(text, "system"))
    }
  }

  property var userScan: Process {
    command: ["bash", "-c", root.scanScript(true)]
    running: false
    stdout: StdioCollector {
      onStreamFinished: root.applyScan("user", root.parseScan(text, "user"))
    }
  }

  property var detailProc: Process {
    running: false
    stdout: StdioCollector {
      onStreamFinished: {
        root.details = root.parseDetails(text)
        root.detailsLoading = false
      }
    }
  }

  property var exitProc: Process {
    command: ["bash", "-c", "systemd-analyze exit-status 2>/dev/null"]
    running: true
    stdout: StdioCollector {
      onStreamFinished: root.exitTable = root.parseExitTable(text)
    }
  }

  property var ticker: Timer {
    interval: Math.max(5, root.intervalSec) * 1000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }
}
