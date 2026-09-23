import "phoenix_html"
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"
import {hooks as colocatedHooks} from "phoenix-colocated/wt_demo"
import topbar from "../vendor/topbar"
// A hex install resolves this as "phoenix_web_transport" via NODE_PATH=deps;
// the demo uses the library from the repo root by path.
import WebTransportTransport, {stats as wtStats} from "../../../assets/js/phoenix_web_transport.js"
import MeteredWebSocket, {stats as wsStats} from "./metered_websocket"
import {hooks as meterHooks, setStats} from "./meters"

const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")
const meta = name => {
  const el = document.querySelector(`meta[name='${name}']`)
  return el && el.getAttribute("content")
}

// The transport is chosen per page from ?transport=wt|ws so the same bundle
// serves both halves of the comparison.
const useWebTransport = new URLSearchParams(location.search).get("transport") === "wt"

let liveSocket
if(useWebTransport && "WebTransport" in window){
  WebTransportTransport.certHash = meta("wt-cert-hash")
  setStats(wtStats)
  liveSocket = new LiveSocket(meta("wt-url"), Socket, {
    transport: WebTransportTransport,
    params: {_csrf_token: csrfToken},
    hooks: {...colocatedHooks, ...meterHooks},
  })
} else {
  if(useWebTransport){ console.warn("WebTransport unavailable in this browser; falling back to WebSocket") }
  setStats(wsStats)
  liveSocket = new LiveSocket("/live", Socket, {
    transport: MeteredWebSocket,
    params: {_csrf_token: csrfToken},
    hooks: {...colocatedHooks, ...meterHooks},
  })
}

topbar.config({barColors: {0: "#29d"}, shadowColor: "rgba(0, 0, 0, .3)"})
window.addEventListener("phx:page-loading-start", _info => topbar.show(300))
window.addEventListener("phx:page-loading-stop", _info => topbar.hide())

liveSocket.connect()
window.liveSocket = liveSocket

if (process.env.NODE_ENV === "development") {
  window.addEventListener("phx:live_reload:attached", ({detail: reloader}) => {
    reloader.enableServerLogs()
    window.liveReloader = reloader
  })
}
