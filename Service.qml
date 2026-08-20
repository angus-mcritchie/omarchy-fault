import QtQuick

// One poller for the whole machine.
//
// The bar builds one widget instance per screen, so a three-monitor setup was
// running three independent copies of the model and asking systemd the same
// questions three times over. A service is instantiated once by the shell and
// shared by every bar instance, which is the same split the first-party media
// plugin uses.
Item {
  id: root

  property var shell: null

  // Widgets hand their settings in; a service has no shell.json entry of its
  // own, and every widget carries the same values.
  function applySettings(s) {
    if (!s) return
    if (s.intervalSec !== undefined && s.intervalSec !== null) model.intervalSec = s.intervalSec
    if (s.journalLines !== undefined && s.journalLines !== null) model.journalLines = s.journalLines
    if (s.watchSystem !== undefined && s.watchSystem !== null) model.watchSystem = s.watchSystem
    if (s.watchUser !== undefined && s.watchUser !== null) model.watchUser = s.watchUser
  }

  readonly property var model: model

  Model { id: model }
}
