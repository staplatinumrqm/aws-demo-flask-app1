import http from "k6/http";
import { check, sleep } from "k6";

// Load test that drives the CPU-bound endpoint to trigger ECS autoscaling.
// Run:  k6 run -e TARGET_URL=http://<your-alb-dns> loadtest/cpu-load.js
//
// Watch during the run:
//   - CloudWatch dashboard "flask-pipeline" → ECS CPU climbs past 60%
//   - ECS service task count rises from 1 toward 4 (scale-out), then back to 1

const BASE = __ENV.TARGET_URL;

export const options = {
  stages: [
    { duration: "2m", target: 40 }, // ramp up virtual users
    { duration: "6m", target: 40 }, // sustain load — autoscaling should kick in
    { duration: "2m", target: 0 }, // ramp down — watch scale-in afterward
  ],
  thresholds: {
    http_req_failed: ["rate<0.05"], // <5% errors (blue/green + scaling should hold)
    http_req_duration: ["p(95)<3000"],
  },
};

export default function () {
  // ~200ms of CPU work per request; with 40 VUs this saturates the small tasks.
  const res = http.get(`${BASE}/api/cpu?ms=200`);
  check(res, { "status is 200": (r) => r.status === 200 });
  sleep(0.5);
}
