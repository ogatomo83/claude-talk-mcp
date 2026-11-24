#!/usr/bin/env python3
"""~/.claude-talk-mcp/logs/timing.jsonl から 1 往復ごとの時間の表 (Markdown) を作る。

usage: timing-report.py [timing.jsonl] [--since 2026-11-24T12:00] [--pid N]

列 (ms):
  listen 全体      listen を受けてから返すまで (話している時間を含む)
  話し終え→文字    本当に話し終えた時刻 → 書き起こし (direct のみ。WAV テストは test.wav_play の値、
                   マイクは speech_stopped の audio_end_ms から prefix_padding_ms を引いた推定)
  文字→返却        書き起こし → MCP の返却
  返却→speak       listen の返却 → 次の speak を受けるまで (Claude が返事を作る時間)
  speak→音         speak を受けてから音が出始めるまで (direct のみ)
  話し終え→声      話し終え → Claude の声が出始めるまで (direct のみ。上の合計)
  speak 全体       speak を受けてから読み終わるまで

claude-talk-voice の行 (mode=voice) は別の表に出す (話し終え→文字 / 送信 / 最初の文 / 声、送信→最初の文字)。
"""
import json, sys, os
from collections import defaultdict, OrderedDict

args = sys.argv[1:]
path = os.path.expanduser("~/.claude-talk-mcp/logs/timing.jsonl")
since = None; pid = None; padding = 300
i = 0
while i < len(args):
    a = args[i]
    if a == "--since": since = args[i + 1]; i += 2; continue
    if a == "--pid": pid = int(args[i + 1]); i += 2; continue
    if a == "--padding": padding = int(args[i + 1]); i += 2; continue
    path = a; i += 1

turns = OrderedDict()
voice = []
for line in open(path, encoding="utf-8"):
    try: e = json.loads(line)
    except ValueError: continue
    # 書いた時刻: at_ms (2026-11-25 以降)。古い行は ms が書いた時刻だった。
    if "at_ms" not in e and "ms" in e: e["at_ms"] = e["ms"]
    if e.get("mode") == "voice":
        if (not since or e.get("t", "") >= since) and (not pid or e.get("pid") == pid): voice.append(e)
        continue
    if since and e.get("t", "") < since: continue
    if pid and e.get("pid") != pid: continue
    key = (e["pid"], e.get("turn", 0))
    turns.setdefault(key, []).append(e)

def first(evs, name):
    for e in evs:
        if e["ev"] == name: return e
    return None

rows = []
for (p, t), evs in turns.items():
    lr, lret = first(evs, "listen.recv"), first(evs, "listen.return")
    if not lr or not lret: continue
    comp = first(evs, "asr.completed"); stop = first(evs, "asr.speech_stopped"); wav = first(evs, "test.wav_play")
    sr, sa, sd = first(evs, "speak.recv"), first(evs, "speak.audio_start"), first(evs, "speak.done")
    mode = lr["mode"]
    speech_end = None; src = ""
    if wav and wav.get("speech_end_at"): speech_end, src = wav["speech_end_at"], "wav"
    elif stop and stop.get("speech_end_at"): speech_end, src = stop["speech_end_at"] - padding, "推定"
    def d(a, b): return (b - a) if (a is not None and b is not None) else None
    r = OrderedDict()
    r["turn"] = f"{p}:{t}"; r["mode"] = mode
    A = lambda e: e["at_ms"]
    r["listen 全体"] = d(A(lr), A(lret))
    r["話し終え→文字"] = d(speech_end, A(comp)) if comp else None
    r["文字→返却"] = d(A(comp), A(lret)) if comp else None
    r["返却→speak"] = d(A(lret), A(sr)) if sr else None
    r["speak→音"] = d(A(sr), A(sa)) if (sr and sa) else None
    r["話し終え→声"] = d(speech_end, A(sa)) if (sa and speech_end) else None
    r["speak 全体"] = d(A(sr), A(sd)) if (sr and sd) else None
    r["chars"] = lret.get("chars", ""); r["src"] = src
    r["ok"] = lret.get("ok")
    rows.append(r)

def table(rows):
    cols = list(rows[0].keys())
    print("| " + " | ".join(cols) + " |")
    print("|" + "---|" * len(cols))
    for r in rows:
        print("| " + " | ".join("" if r[c] is None else str(r[c]) for c in cols) + " |")

# claude-talk-voice (mode=voice): 1 往復 = voice.turn の番号。各イベントの after_speech_end_ms を並べる。
vrows = []
vturns = OrderedDict()
for e in voice:
    if e.get("turn"): vturns.setdefault((e["pid"], e["turn"]), []).append(e)
for (p, t), evs in vturns.items():
    sent = first(evs, "voice.sent")
    if not sent: continue
    def a(name, key="after_speech_end_ms"):
        e = first(evs, name); return e.get(key) if e else None
    r = OrderedDict()
    r["turn"] = f"{p}:{t}"
    r["話し終え→文字"] = a("voice.asr_completed")
    r["話し終え→送信"] = sent.get("after_speech_end_ms")
    r["送信→最初の文字"] = a("claude.first_delta", "after_sent_ms")
    r["話し終え→最初の文"] = a("voice.first_sentence")
    r["話し終え→声"] = a("tts.first_audio")
    r["割り込み"] = "あり" if first(evs, "voice.barge_in") else ""
    res = first(evs, "claude.result")
    r["claude api ms"] = res.get("api_ms") if res else None
    r["src"] = sent.get("speech_end_src", "")
    vrows.append(r)

if not rows and not vrows:
    print("(往復なし)"); sys.exit(0)
if rows: table(rows)
if vrows:
    if rows: print()
    print("claude-talk-voice (ms)")
    table(vrows)
