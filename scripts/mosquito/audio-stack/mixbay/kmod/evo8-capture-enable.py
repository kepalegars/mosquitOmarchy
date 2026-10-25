#!/usr/bin/env python3
"""Enable the EVO 8's 6-channel USB capture selector (EU51) on connect.

The firmware may leave EU51 disabled after power-on, which silences every USB
capture channel (mic 1-4 and loopback 5|6) even with correct gain and 48V.
The kernel module exposes raw control transfers through /dev/evo8. EU51's
Enable selector is write-only on this unit, so a successful SET is the best
confirmation available.
"""

import fcntl
import struct
import sys
import time

XFER_FMT = "<BBHHH256s"
XFER_SIZE = struct.calcsize(XFER_FMT)
EVO_CTRL_TRANSFER = (3 << 30) | (XFER_SIZE << 16) | (0x45 << 8) | 0
REQTYPE_GET = 0xA1
REQTYPE_SET = 0x21
REQ_CUR = 0x01
EU51 = 0x3300


def ctrl(fd, reqtype, wvalue, windex, data=b"", length=None):
    if reqtype & 0x80:
        wlength = length if length is not None else 0
        payload = b"\x00" * 256
    else:
        wlength = len(data)
        payload = data.ljust(256, b"\x00")
    buf = bytearray(
        struct.pack(XFER_FMT, reqtype, REQ_CUR, wvalue, windex, wlength, payload)
    )
    fcntl.ioctl(fd, EVO_CTRL_TRANSFER, buf)
    if reqtype & 0x80:
        _, _, _, _, rlen, rdata = struct.unpack(XFER_FMT, buf)
        return bytes(rdata[: min(rlen, 256)])
    return None


def enable(fd):
    cur = ctrl(fd, REQTYPE_GET, 0x0000, EU51, length=1)
    if cur and cur[0] & 1:
        return "EVO 8 capture already enabled"
    ctrl(fd, REQTYPE_SET, 0x0000, EU51, data=b"\x01")
    return "EVO 8 capture enable requested"


def main():
    last = None
    for _ in range(40):
        try:
            with open("/dev/evo8", "rb") as fd:
                print(enable(fd))
            return 0
        except OSError as err:
            last = err
            time.sleep(0.05)
    print(f"evo8-capture-enable: {last}", file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main())
