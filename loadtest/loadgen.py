"""Dependency-free load generator (alternative to k6 when it's not installed).

Spins N threads hammering the CPU-bound endpoint to drive ECS autoscaling.

  python loadtest/loadgen.py --url http://<alb> --threads 40 --ms 250 --duration 480
"""
import argparse
import threading
import time
import urllib.request

counters = {"ok": 0, "err": 0}


def worker(url, stop_at):
    while time.time() < stop_at:
        try:
            with urllib.request.urlopen(url, timeout=30) as r:
                r.read()
            counters["ok"] += 1
        except Exception:
            counters["err"] += 1


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--url", required=True)
    p.add_argument("--threads", type=int, default=40)
    p.add_argument("--ms", type=int, default=250)
    p.add_argument("--duration", type=int, default=480)
    a = p.parse_args()

    url = f"{a.url}/api/cpu?ms={a.ms}"
    stop_at = time.time() + a.duration
    for _ in range(a.threads):
        threading.Thread(target=worker, args=(url, stop_at), daemon=True).start()

    while time.time() < stop_at:
        time.sleep(15)
        print(f"[{time.strftime('%H:%M:%S')}] ok={counters['ok']} err={counters['err']}", flush=True)
    print(f"DONE ok={counters['ok']} err={counters['err']}", flush=True)


if __name__ == "__main__":
    main()
