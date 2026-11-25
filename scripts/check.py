#!/usr/bin/env python3
"""claude-talk (/voice) の入り具合を、音を出さずに確かめる。

    /usr/bin/python3 -I scripts/check.py [--home DIR] [--skills-dir DIR] [--serve-test]

確かめること (どれも音を出さない・マイクを開けない):
  1. Apple Silicon の macOS か
  2. speech.cpp (speech) が動くか、要るモデルが取得済みか
  3. 設定 (~/.claude-talk-mcp の mode / direct/settings.json など) と /voice skill があるか
  4. MCP サーバーが stdio で speak / listen を返すか (app モードで起動するので serve は起こさない)
  5. Claude Code に claude-talk が登録されているか (claude があれば)
  6. --serve-test: 別のポート (既定 18766 / 18768) で MCP サーバーを direct モードで起動し、
     MCP サーバー自身に speech serve (聞き取り・読み上げ) を起こさせる。読み上げの serve で WAV を作り
     (再生はしない)、聞き取りの serve で書き起こして戻ってくるかを見る。終わったら起こした serve を止める。
     動いている本番の serve (8766 / 8768) には触らない。

終了コード: 0 = 全部通った、1 = どれか失敗。
"""
import argparse
import json
import os
import platform
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request
import uuid

HOME = os.path.expanduser("~")
REQUIRED_MODELS = ["haas-ja-v1.0:f16", "silero-vad", "qwen3-tts-0.6b"]
OPTIONAL_MODELS = ["irodori-tts-mf:q5_k"]

failures = []


def ok(msg):
    print(f"  ok    {msg}")


def warn(msg):
    print(f"  warn  {msg}")


def ng(msg):
    print(f"  NG    {msg}")
    failures.append(msg)


def section(title):
    print(f"==> {title}")


def run(cmd, env=None, timeout=60):
    return subprocess.run(cmd, capture_output=True, text=True, env=env, timeout=timeout)


def speech_env():
    env = dict(os.environ)
    env["SPEECH_NO_UPDATE_CHECK"] = "1"
    return env


# ---------------------------------------------------------------- 1. platform
def check_platform():
    section("Mac")
    if platform.system() != "Darwin":
        ng(f"macOS ではありません ({platform.system()})")
        return
    if platform.machine() != "arm64":
        ng(f"Apple Silicon ではありません ({platform.machine()})。speech.cpp の macOS 版は arm64 だけ")
    else:
        ok("Apple Silicon (arm64)")
    ver = platform.mac_ver()[0]
    major = int(ver.split(".")[0]) if ver else 0
    if major < 13:
        ng(f"macOS {ver}: 13 以上が要る (MCPServer/Package.swift)")
    else:
        ok(f"macOS {ver}")


# ---------------------------------------------------------------- 2. speech.cpp
def check_speech(speech_bin, with_irodori):
    section("speech.cpp とモデル")
    if not os.access(speech_bin, os.X_OK):
        ng(f"{speech_bin} がありません (scripts/install.sh で入れる)")
        return
    r = run([speech_bin, "--version"], env=speech_env())
    if r.returncode != 0:
        ng(f"speech --version が失敗: {r.stderr.strip()}")
        return
    ok(r.stdout.strip())
    r = run([speech_bin, "models", "--json"], env=speech_env())
    if r.returncode != 0:
        ng(f"speech models --json が失敗: {r.stderr.strip()}")
        return
    catalog = json.loads(r.stdout)
    by_name = {m["name"]: m for m in catalog.get("models", [])}
    ok(f"モデルの置き場所: {catalog.get('directory')}")
    wanted = REQUIRED_MODELS + (OPTIONAL_MODELS if with_irodori else [])
    for spec in wanted:
        name, _, typ = spec.partition(":")
        m = by_name.get(name)
        if not m:
            ng(f"{spec}: この speech.cpp のカタログにありません")
            continue
        typ = typ or m.get("type")
        f = next((f for f in m.get("files", []) if f.get("type") == typ), None)
        if not f:
            ng(f"{spec}: 型 {typ} がありません")
        elif f.get("fetched"):
            ok(f"{name}:{typ} ({f['size'] / 1e9:.2f} GB) 取得済み")
        else:
            ng(f"{name}:{typ} が未取得 (speech pull {name}:{typ})")


