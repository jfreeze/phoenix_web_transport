// Client-side measurement. Nothing here talks to the server, so measuring
// does not add traffic to the connection under test.
//
// Latency = Date.now() at DOM update minus the server's sent_at stamp. Both
// run on the same machine in the demo, so the clocks agree.

let transportStats = null
export function setStats(stats){ transportStats = stats }

const pulse = {samples: [], last: null, count: 0}
const heavy = {samples: [], last: null}

function record(bucket, latency){
  bucket.last = latency
  bucket.samples.push(latency)
  if(bucket.samples.length > 500){ bucket.samples.shift() }
}

function percentile(samples, p){
  if(samples.length === 0){ return null }
  const sorted = [...samples].sort((a, b) => a - b)
  return sorted[Math.min(sorted.length - 1, Math.floor(p * sorted.length))]
}

const fmt = ms => ms === null || ms === undefined ? "–" : `${Math.round(ms)} ms`
const kb = bytes => bytes > 1048576 ? `${(bytes / 1048576).toFixed(1)} MB` : `${(bytes / 1024).toFixed(0)} KB`

export const hooks = {
  // Compare page: one scoreboard fed by both iframes.
  Scoreboard: {
    mounted(){
      const panes = {}
      this.listener = event => {
        if(!event.data || event.data.type !== "lv-stats"){ return }
        panes[event.data.transport] = event.data
        this.render(panes)
      }
      window.addEventListener("message", this.listener)
    },
    destroyed(){ window.removeEventListener("message", this.listener) },
    render(panes){
      const ws = panes.websocket, wt = panes.webtransport
      const row = name => this.el.querySelector(`[data-row='${name}']`)
      const put = (name, a, b) => {
        row(name).children[1].textContent = a
        row(name).children[2].textContent = b
      }
      put("p95", fmt(ws && ws.pulse.p95), fmt(wt && wt.pulse.p95))
      put("max", fmt(ws && ws.pulse.max), fmt(wt && wt.pulse.max))
      put("p50", fmt(ws && ws.pulse.p50), fmt(wt && wt.pulse.p50))
      put("heavy", fmt(ws && ws.heavy.p50), fmt(wt && wt.heavy.p50))
      put("bytes", ws ? kb(ws.bytes) : "–", wt ? kb(wt.bytes) : "–")
      const verdict = this.el.querySelector("[data-verdict]")
      if(!(ws && wt && ws.pulse.p95 !== null && wt.pulse.p95 !== null && ws.pulse.count > 20 && wt.pulse.count > 20)){
        verdict.textContent = "Collecting samples…"
        return
      }
      const a = ws.pulse.p95, b = wt.pulse.p95
      const ratio = a / Math.max(b, 1)
      if(ratio >= 1.5){
        verdict.textContent = `WebTransport wins: pulse p95 ${fmt(b)} vs ${fmt(a)} over WebSocket, ${ratio.toFixed(1)}× lower. Small updates are no longer stuck behind the big table.`
        verdict.className = "text-success font-medium"
      } else if(ratio <= 0.67){
        verdict.textContent = `WebSocket is ahead: pulse p95 ${fmt(a)} vs ${fmt(b)}. If the shaper is on, QUIC is probably being crushed by packet drops rather than losing on merit: loopback TCP sends 16 KB packets, QUIC 1.3 KB ones, and a packet-count queue overflows for QUIC first. Use the current scripts/impair.sh (byte queue, 1500 MTU) and reload.`
        verdict.className = "text-error font-medium"
      } else {
        verdict.textContent = `No meaningful difference (pulse p95 ${fmt(a)} vs ${fmt(b)}). That is expected without throttling: the network is not the bottleneck here, the browser's own patch of the table is. Run sudo scripts/impair.sh on and watch this line change.`
        verdict.className = "text-warning font-medium"
      }
    }
  },

  LatencyMeter: {
    updated(){
      const sentAt = parseInt(this.el.dataset.sentAt, 10)
      pulse.count += 1
      record(pulse, Date.now() - sentAt)
    }
  },

  HeavyMeter: {
    updated(){
      const sentAt = parseInt(this.el.dataset.sentAt, 10)
      record(heavy, Date.now() - sentAt)
    }
  },

  StatsPanel: {
    mounted(){
      const cell = name => this.el.querySelector(`[data-stat='${name}']`)
      this.timer = setInterval(() => {
        cell("pulse").textContent =
          `${fmt(pulse.last)} / ${fmt(percentile(pulse.samples, 0.5))} / ${fmt(percentile(pulse.samples, 0.95))} / ${fmt(percentile(pulse.samples, 1))}`
        cell("heavy").textContent =
          `${fmt(heavy.last)} / ${fmt(percentile(heavy.samples, 0.5))} / ${fmt(percentile(heavy.samples, 1))}`
        cell("pulses").textContent = String(pulse.count)
        if(transportStats){
          cell("bytes").textContent = `${kb(transportStats.bytes)} in ${transportStats.frames} frames`
          cell("lanes").textContent = Object.entries(transportStats.lanes)
            .map(([lane, s]) => `${lane}: ${s.frames} / ${kb(s.bytes)}`)
            .join("   ")
        }
        // Let the compare page (parent frame) build a scoreboard from both panes.
        if(window.parent !== window){
          window.parent.postMessage({
            type: "lv-stats",
            transport: transportStats ? transportStats.transport : "unknown",
            pulse: {last: pulse.last, p50: percentile(pulse.samples, 0.5), p95: percentile(pulse.samples, 0.95), max: percentile(pulse.samples, 1), count: pulse.count},
            heavy: {last: heavy.last, p50: percentile(heavy.samples, 0.5), max: percentile(heavy.samples, 1)},
            bytes: transportStats ? transportStats.bytes : 0,
          }, "*")
        }
      }, 250)
    },
    destroyed(){ clearInterval(this.timer) }
  }
}
