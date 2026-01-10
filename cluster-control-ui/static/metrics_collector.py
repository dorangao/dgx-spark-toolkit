#!/usr/bin/env python3
"""
Remote host metrics collection script.
This script is sent via SSH to collect system metrics from remote hosts.
"""
import json
import subprocess
import time
import os


def _safe_float(value, default=None):
    if value is None:
        return default
    text = str(value).strip().strip("[]")
    if not text or text.upper() == "N/A":
        return default
    text = text.replace("%", "").replace("MiB", "").strip()
    try:
        return float(text)
    except ValueError:
        return default


def _cpu_usage():
    def _read():
        with open("/proc/stat", "r", encoding="utf-8") as fh:
            for line in fh:
                if line.startswith("cpu "):
                    parts = [int(x) for x in line.split()[1:]]
                    total = sum(parts)
                    idle = parts[3] + (parts[4] if len(parts) > 4 else 0)
                    return total, idle
        return 0, 0

    total1, idle1 = _read()
    time.sleep(0.2)
    total2, idle2 = _read()
    delta_total = total2 - total1
    if delta_total <= 0:
        return 0.0
    delta_idle = idle2 - idle1
    usage = (1 - (delta_idle / delta_total)) * 100.0
    return max(0.0, min(usage, 100.0))


def _memory_usage():
    info = {}
    with open("/proc/meminfo", "r", encoding="utf-8") as fh:
        for line in fh:
            if ":" not in line:
                continue
            key, rest = line.split(":", 1)
            parts = rest.strip().split()
            if parts:
                info[key.strip()] = int(parts[0])
    total_kb = info.get("MemTotal", 0)
    available_kb = info.get("MemAvailable", info.get("MemFree", 0))
    buffers_kb = info.get("Buffers", 0)
    cached_kb = info.get("Cached", 0)
    sreclaimable_kb = info.get("SReclaimable", 0)
    
    used_kb = max(total_kb - available_kb, 0)
    cache_kb = buffers_kb + cached_kb + sreclaimable_kb
    app_used_kb = max(used_kb - cache_kb, 0)
    
    return {
        "total_mb": int(total_kb / 1024) if total_kb else 0,
        "used_mb": int(used_kb / 1024),
        "available_mb": int(available_kb / 1024),
        "cache_mb": int(cache_kb / 1024),
        "app_used_mb": int(app_used_kb / 1024),
        "percent": round((used_kb / total_kb) * 100, 1) if total_kb else 0.0,
    }


def _disk_usage():
    disks = []
    skip_fs = {'tmpfs', 'devtmpfs', 'squashfs', 'overlay', 'proc', 'sysfs', 'devpts', 
               'cgroup', 'cgroup2', 'securityfs', 'pstore', 'efivarfs', 'bpf', 'tracefs', 
               'debugfs', 'configfs', 'fusectl', 'hugetlbfs', 'mqueue', 'nsfs', 'fuse.lxcfs'}
    seen_devices = set()
    
    try:
        with open("/proc/mounts", "r") as f:
            for line in f:
                parts = line.split()
                if len(parts) < 4:
                    continue
                device, mount, fstype = parts[0], parts[1], parts[2]
                
                if fstype in skip_fs or not device.startswith('/dev/') or device in seen_devices:
                    continue
                seen_devices.add(device)
                
                try:
                    st = os.statvfs(mount)
                    total = st.f_blocks * st.f_frsize
                    free = st.f_bavail * st.f_frsize
                    used = total - free
                    
                    if total > 0:
                        disks.append({
                            "mount": mount,
                            "device": device.split('/')[-1],
                            "total_gb": round(total / (1024**3), 1),
                            "used_gb": round(used / (1024**3), 1),
                            "free_gb": round(free / (1024**3), 1),
                            "percent": round((used / total) * 100, 1),
                        })
                except (OSError, PermissionError):
                    pass
    except Exception:
        pass
    
    disks.sort(key=lambda x: (x["mount"] != "/", x["mount"]))
    return disks


def _network_stats():
    stats = {}
    try:
        with open("/proc/net/dev", "r") as f:
            lines = f.readlines()[2:]
            for line in lines:
                if ":" not in line:
                    continue
                iface, data = line.split(":", 1)
                iface = iface.strip()
                
                skip_prefixes = ('lo', 'docker', 'br-', 'veth', 'cali', 'cni', 'flannel', 'weave', 'vxlan')
                if any(iface.startswith(p) or iface == p for p in skip_prefixes):
                    continue
                
                parts = data.split()
                if len(parts) >= 10:
                    rx_bytes = int(parts[0])
                    tx_bytes = int(parts[8])
                    
                    if rx_bytes > 1024*1024 or tx_bytes > 1024*1024:
                        stats[iface] = {
                            "rx_bytes": rx_bytes,
                            "tx_bytes": tx_bytes,
                            "rx_mb": round(rx_bytes / (1024**2), 2),
                            "tx_mb": round(tx_bytes / (1024**2), 2),
                        }
    except Exception:
        pass
    return stats


def _gpu_usage():
    cmd = [
        "nvidia-smi",
        "--query-gpu=index,name,utilization.gpu,utilization.memory,memory.used,memory.total,temperature.gpu",
        "--format=csv,noheader,nounits",
    ]
    try:
        result = subprocess.run(cmd, capture_output=True, text=True, check=True, timeout=2)
    except FileNotFoundError:
        return [], "nvidia-smi not found"
    except Exception as exc:
        return [], str(exc)
    
    lines = [line.strip() for line in result.stdout.strip().splitlines() if line.strip()]
    gpus = []
    for line in lines:
        parts = [part.strip() for part in line.split(",")]
        if len(parts) < 7:
            continue
        try:
            mem_used = _safe_float(parts[4])
            mem_total = _safe_float(parts[5])
            gpus.append({
                "index": int(parts[0]),
                "name": parts[1],
                "util": _safe_float(parts[2], 0.0),
                "memory_util": _safe_float(parts[3], 0.0),
                "memory_used": mem_used,
                "memory_total": mem_total,
                "temperature": _safe_float(parts[6]),
            })
        except ValueError:
            continue
    
    # For GPUs like GB10 where memory query returns N/A
    for gpu in gpus:
        if gpu["memory_used"] is None or gpu["memory_total"] is None:
            try:
                proc_result = subprocess.run(
                    ["nvidia-smi", "--query-compute-apps=pid,used_gpu_memory", "--format=csv,noheader,nounits"],
                    capture_output=True, text=True, check=True, timeout=2
                )
                total_proc_mem = 0.0
                for proc_line in proc_result.stdout.strip().splitlines():
                    proc_parts = proc_line.split(",")
                    if len(proc_parts) >= 2:
                        proc_mem = _safe_float(proc_parts[1].strip())
                        if proc_mem:
                            total_proc_mem += proc_mem
                if total_proc_mem > 0:
                    gpu["memory_used"] = total_proc_mem
                    if "GB10" in gpu.get("name", ""):
                        gpu["memory_total"] = 131072.0
                        gpu["memory_util"] = round((total_proc_mem / 131072.0) * 100, 1)
            except Exception:
                pass
    return gpus, None


if __name__ == "__main__":
    payload = {
        "cpu": {"percent": round(_cpu_usage(), 1)},
        "memory": _memory_usage(),
        "disk": _disk_usage(),
        "network": _network_stats(),
        "collected": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
    }
    gpus, gpu_error = _gpu_usage()
    payload["gpus"] = gpus
    payload["gpu_error"] = gpu_error
    print(json.dumps(payload))
