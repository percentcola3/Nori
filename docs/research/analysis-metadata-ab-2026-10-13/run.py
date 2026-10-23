import json, os, statistics, subprocess, sys
from pathlib import Path
base = Path(sys.argv[1]).resolve()
repository = Path(sys.argv[2]).resolve()
fixture = base / "fixture" / "home"
subprocess.run([str(base/"after/benchmark"), "create", str(fixture)], check=True)
cases = [(str(fixture), str(n), kind, 7) for n in (8000, 28000) for kind in ("disk", "images")]
cases.append((str(repository), "real", "disk", 7))
environment = {**os.environ, "SWIFT_DETERMINISTIC_HASHING": "1"}
all_rows = []
summaries = []
with (base/"results.jsonl").open("w") as output:
    for root, count, kind, trials in cases:
        rows = []
        # Normalize warm-cache state and dictionary hashing for both binaries.
        for version in ("before", "after"):
            subprocess.run([str(base/version/"benchmark"), version, root, count, kind, "0"],
                           check=True, capture_output=True, text=True, env=environment)
        for trial in range(1, trials+1):
            order = ("before", "after") if trial % 2 else ("after", "before")
            paired = {}
            for version in order:
                run = subprocess.run([str(base/version/"benchmark"), version, root, count, kind, str(trial)],
                                     check=True, capture_output=True, text=True, env=environment)
                parsed = [json.loads(line) for line in run.stdout.splitlines()]
                for row in parsed:
                    output.write(json.dumps(row, sort_keys=True) + "\n")
                    output.flush()
                    rows.append(row)
                    all_rows.append(row)
                    paired[(version, row["phase"])] = row
            for phase in ("full", "unchanged"):
                before, after = [paired[(v, phase)] for v in ("before", "after")]
                keys = ("signature", "indexedFiles", "totalFiles", "totalSize", "issueCount", "canReuse")
                if any(before[k] != after[k] for k in keys):
                    raise RuntimeError(f"Result changed for {count}/{kind}/{trial}/{phase}")
                if not before["canReuse"] or before["issueCount"]:
                    raise RuntimeError("Benchmark must finish with complete results")
        for phase in ("full", "unchanged"):
            old = [r for r in rows if r["version"]=="before" and r["phase"]==phase]
            new = [r for r in rows if r["version"]=="after" and r["phase"]==phase]
            a = statistics.median(r["ms"] for r in old)
            b = statistics.median(r["ms"] for r in new)
            summary = {
                "scope": old[0]["scope"], "files": old[0]["files"], "kind": kind, "phase": phase,
                "trials": trials, "before_median_ms": a, "after_median_ms": b,
                "time_reduction_percent": (a-b)/a*100,
                "before_metadata_reads": old[0]["metadataReads"], "after_metadata_reads": new[0]["metadataReads"],
                "reused_listed_file_metadata": new[0]["reusedListedFileMetadata"],
                "total_size": old[0]["totalSize"], "indexed_files": old[0]["indexedFiles"],
                "results_equal": True
            }
            summaries.append(summary)
            print(json.dumps(summary, sort_keys=True), flush=True)
(base/"summary.json").write_text(json.dumps(summaries, indent=2, sort_keys=True)+"\n")

