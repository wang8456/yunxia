#!/bin/sh
# NAS 上的听译中枢看门狗（cron 每 5 分钟跑一次）
# 干三件事：① 中枢没响应就重启 ② 日志超过 5MB 滚动 ③ 记一行流水
DIR=/mnt/data/home/subs-hub
LOG=$DIR/watchdog.log

health=$(curl -s --max-time 6 http://127.0.0.1:5092/health 2>/dev/null)
case "$health" in
    *'"ok": true'*)
        ;;
    *)
        echo "[$(date '+%m-%d %H:%M')] 中枢没响应，重启" >> "$LOG"
        /etc/init.d/subs-hub restart >/dev/null 2>&1
        sleep 2
        curl -s --max-time 6 http://127.0.0.1:5092/health >/dev/null 2>&1 \
            && echo "[$(date '+%m-%d %H:%M')] 重启成功" >> "$LOG" \
            || echo "[$(date '+%m-%d %H:%M')] 重启后仍不通" >> "$LOG"
        ;;
esac

# 日志滚动：超过 5MB 只留最后 1MB
for f in "$DIR/hub.log" "$LOG"; do
    [ -f "$f" ] || continue
    sz=$(wc -c < "$f" 2>/dev/null || echo 0)
    if [ "${sz:-0}" -gt 5242880 ]; then
        tail -c 1048576 "$f" > "$f.tmp" && mv "$f.tmp" "$f"
    fi
done
