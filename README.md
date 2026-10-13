# AI Service Benchmark

This playbook puts load on the AI Service pods (KServe InferenceServices) and
records how fast they answer and how much CPU and memory they use.
It never changes anything on the cluster, and it does not suggest sizes. It
only measures and writes the results, so the engineering team can decide.

---

## What you need

- `oc`, logged in to the cluster (`oc login ...`)
- `ansible-core` 2.15 or newer, plus `ansible-galaxy collection install kubernetes.core`
- Apache JMeter 5.6.3 or newer on your `PATH`
- For `fieldextractor` and `smartcleanse` only: `python3` with `boto3` installed
  (the test uses it to check S3 for the result)

---

## How to run it

```bash
export AISERVICE_TENANT_ID=dev
export AISERVICE_TEST_SIMILARITY=true
ansible-playbook playbooks/benchmark.yml
```

The reports are written to `results/`:

- `BENCHMARK_RESULTS.md`: the pod sizes at test time, then the latency, error
  rate, peak CPU and peak memory for each capability
- `benchmark_results.json`: the same numbers as JSON

Each run overwrites these two files, so copy them first if you want to keep an
older one. Every run also gets its own folder with the full JMeter report (see
below).

### Settings (environment variables)

| Variable | Default | What it does |
| :--- | :--- | :--- |
| `AISERVICE_NAMESPACE` | empty | Test this exact namespace |
| `AISERVICE_TENANT_ID` | empty | Only look in namespaces ending in this tenant name |
| `AISERVICE_INSTANCE_ID` | empty | Only look in namespaces for this instance |
| `AISERVICE_TEST_<NAME>` | see below | `true` or `false` per capability |
| `AISERVICE_CONCURRENCY` | `10` | How many users send requests at the same time |
| `AISERVICE_DURATION` | `180` | How long the load runs, in seconds |
| `AISERVICE_RAMP_UP` | `5` | Seconds to bring all users up to full |
| `AISERVICE_WORKLOAD_TYPE` | `single` | `single` (1 record) or `batch_50` (50 records) |
| `AISERVICE_BENCHMARK_MODE` | `capability` | `capability` talks to the pod directly, `e2e` goes through the gateway |

Capability names for `AISERVICE_TEST_<NAME>`: `SIMILARITY` (on by default),
`FMEA`, `MCC`, `PCC`, `FIELDEXTRACTOR`, `SMARTCLEANSE`, `DOCSEARCH`, `NL2OSLC`,
`INSIGHTS`, `ALMWATSONX` (all off by default).

A short run gives shaky numbers. Use a few minutes at least for numbers you
plan to rely on.

---

## What gets measured

While JMeter runs, a loop in `run_benchmark.sh` runs `oc adm top pod` about
every 5 seconds and writes one line per sample to `cpu_memory_over_time.log`:

```
14:09:09 my-pod-predictor-abc123   101m   1805Mi
```

When the run ends, the playbook goes through that log and keeps the **highest**
CPU value and the **highest** memory value. These are the "peaks". The code is:

```bash
awk 'NF>=4 { gsub(/m/,"",$3); gsub(/Mi/,"",$4);
             if ($3+0 > max_cpu) max_cpu=$3+0;
             if ($4+0 > max_mem) max_mem=$4+0; }
     END { printf "%d %d", max_cpu+0, max_mem+0 }' cpu_memory_over_time.log
```

Things to keep in mind:

- The peak is one sample, not an average. CPU in particular jumps around, so
  one high sample sets the number.
- Samples are 5 seconds apart, so a spike shorter than that can be missed.
- If the log is empty, the peak shows as 0. That means the sampler did not
  get any data, not that the pod used nothing.

Latency comes from JMeter's own report (`html_report/statistics.json`). The
playbook keeps the **P95** (95 out of 100 requests were faster than this), the
mean, requests per second, the request count and the error rate.

---

## What is in the report

For each capability the report shows:

| Value | Where it comes from |
| :--- | :--- |
| CPU and memory request / limit | The pod's current settings, read from the InferenceService before the test |
| Workers | The `--workers` value on the pod (`n/a` if the pod has no such flag) |
| Users, duration | The settings you ran with |
| Requests, errors | JMeter's count of requests sent and how many failed |
| P95, mean latency, throughput | JMeter's own report (`html_report/statistics.json`) |
| Peak CPU, peak memory | The highest `oc adm top` sample (see above) |

The playbook does not turn these into new sizes. Look at peak usage next to the
current request and limit and decide from there.

Check the **Errors** column first. If most requests failed (for example the pod
answered 429 or 500), the latency and peak numbers are not meaningful.

---

## Workers

`workers` is the `--workers` flag on the model server. It is the number of
copies of the server running inside one pod, and each copy handles one request
at a time. More workers means more requests at once, and also more memory,
because every worker loads its own copy of the model.

The benchmark reads the current value from each pod and shows it in the report.
Peak memory only applies to that worker count. A pod with 1 worker and a pod
with 10 workers use very different amounts of memory.

It also matters for the test itself. If there are more users than workers, extra
requests wait in line and the latency you measure is mostly waiting, not the
pod's real speed. Where you can, keep users and workers about equal.

---

## The scripts and the test plan

### `roles/aiservice_benchmark/files/run_benchmark.sh`

This runs one test against one pod. The playbook calls it with eight
arguments, in this order: users, duration in seconds, model id, namespace,
workload type, mode, gateway host, capability. In order, it:

1. Checks you are logged in to `oc`.
2. Finds the pod for that model.
3. Saves the pod's idle usage (`initial_resources.txt`).
4. Opens a tunnel from your machine to the pod with `oc port-forward`
   (or, in `e2e` mode, uses the gateway address).
5. Starts the usage logger described above.
6. Runs JMeter without a window and makes an HTML report.
7. Stops the logger and the tunnel.

Everything lands in `roles/aiservice_benchmark/results/<model>_<users>users_<type>_<time>/`.
Open `html_report/index.html` there to see the graphs.

It picks its request body from `files/payloads/<capability>.json`, or
`single.json` if there is no file for that capability.

### `roles/aiservice_benchmark/files/jmeter_similarity_test.jmx`

This is the JMeter test plan. Despite the name, it is used for every
capability. It reads its settings from the command line, so the same file
works for all of them.

- A group of users (`USERS`) starts over `RAMP_UP` seconds and keeps sending
  requests until `DURATION` seconds are up.
- After each request a user waits a random short time (`THINK_TIME` plus up to
  `RANDOM_DELAY`) so the requests don't all land at the same instant.
- Each request is a POST to the model's `:predict` address with the bearer
  token and the JSON body from the payload file.
- When the time is up, JMeter stops sending, but waits for requests that are
  still running. The run can end well after the duration you set.

**Two kinds of capability.** Most return the answer straight away. `fieldextractor`
and `smartcleanse` are queue-based: the first call only returns a job id, and
the real result shows up later in S3 (MinIO).

- The plan checks a flag, `IS_ASYNC`. For `fieldextractor` and `smartcleanse`
  the script sets it to `true`.
- In that case the plan sends the job, then checks S3 every `ASYNC_POLL_INTERVAL_MS`
  (default 5000) until the result file exists or `ASYNC_TIMEOUT_MS` (default
  300000, 5 minutes) passes. The time recorded is the whole wait, from sending
  to the result appearing.
- The S3 check runs `python3` with `boto3`, so that must be installed.
- To reach S3 from your machine, the script opens a second `oc port-forward`
  to the MinIO service.

### Folder layout

```
playbooks/
  benchmark.yml          the playbook
vars/
  main.yml               settings shared across the playbook
roles/
  aiservice_benchmark/
    defaults/main.yml    default settings for the role
    tasks/               find the namespaces, find the pods, run, write the report
    files/
      run_benchmark.sh
      jmeter_similarity_test.jmx
      payloads/          one request body per capability
    results/             one folder per run
results/                 BENCHMARK_RESULTS.md and benchmark_results.json
```
