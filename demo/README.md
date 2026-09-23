# Demo: LiveView over WebSocket vs WebTransport

The same LiveView served twice: left over the stock WebSocket, right over
WebTransport with one QUIC stream per component. A scoreboard compares the
two and says in words which is ahead and why. See the root README for the
library and `../docs/SPEC.md` for the design.

```sh
mix setup            # deps and assets; erlang_quic needs no native build
mix phx.server
open http://localhost:4000
```

Ports: `PORT` (HTTP, default 4000) and `WT_PORT` (UDP, default 4433).
`WT_URL` overrides the URL pages connect to.

The cowboy + msquic backend is optional: `brew install cmake openssl@3`,
`mix deps.quic` (builds msquic, slow the first time), then
`WT_BACKEND=cowboy mix phx.server`. `WT_PRIORITY=command` uses the cowboy
command from `../patches` instead of peeking at the quicer handle; apply the
patch to `../deps/cowboy` first.

Loopback is too fast to show a difference. To make the network the
bottleneck:

```sh
sudo ../scripts/impair.sh on            # 20 Mbit/s, 20 ms, one pipe per port
sudo ../scripts/impair.sh off
```

Keep exactly one session per transport open while measuring. Each extra tab
adds the full table load to that pipe.

The demo shares `../deps`, `../_build` and `../mix.lock` with the library
and depends on it by path. `mix precommit` runs the checks; the test env
does not start the QUIC listener.
