# LiveView over WebTransport: one QUIC stream per component

Status: prototype working end to end in Chrome (September 2026). The library lives at the repo root, the demo app in `demo/`. This document
is the spec for the transport, the answer to "library or patch", and the list
of what a production version still needs.

## 1. The problem

A LiveView pushes every diff down one WebSocket, which is one ordered TCP
stream. A small update queued behind a large one waits for every byte of the
large one to arrive, and a single lost packet stalls everything behind it.
That is head-of-line blocking, and it is why a flash message or a form
validation can feel sluggish while a big table is streaming in.

The two updates are already separate channel messages. What they share is the
wire. QUIC gives a connection many independent, ordered streams, and
WebTransport exposes those streams to the browser. So the fix is at the
packaging layer: put each component's diffs on its own stream, and let the
sender favour small frames over large ones, which is the shortest-message-first
rule at the heart of Homa's scheduling.

## 2. What was built

Nothing in Phoenix, LiveView or phoenix.js is patched. The prototype is three
server modules, one client class and a serializer, all of which could ship as
a Hex package.

| Piece | File | Role |
|---|---|---|
| Listener | `lib/phoenix_web_transport/listener.ex` | Starts a cowboy HTTP/3 listener on UDP 4433 beside the normal endpoint |
| Handler | `lib/phoenix_web_transport/handler.ex` | `cowboy_webtransport` handler that drives `Phoenix.LiveView.Socket` through the `Phoenix.Socket.Transport` callbacks, like the WebSocket transport does |
| Lane serializer | `lib/phoenix_web_transport/lane_serializer.ex` | A `Phoenix.Socket.Serializer` that splits one `diff` push into per-component frames |
| Frame | `lib/phoenix_web_transport/frame.ex` | Length-prefixed framing on streams |
| Cert | `lib/phoenix_web_transport/cert.ex` | 13-day ECDSA P-256 dev cert, as Chrome's `serverCertificateHashes` requires |
| Client transport | `assets/js/phoenix_web_transport.js` | A WebSocket-shaped class handed to `LiveSocket` via the `transport` option |

### 2.1 Session layout

```
browser                                     server
  |-- CONNECT :protocol=webtransport ---------> handler.init/2: socket.connect/1
  |<-- 200 ----------------------------------- (upgrade; session process = transport pid)
  |-- bidi stream: client frames ------------> handle_in/2 (join, events, heartbeat)
  |<-- uni stream, lane 0 -------------------- control: join reply, root diffs, events, replies
  |<-- uni stream, lane 1 -------------------- component 1 deltas
  |<-- uni stream, lane N -------------------- component N deltas
```

Every server stream starts with `<<lane::32>>`, then frames
`<<len::32, type::8, payload>>`. Lanes map onto a bounded stream set
(`max_lanes`, default 16): lane 0 owns a stream, component lanes share the
rest by `rem(cid - 1, max_lanes - 1) + 1`. The client dispatches frames from
every stream into the same `phoenix.js` socket, so the channel layer never
knows.

### 2.2 The split rule

A component diff in `c` that has no `s` key is a pure delta to a component the
client already holds. It depends on nothing else in the same message, so it
goes on lane `cid`. Everything else stays together on lane 0: the root diff,
new or reset components (they carry `s` and the root references them),
components sharing statics with a sibling (`s` is a positive cid), events,
title, replies, joins and heartbeats.

The serializer is where the split lives, not the transport. It sees the
`Phoenix.Socket.Message` before JSON encoding, so there is no double decode,
and the WebSocket baseline keeps the stock serializer untouched.

### 2.3 Scheduling

Independent streams are necessary but not sufficient. msquic schedules
streams of equal priority FIFO, so a small frame queued after a large one
would still wait. Before each send the handler sets the stream priority from
the size of the frame it is about to write (`0xFFFF - size / 32`), so a 200
byte pulse always jumps ahead of a 300 KB table. That is Homa's
shortest-remaining-first idea applied at the diff layer.

## 3. Library or patch?

**Library.** Everything needed already exists as an extension point:

- `Phoenix.Socket.Transport` is a documented behaviour for custom transports.
  The handler calls `connect/1`, `init/1`, `handle_in/2`, `handle_info/2` and
  `terminate/2`, the same five calls the WebSocket plug makes.
- `Phoenix.Socket` takes a `serializer` list per transport, so the lane
  serializer is configuration.
- `phoenix.js` takes any WebSocket-shaped constructor through the `transport`
  option, and `LiveSocket` passes its options through.
- cowboy 2.19 ships experimental HTTP/3 and WebTransport (drafts 07 to 13)
  when compiled with the `COWBOY_QUICER` macro, on top of emqx's `quicer`
  NIF around msquic.

