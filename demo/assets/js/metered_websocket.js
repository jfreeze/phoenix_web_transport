// The stock WebSocket transport with byte and frame counters, so the demo
// page can show the same numbers for both transports.

export const stats = {
  transport: "websocket",
  frames: 0,
  bytes: 0,
  lanes: {0: {frames: 0, bytes: 0}},
  reset(){
    this.frames = 0
    this.bytes = 0
    this.lanes = {0: {frames: 0, bytes: 0}}
  }
}

export default class MeteredWebSocket extends WebSocket {
  constructor(url, protocols){
    super(url, protocols)
    stats.reset()
  }

  set onmessage(fn){
    super.onmessage = event => {
      const size = typeof event.data === "string" ? event.data.length : event.data.byteLength
      stats.frames += 1
      stats.bytes += size
      stats.lanes[0].frames += 1
      stats.lanes[0].bytes += size
      fn(event)
    }
  }

  get onmessage(){
    return super.onmessage
  }
}
