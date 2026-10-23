import json, os, statistics, subprocess, sys
from pathlib import Path
base = Path(sys.argv[1]).resolve()
repository = Path(sys.argv[2]).resolve()
fixture = base / "fixture" / "home"
environment = {**os.environ, "SWIFT_DETERMINISTIC_HASHING": "1"}
cases = [
    (str(fixture), "8000", "disk"),
    (str(fixture), "28000", "disk"),
    (str(fixture), "wide", "disk"),
    (str(fixture), "28000", "images"),
    (str(fixture), "wide", "images"),
    (str(repository), "real", "disk"),
]
if not (fixture/"files-wide").exists():
    subprocess.run([str(base/"after/benchmark"), "create", str(fixture)], check=True)
summaries = []
metrics = {
    "peak_footprint_bytes": ("scanEnd", "peakFootprintBytes"),
    "peak_rss_bytes": ("scanEnd", "peakRSSBytes"),
    "retained_footprint_bytes": ("retained", "footprintBytes"),
    "retained_heap_in_use_bytes": ("retained", "heapInUseBytes"),
    "released_footprint_bytes": ("released", "footprintBytes"),
    "released_heap_in_use_bytes": ("released", "heapInUseBytes"),
}
with (base/"results.jsonl").open("w") as output:
    for root, scope, kind in cases:
        rows = []
        for version in ("before", "after"):
            subprocess.run([str(base/version/"benchmark"), version, root, scope, kind, "0"],
                           check=True, capture_output=True, text=True, env=environment)
        for trial in range(1, 8):
            paired = {}
            order = ("before", "after") if trial % 2 else ("after", "before")
            for version in order:
                run = subprocess.run([str(base/version/"benchmark"), version, root, scope, kind, str(trial)],
                                     check=True, capture_output=True, text=True, env=environment)
                row = json.loads(run.stdout)
                paired[version] = row
                rows.append(row)
                output.write(json.dumps(row, sort_keys=True)+"\n")
                output.flush()
                for stage in ("start", "scanEnd", "retained", "released"):
                    if row[stage]["footprintBytes"] <= 0 or row[stage]["peakFootprintBytes"] <= 0:
                        raise RuntimeError("Memory metric is unavailable, not zero")
            keys = ("indexedFiles", "indexedDirectories", "totalSize", "issueCount", "canReuse")
            if any(paired["before"]["counts"][k] != paired["after"]["counts"][k] for k in keys):
                raise RuntimeError(f"Output changed for {scope}/{kind}/{trial}")
            if not paired["after"]["counts"]["canReuse"] or paired["after"]["counts"]["issueCount"]:
                raise RuntimeError("Only complete memory profiles are comparable")
        summary = {"scope":scope, "kind":kind, "trials":7, "files":rows[0]["counts"]["indexedFiles"],
                   "total_size":rows[0]["counts"]["totalSize"], "outputs_equal":True}
        for name, (stage, field) in metrics.items():
            values = {}
            for version in ("before", "after"):
                samples = [r[stage][field] for r in rows if r["version"]==version]
                values[version] = {"median":statistics.median(samples), "min":min(samples), "max":max(samples)}
            values["change_bytes"] = values["after"]["median"]-values["before"]["median"]
            values["change_percent"] = values["change_bytes"]/values["before"]["median"]*100
            summary[name] = values
        for stage in ("start", "scanEnd", "retained", "released"):
            summary[stage+"_medians"] = {
                version:{field:statistics.median(r[stage][field] for r in rows if r["version"]==version)
                         for field in rows[0][stage]} for version in ("before","after")}
        summaries.append(summary)
        compact = {"scope":scope,"kind":kind,"files":summary["files"]}
        for name in ("peak_footprint_bytes","retained_footprint_bytes","retained_heap_in_use_bytes","released_heap_in_use_bytes"):
            compact[name] = {v: round(summary[name][v]["median"]/1048576,3) for v in ("before","after")}
            compact[name]["change_percent"] = round(summary[name]["change_percent"],2)
        print(json.dumps(compact,sort_keys=True),flush=True)
(base/"summary.json").write_text(json.dumps(summaries,indent=2,sort_keys=True)+"\n")