Two things are not extension points and are handled with workarounds:

1. **Stream priority.** cowboy's WebTransport commands cannot set stream
   options, so by default the handler reads the stream handle out of the
   connection process's dictionary. `patches/0001` adds a
   `{set_stream_priority, StreamID, Prio}` command to cowboy (20 lines,
   verified with the demo via the `stream_priority: :command` option).
2. **The `COWBOY_QUICER` macro.** Mix cannot pass `erl_opts` to a rebar3
   dependency, so `scripts/build_quic.sh` sets `ERL_COMPILER_OPTIONS` for the
   cowboy compile. A cowboy release that compiles the QUIC modules whenever
   `quicer` is present would fix that.

No change to `phoenix_live_view` is required for the split, because
`Rendered.mergeDiff` merges component diffs independently and
`View.update` patches only the components a diff names.

## 4. Things a production version must handle

- **No cookies on the CONNECT.** WebTransport sends the handshake with
  credentials mode `omit`, so there is no Plug session and LiveView skips its
  CSRF-to-session check. LiveView still verifies the signed session token
  from the page, so mount works, but `live_socket_id` disconnects and any
  `on_mount` hook that reads the session need identity from elsewhere. The
  right pattern is the one Phoenix already has for WebSocket auth tokens: a
  signed, short-lived token in the connect params.
- **Origin.** The handler checks the `Origin` header against a list. Wire it
  to the endpoint's `check_origin` config.
- **Certificates.** Dev uses a pinned 13-day cert. Production needs a public
  cert on the QUIC port, and UDP 443 (or an alternate port advertised via
  `Alt-Svc`) open through Cloudflare or whatever fronts the app. Cloudflare
  tunnels do not carry WebTransport today; this needs a direct path or a
  QUIC-aware edge.
- **Fallback.** Safari support is recent and `serverCertificateHashes` is
  Chromium-only, so the client must fall back to WebSocket. The demo does
  this when `WebTransport` is absent; a real client should also fall back on
  handshake failure, the way `longPollFallbackMs` works.
- **Cross-lane ordering edge cases.** A root diff that removes a component
  and a late delta for that component can arrive in either order. The client
  ignores deltas for components no longer in the DOM, so this is benign, but
  events (`e`) pushed alongside a component delta may fire before the delta
  lands. Option: carry a per-diff sequence number and let the client hold
  events until every lane of that diff has arrived.
- **Flow control.** Chrome limits how many unidirectional streams the server
  may open; `max_lanes` keeps the server under it. A page with hundreds of
  components shares streams, which is still correct.
- **Binary payloads.** Lane 0 handles them; `push_event` binaries are rare in
  practice and untested here.
- **Supervision.** cowboy's `start_quic` spawns unlinked processes; the
  listener GenServer only closes the msquic listener on shutdown. Fine for a
  prototype, not for a release.

## 5. Measured

Headless Chrome 153, loopback, 2000 rows every 400 ms, pulse every 100 ms,
8 seconds per run:

| | WebSocket | WebTransport |
|---|---|---|
| pulse latency last / p50 / p95 / max | 1 / 1 / 102 / 108 ms | 1 / 1 / 87 / 105 ms |
| heavy latency last / p50 / max | 94 / 88 / 96 ms | 85 / 88 / 105 ms |
| bytes, frames | 6.8 MB, 97 | 6.8 MB, 97 |
| streams | 1 | lane 0: 1 frame, 379 KB (join); lane 1: 77 frames, 10 KB (pulse); lane 2: 19 frames, 6.4 MB (heavy) |

On unthrottled loopback the two are equal. The p95 in both is the browser's
own DOM patch of the 340 KB table, which blocks the main thread for about 85
ms regardless of how the bytes arrived. The transport only matters once the
network is the bottleneck, which is the normal case over the internet. Run
`sudo scripts/impair.sh on` (20 Mbit/s, 20 ms) to see it: at that rate a
heavy diff takes about 140 ms to transfer, and every pulse behind it on the
WebSocket waits that long.

## 6. What the win actually is

- **Per-component independence** is real and cheap: a slow table cannot delay
  a fast counter, a lost packet in one stream does not stall the others.
- **Shortest-message-first** at the sender is the Homa-flavoured part and is
  what makes the independence pay off under load.
- **Not** a win on loopback, or when the client's own patch time dominates,
  and no transport can help a LiveView whose server render is slow.

Follow-ups worth doing if this goes further: the cowboy priority command,
WebTransport datagrams for fire-and-forget presence pings, and moving the
split from "per component" to "per stream insert" so a single big `stream/3`
container can also be chunked without blocking its siblings.
