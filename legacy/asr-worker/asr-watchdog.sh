#!/bin/bash
# 电脑侧的转写工看门狗（systemd timer 每 5 分钟跑一次）
# ① 有任务卡在 asr 状态、10 分钟没有新段落 → 重启 worker（systemd 会拉起来并重新领活）
# ② 日志超过 10MB 滚动一次，只留最后 2MB
LOG=/home/administrator/.hermes/cache/asr-watchdog.log
WORKER_LOG=/home/administrator/.hermes/cache/asr-worker.log

H=$(curl -s --max-time 6 http://192.168.1.10:5092/health 2>/dev/null)
if [ -z "$H" ]; then
    echo "[$(date '+%m-%d %H:%M')] 中枢连不上（NAS 可能重启了），跳过这一轮" >> "$LOG"
else
    STUCK=$(printf '%s' "$H" | python3 -c "import json,sys;print(json.load(sys.stdin).get('stuck',0))" 2>/dev/null || echo 0)
    if [ "${STUCK:-0}" -gt 0 ]; then
        echo "[$(date '+%m-%d %H:%M')] 转写卡死 stuck=$STUCK，重启转写工" >> "$LOG"
        systemctl --user restart asr-worker
    fi
fi

sz=$(stat -c%s "$WORKER_LOG" 2>/dev/null || echo 0)
if [ "${sz:-0}" -gt 10485760 ]; then
    tail -c 2097152 "$WORKER_LOG" > "$WORKER_LOG.tmp" && mv "$WORKER_LOG.tmp" "$WORKER_LOG"
    echo "[$(date '+%m-%d %H:%M')] 转写日志已滚动" >> "$LOG"
fi
