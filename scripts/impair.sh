#!/usr/bin/env bash
# Shapes the demo's server-to-client traffic on loopback with macOS dummynet,
# so the transport becomes the bottleneck and the head-of-line blocking of
# one TCP stream becomes visible.
#
#   sudo scripts/impair.sh on [bandwidth] [delay] [loss]   default 20Mbit/s 20ms 0
#   sudo scripts/impair.sh off
#
# Each port gets its own pipe with identical settings: pipe 1 for 4000
# (WebSocket over TCP), pipe 2 for 4433 (WebTransport over UDP). A shared pipe
# would let one transport's bytes queue in front of the other's, and the
# comparison would measure the sharing, not the transports. Even so, only one
# session per transport should be open while measuring: every extra tab adds
# 6.8 Mbit/s of table diffs to a 20 Mbit/s pipe.
#
# Two loopback artifacts have to be neutralised or QUIC is punished unfairly:
#   * lo0's MTU is 16384, so TCP moves 16 KB per packet while QUIC is capped
#     at ~1350-byte datagrams. dummynet's default queue is 50 *packets*, so
#     QUIC overflows it 12x sooner and collapses under loss. The queue is set
#     in bytes and lo0 is dropped to a real-world 1500 MTU while impaired.
#   * The default pf.conf skips lo0 entirely; a copy without that line is
#     loaded and the original restored on "off".
set -euo pipefail

ANCHOR=wtdemo
BW="${2:-20Mbit/s}"
DELAY="${3:-20ms}"
PLR="${4:-0}"
MTU_FILE=/tmp/wtdemo-lo0-mtu

case "${1:-}" in
  on)
    [ -f "$MTU_FILE" ] || ifconfig lo0 | awk '/mtu/ {print $NF}' > "$MTU_FILE"
    ifconfig lo0 mtu 1500
    dnctl pipe 1 config bw "$BW" delay "$DELAY" plr "$PLR" queue 512Kbytes
    dnctl pipe 2 config bw "$BW" delay "$DELAY" plr "$PLR" queue 512Kbytes
    grep -v 'set skip on lo0' /etc/pf.conf > /tmp/pf-wtdemo.conf
    printf 'dummynet-anchor "%s"\nanchor "%s"\n' "$ANCHOR" "$ANCHOR" >> /tmp/pf-wtdemo.conf
    pfctl -q -f /tmp/pf-wtdemo.conf
    pfctl -q -a "$ANCHOR" -f - <<RULES
dummynet out quick proto tcp from any port 4000 to any pipe 1
dummynet out quick proto udp from any port 4433 to any pipe 2
RULES
    pfctl -q -e 2>/dev/null || true
    echo "impairment on: $BW, $DELAY delay, loss $PLR, 512 KB queue, lo0 mtu 1500; pipe 1 = 4000/tcp, pipe 2 = 4433/udp"
    echo "close other demo tabs, then reload one compare page so each pipe carries exactly one session"
    ;;
  off)
    pfctl -q -a "$ANCHOR" -F all 2>/dev/null || true
    dnctl -q flush 2>/dev/null || true
    pfctl -q -f /etc/pf.conf
    pfctl -q -d 2>/dev/null || true
    if [ -f "$MTU_FILE" ]; then ifconfig lo0 mtu "$(cat "$MTU_FILE")"; rm -f "$MTU_FILE"; fi
    echo "impairment off"
    ;;
  *)
    echo "usage: sudo $0 on [bandwidth] [delay] [loss] | off" >&2
    exit 1
    ;;
esac
