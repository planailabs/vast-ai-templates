"""Tail the running jobs' logs over HTTP, with a progress bar inferred from them.

A job is any process in this container that declares WEBUI_LOGS, found by
scanning /proc every few seconds -- so a run started hours after boot is picked
up without restarting anything, and `-e WEBUI_LOGS=...` at rental time works
too, because PID 1 is just another candidate and children inherit it.

Every distinct log is followed at once and offered in the UI; two processes
naming the same file share one tail, because that is one log, not two.

Standard library only: it has to run on a rented box with nothing installed.
"""

import collections
import hmac
import json
import os
import re
import secrets
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

SCAN_INTERVAL = 3.0          # how fast a newly started job shows up
MAX_LINE = 4096              # a binary blob must not become one 2 GB "line"
MAX_SOURCES = 16             # a loop over unique paths must not grow the heap
TOKEN_FILE = "/run/vastai-webui/token"

# CSI, OSC and the remaining two-byte escapes; then the C0 controls that are
# left once the line splitter has consumed \r and \n.
ANSI = re.compile(r"\x1b\[[0-9;?]*[ -/]*[@-~]|\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)|\x1b[@-_]")
CTRL = re.compile(r"[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]")

Cand = collections.namedtuple("Cand", "pid start logs pattern cmd")


def sanitize(text):
    """Make one log line safe to put in a <pre> and cheap to store."""
    return CTRL.sub("", ANSI.sub("", text)).rstrip()[:MAX_LINE]


def unquote(value):
    """vast re-parses the template's docker-options string, so the quotes
    order.sh wrote can arrive literally."""
    if len(value) > 1 and value[0] == value[-1] and value[0] in "'\"":
        return value[1:-1]
    return value


def parse_environ(blob):
    env = {}
    for item in blob.decode("utf-8", "replace").split("\0"):
        key, sep, value = item.partition("=")
        if key and sep:
            env[key] = unquote(value)
    return env


def read_env(pid):
    with open("/proc/%d/environ" % pid, "rb") as handle:
        return parse_environ(handle.read())


def proc_start(pid):
    """starttime (stat field 22). comm may contain spaces and ')', so the
    fields are counted from after the last ')'."""
    with open("/proc/%d/stat" % pid, "rb") as handle:
        rest = handle.read().decode("utf-8", "replace").rsplit(")", 1)[1]
    return int(rest.split()[19])


def proc_cmd(pid):
    with open("/proc/%d/cmdline" % pid, "rb") as handle:
        raw = handle.read().decode("utf-8", "replace")
    return " ".join(part for part in raw.split("\0") if part)[:200] or "pid %d" % pid


def scan():
    """Every process that declares WEBUI_LOGS."""
    found = []
    for entry in os.listdir("/proc"):
        if not entry.isdigit():
            continue
        pid = int(entry)
        try:
            env = read_env(pid)
            if not env.get("WEBUI_LOGS"):
                continue
            found.append(Cand(pid, proc_start(pid), env["WEBUI_LOGS"],
                              env.get("WEBUI_PROGRESS_PATTERN"), proc_cmd(pid)))
        except (OSError, ValueError, IndexError):
            continue  # exited mid-scan, or not ours to read
    return found


def rank(cand):
    # PID 1 carries the container-wide default; a real job outranks it.
    return (cand.pid != 1, cand.start)


def source_key(source):
    """Two processes naming the same log are one log, not two."""
    return os.path.normpath(source) if "/" in source else source


def default_key(cands, previous=None):
    """Which log the UI opens on: the newest real run. Nothing to choose from
    means the last one stays -- a finished run must not blank the screen."""
    if not cands:
        return previous
    return source_key(max(cands, key=rank).logs)


def pattern_for(cand, cands):
    """A job that sets only WEBUI_LOGS still gets the container-wide pattern."""
    if cand.pattern:
        return cand.pattern
    for other in cands:
        if other.pid == 1 and other.pattern:
            return other.pattern
    return None


