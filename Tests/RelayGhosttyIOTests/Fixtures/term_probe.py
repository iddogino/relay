# A terminal probe, run as the program inside a terminal under test (locally
# or over SSH) to record exactly what the terminal sends back to programs.
# Python 3 standard library only, so it runs on any host. Output lines:
#   <TAG>:<hex>   the bytes received, 32 per line (an empty line when none)
#   LEN:<n> / SHA:<hex>   for large inputs ("hash" option)
#   READY / END   when it is listening / finished
#
#   query <hex>...                 write each query, collect the replies
#   record <setup> <teardown> <idle> [hash] [quiet]
#                                  write setup, then record input until it
#                                  goes quiet for <idle> seconds ("quiet":
#                                  when none is expected, wait only <idle>)
#   emit <hex> [linger]           write bytes (and stay for <linger> seconds)
#   emitseq <pause> <hex>...       write each, pausing <pause> seconds after each
#   osc52 <lines>                  copy <lines> numbered lines with OSC 52
#   image <id> <w> <h> <rrggbbaa> <fmt> <chunk> [q]
#                                  transmit and display a kitty graphics
#                                  image (fmt 32 = RGBA, 100 = PNG) in
#                                  base64 chunks of <chunk> bytes; record
#                                  the replies
import base64, hashlib, os, select, sys, termios, time, tty, zlib, struct

fd = sys.stdin.fileno()


def write(data):
    while data:
        n = os.write(1, data)
        data = data[n:]


def collect(first, idle, total):
    """Reads input until none arrives for `idle` seconds (waiting up to
    `first` seconds for the first byte, `total` seconds at most)."""
    data = b""
    start = time.time()
    deadline = start + first
    while True:
        remaining = min(deadline, start + total) - time.time()
        if remaining <= 0:
            break
        ready, _, _ = select.select([fd], [], [], remaining)
        if not ready:
            break
        chunk = os.read(fd, 65536)
        if not chunk:
            break
        data += chunk
        deadline = time.time() + idle
    return data


def dump(tag, data):
    h = data.hex()
    lines = [h[i:i + 64] for i in range(0, len(h), 64)] or [""]
    for line in lines:
        write(("%s:%s\r\n" % (tag, line)).encode())


def png(w, h, rgba):
    raw = b"".join(b"\x00" + rgba * w for _ in range(h))
    def chunk(kind, body):
        return struct.pack(">I", len(body)) + kind + body + struct.pack(">I", zlib.crc32(kind + body) & 0xFFFFFFFF)
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 6, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b""))


def main(args):
    mode = args[0]
    saved = termios.tcgetattr(fd)
    tty.setraw(fd)
    try:
        clear = os.environ.get("PROBE_NOCLEAR") != "1"
        if mode == "query":
            # Drop keys typed before the probe started (they're not replies).
            time.sleep(0.3)
            termios.tcflush(fd, termios.TCIFLUSH)
            if clear:
                write(b"\x1b[H\x1b[2J")
            replies = []
            for query in args[1:]:
                write(bytes.fromhex(query))
                replies.append(collect(3, 0.4, 8))
            # Reported only now: the queries move the cursor around.
            write(b"\x1b[0m\x1b[H\x1b[2J" if clear else b"\r\n")
            for i, reply in enumerate(replies):
                dump("R%d" % i, reply)
        elif mode == "record":
            setup, teardown, idle = bytes.fromhex(args[1]), bytes.fromhex(args[2]), float(args[3])
            write(setup + b"READY\r\n")
            data = collect(idle if "quiet" in args[4:] else 20, idle, 120)
            write(teardown)
            if "hash" in args[4:]:
                write(("LEN:%d\r\nSHA:%s\r\n" % (len(data), hashlib.sha256(data).hexdigest())).encode())
                dump("HEAD", data[:48])
                dump("TAIL", data[-48:])
            else:
                dump("GOT", data)
        elif mode == "emit":
            write(bytes.fromhex(args[1]))
            time.sleep(float(args[2]) if len(args) > 2 else 0)
        elif mode == "emitseq":
            for part in args[2:]:
                write(bytes.fromhex(part))
                time.sleep(float(args[1]))
        elif mode == "osc52":
            text = "\n".join("line %d of a large copy" % i for i in range(int(args[1])))
            write(b"\x1b]52;c;" + base64.b64encode(text.encode()) + b"\x1b\\")
            time.sleep(0.5)
        elif mode == "image":
            image_id, w, h = int(args[1]), int(args[2]), int(args[3])
            rgba, fmt, size = bytes.fromhex(args[4]), int(args[5]), int(args[6])
            quiet = args[7] if len(args) > 7 else "0"
            body = rgba * (w * h) if fmt == 32 else png(w, h, rgba)
            payload = base64.b64encode(body)
            write(b"\x1b[H\x1b[2J")
            chunks = [payload[i:i + size] for i in range(0, len(payload), size)]
            for n, part in enumerate(chunks):
                more = 1 if n < len(chunks) - 1 else 0
                if n == 0:
                    head = "a=T,f=%d,s=%d,v=%d,i=%d,q=%s,C=1,m=%d" % (fmt, w, h, image_id, quiet, more)
                else:
                    head = "m=%d" % more
                write(b"\x1b_G" + head.encode() + b";" + part + b"\x1b\\")
            dump("R0", collect(5, 0.5, 15))
            write(b"\x1b[%dHIMAGE-SENT\r\n" % (h // 16 + 3))
    finally:
        termios.tcsetattr(fd, termios.TCSAFLUSH, saved)
    write(b"\r\nEND\r\n")
    if mode == "image":
        time.sleep(float(os.environ.get("PROBE_LINGER", "30")))


main(sys.argv[1:])
