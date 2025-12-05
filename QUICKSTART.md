# NEXTO Quick Start Guide

Get started with NEXTO in 5 minutes!

## Prerequisites

1. Nextflow installed (`curl -s https://get.nextflow.io | bash`)
2. PRESTO 3.0 or 4.0 installed and working
3. Input observation file (.fil or .fits format)

## Step 1: Configure PRESTO Path

Edit `nextflow.config` and set your PRESTO installation path:

```groovy
params.presto_path = "/path/to/your/presto"
```

## Step 2: Test Run

Run a quick test with minimal parameters:

```bash
nextflow run nexto_search.nf \
    --input test_observation.fil \
    --outdir test_results \
    --dm_low 0 \
    --dm_high 10 \
    --dm_step 2 \
    --zmax 10
```

## Step 3: Full Search

Once the test works, run a full search:

```bash
nextflow run nexto_search.nf \
    --input observation.fil \
    --outdir results \
    --dm_low 0 \
    --dm_high 200 \
    --dm_step 0.5 \
    --zmax 100 \
    --numharm 16
```

## Step 4: Cluster Execution

NEXTO includes pre-configured profiles for three HPC clusters:

**OzSTAR (Swinburne):**
```bash
nextflow run nexto_search.nf \
    -profile ozstar \
    --input observation.fil \
    --outdir results
```

**Hercules (MPIfR Bonn):**
```bash
nextflow run nexto_search.nf \
    -profile hercules \
    --input observation.fil \
    --outdir results
```

**Contra (MPIfR Bonn):**
```bash
nextflow run nexto_search.nf \
    -profile contra \
    --input observation.fil \
    --outdir results
```

For custom clusters, copy and customize the template:
```bash
# 1. Copy template
cp conf/slurm_example.config conf/mycluster.config

# 2. Edit conf/mycluster.config with your cluster details

# 3. Add profile to nextflow.config:
#    profiles {
#        mycluster { includeConfig 'conf/mycluster.config' }
#    }

# 4. Run with your profile
nextflow run nexto_search.nf \
    -profile mycluster \
    --input observation.fil
```

## Step 5: Check Results

Results are organized in subdirectories:

```bash
results/
├── 01_RFIFIND/          # RFI masks
├── 02_BIRDIES/          # RFI frequency lists
├── 03_DEDISPERSION/     # DM trial data
├── 04_SIFTING/          # Candidate lists
├── 05_FOLDING/          # Folded profiles (*.pfd, *.ps)
└── report.html          # Execution report
```

View the execution report:

```bash
firefox results/report.html
```

## Common Use Cases

### High DM Search (e.g., globular cluster)

```bash
nextflow run nexto_search.nf \
    --input observation.fil \
    --dm_low 0 \
    --dm_high 500 \
    --dm_step 1.0 \
    --zmax 200
```

### Low DM, High Sensitivity (e.g., nearby pulsar)

```bash
nextflow run nexto_search.nf \
    --input observation.fil \
    --dm_low 0 \
    --dm_high 50 \
    --dm_step 0.1 \
    --zmax 50 \
    --numharm 16 \
    --sigma_threshold 5.0
```

### GPU-Accelerated Search

Enable GPU acceleration on supported clusters:

```bash
nextflow run nexto_search.nf \
    -profile hercules \
    --input observation.fil \
    --use_cuda true
```

### Batch Processing

Process multiple observations:

```bash
./bin/run_batch.sh -p slurm --dm-high 200 observations/*.fil
```

## Troubleshooting

### "Command not found: rfifind"

Your PRESTO path is incorrect. Check:
- `params.presto_path` in `nextflow.config`
- PRESTO is compiled and binaries exist in `$PRESTO/bin/`

### Out of Memory

Resources scale automatically with retries. If jobs consistently fail, customize resources in your cluster config file (e.g., `conf/hercules.config`):

```groovy
withName: 'ACCELSEARCH' {
    memory = { check_max(16.GB * task.attempt, 'memory') }  // Increase base memory
}
```

See [CLUSTER_CONFIGS.md](CLUSTER_CONFIGS.md) for standard resource allocations.

### Jobs Not Submitting to Cluster

Check your cluster profile settings:
- Queue name exists
- Account/project is correct
- You have permission to submit jobs

Test with:
```bash
sbatch --test-only  # For SLURM
```

## Next Steps

1. Read the full [README.md](README.md) for detailed documentation
2. See [CLUSTER_CONFIGS.md](CLUSTER_CONFIGS.md) for cluster configuration details
3. Check [ARCHITECTURE.md](ARCHITECTURE.md) to understand the pipeline design
4. Explore [modules.nf](modules.nf) to see all process definitions
5. Join the discussion on GitHub Issues

## Getting Help

- Check the [README.md](README.md)
- Look at example configs in `conf/`
- Open an issue on GitHub
- Check PRESTO documentation: https://www.cv.nrao.edu/~sransom/presto/

Happy pulsar hunting! 🔭
