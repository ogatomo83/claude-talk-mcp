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
for line in open(path, encoding="utf-8"):
    try: e = json.loads(line)
    except ValueError: continue
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
    r["listen 全体"] = d(lr["ms"], lret["ms"])
    r["話し終え→文字"] = d(speech_end, comp["ms"]) if comp else None
    r["文字→返却"] = d(comp["ms"], lret["ms"]) if comp else None
    r["返却→speak"] = d(lret["ms"], sr["ms"]) if sr else None
    r["speak→音"] = d(sr["ms"], sa["ms"]) if (sr and sa) else None
    r["話し終え→声"] = d(speech_end, sa["ms"]) if (sa and speech_end) else None
    r["speak 全体"] = d(sr["ms"], sd["ms"]) if (sr and sd) else None
    r["chars"] = lret.get("chars", ""); r["src"] = src
    r["ok"] = lret.get("ok")
    rows.append(r)

if not rows:
    print("(往復なし)"); sys.exit(0)
cols = list(rows[0].keys())
print("| " + " | ".join(cols) + " |")
print("|" + "---|" * len(cols))
for r in rows:
    print("| " + " | ".join("" if r[c] is None else str(r[c]) for c in cols) + " |")
