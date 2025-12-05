# NEXTO Container Setup Guide

## Overview

NEXTO now uses Singularity/Apptainer containers for all PRESTO processes, ensuring reproducible execution across different HPC clusters.

## Changes Made

### 1. ✅ All Modules Use Bash

**Converted from Python to Bash:**
- `MAKE_ZAPLIST` - Now uses `grep | awk` instead of Python
- `ACCELSIFT` - Now uses bash loops and `awk` for candidate filtering
- Removed `EXTRACT_METADATA` process (not essential)

**Benefits:**
- Faster execution (no Python interpreter overhead)
- Simpler dependencies
- Better integration with PRESTO tools

### 2. ✅ Singularity Container Support

**All processes now include:**
```groovy
container "${params.presto_container}"
```

**Processes with containers:**
- READFILE
- RFIFIND
- PREPDATA (both ZERODM and DMTRIALS)
- REALFFT (both ZERODM and DMTRIALS)
- REDNOISE (both ZERODM and DMTRIALS)
- ZAPBIRDS
- ACCELSEARCH_ZMAX0
- ACCELSEARCH
- ACCELSEARCH_JERK
- ACCELSIFT
- PREPFOLD
- PREPFOLD_TIMESERIES
- SINGLE_PULSE_SEARCH
- MAKE_ZAPLIST
- COMBINE_CANDIDATES

### 3. ✅ Configuration Parameters

Added to `nextflow.config`:

```groovy
params {
    // Singularity container
    presto_container = "/path/to/singularity_images/presto_latest.sif"
    singularity_cachedir = "/path/to/singularity_cache"
}
```

### 4. ✅ Apptainer/Singularity Profile

Based on one_ring best practices:

```groovy
singularity {
    apptainer.enabled = true
    apptainer.autoMounts = true
    apptainer.runOptions = '--env PYTHONNOUSERSITE=1 --nv'
    apptainer.cacheDir = params.singularity_cachedir
    apptainer.envWhitelist = 'APPTAINER_BINDPATH,APPTAINER_LD_LIBRARY_PATH'
}
```

**Features:**
- `PYTHONNOUSERSITE=1` - Prevents user site-packages conflicts
- `--nv` - NVIDIA GPU support for CUDA acceleration
- Auto-mounting of common paths
- Configurable cache directory

### 5. ✅ Cluster-Specific Configurations

Created dedicated configs based on one_ring patterns:

#### **OzSTAR** ([conf/ozstar.config](conf/ozstar.config))
- SLURM executor with 2000 queue size
- Bind mounts: `/fred`, `$HOME`
- Uses `$JOBFS` scratch space
- Auto-scaling resources on retries
- maxForks tuned per process (100-500)

#### **Hercules** ([conf/hercules.config](conf/hercules.config))
- SLURM executor with 10,000 queue size
- Bind mounts: `/hercules`, `/mandap`, `/mkfs`, `$HOME`
- Dynamic queue selection (`short.q` vs `long.q` vs `gpu.q`)
- Module loading: `jdk/17.0.6`
- `/tmp/$USER` scratch space

## Container Requirements

### Building a PRESTO Container

Your PRESTO Singularity image should include:

**Required binaries:**
- `readfile`
- `rfifind`
- `prepdata`
- `realfft`
- `rednoise`
- `zapbirds`
- `accelsearch` (with optional CUDA support)
- `prepfold`
- `single_pulse_search.py`

**Example Singularity definition:**

```singularity
Bootstrap: docker
From: ubuntu:22.04

%post
    apt-get update && apt-get install -y \
        build-essential \
        git \
        python3 \
        python3-numpy \
        python3-scipy \
        gfortran \
        libfftw3-dev \
        libglib2.0-dev \
        libcfitsio-dev \
        pgplot5

    # Install PRESTO
    git clone https://github.com/scottransom/presto /opt/presto
    cd /opt/presto/src
    make && make prep

    # Install Python libraries
    cd /opt/presto/python
    pip3 install .

%environment
    export PRESTO=/opt/presto
    export PATH=$PRESTO/bin:$PATH
    export LD_LIBRARY_PATH=$PRESTO/lib:$LD_LIBRARY_PATH
    export PYTHONPATH=$PRESTO/lib/python:$PYTHONPATH

%runscript
    exec "$@"
```

### Building the Container

```bash
# On a system with sudo/root
sudo singularity build presto_latest.sif presto.def

# Or using remote build
singularity build --remote presto_latest.sif presto.def
```

## Usage Examples

### Basic Usage with Singularity

```bash
nextflow run nexto_search.nf \
    -profile singularity \
    --presto_container /path/to/presto_latest.sif \
    --input observation.fil \
    --outdir results
```

### OzSTAR Cluster

```bash
nextflow run nexto_search.nf \
    -profile ozstar \
    --input observation.fil \
    --outdir results \
    --dm_low 0 --dm_high 200
```

### Hercules Cluster

```bash
nextflow run nexto_search.nf \
    -profile hercules \
    --input observation.fil \
    --outdir results \
    --dm_low 0 --dm_high 200
```

### Generic SLURM with Custom Container

```bash
nextflow run nexto_search.nf \
    -profile slurm \
    --presto_container /custom/path/presto.sif \
    --singularity_cachedir /custom/cache \
    --input observation.fil
```

## Configuration for Your Cluster

### 1. Set Container Path

Edit `nextflow.config` or create a cluster-specific config:

```groovy
params {
    presto_container = "/your/cluster/path/presto_latest.sif"
    singularity_cachedir = "/your/cluster/cache"
}
```

