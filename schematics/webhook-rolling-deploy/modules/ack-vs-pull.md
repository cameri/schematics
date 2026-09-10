# Module: ack vs pull

The single most load-bearing decision in this pipeline: the HTTP response
to GitHub and the Docker image pull are performed by different processes,
connected by an in-memory queue. This module records why, with the
timings, so nobody "simplifies" it back into the failure mode.

## The failure that forced the design

First production attempt: the receiver's `fan_out` broker sent each
message to `sync_response` (ack GitHub) AND to a direct `http_client`
output POSTing `/images/create`. A fan_out broker acknowledges only when
EVERY child output finishes. A docker pull streams for 30s+; the http_server
input's sync-response window is ~5s. Result: GitHub received 408s on every
real push, and retried, compounding the pulls.

## The contract

| Side | Obligation |
|------|------------|
| Receiver (webhook-connect) | Validate (path token, event, ref, dedup), then RPUSH the queue and ack immediately. Never touch the Docker API. |
| Queue (redis, no persistence) | Hold pull requests between the two sides. Lost entries are acceptable: the next push re-pulls. |
| Worker (puller) | BLPOP the queue, POST the pull with a 10m timeout, 3 retries at 1m (max backoff 5m), nack re-queued (`auto_replay_nacks`). |

## Why the timings are what they are

- **5s ack budget**: GitHub's webhook timeout is ~10s; the ack must land
  with margin, so validation and enqueue are the only receiver work.
- **10m pull timeout**: registry manifest checks alone can exceed 5s;
  large layers stream for minutes. The worker's pull is allowed to be
  slow because nobody is waiting on it.
- **1m retry spacing, 5m cap**: registry hiccups resolve in minutes;
  tighter retries hammer the registry, looser ones stall deploys.
- **No queue persistence**: `--save "" --appendonly no`. A restart loses
  queued pulls; since any push re-pulls the same image, the cost of a
  lost entry is zero and the cost of replaying a stale entry after an
  outage is a wrong-version pull.

## Property to preserve in any reimplementation

Ack latency must be independent of pull latency, forever. If a future
change makes the HTTP response wait on anything downstream of the queue
(a pull, a registry probe, a digest check), the design is broken, whatever
the tests say.
