#!/usr/bin/env python3
"""
zmq_client.py — blockcell MT4 DataService EA 的命令行客户端

用法:
    python zmq_client.py <command>
    python zmq_client.py <command> --endpoint tcp://localhost:5556
    python zmq_client.py <command> --timeout 5000

示例:
    python zmq_client.py PING
    python zmq_client.py "GET_ACCOUNT_INFO"
    python zmq_client.py "GET_INDICATOR:RSI,EURUSD,240,14"
    python zmq_client.py "GET_INDICATOR:MACD,EURUSD,240,12,26,9"
    python zmq_client.py "GET_INDICATOR:BB,EURUSD,240,20,2.0"
    python zmq_client.py "GET_INDICATOR:ATR,EURUSD,240,14"
    python zmq_client.py "GET_INDICATOR:EMA,EURUSD,240,200"
    python zmq_client.py "GET_HISTORICAL_DATA:EURUSD,240,100"
    python zmq_client.py "GET_SYMBOL_INFO:EURUSD"
    python zmq_client.py "IS_MARKET_OPEN"
    python zmq_client.py "GET_POSITIONS"

退出码:
    0  成功（含 EA 返回的业务错误，如 {"error": "..."}）
    1  连接超时或网络错误
    2  参数错误
"""

import sys
import json
import argparse


def query(command: str, endpoint: str = "tcp://localhost:5556", timeout_ms: int = 3000) -> dict:
    """向 DataService_EA 发送一条请求，返回解析后的 JSON dict。"""
    try:
        import zmq
    except ImportError:
        return {"error": "pyzmq not installed — run: pip install pyzmq"}

    ctx = zmq.Context()
    sock = ctx.socket(zmq.REQ)
    sock.setsockopt(zmq.RCVTIMEO, timeout_ms)
    sock.setsockopt(zmq.SNDTIMEO, timeout_ms)
    sock.setsockopt(zmq.LINGER, 0)
    sock.connect(endpoint)

    try:
        sock.send_string(command)
        raw = sock.recv_string()
        # PING 返回纯文本 "PONG"，不是 JSON
        if raw == "PONG":
            return {"pong": True}
        return json.loads(raw)
    except zmq.Again:
        return {"error": f"timeout after {timeout_ms}ms — is DataService_EA running?"}
    except json.JSONDecodeError as e:
        return {"error": f"invalid JSON from EA: {e}", "raw": raw}
    finally:
        sock.close()
        ctx.term()


def main():
    parser = argparse.ArgumentParser(
        description="blockcell MT4 DataService EA client",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__,
    )
    parser.add_argument("command", nargs="?", default="PING",
                        help="命令字符串，例如 'GET_INDICATOR:RSI,EURUSD,240,14'")
    parser.add_argument("--endpoint", default="tcp://localhost:5556",
                        help="ZMQ endpoint（默认 tcp://localhost:5556）")
    parser.add_argument("--timeout", type=int, default=3000,
                        help="超时毫秒数（默认 3000）")
    parser.add_argument("--pretty", action="store_true",
                        help="格式化输出 JSON")

    args = parser.parse_args()

    result = query(args.command, endpoint=args.endpoint, timeout_ms=args.timeout)

    if args.pretty:
        print(json.dumps(result, ensure_ascii=False, indent=2))
    else:
        print(json.dumps(result, ensure_ascii=False))

    # 如果 EA 返回了 error 字段，以非零退出码通知调用方
    if "error" in result:
        sys.exit(1)


if __name__ == "__main__":
    main()