### 2. Configure Bind Mounts

Adjust `apptainer.runOptions` for your filesystem:

```groovy
apptainer.runOptions = '--env PYTHONNOUSERSITE=1 --nv -B /data -B /scratch -B $HOME'
```

### 3. Set Scratch Directory

```groovy
process.scratch = '$TMPDIR'  // or $JOBFS, /tmp/$USER, etc.
```

### 4. Tune Resource Limits

```groovy
params {
    max_cpus = 64       # Adjust to your cluster
    max_memory = '512.GB'
    max_time = '168.h'
}
```

## Creating a Custom Cluster Config

Based on OzSTAR/Hercules templates:

```bash
cp conf/ozstar.config conf/mycluster.config
```

Edit `conf/mycluster.config`:

1. **Change hostname validation:**
```groovy
if (!['mynode'].any { System.getenv('HOSTNAME')?.startsWith(it) }) {
    System.err.println "ERROR: Wrong cluster"
    System.exit(1)
}
```

2. **Set container paths:**
```groovy
params {
    presto_container = "/cluster/path/presto.sif"
    singularity_cachedir = "/cluster/cache"
}
```

3. **Configure bind mounts:**
```groovy
apptainer.runOptions = '--env PYTHONNOUSERSITE=1 --nv -B /your/data -B $HOME'
```

4. **Set executor:**
```groovy
executor {
    name = 'slurm'  # or pbs, sge, lsf
    pollInterval = '1 min'
    queueSize = 1000
}
```

5. **Add to main config:**

Edit `nextflow.config`:
```groovy
profiles {
    mycluster {
        includeConfig 'conf/mycluster.config'
    }
}
```

## GPU Support

For GPU-accelerated searches, ensure:

1. **Container has CUDA support:**
```bash
# Test in container
singularity exec --nv presto.sif accelsearch --help
```

2. **Enable GPU in config:**
```groovy
withName: 'ACCELSEARCH' {
    queue = 'gpu'
    clusterOptions = '--gres=gpu:1 --constraint=cuda'
}
```

3. **Run with GPU profile:**
```bash
nextflow run nexto_search.nf \
    -profile ozstar,gpu \
    --use_cuda true \
    --input observation.fil
```

## Troubleshooting

### Issue: Container not found

```bash
# Check container path
ls -lh /path/to/presto_latest.sif

# Set explicitly
nextflow run ... --presto_container /full/path/presto.sif
```

### Issue: Bind mount errors

```bash
# Add missing paths to runOptions
apptainer.runOptions = '--env PYTHONNOUSERSITE=1 -B /missing/path'
```

### Issue: PRESTO tools not found

```bash
# Test container
singularity exec presto.sif which rfifind
singularity exec presto.sif readfile --help
```

### Issue: Permission errors

```bash
# Check cache directory permissions
mkdir -p /path/to/cache
chmod 755 /path/to/cache

# Set in config
params.singularity_cachedir = "/writable/path"
```

### Issue: Out of memory in container

```bash
# Increase memory for processes
withName: 'ACCELSEARCH' {
    memory = '64.GB'
}
```

## Best Practices

### 1. **Use Cluster-Specific Configs**

✅ DO:
```bash
nextflow run nexto_search.nf -profile ozstar --input obs.fil
```

❌ DON'T:
```bash
nextflow run nexto_search.nf --input obs.fil  # Uses defaults
```

### 2. **Version Control Your Containers**

```bash
# Tag containers with versions
presto_v4.0.sif
presto_v4.1_cuda11.8.sif

# Reference specific versions
params.presto_container = "/images/presto_v4.0.sif"
```

### 3. **Test Container First**

```bash
# Test all required tools
singularity exec presto.sif bash << 'EOF'
which rfifind readfile prepdata realfft accelsearch prepfold
python3 -c "import presto"
EOF
```

### 4. **Use Shared Container Locations**

```bash
# Don't duplicate containers
# Use shared project directory
/project/pulsar_images/presto_latest.sif  ✅
~/my_personal_copy/presto.sif            ❌
```

### 5. **Monitor Resource Usage**

```bash
# Check Nextflow reports
firefox results/report.html

# Tune resources based on actual usage
withName: 'PREPDATA.*' {
    memory = { actual_usage * 1.2 }  # 20% buffer
}
```

## Advantages of Containerization

### ✅ Reproducibility
- Same environment on all clusters
- No dependency conflicts
- Version-controlled software stack

### ✅ Portability
- Run on any cluster with Singularity
- No manual PRESTO installation
- Easy to share and collaborate

### ✅ Isolation
- No conflicts with system libraries
- Clean environment per job
- Predictable behavior

### ✅ Simplified Management
- Single container for entire pipeline
- Easy updates (replace .sif file)
- No module loading complexity

## Migration from Non-Container Setup

If you have an existing non-container setup:

1. **Build or obtain PRESTO container**
2. **Test container:**
```bash
singularity exec presto.sif rfifind --help
```

3. **Set container path:**
```bash
nextflow run nexto_search.nf \
    -profile singularity \
    --presto_container /path/to/presto.sif \
    --input observation.fil
```

4. **Compare results with non-container run**

5. **Switch to cluster-specific profile**

## Summary

✅ All modules converted to bash
✅ All processes use Singularity containers
✅ Apptainer configuration with best practices
✅ Cluster-specific configs (OzSTAR, Hercules)
✅ GPU support enabled
✅ Auto-scaling resources on retries
✅ Optimized queue and fork limits

The pipeline is now fully containerized and ready for multi-cluster deployment!
