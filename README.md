# AzadiDNSTester

**Languages:** [English](README.md) | [فارسی](README-fa.md)

**Azadi DNS Tester** - Tests DNS servers from `dns_servers.txt` and saves working ones to `working_dns.txt`.

Perfect for finding available DNS servers on restricted networks.

---

## Three Ways to Test DNS Servers

| Method | Platform | Dependencies | Best For |
|--------|----------|--------------|----------|
| **Python** | All | Python + pip packages | Full features, best UX |
| **Bash** | Linux/macOS | None (built-in tools) | Restricted networks |
| **PowerShell** | Windows | None (built-in cmdlets) | Restricted networks |

---

## 1. Python Script (Full Featured)

The Python version offers the best user experience with progress bars, colored output, and high-precision timing.

### Requirements
- Python 3.6+
- `dnspython` and `tqdm` packages

### Installation
```bash
pip install dnspython tqdm
```

### Usage
```bash
python AzadiDNSTester.py
```

### Features
- ✅ Interactive prompts for workers, timeout, and test domain
- ✅ Real-time progress bar with `tqdm`
- ✅ Parallel testing with configurable worker count
- ✅ Colored terminal output
- ✅ Millisecond-precision timing
- ✅ Results saved in real-time

---

## 2. Bash Script (No Dependencies - Linux/macOS)

A standalone Bash script that works on any Linux or macOS system without requiring Python or any external dependencies. Perfect for sharing with users on restricted networks.

### Requirements
- Bash 3.x+ (pre-installed on macOS/Linux)
- One of: `dig`, `host`, or `nslookup` (usually pre-installed)

### Usage
```bash
chmod +x AzadiDNSTester.sh
./AzadiDNSTester.sh
```

### Features
- ✅ No external dependencies - uses only built-in tools
- ✅ Auto-detects DNS tool (prefers `dig` → `host` → `nslookup`)
- ✅ Parallel testing with configurable workers via `xargs -P`
- ✅ Real-time progress display
- ✅ High-precision timing if `perl Time::HiRes` is available
- ✅ Works on macOS (Bash 3.x) and Linux (Bash 4.x+)
- ✅ Extracts IPv4 addresses from any input format

### DNS Tool Priority
1. **dig** (best) - Most reliable, built-in timeout support
2. **host** - Good alternative, supports timeout
3. **nslookup** - Fallback, limited timeout control

---

## 3. PowerShell Script (No Dependencies - Windows)

A standalone PowerShell script for Windows users that requires no external dependencies. Works with both Windows PowerShell 5.1 and PowerShell 7+.

### Requirements
- Windows PowerShell 5.1+ (pre-installed on Windows 10/11)
- Or PowerShell 7+ (cross-platform)

### Usage
```powershell
# Interactive mode
.\AzadiDNSTester.ps1

# Non-interactive mode with parameters
.\AzadiDNSTester.ps1 -NonInteractive -Workers 50 -Timeout 3 -Domain google.com
```

### Features
- ✅ No external dependencies - uses only built-in cmdlets
- ✅ Uses `Resolve-DnsName` cmdlet (or `nslookup` fallback)
- ✅ Parallel testing:
  - PowerShell 7+: `ForEach-Object -Parallel`
  - PowerShell 5.1: Runspace pools
- ✅ Real-time progress display
- ✅ High-precision timing with `[Stopwatch]`
- ✅ Thread-safe file writes
- ✅ Supports non-interactive mode for automation

### Parameters
| Parameter | Description | Default |
|-----------|-------------|---------|
| `-Workers` | Number of parallel tests | 100 |
| `-Timeout` | Timeout per test (seconds) | 3 |
| `-Domain` | Domain to resolve | google.com |
| `-NonInteractive` | Skip prompts, use defaults/params | false |

---

## Input File Format

All scripts read from `dns_servers.txt` in the same directory. The scripts automatically extract IPv4 addresses from **any format**:

```
# Comments are ignored
1.1.1.1
8.8.8.8
Server: 208.67.222.222 (OpenDNS)
DNS=9.9.9.9
```

If the file doesn't exist, a sample file with popular public DNS servers will be created.

---

## Output File Format

Working servers are saved to `working_dns.txt`:

```
# Working DNS servers - Tested: 2026-01-18 12:00:00
# Test domain: google.com
# Format: IP (response_time_ms)
1.1.1.1 (23ms)
8.8.8.8 (45ms)
9.9.9.9 (67ms)
```

---

## Sharing with Restricted Network Users

For users who can't install Python or download executables:

1. **Copy the script content** (Bash or PowerShell depending on their OS)
2. **Send them via chat or any file sharing method**
3. **Paste into a text file** on their machine
4. **Save with the correct extension** (`.sh` or `.ps1`)
5. **Run it** - no installation needed!

The Bash and PowerShell scripts are completely self-contained and work with only the tools that come pre-installed on the operating system.