def log_command(source):
    """A path is tailed, anything else is a systemd unit.

    `tail -F` handles rotation, truncation and a file that does not exist yet,
    which is most of the hard part of following a log.
    """
    if "/" in source or os.path.exists(source):
        return ["tail", "-n", "+1", "-F", source]
    return ["journalctl", "-n", "2000", "-f", "-u", source]


def num(text):
    if text is None:
        return None
    try:
        return float(text.strip().rstrip("%").replace(",", "").replace("_", ""))
    except (ValueError, AttributeError):
        return None


def parse_progress(rx, line):
    """None when the line does not match or carries no usable number."""
    match = rx.search(line)
    if not match:
        return None
    named = match.groupdict()
    percent = current = total = None
    if named.get("percent") is not None:
        percent = num(named["percent"])
    elif named.get("current") is not None and named.get("total") is not None:
        current, total = num(named["current"]), num(named["total"])
    else:
        values = [num(g) for g in (match.groups() or ()) if g is not None]
        values = [v for v in values if v is not None]
        if len(values) >= 2:
            current, total = values[0], values[1]
        elif len(values) == 1:
            percent = values[0]
    if percent is None and current is not None and total:
        percent = 100.0 * current / total
    if percent is None and current is None and match.groups():
        return None  # groups matched but none of them was a number
    if percent is not None:
        percent = max(0.0, min(100.0, percent))
    return {"percent": percent, "current": current, "total": total,
            "line": line, "at": time.time()}


class Tail(object):
    """One followed log: a bounded ring buffer plus its inferred progress.

    One follower thread per log, any number of browsers.
    """

    def __init__(self, key, path, pattern, lines):
        self.key = key
        self.path = path
        self.pattern = pattern
        self.procs = []
        self.state = "following"
        self.stopped = False
        self.proc = None
        self.lock = threading.Lock()
        self.buf = collections.deque(maxlen=lines)
        self.seq = 0
        self.partial = ""
        self.progress = None
        self.first = None
        self.rx = None
        self.rx_error = None
        if pattern:
            try:
                self.rx = re.compile(pattern)
            except re.error as err:
                # A bad regex costs you the bar, not the log.
                self.rx_error = "WEBUI_PROGRESS_PATTERN is not a valid regex: %s" % err

    # -- writing -------------------------------------------------------

    def add(self, line):
        with self.lock:
            self.seq += 1
            self.buf.append((self.seq, line))
            self._match(line)

    def _match(self, line):
        """Caller holds the lock. A non-matching or unparseable line leaves the
        previous value alone -- progress is sticky, it never falls back to
        'unknown' because line 5001 was a stack trace."""
        if self.rx is None:
            return
        hit = parse_progress(self.rx, line)
        if hit is None:
            return
        self.progress = hit
        if hit["percent"] is not None and self.first is None:
            self.first = (hit["at"], hit["percent"])

    def consume(self, text):
        text = self.partial + text.replace("\r\n", "\n")
        parts = re.split(r"[\r\n]", text)
        self.partial = parts.pop()
        for part in parts:
            self.add(sanitize(part))
        # tqdm-style writers emit \n only when the run ends, so the line in
        # flight is where their progress lives.
        if self.partial:
            with self.lock:
                self._match(sanitize(self.partial))

    def stop(self):
        """Evicted: drop the `tail -F` too, or a caller looping over unique
        paths leaves one running per log forever."""
        self.stopped = True
        if self.proc is not None:
            self.proc.kill()

    def follow(self):
        argv = log_command(self.path)
        self.add("-- following %s --" % self.path)
        while not self.stopped:
            try:
                proc = subprocess.Popen(argv, stdout=subprocess.PIPE,
                                        stderr=subprocess.STDOUT, bufsize=0)
            except OSError as err:
                self.add("[webui] cannot run %s: %s" % (argv[0], err))
                time.sleep(5)
                continue
            self.proc = proc
            for chunk in iter(lambda: proc.stdout.read(4096), b""):
                self.consume(chunk.decode("utf-8", "replace"))
            proc.stdout.close()
            rc = proc.wait()
            if self.stopped:
                return
            self.add("[webui] %s exited (rc=%s), retrying" % (argv[0], rc))
            time.sleep(2)

    # -- reading -------------------------------------------------------

    def summary(self):
        with self.lock:
            progress = dict(self.progress) if self.progress else None
            first = self.first
            out = {"key": self.key, "path": self.path, "pattern": self.pattern,
                   "state": self.state, "error": self.rx_error, "seq": self.seq,
                   "procs": [{"pid": pid, "cmd": cmd} for pid, cmd in self.procs]}
        if progress and progress["percent"] is not None and first:
            done, elapsed = progress["percent"] - first[1], progress["at"] - first[0]
            if done > 0 and elapsed > 0:
                progress["eta"] = (100.0 - progress["percent"]) * elapsed / done
        out["progress"] = progress
        return out

    def chunk(self, since):
        with self.lock:
            oldest = self.buf[0][0] if self.buf else self.seq + 1
            reset = since != 0 and since < oldest - 1
            if reset or since <= 0:
                lines = [text for _, text in self.buf]
            else:
                lines = [text for seq, text in self.buf if seq > since]
            return {"key": self.key, "next": self.seq, "reset": reset,
                    "lines": lines, "partial": sanitize(self.partial)}

    def raw(self):
        with self.lock:
            return "\n".join(text for _, text in self.buf) + "\n"


