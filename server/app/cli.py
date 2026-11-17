"""命令行小工具：生成口令哈希、签发一个设备令牌（调试用）。

用法：

    python -m app.cli hash 你的口令
    python -m app.cli token 调试设备
"""

from __future__ import annotations

import sys

from .auth import hash_password, make_token


def main(argv: list[str]) -> int:
    if len(argv) < 2 or argv[1] in ("-h", "--help"):
        print(__doc__)
        return 0
    cmd = argv[1]
    if cmd == "hash":
        if len(argv) < 3:
            print("用法：python -m app.cli hash <口令>")
            return 2
        print(hash_password(argv[2]))
        print("把它整行填进 config.json 的 auth.password（注意保留 $ 分隔符）")
        return 0
    if cmd == "token":
        device = argv[2] if len(argv) > 2 else "debug"
        token, exp = make_token(device)
        print(token)
        print(f"# device={device} expires_at={exp}", file=sys.stderr)
        return 0
    print(f"未知命令：{cmd}")
    return 2


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