# ---------------------------------------------------------------- 3. config / skill
def check_config(talk_home, skills_dir):
    section(f"設定 ({talk_home}) と skill ({skills_dir})")
    mode_file = os.path.join(talk_home, "mode")
    try:
        mode = open(mode_file, encoding="utf-8").read().strip()
        if mode == "direct":
            ok("mode = direct")
        else:
            warn(f"mode = {mode!r} (/voice の direct モードは 'direct')")
    except OSError:
        ng(f"{mode_file} がありません")
    settings = os.path.join(talk_home, "direct", "settings.json")
    try:
        json.load(open(settings, encoding="utf-8"))
        ok("direct/settings.json (JSON として読める)")
    except OSError:
        warn("direct/settings.json が無い (全部既定値で動く)")
    except ValueError as e:
        ng(f"direct/settings.json が JSON として壊れています: {e}")
    for name in ("keywords.txt", "readings.txt"):
        p = os.path.join(talk_home, "direct", name)
        (ok if os.path.isfile(p) else warn)(f"direct/{name}" + ("" if os.path.isfile(p) else " が無い (組み込みの既定だけで動く)"))
    skill = os.path.join(skills_dir, "voice", "SKILL.md")
    if os.path.isfile(skill):
        ok(f"skill: {skill}")
    else:
        ng(f"{skill} がありません")


# ---------------------------------------------------------------- 4. MCP stdio
class MCPClient:
    def __init__(self, cmd, env):
        self.p = subprocess.Popen(cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                  stderr=subprocess.DEVNULL, env=env, text=True, bufsize=1)
        self.next_id = 1

    def send(self, method, params=None, notify=False):
        msg = {"jsonrpc": "2.0", "method": method}
        if params is not None:
            msg["params"] = params
        if not notify:
            msg["id"] = self.next_id
            self.next_id += 1
        self.p.stdin.write(json.dumps(msg) + "\n")
        self.p.stdin.flush()
        if notify:
            return None
        want = msg["id"]
        while True:
            line = self.p.stdout.readline()
            if not line:
                raise RuntimeError("MCP サーバーが応答の前に終了しました")
            obj = json.loads(line)
            if obj.get("id") == want:
                return obj

    def close(self):
        try:
            self.p.stdin.close()
        except OSError:
            pass
        try:
            self.p.wait(timeout=5)
        except subprocess.TimeoutExpired:
            self.p.terminate()
            self.p.wait(timeout=5)


def mcp_handshake(mcp_bin, env):
    c = MCPClient([mcp_bin], env)
    try:
        init = c.send("initialize", {"protocolVersion": "2024-11-05", "capabilities": {},
                                     "clientInfo": {"name": "claude-talk-check", "version": "1"}})
        c.send("notifications/initialized", notify=True)
        tools = c.send("tools/list", {})
        return c, init, tools
    except Exception:
        c.close()
        raise


def check_mcp(mcp_bin, talk_home):
    section("MCP サーバー (stdio)")
    if not os.access(mcp_bin, os.X_OK):
        ng(f"{mcp_bin} がありません (swift build -c release)")
        return
    # app モードは起動時に何も起こさない。時間ログを本番に書かないよう、置き場所は一時ディレクトリにする。
    scratch = tempfile.mkdtemp(prefix="claude-talk-check-mcp-")
    env = dict(os.environ, CLAUDE_TALK_MODE="app", CLAUDE_TALK_HOME=scratch)
    try:
        c, init, tools = mcp_handshake(mcp_bin, env)
        c.close()
        shutil.rmtree(scratch, ignore_errors=True)
    except Exception as e:
        ng(f"MCP の handshake が失敗: {e}")
        return
    info = init.get("result", {}).get("serverInfo", {})
    names = [t["name"] for t in tools.get("result", {}).get("tools", [])]
    ok(f"serverInfo: {info.get('name')} {info.get('version')}")
    if {"speak", "listen"} <= set(names):
        ok(f"tools: {', '.join(names)}")
    else:
        ng(f"speak / listen がありません (tools: {names})")


# ---------------------------------------------------------------- 5. Claude Code 登録
def check_registration(mcp_bin, talk_home):
    section("Claude Code への登録")
    claude = shutil.which("claude")
    if not claude:
        warn("claude が PATH にありません (登録の確認を飛ばします)")
        return
    try:
        r = run([claude, "mcp", "get", "claude-talk"], timeout=60)
    except subprocess.TimeoutExpired:
        warn("claude mcp get が 60 秒で返りません")
        return
    out = r.stdout + r.stderr
    if r.returncode != 0 or "Command:" not in out:
        ng("claude-talk が登録されていません (scripts/install.sh か claude mcp add)")
        return
    cmd = next((l.split("Command:", 1)[1].strip() for l in out.splitlines() if "Command:" in l), "")
    if os.path.realpath(cmd) == os.path.realpath(mcp_bin):
        ok(f"claude-talk -> {cmd}")
    else:
        warn(f"claude-talk は別のバイナリを指しています: {cmd} (今回のビルド: {mcp_bin})")
    default_home = os.path.join(HOME, ".claude-talk-mcp")
    if os.path.realpath(talk_home) != os.path.realpath(default_home) and "CLAUDE_TALK_HOME" not in out:
        warn(f"設定の置き場所が既定と違うのに、登録に CLAUDE_TALK_HOME={talk_home} がありません")