class Registry(object):
    """Every log declared in this container, followed at once."""

    def __init__(self, lines, limit=MAX_SOURCES):
        self.lines = lines
        self.limit = limit
        self.lock = threading.Lock()
        self.tails = collections.OrderedDict()
        self.default = None

    def supervise(self):
        while True:
            try:
                self.refresh(scan())
            except OSError:
                pass
            time.sleep(SCAN_INTERVAL)

    def refresh(self, cands):
        groups = collections.OrderedDict()
        for cand in sorted(cands, key=rank, reverse=True):
            groups.setdefault(source_key(cand.logs), []).append(cand)
        started = []
        with self.lock:
            for key, group in groups.items():
                tail = self.tails.get(key)
                if tail is None:
                    tail = Tail(key, group[0].logs, pattern_for(group[0], cands), self.lines)
                    self.tails[key] = tail
                    started.append(tail)
                tail.procs = [(c.pid, c.cmd) for c in group]
                tail.state = "following"
            for key, tail in self.tails.items():
                if key not in groups:
                    tail.procs = []
                    tail.state = "orphaned"
            self.default = default_key(cands, self.default)
            self._evict()
        for tail in started:
            threading.Thread(target=tail.follow, daemon=True).start()
        return started

    def _evict(self):
        """A caller looping over unique paths must not grow the heap forever;
        the oldest finished log goes first, and a live one is never dropped."""
        while len(self.tails) > self.limit:
            victim = next((k for k, t in self.tails.items()
                           if t.state == "orphaned" and k != self.default), None)
            if victim is None:
                victim = next((k for k in self.tails if k != self.default), None)
            if victim is None:
                return
            self.tails.pop(victim).stop()

    def view(self, key=None):
        with self.lock:
            order = sorted(self.tails.values(),
                           key=lambda t: (t.state == "following", t.procs and t.procs[0][0] or 0),
                           reverse=True)
            tail = self.tails.get(key) or self.tails.get(self.default)
            default = self.default
        return order, tail, default

    def state_dict(self, key, since):
        order, tail, default = self.view(key)
        return {"sources": [t.summary() for t in order], "default": default,
                "now": time.time(), "tail": None if tail is None else tail.chunk(since)}


