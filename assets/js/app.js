// If you want to use Phoenix channels, run `mix help phx.gen.channel`
// to get started and then uncomment the line below.
// import "./user_socket.js"

// You can include dependencies in two ways.
//
// The simplest option is to put them in assets/vendor and
// import them using relative paths:
//
//     import "../vendor/some-package.js"
//
// Alternatively, you can `npm install some-package --prefix assets` and import
// them using a path starting with the package name:
//
//     import "some-package"
//
// If you have dependencies that try to import CSS, esbuild will generate a separate `app.css` file.
// To load it, simply add a second `<link>` to your `root.html.heex` file.

// Include phoenix_html to handle method=PUT/DELETE in forms and buttons.
import "phoenix_html"
// Establish Phoenix Socket and LiveView configuration.
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"
import {hooks as colocatedHooks} from "phoenix-colocated/scheduling"
import topbar from "../vendor/topbar"

// Confirmation dialog: move focus to Cancel (the safe default), trap Tab inside
// the modal, and return focus to the trigger on close. Esc + backdrop dismissal
// are wired through phx events on the component itself.
const Hooks = {
  ConfirmDialog: {
    mounted() {
      this.lastFocused = document.activeElement
      const focusables = () =>
        this.el.querySelectorAll(
          'button, [href], input, select, textarea, [tabindex]:not([tabindex="-1"])'
        )
      const cancel = this.el.querySelector("[data-confirm-cancel]") || focusables()[0]
      cancel && cancel.focus()

      this.onKey = (e) => {
        if (e.key !== "Tab") return
        const f = Array.from(focusables())
        if (f.length === 0) return
        const first = f[0]
        const last = f[f.length - 1]
        if (e.shiftKey && document.activeElement === first) {
          e.preventDefault()
          last.focus()
        } else if (!e.shiftKey && document.activeElement === last) {
          e.preventDefault()
          first.focus()
        }
      }
      this.el.addEventListener("keydown", this.onKey)
    },
    destroyed() {
      this.el.removeEventListener("keydown", this.onKey)
      this.lastFocused && this.lastFocused.focus && this.lastFocused.focus()
    },
  },
}

// Keyboard-first accept queue: roving tabindex over role=option rows, Arrow/j/k
// to move, Enter/Space to accept. Selection is owned client-side for snappiness;
// the server is told which row is selected (to render the routing preview) and
// which row to accept.
Hooks.QueueList = {
  mounted() {
    this.sel = 0
    this.lastId = null
    this.onKey = this.onKey.bind(this)
    this.onClick = this.onClick.bind(this)
    this.el.addEventListener("keydown", this.onKey)
    this.el.addEventListener("click", this.onClick)
    this.apply()
  },
  updated() {
    const n = this.rows().length
    if (this.sel >= n) this.sel = Math.max(n - 1, 0)
    this.apply()
  },
  destroyed() {
    this.el.removeEventListener("keydown", this.onKey)
    this.el.removeEventListener("click", this.onClick)
  },
  rows() {
    return Array.from(this.el.querySelectorAll('[role="option"]'))
  },
  apply() {
    const rows = this.rows()
    rows.forEach((r, i) => {
      const on = i === this.sel
      r.setAttribute("tabindex", on ? "0" : "-1")
      r.setAttribute("aria-selected", on ? "true" : "false")
      r.classList.toggle("pcard--selected", on)
    })
    const cur = rows[this.sel]
    const id = cur ? cur.dataset.id : null
    if (id !== this.lastId) {
      this.lastId = id
      this.pushEvent("select", {id: id})
    }
  },
  move(delta) {
    const rows = this.rows()
    if (rows.length === 0) return
    this.sel = Math.max(0, Math.min(rows.length - 1, this.sel + delta))
    this.apply()
    const cur = this.rows()[this.sel]
    cur && cur.focus()
  },
  accept() {
    const cur = this.rows()[this.sel]
    if (cur && cur.dataset.id) this.pushEvent("accept", {id: cur.dataset.id})
  },
  onKey(e) {
    if (e.key === "ArrowDown" || e.key === "j") {
      e.preventDefault()
      this.move(1)
    } else if (e.key === "ArrowUp" || e.key === "k") {
      e.preventDefault()
      this.move(-1)
    } else if (e.key === "Enter" || e.key === " ") {
      e.preventDefault()
      this.accept()
    }
  },
  onClick(e) {
    // The Accept button carries its own phx-click; don't double-fire.
    if (e.target.closest("[data-accept]")) return
    const li = e.target.closest('[role="option"]')
    if (!li) return
    const i = this.rows().indexOf(li)
    if (i >= 0) {
      this.sel = i
      this.apply()
      li.focus()
    }
  },
}

const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")
const liveSocket = new LiveSocket("/live", Socket, {
  longPollFallbackMs: 2500,
  params: {_csrf_token: csrfToken},
  hooks: {...colocatedHooks, ...Hooks},
})

// Show progress bar on live navigation and form submits
topbar.config({barColors: {0: "#29d"}, shadowColor: "rgba(0, 0, 0, .3)"})
window.addEventListener("phx:page-loading-start", _info => topbar.show(300))
window.addEventListener("phx:page-loading-stop", _info => topbar.hide())

// connect if there are any LiveViews on the page
liveSocket.connect()

// expose liveSocket on window for web console debug logs and latency simulation:
// >> liveSocket.enableDebug()
// >> liveSocket.enableLatencySim(1000)  // enabled for duration of browser session
// >> liveSocket.disableLatencySim()
window.liveSocket = liveSocket

// The lines below enable quality of life phoenix_live_reload
// development features:
//
//     1. stream server logs to the browser console
//     2. click on elements to jump to their definitions in your code editor
//
if (process.env.NODE_ENV === "development") {
  window.addEventListener("phx:live_reload:attached", ({detail: reloader}) => {
    // Enable server log streaming to client.
    // Disable with reloader.disableServerLogs()
    reloader.enableServerLogs()

    // Open configured PLUG_EDITOR at file:line of the clicked element's HEEx component
    //
    //   * click with "c" key pressed to open at caller location
    //   * click with "d" key pressed to open at function component definition location
    let keyDown
    window.addEventListener("keydown", e => keyDown = e.key)
    window.addEventListener("keyup", _e => keyDown = null)
    window.addEventListener("click", e => {
      if(keyDown === "c"){
        e.preventDefault()
        e.stopImmediatePropagation()
        reloader.openEditorAtCaller(e.target)
      } else if(keyDown === "d"){
        e.preventDefault()
        e.stopImmediatePropagation()
        reloader.openEditorAtDef(e.target)
      }
    }, true)

    window.liveReloader = reloader
  })
}