# ---------------------------------------------------------------- 6. serve test
def http_json(url, timeout=3):
    with urllib.request.urlopen(url, timeout=timeout) as r:
        return json.loads(r.read() or b"{}")


def wait_health(port, deadline):
    while time.time() < deadline:
        try:
            with urllib.request.urlopen(f"http://127.0.0.1:{port}/health", timeout=1.5) as r:
                if r.status == 200:
                    return True
        except (urllib.error.URLError, OSError):
            pass
        time.sleep(0.5)
    return False


def port_in_use(port):
    import socket
    s = socket.socket()
    try:
        return s.connect_ex(("127.0.0.1", port)) == 0
    finally:
        s.close()


def listener_pids(port):
    r = run(["/usr/sbin/lsof", "-nP", "-t", f"-iTCP:{port}", "-sTCP:LISTEN"])
    return {int(x) for x in r.stdout.split()}


def multipart(fields, file_field, file_name, file_bytes):
    boundary = uuid.uuid4().hex
    parts = []
    for k, v in fields:
        parts.append(f"--{boundary}\r\nContent-Disposition: form-data; name=\"{k}\"\r\n\r\n{v}\r\n".encode())
    parts.append((f"--{boundary}\r\nContent-Disposition: form-data; name=\"{file_field}\"; "
                  f"filename=\"{file_name}\"\r\nContent-Type: audio/wav\r\n\r\n").encode() + file_bytes + b"\r\n")
    parts.append(f"--{boundary}--\r\n".encode())
    return b"".join(parts), f"multipart/form-data; boundary={boundary}"