PAGE = """<!doctype html>
<meta charset=utf-8><meta name=viewport content="width=device-width,initial-scale=1">
<meta name=color-scheme content="light dark"><title>log</title>
<style>
:root{--bg:#fff;--fg:#111;--dim:#666;--line:#ddd;--acc:#2563eb}
@media(prefers-color-scheme:dark){:root{--bg:#111417;--fg:#e6e6e6;--dim:#8b949e;--line:#2a2f35;--acc:#58a6ff}}
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--fg);font:14px/1.45 ui-sans-serif,system-ui,sans-serif;
 display:flex;flex-direction:column;height:100vh}
header{padding:.6rem .9rem;border-bottom:1px solid var(--line)}
.row{display:flex;align-items:center;gap:.6rem;flex-wrap:wrap}
select,input{font:inherit;padding:.25rem .4rem;background:var(--bg);color:var(--fg);
 border:1px solid var(--line);border-radius:4px;max-width:100%}
.dim{color:var(--dim);font-size:12px}
progress{flex:1;min-width:8rem;height:.8rem;accent-color:var(--acc)}
#log{flex:1;overflow:auto;margin:0;padding:.6rem .9rem;white-space:pre-wrap;word-break:break-word;
 font:12px/1.45 ui-monospace,SFMono-Regular,Menlo,monospace}
.err{color:#b91c1c;font-size:12px}
@media(prefers-color-scheme:dark){.err{color:#ff7b72}}
</style>
<header>
 <div class=row><select id=sel></select><span class=dim id=meta>connecting...</span></div>
 <div class=row id=bar hidden><progress id=pr max=100></progress><span class=dim id=pct></span></div>
 <div class=err id=err hidden></div>
 <div class=row id=auth hidden><span class=dim>token</span><input id=tok size=28></div>
 <div class=row><label class=dim><input type=checkbox id=follow checked> follow</label></div>
</header>
<pre id=log></pre>
<script>
var since=0,delay=1000,sel=null,tok=null;
function $(id){return document.getElementById(id)}
function cookie(){var m=/(?:^|; )webui_token=([^;]*)/.exec(document.cookie);return m?decodeURIComponent(m[1]):null}
function keep(t){tok=t;document.cookie='webui_token='+encodeURIComponent(t)+';path=/;max-age=31536000;samesite=lax'}
tok=new URLSearchParams(location.search).get('token')||cookie();
if(tok)keep(tok);
$('tok').onchange=function(e){keep(e.target.value.trim());restart()};
$('sel').onchange=function(e){sel=e.target.value;restart()};
function restart(){since=0;$('log').textContent='';poll()}
function hms(s){s=Math.round(s);var h=Math.floor(s/3600),m=Math.floor(s%3600/60);
 return h?h+'h'+m+'m':(m?m+'m':s+'s')}
function label(s){var p=s.progress&&s.progress.percent!=null?' '+Math.round(s.progress.percent)+'%':'';
 return s.path+p+(s.state==='orphaned'?' (ended)':'')}
function sources(d){
 var box=$('sel'),want=d.sources.map(function(s){return s.key+' '+label(s)}).join('|');
 if(box.dataset.sig!==want){box.dataset.sig=want;box.textContent='';
  d.sources.forEach(function(s){var o=document.createElement('option');o.value=s.key;
   o.textContent=label(s);box.appendChild(o)})}
 box.hidden=d.sources.length<2;
 if(sel)box.value=sel;
}
function render(d){
 sources(d);
 var t=d.tail;
 if(!t){$('meta').textContent='idle - no process has WEBUI_LOGS set. Start one with '+
   'WEBUI_LOGS=/root/job.log (see /etc/ai-guide.md)';$('bar').hidden=true;return}
 if(sel!==t.key){sel=t.key;$('sel').value=sel;since=0;$('log').textContent=''}
 var cur=d.sources.filter(function(s){return s.key===t.key})[0]||{};
 var log=$('log'),pinned=log.scrollTop+log.clientHeight>=log.scrollHeight-4;
 if(t.reset)log.textContent='';
 if(t.lines.length)log.appendChild(document.createTextNode(t.lines.join('\n')+'\n'));
 if($('follow').checked&&(pinned||t.reset))log.scrollTop=log.scrollHeight;
 since=t.next;
 $('meta').textContent=(cur.procs&&cur.procs.length?
   cur.procs.map(function(p){return 'pid '+p.pid+' '+p.cmd}).join(' | '):'no live process')+
   ' ['+cur.state+']';
 var e=$('err');e.hidden=!cur.error;e.textContent=cur.error||'';
 var p=cur.progress,bits=[];
 $('bar').hidden=!p&&!t.partial;
 if(p){var pr=$('pr');
  if(p.percent==null){pr.removeAttribute('value')}else{pr.value=p.percent;bits.push(p.percent.toFixed(1)+'%')}
  if(p.current!=null&&p.total!=null)bits.push(p.current+'/'+p.total);
  if(p.eta)bits.push('~'+hms(p.eta)+' left');
  if(d.now-p.at>60)bits.push('stale '+hms(d.now-p.at));
  document.title=(p.percent==null?'':Math.round(p.percent)+'% ')+t.key}
 if(t.partial)bits.push(t.partial);
 $('pct').textContent=bits.join(' - ');
}
function poll(){
 fetch('/api/tail?since='+since+(sel?'&source='+encodeURIComponent(sel):'')+
       (tok?'&token='+encodeURIComponent(tok):''))
  .then(function(r){if(r.status===401){$('auth').hidden=false;throw new Error('token')}
   return r.json()})
  .then(function(d){$('auth').hidden=true;delay=1000;render(d)})
  .catch(function(){delay=5000})
  .then(function(){setTimeout(poll,delay)})
}
poll();
</script>
"""


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    registry = None
    token = ""

    def log_message(self, fmt, *args):
        """A 1 Hz poll would otherwise push ~86k lines a day into journald,
        which docker-journal-forward sends straight to `vastai logs`."""

    def _send(self, code, body, ctype="text/plain; charset=utf-8"):
        blob = body.encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(blob)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(blob)

    def _authorized(self, query):
        given = ""
        if query.get("token"):
            given = query["token"][0]
        elif self.headers.get("Authorization", "").startswith("Bearer "):
            given = self.headers["Authorization"][7:]
        else:
            match = re.search(r"(?:^|; )webui_token=([^;]*)", self.headers.get("Cookie", ""))
            if match:
                given = match.group(1)
        return hmac.compare_digest(given, self.token)

    def do_GET(self):
        url = urlparse(self.path)
        query = parse_qs(url.query)
        if url.path == "/healthz":
            return self._send(200, "ok\n")
        if url.path == "/":
            return self._send(200, PAGE, "text/html; charset=utf-8")
        # Everything carrying log content needs the token: the port is mapped
        # to a public IP.  Sources are named by key, never by a path from the
        # request -- that would be an arbitrary-file-read gadget.
        if url.path in ("/api/tail", "/raw"):
            if not self._authorized(query):
                return self._send(401, "token required: append ?token=... "
                                       "(cat /run/vastai-webui/token on the box)\n")
            key = query.get("source", [None])[0]
            if url.path == "/raw":
                _, tail, _ = self.registry.view(key)
                return self._send(200, "" if tail is None else tail.raw())
            try:
                since = int(query.get("since", ["0"])[0])
            except ValueError:
                since = 0
            return self._send(200, json.dumps(self.registry.state_dict(key, since)),
                              "application/json")
        self._send(404, "not found\n")


