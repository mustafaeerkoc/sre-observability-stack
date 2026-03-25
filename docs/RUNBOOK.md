# Runbook

Operational guide for alerts defined in `prometheus/alerts.yml`.  
Each section covers: what the alert means, likely causes, investigation steps, and resolution.

---

## Table of Contents

- [HighCPUUsage](#highcpuusage)
- [HighMemoryUsage](#highmemoryusage)
- [HighDiskUsage](#highdiskusage)
- [InstanceDown](#instancedown)
- [EndpointDown](#endpointdown)
- [SlowResponseTime](#slowresponsetime)

---

## HighCPUUsage

**Severity:** warning  
**Condition:** CPU usage > 80% for more than 2 minutes  
**Alert expression:**
```
100 - (avg by(instance) (rate(node_cpu_seconds_total{mode="idle"}[5m])) * 100) > 80
```

### What it means
The host has been under sustained CPU pressure. Short spikes are normal; this alert fires only after 2 continuous minutes above 80%, indicating a real workload issue rather than a transient burst.

### Likely causes
- A container running a CPU-intensive workload (batch job, build process, infinite loop)
- A runaway process or memory leak causing excessive GC or swap activity
- Legitimate traffic spike requiring scaling

### Investigation steps

**1. Identify the top CPU consumers:**
```bash
docker stats --no-stream --format "table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}"
```

**2. Check cAdvisor metrics in Grafana:**  
Open the **Container CPU Usage %** panel → identify which container's series is elevated.

**3. Query Prometheus directly:**
```
sum(rate(container_cpu_usage_seconds_total{name!=""}[2m])) by (name) * 100
```

**4. Inspect container logs:**
```bash
docker logs <container_name> --tail 100
```

### Resolution
- If a batch job: let it finish, consider resource limits (`--cpus` in compose)
- If a runaway process: `docker restart <container_name>`
- If traffic spike: scale horizontally or increase CPU allocation
- Add `deploy.resources.limits.cpus` to the offending service in `docker-compose.yml`

---

## HighMemoryUsage

**Severity:** warning  
**Condition:** Memory usage > 85% for more than 2 minutes  
**Alert expression:**
```
(1 - (node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes)) * 100 > 85
```

### What it means
Available memory is critically low. At this level, the OS may start swapping, causing significant performance degradation. OOM kills become likely above 95%.

### Likely causes
- A container with a memory leak
- Too many containers running simultaneously without memory limits
- A legitimate workload requiring more memory than available

### Investigation steps

**1. Check memory usage per container:**
```bash
docker stats --no-stream --format "table {{.Name}}\t{{.MemUsage}}\t{{.MemPerc}}"
```

**2. Check Grafana — Container Memory Usage panel:**  
Look for a container with a steadily increasing memory trend (sawtooth pattern = normal GC, straight line up = leak).

**3. Check if swap is being used:**
```bash
free -h
```

**4. Query Prometheus:**
```
container_memory_usage_bytes{name!=""} / 1024 / 1024
```

### Resolution
- Restart the leaking container: `docker restart <container_name>`
- Add memory limits to `docker-compose.yml`:
  ```yaml
  deploy:
    resources:
      limits:
        memory: 512m
  ```
- If the host is genuinely undersized, consider reducing the number of running containers or upgrading RAM

---

## HighDiskUsage

**Severity:** critical  
**Condition:** Disk usage > 85% for more than 5 minutes  
**Alert expression:**
```
(1 - (node_filesystem_avail_bytes{fstype!~"tmpfs|overlay"} / node_filesystem_size_bytes{fstype!~"tmpfs|overlay"})) * 100 > 85
```

### What it means
A real filesystem (excluding Docker overlay and tmpfs) is running out of space. At 85%, you have limited runway before writes start failing, which can cause data corruption, container crashes, and unrecoverable states.

### Likely causes
- Prometheus TSDB growing beyond expected size (long retention, high cardinality)
- Docker images, stopped containers, and unused volumes accumulating
- Application logs filling the disk
- Large files written by a container to a mounted volume

### Investigation steps

**1. Find which filesystem is affected (check Grafana — Disk Usage % panel):**  
The `mountpoint` label on the panel identifies the partition.

**2. Check overall disk usage:**
```bash
df -h
```

**3. Find large directories:**
```bash
du -sh /* 2>/dev/null | sort -rh | head -20
```

**4. Check Docker disk usage:**
```bash
docker system df
```

**5. Check Prometheus TSDB size:**
```bash
docker exec prometheus du -sh /prometheus
```

### Resolution

**Free Docker resources (safe):**
```bash
# Remove stopped containers, unused images, dangling volumes
docker system prune -f

# Remove unused volumes (careful — check first)
docker volume ls -f dangling=true
docker volume prune -f
```

**Reduce Prometheus retention** (edit `docker-compose.yml`):
```yaml
command:
  - '--storage.tsdb.retention.time=7d'   # reduce from 15d
```

**If disk is critically full (>95%):**  
Stop non-essential containers first, free space, then investigate root cause before restarting.

---

## InstanceDown

**Severity:** critical  
**Condition:** A scrape target returns `up == 0` for more than 1 minute  
**Alert expression:**
```
up == 0
```

### What it means
Prometheus cannot reach one of its scrape targets. The target is either down, crashed, or unreachable on the network.

### Likely causes
- Container crashed or was stopped
- Port binding conflict causing the service to fail on startup
- Network misconfiguration isolating the container
- OOM kill

### Investigation steps

**1. Check which target is down:**  
Open `http://localhost:9090/targets` → look for `DOWN` state and the error message.

**2. Check container status:**
```bash
docker compose ps
```

**3. Check container logs:**
```bash
docker logs <container_name> --tail 50
```

**4. Check if the port is reachable:**
```bash
curl -v http://localhost:<port>/-/healthy
```

**5. Check recent events:**
```bash
docker inspect <container_name> --format '{{.State}}'
```

### Resolution
- If container exited: `docker compose up -d <service_name>`
- If container is in a restart loop: check logs for the root cause before restarting
- If network issue: `docker compose down && docker compose up -d` (recreates the network)

---

## EndpointDown

**Severity:** critical  
**Condition:** `probe_success == 0` for more than 1 minute  
**Alert expression:**
```
probe_success == 0
```

### What it means
Blackbox Exporter's HTTP probe to an endpoint returned a non-2xx response or timed out. Unlike `InstanceDown` (which checks if Prometheus can scrape a target), this checks whether the service's health endpoint is actually responding correctly from the outside.

### Likely causes
- Service is up but returning errors (500, 503)
- Service is starting up and not yet ready
- Health endpoint path changed
- Network routing issue between Blackbox Exporter and the target

### Investigation steps

**1. Identify the failing endpoint:**  
Check Grafana — **Endpoint Health** panel → which endpoint shows DOWN.

**2. Manually probe the endpoint:**
```bash
curl -v http://localhost:<port>/-/healthy
```

**3. Check probe details in Prometheus:**
```
probe_success{job="blackbox-http"}
probe_http_status_code{job="blackbox-http"}
probe_duration_seconds{job="blackbox-http"}
```

**4. Test via Blackbox Exporter directly:**
```
http://localhost:9115/probe?target=http://prometheus:9090/-/healthy&module=http_2xx&debug=true
```
The `debug=true` parameter shows the full probe log.

### Resolution
- If service is starting: wait for healthcheck to pass, alert should auto-resolve
- If service is returning errors: investigate application logs
- If path changed: update `prometheus/prometheus.yml` scrape targets and reload:
  ```bash
  curl -X POST http://localhost:9090/-/reload
  ```

---

## SlowResponseTime

**Severity:** warning  
**Condition:** `probe_duration_seconds > 2` for more than 2 minutes  
**Alert expression:**
```
probe_duration_seconds > 2
```

### What it means
An endpoint is consistently responding in more than 2 seconds. The service is reachable but degraded. This often precedes an `EndpointDown` or `HighCPUUsage` alert.

### Likely causes
- Service is under high load (correlated with HighCPUUsage)
- Database or dependency is slow
- Network congestion or high latency between Blackbox Exporter and the target
- Service is GC-pausing or waiting on I/O

### Investigation steps

**1. Check response time trend in Grafana:**  
Open **Endpoint Response Time** panel → is it a gradual increase (load) or sudden spike (event)?

**2. Correlate with CPU and Memory panels:**  
If CPU is also elevated, this is a resource contention issue.

**3. Query Prometheus:**
```
probe_duration_seconds{job="blackbox-http"}
probe_http_duration_seconds{job="blackbox-http", phase="processing"}
```
The `phase="processing"` label isolates server processing time from DNS/connect overhead.

**4. Check container resource usage:**
```bash
docker stats --no-stream
```

### Resolution
- If correlated with high CPU: resolve the CPU issue first, response times should recover
- If isolated to one service: restart the service — `docker compose restart <service_name>`
- If persistent: investigate the service's internal performance (query plans, connection pools, thread contention)
- Consider tightening the probe timeout in `blackbox/blackbox.yml` to fail faster and escalate sooner

---

## General Principles

**Always check Grafana first.** The dashboard gives you the full picture — correlate CPU, memory, disk, and endpoint panels before diving into logs.

**Use `debug=true` on Blackbox probes** to get full probe traces when endpoint issues are unclear.

**Reload Prometheus config without restarting:**
```bash
curl -X POST http://localhost:9090/-/reload
```

**Check alert state transitions** at `http://localhost:9090/alerts` — an alert in `Pending` state means the condition is met but the `for` duration hasn't elapsed yet.
