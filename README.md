# phoenix_web_transport

WebTransport (HTTP/3 over QUIC) as a transport for Phoenix sockets and
LiveView, with **one QUIC stream per LiveView component** and
**shortest-message-first scheduling**, so a small update is never stuck
behind a large one.

**Status: working prototype, not a release.** Verified end to end in Chrome
153 against a local server. Not yet run over a real network or from a phone.
See [Status](#status) before depending on it.

## Why

A LiveView pushes every diff down one WebSocket, which is one ordered TCP
stream. A 50-byte counter update queued behind a 300 KB table diff waits for
every byte of the table, and one lost packet stalls everything behind it.
That head-of-line blocking is the reason a flash message or a form validation
feels sluggish while something big is streaming in, and it is worst on
mobile, where loss is bursty and round trips are long.

QUIC gives a connection many independent ordered streams, and WebTransport
hands those streams to the browser. LiveView's own diff format already
splits cleanly by component, so this library puts each component's deltas on
its own stream and tells the QUIC sender to favour small frames. The client
reassembles frames from every stream into the same `phoenix.js` socket, and
nothing in Phoenix, LiveView or `phoenix.js` is patched.

Beyond the split, QUIC brings things a mobile LiveView wants anyway:
per-stream loss recovery, one-round-trip handshakes, and potentially
connection migration across a Wi-Fi to cellular switch.

## How it works

```
browser                                     server
  |-- CONNECT :protocol=webtransport ---------> handler: socket.connect/1  (Phoenix.Socket.Transport)
  |-- bidi stream: client frames ------------> handle_in/2  (joins, events, heartbeats)
  |<-- uni stream, lane 0 -------------------- control: join reply, root diffs, events, replies
  |<-- uni stream, lane 1 -------------------- component 1 deltas
  |<-- uni stream, lane N -------------------- component N deltas
```

| Piece | File | Role |
|---|---|---|
| `PhoenixWebTransport.LaneSerializer` | `lib/phoenix_web_transport/lane_serializer.ex` | A `Phoenix.Socket.Serializer` that splits one `diff` push into per-component frames. **This is the idea.** |
| `PhoenixWebTransport.Handler` | `lib/phoenix_web_transport/handler.ex` | `cowboy_webtransport` handler that drives a `Phoenix.Socket.Transport` (e.g. `Phoenix.LiveView.Socket`), maps lanes to QUIC streams, sets stream priority by frame size |
| `PhoenixWebTransport.Listener` | `lib/phoenix_web_transport/listener.ex` | Starts a cowboy HTTP/3 listener on a UDP port beside your existing endpoint |
| `PhoenixWebTransport.Frame` | `lib/phoenix_web_transport/frame.ex` | Length-prefixed framing on streams |
| `PhoenixWebTransport.Cert` | `lib/phoenix_web_transport/cert.ex` | 13-day ECDSA P-256 dev cert for Chrome's `serverCertificateHashes` |
| `WebTransportTransport` | `assets/js/phoenix_web_transport.js` | WebSocket-shaped class handed to `LiveSocket` via the `transport` option |

The split rule: a component diff without statics (`s`) is a pure delta to a
component the browser already holds and travels alone on lane `cid`.
Everything else (root diff, new or reset components, events, title, replies)
stays on lane 0. Full design, edge cases and measurements are in
[docs/SPEC.md](docs/SPEC.md).

## Server requirements

Your Phoenix endpoint keeps running on **Bandit** (or cowboy) exactly as it
does today, for HTTP and the WebSocket fallback. The QUIC listener is a
separate OTP child, because no Elixir server speaks QUIC: Bandit and
Thousand Island are TCP only, and the only QUIC stack on the BEAM is
[quicer](https://github.com/emqx/quic) (msquic). cowboy 2.19 has an
experimental HTTP/3 and WebTransport layer on top of it, and that is what
the listener uses. A cowboy-free connection loop on quicer plus cowlib's
HTTP/3 machine is on the roadmap.

- Elixir 1.15+, OTP 26+
- `cmake` and OpenSSL 3 (`brew install cmake openssl@3` on macOS) to build the msquic NIF
- cowboy compiled with the `COWBOY_QUICER` macro: `mix deps.quic` does it (see `scripts/build_quic.sh`)

## Usage

```elixir
# mix.exs
{:phoenix_web_transport, github: "jfreeze/phoenix_web_transport"}

# application.ex, after your endpoint
{PhoenixWebTransport.Listener,
 endpoint: MyAppWeb.Endpoint,
 socket: Phoenix.LiveView.Socket,
 path: "/live",
 port: 4433,
 check_origin: ["https://myapp.example.com"],
 certfile: "/etc/letsencrypt/live/quic.myapp.example.com/fullchain.pem",
 keyfile: "/etc/letsencrypt/live/quic.myapp.example.com/privkey.pem",
 url: "https://quic.myapp.example.com:4433/live"}
```

```html
<!-- root layout -->
<meta name="wt-url" content={PhoenixWebTransport.Listener.url()} />
<meta name="wt-cert-hash" content={PhoenixWebTransport.Listener.cert_hash()} />  <!-- dev only -->
```

```js
// app.js
import WebTransportTransport from "phoenix_web_transport"
WebTransportTransport.certHash = document.querySelector("meta[name='wt-cert-hash']")?.content
const liveSocket = new LiveSocket(wtUrl, Socket, {transport: WebTransportTransport, params: {...}})
```

Then run `mix deps.quic` once after `mix deps.get`.

## Demo and test harness

`demo/` is a Phoenix app that runs the same LiveView over WebSocket and over
WebTransport side by side, with a scoreboard that says which is ahead and
why. `scripts/impair.sh` shapes loopback with dummynet so the network
becomes the bottleneck.

```sh
brew install cmake openssl@3
cd demo && mix setup && mix phx.server     # first run builds msquic, several minutes
open http://localhost:4000
sudo ../scripts/impair.sh on               # 20 Mbit/s, 20 ms; sudo ../scripts/impair.sh off
```

Headless runs: `/demo?transport=wt&rows=2000&hold=8000` keeps the page's
load event pending so `chrome --headless=new --dump-dom` captures the stats
after 8 seconds.

## Status

Done and verified locally:

- Chrome connects over WebTransport, LiveView mounts, joins, receives diffs
  and sends events through the lane serializer and handler.
- Per-component streams: a two-component page shows lane 0 (join), lane 1
  (small component, KBs), lane 2 (large component, MBs).
- Stream priority set per frame, either by peeking at the quicer handle
  (default, unpatched cowboy) or through a new cowboy command
  (`patches/0001-cowboy-webtransport-set-stream-priority.patch`, verified).
- A vanished peer ends the session promptly instead of buffering forever.
- Unit tests for the split rule and framing; LiveView tests for the demo.

Not done:

- **A clean measurement showing the win.** On unthrottled loopback both
  transports are identical, as expected (the browser's DOM patch dominates).
  A loopback dummynet run needs the MTU and queue fixes in `impair.sh` and
  one session per pipe; the definitive test is a phone on cellular.
- **Automatic fallback** to WebSocket on handshake failure (the demo only
  falls back when the API is absent). Required: some networks drop UDP 443,
  and Safari support (26.4+) is recent.
- **Auth on connect.** WebTransport sends no cookies, so there is no Plug
  session. LiveView still verifies its signed page token, but
  `live_socket_id` and session-reading `on_mount` hooks need a signed
  connect param, the way Phoenix's WebSocket auth token works.
- **Cross-lane ordering**: events pushed alongside a component delta may
  fire before the delta lands. Fix: a per-diff sequence number.
- **Endpoint integration** (`socket "/live", ..., webtransport: [...]`).
- **A cowboy-free QUIC connection loop**, for Bandit shops.
- **Hosting**: needs a direct UDP path with a public cert. Cloudflare
  Tunnel and the Cloudflare edge do not carry WebTransport.

## Upstream

- `patches/0001-cowboy-webtransport-set-stream-priority.patch`: adds a
  `{set_stream_priority, StreamID, Prio}` WebTransport command to cowboy
  2.19, so handlers stop reading the connection process dictionary.
- Proposal for cowboy: compile the HTTP/3 modules whenever `quicer` is a
  dependency, instead of requiring the `COWBOY_QUICER` macro. Mix cannot
  pass `erl_opts` to a rebar3 dependency, so today every Elixir user needs
  the `ERL_COMPILER_OPTIONS` workaround in `scripts/build_quic.sh`.
- Nothing needed in Phoenix or LiveView: the `Phoenix.Socket.Transport`
  behaviour, the per-transport serializer option and `phoenix.js`'s
  `transport` option were enough.

## Layout

```
lib/phoenix_web_transport/   the library
assets/js/                   the browser transport class
test/                        split rule and framing tests
demo/                        Phoenix app: side-by-side comparison (shares ../deps and ../_build)
scripts/build_quic.sh        builds quicer and cowboy with QUIC (mix deps.quic)
scripts/impair.sh            macOS dummynet shaping for the demo
patches/                     proposed upstream changes
docs/SPEC.md                 design, edge cases, measurements
```

## License

MIT