def load_token(cfg):
    """WEBUI_TOKEN if the operator set one, else a stable generated one.

    Whichever it is, it lands in TOKEN_FILE: the login banner and every
    `curl` example read the token from there, so the file has to hold the
    token actually in force, not only the ones this process invented.
    """
    token = cfg.get("WEBUI_TOKEN")
    if not token:
        try:
            with open(TOKEN_FILE) as handle:
                token = handle.read().strip()
        except OSError:
            token = ""
    token = token or secrets.token_urlsafe(16)
    try:
        os.makedirs(os.path.dirname(TOKEN_FILE), exist_ok=True)
        fd = os.open(TOKEN_FILE, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "w") as handle:
            handle.write(token + "\n")
    except OSError as err:
        print("webui: cannot persist a token in %s (%s)" % (TOKEN_FILE, err))
    return token


def container_env():
    """PID 1 holds what vast passed with -e; a manual run wins over it."""
    cfg = {}
    try:
        cfg.update(read_env(1))
    except OSError:
        pass
    cfg.update(os.environ)
    return cfg


def selftest():
    def pct(pattern, line):
        hit = parse_progress(re.compile(pattern), line)
        return None if hit is None else hit["percent"]

    assert pct(r"(?P<percent>\d+(?:\.\d+)?)%", "loss 3 | 47.5% done") == 47.5
    assert pct(r"step (?P<current>\d+)/(?P<total>\d+)", "step 3/10") == 30.0
    assert pct(r"step (\d+)/(\d+)", "step 3/10") == 30.0
    assert pct(r"(\d+)%", "50%") == 50.0
    assert pct(r"(\d+)/(\d+)", "0/0") is None, "a zero total is not 0%"
    assert pct(r"step (\d+)/(\d+)", "loss=0.3") is None
    assert pct(r"(\d+)%", "250%") == 100.0, "clamped"
    assert pct(r"(?P<current>[\d,]+) of (?P<total>[\d,]+)", "1,500 of 3,000") == 50.0
    assert pct(r"epoch \d+", "epoch 7") is None, "no groups, no number"
    assert parse_progress(re.compile(r"epoch"), "epoch 7")["line"] == "epoch 7"

    assert log_command("/root/job.log") == ["tail", "-n", "+1", "-F", "/root/job.log"]
    assert log_command("./job.log")[0] == "tail"
    assert log_command("trainer.service") == \
        ["journalctl", "-n", "2000", "-f", "-u", "trainer.service"]

    one = Cand(1, 10, "/a.log", "x", "init")
    job = Cand(50, 20, "/b.log", None, "train")
    newer = Cand(70, 40, "/c.log", None, "train2")
    same = Cand(71, 31, "/b.log", None, "train-child")
    assert default_key([]) is None
    assert default_key([one]) == "/a.log"
    assert default_key([one, job]) == "/b.log", "a real job outranks PID 1"
    assert default_key([one, job, newer]) == "/c.log", "newest wins"
    assert default_key([], "/b.log") == "/b.log", "a finished run stays on screen"
    assert source_key("/root/../root/x.log") == "/root/x.log"
    assert pattern_for(job, [one, job]) == "x"
    assert pattern_for(job, [job]) is None

    assert sanitize("\x1b" + "[32mstep 7/10" + "\x1b" + "[0m") == "step 7/10"
    assert sanitize("a\x00b\x07") == "ab"
    assert parse_environ(b"WEBUI_LOGS='/a b'\0X=1")["WEBUI_LOGS"] == "/a b"

    reg = Registry(3, limit=2)
    reg.refresh([one, job, same])
    assert sorted(reg.tails) == ["/a.log", "/b.log"], "deduped on the file name"
    assert [p[0] for p in reg.tails["/b.log"].procs] == [71, 50], "both processes listed"
    assert reg.default == "/b.log"
    reg.refresh([one, job, same, newer])
    assert reg.default == "/c.log" and len(reg.tails) == 2, "evicted down to the limit"
    dropped = reg.tails["/a.log"]
    reg.refresh([one, job, same, newer])
    assert dropped.stopped and "/a.log" not in reg.tails, "an evicted tail is stopped"
    reg.refresh([])
    assert reg.tails["/c.log"].state == "orphaned"

    tail = Tail("/x", "/nonexistent-on-purpose", r"step (\d+)/(\d+)", 3)
    tail.consume("step 1/10\nstep 2/10\r\n")
    assert tail.progress["percent"] == 20.0
    tail.consume("\x1b" + "[32mstep 7/10" + "\x1b" + "[0m\r")
    assert tail.progress["percent"] == 70.0, "the line in flight counts"
    assert len(tail.buf) == 3, "ring buffer is bounded"
    assert "\x1b" not in tail.raw()
    assert tail.chunk(0)["next"] == tail.seq
    print("selftest ok")


def main():
    if "--selftest" in sys.argv:
        return selftest()
    cfg = container_env()
    registry = Registry(int(cfg.get("WEBUI_LINES", "2000")))
    Handler.registry = registry
    Handler.token = load_token(cfg)
    threading.Thread(target=registry.supervise, daemon=True).start()
    port = int(cfg.get("WEBUI_PORT", "1111"))
    server = ThreadingHTTPServer(("0.0.0.0", port), Handler)
    server.daemon_threads = True
    print("webui: http://0.0.0.0:%d/?token=%s" % (port, Handler.token), flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
