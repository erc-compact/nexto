# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

NEXTO is a Nextflow (DSL2) port of the PULSAR_MINER pulsar-search pipeline, running PRESTO and PulsarX tools inside Singularity/Apptainer containers on HPC clusters. There is no build step, linter, or test suite — the code is Nextflow/Groovy plus Python helper scripts, verified by running the pipeline.

## Commands

```bash
# Run the pipeline (local)
nextflow run nexto_search.nf --input observation.fil --outdir results -profile local

# Run on a cluster (profiles: hercules, ozstar, contra)
nextflow run nexto_search.nf -profile hercules --input observation.fil --outdir results

# Resume a failed/interrupted run (reuses cached task results)
nextflow run nexto_search.nf --input observation.fil -resume

# Show all pipeline parameters
nextflow run nexto_search.nf --help

# GPU acceleration (uses accelsearch_cu; requires CUDA <= 11.8)
nextflow run nexto_search.nf -profile hercules --input observation.fil --use_cuda true
```

Requires Nextflow >= 23.04.0 and PRESTO 3.x/4.x (incompatible with PRESTO 5+). Debug via `.nextflow.log` and per-task work directories; execution trace/timeline/report land in `--outdir`.

## Code layout

- `nexto_search.nf` — the single entry point; contains the whole workflow graph (channel wiring, DM-trial fan-out, segmentation, sift grouping, fold branching).
- `modules.nf` — every process definition (FILTOOL, RFIFIND, PREPDATA, COMPUTE_BARYV, ACCELSEARCH_ZMAX0, ACCELSEARCH, ACCELSIFT, PREPFOLD_FROM_CANDFILE, PSRFOLD_PULSARX, SINGLE_PULSE_SEARCH, MAKE_ZAPLIST). Each process declares its container and `publishDir` explicitly.
- `nextflow.config` — manifest, default params, local profiles; cluster profiles just `includeConfig` from `conf/`.
- `conf/{hercules,ozstar,contra}.config` — per-cluster settings: container image paths, executor (SLURM or HT-Condor), queue selection, and per-process resources via `withName:` blocks with a `check_max()` helper and retry-scaled resources. Each config validates the hostname at load time and throws if run on the wrong cluster.
- `bin/` — Python helpers invoked from process scripts (Nextflow puts `bin/` on PATH automatically): `sift_candidates.py` + `sifting.py` (candidate sifting, needs the PRESTO Python module inside the container), `compute_baryv.py` (average barycentric velocity via presto `get_baryv`, needs PRESTO container), `prepare_psrfold_cands.py` (barycentric→topocentric candfile conversion + segment pepoch for psrfold, stdlib only), `split_datfile.py` (segment splitting).

## Pipeline architecture (the part that spans files)

The workflow is a two-stage design inherited from PULSAR_MINER — order matters:

1. **Birdie stage (topocentric)**: `PREPDATA_ZERODM` runs at DM=0 **with** `-nobary`, then `ACCELSEARCH_ZMAX0` (z=0 search) finds persistent RFI lines, and `MAKE_ZAPLIST` builds a frequency zaplist from them.
2. **Search stage (barycentered)**: `PREPDATA_DMTRIALS` runs one job per DM trial **without** `-nobary`. `ACCELSEARCH` then applies the zaplist and searches. Both stages reuse the same `PREPDATA` process via `include ... as` aliasing with a `nobary` boolean input — don't collapse the two invocations.

Fan-out dimensions: candidates come from the cross product of **DM trials × segments × search_params**. `params.segments` is a list of `[name, fraction]` tuples expanded into chunks (e.g. `["half", 0.5]` → 2 chunks); `params.search_params` is a list of `[zmax, wmax]` tuples where `wmax > 0` switches to a jerk search (output files gain a `_JERK_<wmax>` suffix). `ACCELSEARCH` is a compound process: it internally splits the .dat file for segments, runs realfft, rednoise, zapbirds, and accelsearch in one task, using node-local `scratch`.

**Reference frames matter.** The zaplist frequencies are topocentric while the search-stage FFTs are barycentered, so `zapbirds` must always receive `-baryv` (computed once per observation by `COMPUTE_BARYV` / `bin/compute_baryv.py`). The sifted candfile F0/F1/F2 are barycentric and referenced to the *segment start*: `prepfold` handles this natively (it barycenters raw data), but PulsarX `psrfold_fil` does not — PSRFOLD_PULSARX first runs `bin/prepare_psrfold_cands.py` to Doppler-shift the spin parameters and compute the topocentric pepoch of the segment start. PRESTO's convention is `f_bary = f_topo * (1 + baryv)`, so barycentric→topocentric **divides**: `F0/(1+baryv)`, and each derivative gains a power because topocentric time intervals stretch by the same factor (`F1/(1+baryv)^2`, `F2/(1+baryv)^3`). Getting this sign backwards costs almost nothing for a slow pulsar in a short observation (the two directions differ by only `2*baryv`) but destroys a fast MSP over a long segment — test frame changes with high `F0 * Tobs`, and compare folded S/N, never psrfold's `f0_new - f0_old` (its F0 search range is far too narrow to reveal a frame error). Also note `psrfold_fil` exits 0 on fatal errors, hence the explicit archive-exists check in the process script.

Sifting (`ACCELSIFT`) runs one job per `(obs_id, segment chunk)` covering **all** DM trials and **all** zmax/wmax searches of that chunk, so duplicate/harmonic removal spans search configurations; different observations (beams) are never sifted together. Folding then branches on `params.fold_with_psrfold`: PRESTO `prepfold` gets one job per candidate (candfiles are parsed line-by-line in the workflow with `splitCsv`), while PulsarX `psrfold` gets one job per sifted candidate file.

Two containers are used: `params.presto_container` for PRESTO processes and `params.pulsarx_container` for FILTOOL and PSRFOLD_PULSARX. **Every process takes a canonical `obs_id` as the first tuple element** (input basename with any `_filtool` suffix stripped, computed once at the top of the workflow) and uses it for `publishDir` paths and per-observation channel joins (`combine(..., by: 0)` / `join`) — keep that convention when adding processes; never derive output directories from filenames.

## Conventions

- Resource allocation is intentionally explicit per process in the cluster configs (`withName:` blocks), not via generic labels — set resources there, not in `modules.nf`.
- Retry-based resource scaling: cluster configs multiply memory/time by `task.attempt` and retry on OOM/timeout exit codes (124, 137–140).
- Candfile format produced by sifting and consumed by folding: tab-separated `#id dm acc F0 F1 F2 S/N` with one header line.
- Reference docs in the repo: `ARCHITECTURE.md` (DAG and channel flow), `WORKFLOW_CORRECTIONS.md` (why the -nobary two-stage order exists), `CLUSTER_CONFIGS.md` (per-cluster details), `CONTAINER_SETUP.md`, `QUICKSTART.md`.
