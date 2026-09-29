#!/usr/bin/env python3
"""Generate one ARP exchange, one ping and one UDP round trip, back to back.

The acceptance test for the SoC's Ethernet peripheral, driven by `make loopback`.
Nothing here needs root: UDP sockets are unprivileged, and `ping` carries its own
capability.

The ordering is the point. Straight after the board is programmed its ARP cache
is empty, so the *first* thing sent to it makes the fabric broadcast an ARP
request and the PC answer it. The datagram is not lost doing so -- the capture
shows the reply going out after the resolution completes, 12 us later -- but it
does mean the sequence exercises three protocols rather than one:

    1. a UDP datagram, whose reply waits on ARP resolution
    2. a ping, which now has a resolved cache
    3. a UDP datagram, answered immediately

To see the ARP at all, both caches have to be cold: reprogram the board and run
`nmcli device reapply <iface>` to empty the PC's neighbour table.

Three protocols, five or six frames, spread over a few hundred milliseconds --
which is the whole question the capture is asked to answer.

    ./scripts/eth-traffic.py            # against the defaults below
    ./scripts/eth-traffic.py --gap 0.05
"""

import argparse
import socket
import subprocess
import sys
import time

DEFAULT_IP = "10.0.0.2"
DEFAULT_PORT = 7


def udp(target, port, payload, timeout):
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.settimeout(timeout)
    sock.sendto(payload, (target, port))
    try:
        reply, _ = sock.recvfrom(2048)
        return reply
    except socket.timeout:
        return None
    finally:
        sock.close()


def wait_for(target, timeout):
    """Poll until the board answers a ping, or the timeout runs out."""
    deadline = time.monotonic() + timeout
    first = True
    while time.monotonic() < deadline:
        if subprocess.run(
            ["ping", "-c", "1", "-W", "1", target],
            capture_output=True,
        ).returncode == 0:
            if not first:
                print(" up")
            return True
        if first:
            print(f"waiting for {target}", end="", flush=True)
            first = False
        print(".", end="", flush=True)
        time.sleep(1)
    if not first:
        print()
    return False


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--ip", default=DEFAULT_IP)
    ap.add_argument("--port", type=int, default=DEFAULT_PORT)
    ap.add_argument("--gap", type=float, default=0.05, help="seconds between steps")
    ap.add_argument(
        "--wait",
        type=float,
        default=20.0,
        help="seconds to wait for the board to answer before giving up. "
        "Programming the FPGA resets the PHY, so the link drops and "
        "renegotiates; for a second or two afterwards nothing answers and "
        "that is not a fault.",
    )
    ap.add_argument("--timeout", type=float, default=0.3)
    ap.add_argument(
        "--extra",
        type=int,
        default=0,
        help="further UDP round trips after the three, to push the ILA past its "
        "trigger point so the buffer can be read back",
    )
    args = ap.parse_args()

    if args.wait and not wait_for(args.ip, args.wait):
        print(f"{args.ip} did not answer within {args.wait:g}s -- is the link up?")
        return 1

    print(f"1. UDP to {args.ip}:{args.port} (may be lost to ARP resolution)")
    lost = udp(args.ip, args.port, b"arp-warm", args.timeout)
    print(f"   {'echoed: ' + repr(lost) if lost else 'no reply, as expected'}")
    time.sleep(args.gap)

    print(f"2. ping {args.ip}")
    ping = subprocess.run(
        ["ping", "-c", "1", "-W", "1", args.ip], capture_output=True, text=True
    )
    line = next((l for l in ping.stdout.splitlines() if "bytes from" in l), None)
    print(f"   {line or 'no reply'}")
    time.sleep(args.gap)

    print(f"3. UDP to {args.ip}:{args.port}")
    echoed = udp(args.ip, args.port, b"hello ila", args.timeout)
    print(f"   {'echoed: ' + repr(echoed) if echoed else 'no reply'}")

    for i in range(args.extra):
        time.sleep(args.gap)
        udp(args.ip, args.port, f"filler {i}".encode(), args.timeout)
    if args.extra:
        print(f"4. {args.extra} further UDP round trips, to finish the acquisition")

    ok = ping.returncode == 0 and echoed == b"hello ila"
    print("\nall three protocols exercised" if ok else "\nsomething did not answer")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
