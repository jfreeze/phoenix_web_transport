// A phoenix.js transport that speaks WebTransport instead of WebSocket.
//
// phoenix.js only needs a WebSocket-shaped object: readyState, send(), close()
// and the four on* callbacks. This class satisfies that contract, so it plugs
// into `new LiveSocket(url, Socket, {transport: WebTransportTransport})`
// without patching phoenix.js or LiveView.
//
// Wire format (see lib/phoenix_web_transport/frame.ex):
//   client -> server: one bidirectional stream, frames <<len:32, type:8, payload>>
//   server -> client: one unidirectional stream per lane, starting with
//                     <<lane:32>> then frames. Frames from every lane are
//                     handed to onmessage in arrival order.

const CONNECTING = 0
const OPEN = 1
const CLOSING = 2
const CLOSED = 3

const encoder = new TextEncoder()
const decoder = new TextDecoder()

export const stats = {
  transport: "webtransport",
  frames: 0,
  bytes: 0,
  lanes: {},
  reset(){
    this.frames = 0
    this.bytes = 0
    this.lanes = {}
  }
}

export default class WebTransportTransport {
  // Set once from the page's <meta name="wt-cert-hash"> before connecting.
  static certHash = null

  constructor(endPoint, _protocols){
    this.readyState = CONNECTING
    this.onopen = () => {}
    this.onerror = () => {}
    this.onmessage = () => {}
    this.onclose = () => {}
    this.skipHeartbeat = false
    this.url = endPoint.replace("/websocket?", "/webtransport?")
    this.connect()
  }

  connect(){
    const options = {}
    if(WebTransportTransport.certHash){
      options.serverCertificateHashes = [{
        algorithm: "sha-256",
        value: hexToBytes(WebTransportTransport.certHash)
      }]
    }
    try {
      this.transport = new WebTransport(this.url, options)
    } catch(error){
      this.fail(error)
      return
    }

    this.transport.closed
      .then(info => this.finish(info))
      .catch(error => this.fail(error))

    this.transport.ready
      .then(() => this.open())
      .catch(error => this.fail(error))
  }

  async open(){
    this.control = await this.transport.createBidirectionalStream()
    this.writer = this.control.writable.getWriter()
    this.readyState = OPEN
    stats.reset()
    this.onopen()
    this.readLanes()
  }

  async readLanes(){
    const reader = this.transport.incomingUnidirectionalStreams.getReader()
    try {
      while(true){
        const {value: stream, done} = await reader.read()
        if(done){ break }
        this.readLane(stream)
      }
    } catch(_error){
      // The session is closing; transport.closed reports the reason.
    }
  }

  async readLane(stream){
    const reader = stream.getReader()
    let buffer = new Uint8Array(0)
    let lane = null
    try {
      while(true){
        const {value, done} = await reader.read()
        if(done){ break }
        buffer = concat(buffer, value)
        if(lane === null){
          if(buffer.length < 4){ continue }
          lane = readUint32(buffer, 0)
          buffer = buffer.subarray(4)
          stats.lanes[lane] = stats.lanes[lane] || {frames: 0, bytes: 0}
        }
        buffer = this.drainFrames(buffer, lane)
      }
    } catch(_error){
      // Stream reset or session closed.
    }
  }

  drainFrames(buffer, lane){
    while(buffer.length >= 4){
      const len = readUint32(buffer, 0)
      if(buffer.length < 4 + len){ break }
      const type = buffer[4]
      const payload = buffer.subarray(5, 4 + len)
      buffer = buffer.subarray(4 + len)
      stats.frames += 1
      stats.bytes += len
      stats.lanes[lane].frames += 1
      stats.lanes[lane].bytes += len
      const data = type === 0 ? decoder.decode(payload) : payload.slice().buffer
      this.onmessage({data})
    }
    return buffer.length === 0 ? new Uint8Array(0) : buffer.slice()
  }

  send(data){
    if(this.readyState !== OPEN){ return }
    const payload = typeof data === "string" ? encoder.encode(data) : new Uint8Array(data)
    const type = typeof data === "string" ? 0 : 1
    const frame = new Uint8Array(5 + payload.length)
    writeUint32(frame, 0, payload.length + 1)
    frame[4] = type
    frame.set(payload, 5)
    this.writer.write(frame).catch(error => this.fail(error))
  }

  close(code, reason){
    if(this.readyState === CLOSED){ return }
    this.readyState = CLOSING
    try { this.transport.close({closeCode: code || 0, reason: reason || ""}) } catch(_e){ }
  }

  finish(info){
    if(this.readyState === CLOSED){ return }
    this.readyState = CLOSED
    console.info("[phoenix_web_transport] session closed:", info && info.closeCode, info && info.reason)
    this.onclose({code: info && info.closeCode, reason: info && info.reason, wasClean: true})
  }

  fail(error){
    if(this.readyState === CLOSED){ return }
    this.readyState = CLOSED
    console.warn("[phoenix_web_transport] session failed:", error && (error.message || error), this.url)
    this.onerror(error)
    this.onclose({code: 1006, reason: String(error), wasClean: false})
  }
}

function hexToBytes(hex){
  const out = new Uint8Array(hex.length / 2)
  for(let i = 0; i < out.length; i++){ out[i] = parseInt(hex.substr(i * 2, 2), 16) }
  return out
}

function concat(a, b){
  if(a.length === 0){ return b }
  const out = new Uint8Array(a.length + b.length)
  out.set(a, 0)
  out.set(b, a.length)
  return out
}

function readUint32(buf, offset){
  return ((buf[offset] << 24) >>> 0) + (buf[offset + 1] << 16) + (buf[offset + 2] << 8) + buf[offset + 3]
}

function writeUint32(buf, offset, value){
  buf[offset] = (value >>> 24) & 0xff
  buf[offset + 1] = (value >>> 16) & 0xff
  buf[offset + 2] = (value >>> 8) & 0xff
  buf[offset + 3] = value & 0xff
}
