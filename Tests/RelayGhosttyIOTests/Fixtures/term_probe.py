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
#   termios                        report the terminal's modes (TIOS lines)
#                                  and the environment a terminal sets (ENV)
#   winsize <seconds>              report the window size (WS:rows,cols,
#                                  xpixels,ypixels) now and on each SIGWINCH,
#                                  until "q" is typed or <seconds> pass
#   cooked <seconds> [noecho]      leave the line discipline as it is: report
#                                  each line read (LINE:<hex>), end of file
#                                  (EOF) and signals (SIG:<name>), until a
#                                  line "quit" or <seconds> pass
#   flood <bytes>                  write <bytes> of numbered lines as fast as
#                                  the terminal takes them, then FLOOD-DONE
import base64, hashlib, os, select, signal, struct, sys, termios, time, tty, zlib, fcntl

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


def winsize():
    rows, cols, xpix, ypix = struct.unpack("HHHH", fcntl.ioctl(fd, termios.TIOCGWINSZ, b"\0" * 8))
    return "%d,%d,%d,%d" % (rows, cols, xpix, ypix)


def cooked(seconds, noecho):
    """Reads lines with the line discipline as the terminal set it up."""
    saved = termios.tcgetattr(fd)
    if noecho:
        attrs = termios.tcgetattr(fd)
        attrs[3] &= ~termios.ECHO
        termios.tcsetattr(fd, termios.TCSANOW, attrs)
    got = []
    for name in ("SIGINT", "SIGQUIT", "SIGTSTP", "SIGWINCH"):
        signal.signal(getattr(signal, name), lambda n, f, name=name: got.append("SIG:" + name[3:]))
    try:
        write(b"READY\r\n")
        deadline = time.time() + seconds
        while time.time() < deadline:
            while got:
                write((got.pop(0) + "\r\n").encode())
            try:
                ready, _, _ = select.select([fd], [], [], 0.1)
            except InterruptedError:
                continue
            if not ready:
                continue
            try:
                line = os.read(fd, 4096)
            except InterruptedError:
                continue
            if not line:
                write(b"EOF\r\n")
                continue
            write(("LINE:%s\r\n" % line.hex()).encode())
            if line.rstrip(b"\n") == b"quit":
                break
        while got:
            write((got.pop(0) + "\r\n").encode())
    finally:
        termios.tcsetattr(fd, termios.TCSANOW, saved)
    write(b"END\r\n")


def main(args):
    mode = args[0]
    if mode == "cooked":
        return cooked(float(args[1]), "noecho" in args[2:])
    if mode == "flood":
        total, n, chunk = int(args[1]), 0, []
        sent = 0
        while sent < total:
            n += 1
            line = b"flood line %d %s\r\n" % (n, b"x" * (n % 60))
            chunk.append(line)
            sent += len(line)
            if len(chunk) == 256:
                write(b"".join(chunk))
                chunk = []
        write(b"".join(chunk) + b"FLOOD-DONE %d\r\n" % n)
        write(b"END\r\n")
        return
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
        elif mode == "termios":
            iflag, oflag, cflag, lflag, _, _, cc = saved
            write(("TIOS:i=%x o=%x c=%x l=%x\r\n" % (iflag, oflag, cflag, lflag)).encode())
            names = [n for n in dir(termios) if n.startswith("V") and n.isupper() and isinstance(getattr(termios, n), int)
                     and getattr(termios, n) < len(cc) and n not in ("VMIN", "VTIME", "VT0", "VT1", "VTDLY")]
            for name in sorted(names):
                c = cc[getattr(termios, name)]
                write(("TIOS:%s=%02x\r\n" % (name, c if isinstance(c, int) else ord(c))).encode())
            for name in sorted(os.environ):
                if name in ("TERM", "COLORTERM", "TERM_PROGRAM", "LANG") or name.startswith("LC_"):
                    write(("ENV:%s=%s\r\n" % (name, os.environ[name])).encode())
        elif mode == "winsize":
            changes = []
            signal.signal(signal.SIGWINCH, lambda n, f: changes.append(1))
            write(("WS:%s\r\nREADY\r\n" % winsize()).encode())
            deadline = time.time() + float(args[1])
            while time.time() < deadline:
                try:
                    ready, _, _ = select.select([fd], [], [], 0.05)
                except InterruptedError:
                    ready = []
                if changes:
                    del changes[:]
                    write(("WS:%s\r\n" % winsize()).encode())
                if ready and b"q" in os.read(fd, 1024):
                    break
            write(("WS:%s\r\n" % winsize()).encode())
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
