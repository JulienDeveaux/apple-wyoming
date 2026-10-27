#!/usr/bin/env python3
# Client Wyoming STT commun : envoie chaque WAV au rythme réel, mesure la latence fin d'audio -> transcript,
# et le taux d'erreur de mots (WER) contre phrases.txt.
import json, os, socket, sys, time, unicodedata, wave

HOST, PORT = sys.argv[1], int(sys.argv[2])
LABEL = sys.argv[3] if len(sys.argv) > 3 else f"{HOST}:{PORT}"
LANG = "fr"
HERE = os.path.dirname(os.path.abspath(__file__))
REFS = [l.strip() for l in open(os.path.join(HERE, "phrases.txt"), encoding="utf-8") if l.strip()]
REFS_NUM = [l.strip() for l in open(os.path.join(HERE, "phrases_num.txt"), encoding="utf-8") if l.strip()]
PAD_MS = int(os.environ.get("PAD_MS", "0"))  # silence ajouté en fin d'audio, comme un satellite après la parole
CHUNK = 1024  # échantillons par bloc (64 ms à 16 kHz)


def send(sock, typ, data=None, payload=b""):
    data_b = json.dumps(data or {}).encode()
    hdr = {"type": typ, "data_length": len(data_b)}
    if payload:
        hdr["payload_length"] = len(payload)
    sock.sendall(json.dumps(hdr).encode() + b"\n" + data_b + payload)


def recv(f):
    hdr = json.loads(f.readline())
    data = hdr.get("data") or {}
    if hdr.get("data_length"):
        data = json.loads(f.read(hdr["data_length"]))
    if hdr.get("payload_length"):
        f.read(hdr["payload_length"])
    return hdr["type"], data


def norm(s):
    s = unicodedata.normalize("NFD", s.lower())
    s = "".join(c for c in s if unicodedata.category(c) != "Mn")
    s = s.replace("%", " pour cent ").replace("°", " degres ").replace("kw", " kilowatt ")
    s = "".join(c if c.isalnum() else " " for c in s)
    s = " ".join("%s heures %s" % tuple(w.split("h")) if w[:1].isdigit() and "h" in w else w for w in s.split())
    return [w for w in s.split() if w]


def wer(ref, hyp):
    r, h = norm(ref), norm(hyp)
    d = list(range(len(h) + 1))
    for i in range(1, len(r) + 1):
        prev, d[0] = d[0], i
        for j in range(1, len(h) + 1):
            cur = min(d[j] + 1, d[j - 1] + 1, prev + (r[i - 1] != h[j - 1]))
            prev, d[j] = d[j], cur
    return d[len(h)], len(r)


def one(path):
    w = wave.open(path)
    rate, width, ch = w.getframerate(), w.getsampwidth(), w.getnchannels()
    frames = w.readframes(w.getnframes()) + b"\x00" * (rate * width * ch * PAD_MS // 1000)
    sock = socket.create_connection((HOST, PORT), timeout=60)
    f = sock.makefile("rb")
    send(sock, "transcribe", {"language": LANG})
    send(sock, "audio-start", {"rate": rate, "width": width, "channels": ch})
    step = CHUNK * width * ch
    t0 = time.monotonic()
    for k, off in enumerate(range(0, len(frames), step)):
        # rythme temps réel : le bloc k part à l'instant k * durée_bloc
        lag = t0 + k * CHUNK / rate - time.monotonic()
        if lag > 0:
            time.sleep(lag)
        send(sock, "audio-chunk", {"rate": rate, "width": width, "channels": ch}, frames[off:off + step])
    send(sock, "audio-stop", {})
    t_stop = time.monotonic()
    while True:
        typ, data = recv(f)
        if typ == "transcript":
            break
    lat = time.monotonic() - t_stop
    sock.close()
    return data.get("text", ""), lat


def main():
    files = sorted(x for x in os.listdir(os.path.join(HERE, "corpus")) if x.endswith(".wav"))
    errs = words = 0
    lats = []
    rows = []
    for i, name in enumerate(files):
        text, lat = one(os.path.join(HERE, "corpus", name))
        e, n = min(wer(REFS[i], text), wer(REFS_NUM[i], text))
        errs += e; words += n; lats.append(lat)
        rows.append(f"{name} {lat*1000:6.0f} ms  err {e}/{n}  | {text}")
    print(f"=== {LABEL} (silence final {PAD_MS} ms)")
    print("\n".join(rows))
    lats.sort()
    print(f">>> {LABEL}: WER {100*errs/words:.1f}% ({errs}/{words}) | latence médiane {lats[len(lats)//2]*1000:.0f} ms, "
          f"p90 {lats[int(len(lats)*0.9)]*1000:.0f} ms, max {lats[-1]*1000:.0f} ms")


main()