def serve_test(mcp_bin, talk_home, speech_bin, asr_port, tts_port, timeout):
    section(f"serve の通し (別ポート {asr_port} / {tts_port}、音は出さない)")
    for p in (asr_port, tts_port):
        if port_in_use(p):
            ng(f"127.0.0.1:{p} が使用中です。--asr-port / --tts-port で空いているポートにしてください")
            return
    work = tempfile.mkdtemp(prefix="claude-talk-check-")
    direct = os.path.join(work, "direct")
    os.makedirs(direct)
    # 本番の設定を写し、ポートと speech の場所だけ変える (keywords・readings も効く状態で試す)
    src_settings = os.path.join(talk_home, "direct", "settings.json")
    try:
        settings = json.load(open(src_settings, encoding="utf-8"))
    except (OSError, ValueError):
        settings = {}
    settings.update({"port": asr_port, "ttsPort": tts_port, "speechBin": speech_bin, "tts": "qwen"})
    json.dump(settings, open(os.path.join(direct, "settings.json"), "w"))
    for name in ("keywords.txt", "readings.txt"):
        src = os.path.join(talk_home, "direct", name)
        if os.path.isfile(src):
            shutil.copy(src, direct)
    open(os.path.join(work, "mode"), "w").write("direct\n")

    env = dict(os.environ, CLAUDE_TALK_MODE="direct", CLAUDE_TALK_HOME=work)
    client = None
    started = time.time()
    try:
        # MCP サーバーを direct で起こす → 起動時の prewarm が 2 つの serve を立てる (本番と同じ経路)
        client, _, _ = mcp_handshake(mcp_bin, env)
        deadline = time.time() + timeout
        asr_up = wait_health(asr_port, deadline)
        tts_up = wait_health(tts_port, deadline)
        if not asr_up:
            ng(f"聞き取りの serve が {timeout} 秒で立ちません ({direct}/serve.log)")
        if not tts_up:
            ng(f"読み上げの serve が {timeout} 秒で立ちません ({direct}/tts-serve-qwen.log)")
        if not (asr_up and tts_up):
            return
        ok(f"MCP サーバーが 2 つの serve を起動 ({time.time() - started:.1f} 秒)")
        ids = [m.get("id") for m in http_json(f"http://127.0.0.1:{asr_port}/v1/models").get("data", [])]
        if any("silero" in (i or "").lower() for i in ids):
            ok(f"聞き取りの serve: {', '.join(ids)}")
        else:
            ng(f"聞き取りの serve に VAD がありません: {ids}")

        sentence = "今日は良い天気ですね。"
        body = json.dumps({"input": sentence, "voice": settings.get("ttsVoiceName", "serena"),
                           "response_format": "wav"}).encode()
        req = urllib.request.Request(f"http://127.0.0.1:{tts_port}/v1/audio/speech", data=body,
                                     headers={"Content-Type": "application/json"})
        t0 = time.time()
        with urllib.request.urlopen(req, timeout=120) as r:
            wav = r.read()
        wav_path = os.path.join(work, "check.wav")
        open(wav_path, "wb").write(wav)
        if len(wav) < 1000:
            ng(f"読み上げの WAV が小さすぎます ({len(wav)} bytes)")
            return
        ok(f"読み上げ: 「{sentence}」→ WAV {len(wav) / 1024:.0f} KB ({time.time() - t0:.1f} 秒、再生はしない)")

        data, ctype = multipart([("language", "ja"), ("response_format", "json")], "file", "check.wav", wav)
        req = urllib.request.Request(f"http://127.0.0.1:{asr_port}/v1/audio/transcriptions", data=data,
                                     headers={"Content-Type": ctype})
        t0 = time.time()
        with urllib.request.urlopen(req, timeout=120) as r:
            text = json.loads(r.read()).get("text", "")
        norm = lambda s: "".join(ch for ch in s if ch not in "。、,. 　")
        if norm(text) and (norm(text) in norm(sentence) or norm(sentence) in norm(text) or "天気" in text):
            ok(f"聞き取り: 「{text}」 ({time.time() - t0:.1f} 秒)")
        else:
            ng(f"聞き取りの結果が合いません: 「{text}」 (期待: 「{sentence}」)")
    except Exception as e:
        ng(f"serve の通しで失敗: {e}")
    finally:
        if client:
            client.close()
        # 起こした serve を止める。pid ファイルの pid が、そのテスト用ポートで待ち受けている時だけ。
        for pidfile, port in (("serve.pid", asr_port), ("tts-serve-qwen.pid", tts_port)):
            path = os.path.join(direct, pidfile)
            try:
                pid = int(open(path).read().strip())
            except (OSError, ValueError):
                continue
            if pid in listener_pids(port):
                os.kill(pid, signal.SIGTERM)
                for _ in range(20):
                    if pid not in listener_pids(port):
                        break
                    time.sleep(0.25)
                ok(f"テスト用の serve (pid {pid}, :{port}) を止めました")
        print(f"  (ログ: {work})")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    repo = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    ap.add_argument("--home", default=os.environ.get("CLAUDE_TALK_HOME") or os.path.join(HOME, ".claude-talk-mcp"),
                    help="設定の置き場所 (既定 ~/.claude-talk-mcp)")
    ap.add_argument("--skills-dir", default=os.path.join(HOME, ".claude", "skills"))
    ap.add_argument("--speech-bin", default=os.path.join(HOME, ".local", "bin", "speech"))
    ap.add_argument("--mcp-bin", default=None, help="既定: swift build -c release --show-bin-path の claude-talk-mcp-server")
    ap.add_argument("--with-irodori", action="store_true", help="Irodori-TTS のモデルも確かめる")
    ap.add_argument("--no-claude", action="store_true", help="Claude Code への登録を確かめない")
    ap.add_argument("--serve-test", action="store_true", help="別ポートで serve を起こして TTS→ASR を通す (数十秒・約 3 GB のメモリ)")
    ap.add_argument("--asr-port", type=int, default=18766)
    ap.add_argument("--tts-port", type=int, default=18768)
    ap.add_argument("--serve-timeout", type=int, default=180)
    a = ap.parse_args()

    mcp_bin = a.mcp_bin
    if not mcp_bin:
        r = run(["swift", "build", "-c", "release", "--show-bin-path", "--package-path", os.path.join(repo, "MCPServer")])
        mcp_bin = os.path.join(r.stdout.strip(), "claude-talk-mcp-server")

    check_platform()
    check_speech(a.speech_bin, a.with_irodori)
    check_config(a.home, a.skills_dir)
    check_mcp(mcp_bin, a.home)
    if not a.no_claude:
        check_registration(mcp_bin, a.home)
    if a.serve_test:
        if failures:
            warn("前の確認に失敗があるので serve の通しは飛ばします")
        else:
            serve_test(mcp_bin, a.home, a.speech_bin, a.asr_port, a.tts_port, a.serve_timeout)

    print()
    if failures:
        print(f"失敗 {len(failures)} 件:")
        for f in failures:
            print(f"  - {f}")
        sys.exit(1)
    print("全部通りました。マイクの許可だけは音を出さずに確かめられないので、初回の /voice で許可してください。")


if __name__ == "__main__":
    main()
