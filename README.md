DiskScan.ps1 — Hyper-perfomance edition
Two-stage, stream-first disk & UNC scanner (PowerShell 7+)
=

Results may vary based on total files on disk

# Getting started

real fast scan:
```
pwsh .\diskScan.ps1 -Roots 'C:\Users\Downloads'
```
scan local + UNC, only exe files, show progress to console
```
pwsh .\diskScan.ps1 -Roots 'C:\','\\srv\share' -IncludeExt 'exe' -EchoToConsole
```
TIP: Pick the right -ThrottleLimit i did some testing but not a lot.

More threads ≠ faster 

small trees favor less threads because of startup overhead.

20,000 files try 2 threads

1,400,000 files (505 GB) try 12 threads even if you have more

1,400,000 files (505 GB) 5 threads was 3 seconds behind 12

The default 5 is good for most situations I could proably go lower I think If you have a specific worklaod (i'm talking MANY TBs not just 1 ) that need more threads then do it 
otherwise 5 is fine. 

```
.\diskScan-1.0.0.ps1 -ThrottleLimit 20
```

```
505 GB
BENCHMARK RESULTS 1,414,001 files on C:\

Stage 1 complete: 24 targets -> C:\IT\diskScan\results\20251023_T191950\targets.csv
Stage 2: C:\ -> C:\IT\diskScan\results\20251023_T191950\C.zip (rows: 1414001)
87.90 s
DONE.
```
## Overview

`DiskScan.ps1` is a **multi-threaded, two-stage disk scanner** optimized for large-scale file inventorying across local drives and network (UNC) paths.  
The design emphasizes **throughput, stability, and minimal memory use**, even across multi-terabyte file sets.

### Key Performance Enhancements

- **Parallel Queue Model**
  - Uses a `ConcurrentQueue` to dynamically assign work to runspaces.
  - Workers pull new targets as they finish, maximizing CPU and I/O efficiency.

- **Dynamic work pool**
  - Parallel work uses dynamic dequeueing, ensuring no thread idles early.
  - Performance scales linearly up to disk or SMB saturation.
    
- **StreamWriter I/O**
  - Replaced `Add-Content` with a persistent `StreamWriter` (64 KB buffer).
  - Eliminates per-line file reopen overhead for up to **20× faster write throughput**.

- **Provider-Side Filtering**
  - Uses `Get-ChildItem -Attributes !ReparsePoint` to skip junctions before pipeline emission.
  - Uses `-Filter *.ext` when scanning for a single extension to leverage filesystem-level filtering.

- **UNC Host Caching**
  - `ConcurrentDictionary` caches reachability results (`Test-Connection`).
  - Each unique host is pinged **once per run**, avoiding redundant latency.

- **Streamed ZIP Output**
  - Directly streams CSV data into a compressed `.zip` without intermediate staging.
  - Each root’s results are written to a self-contained ZIP with `Root,Path,SizeBytes` columns.

- **Minimal Provider Overhead**
  - Progress bars and pipeline buffering disabled inside runspaces.
  - Hidden/system file enumeration is optional but safe under `-Force`.

## Flags
```
-Roots          [string[]]  # 'C:\','D:\','\\Server\Share'  (required-ish)
-ThrottleLimit  [int]       # parallel worker count (default 4)
-BaseDir        [string]    # working dir (default: C:\IT\diskScan)
-IncludeExt     [string[]]  # optional filter list: 'exe','log',...
-EchoToConsole  [switch]    # print each path as discovered
-VerboseErrors  [switch]    # write detailed failures to errors.log
-TargetFile     [string]    # override Stage 1 CSV location
-OutDir         [string]    # override results dir
-TempDir        [string]    # override tmp dir
```
---

## Stages

### **Stage 1 – Target Discovery**

1. Enumerates top-level directories for each root (local or UNC).
2. Skips reparse points and logs missing/unreachable roots.
3. Outputs all discovered targets into a CSV (`targets.csv`) under a timestamped folder.

---

### **Stage 2 – Recursive Scan**

1. Each top-level path from Stage 1 is scanned recursively in parallel.
2. File entries are streamed into temporary `.tmp` files (per-thread).
3. Once complete, temporary files are compressed into a ZIP per root:

## Output

Each run creates a timestamped folder so results are ordered like a ledger:
pwsh .diskScan.ps1 -Roots 'C:\Users\Public', '\\FILE\SERVER\Share'
```
C:\IT\diskScan\results\20251023_T141623\
├── targets.csv          # Stage 1: list of top-level targets
├── errors.log           # optional verbose errors
├── C__Users_Public.zip  # Stage 2: results for that root, contains C__Users_Public.csv
└── UNC_FILE_SERVER_Share.zip
```

Inside each ZIP: one CSV named <RootTag>.csv with rows: Root, Path, SizeBytes
