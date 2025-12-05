# NEXTO Cluster Configuration Guide

## Overview

NEXTO uses a modular configuration system where cluster-specific settings are isolated in separate config files. The main `nextflow.config` contains only base settings and profile declarations.

## Configuration Architecture

```
nextflow.config (base settings + profile declarations)
    ├── standard (local, single CPU)
    ├── local (local, multi-core)
    ├── singularity (local with containers)
    ├── test (minimal test run)
    └── HPC Clusters:
        ├── ozstar → conf/ozstar.config
        ├── hercules → conf/hercules.config
        └── contra → conf/contra.config
```

## Available Cluster Profiles

### 1. **OzSTAR** (Swinburne University)

**File**: [conf/ozstar.config](conf/ozstar.config)

**Executor**: SLURM
**Queue Size**: 2,000 concurrent jobs
**Container Path**: `/fred/oz418/singularity_images/`
**Bind Mounts**: `/fred`, `$HOME`
**Scratch**: `$JOBFS`
**Modules**: `apptainer`

**Usage**:
```bash
nextflow run nexto_search.nf -profile ozstar --input obs.fil
```

**Key Features**:
- Auto-scaling resources on retries
- Process-specific maxForks (100-500)
- SLURM integration with 1-minute polling

### 2. **Hercules** (MPIfR Bonn)

**File**: [conf/hercules.config](conf/hercules.config)

**Executor**: SLURM
**Queue Size**: 10,000 concurrent jobs
**Container Path**: `/hercules/scratch/vishnu/singularity_images/`
**Bind Mounts**: `/hercules`, `/mandap`, `/mkfs`, `$HOME`
**Scratch**: `/tmp/$USER`
**Modules**: `jdk/17.0.6`

**Usage**:
```bash
nextflow run nexto_search.nf -profile hercules --input obs.fil
```

**Key Features**:
- Dynamic queue selection (short.q, long.q, gpu.q)
- Time-based queue routing (≤4h → short.q)
- GPU queue for acceleration searches
- Very high queue capacity (10,000 jobs)

### 3. **Contra** (MPIfR Bonn)

**File**: [conf/contra.config](conf/contra.config)

**Executor**: HT-Condor
**Queue Size**: 1,500 concurrent jobs
**Container Path**: `/homes/vkrishnan/singularity_images/`
**Bind Mounts**: `/b`, `/bscratch`, `/homes`
**Scratch**: `false` (TMPFS not supported)
**Modules**: `jdk/17.0.4`, `apptainer`

**Usage**:
```bash
nextflow run nexto_search.nf -profile contra --input obs.fil
```

**Key Features**:
- HT-Condor executor
- GPU support via `request_GPUs = 1`
- CUDA environment variable passing
- Error strategy: retry or ignore

## Cluster Comparison

| Feature | OzSTAR | Hercules | Contra |
|---------|--------|----------|---------|
| **Executor** | SLURM | SLURM | HT-Condor |
| **Max Jobs** | 2,000 | 10,000 | 1,500 |
| **Queue System** | Single | Multi (short/long/gpu) | Single |
| **Scratch** | $JOBFS | /tmp/$USER | false |
| **GPU Support** | Yes | Yes (gpu.q) | Yes (Condor) |
| **Max CPUs** | 32 | 48 | 48 |
| **Max Memory** | 128 GB | 256 GB | 256 GB |
| **Max Time** | 168h | 168h | 240h |

## Creating a Custom Cluster Config

### Step 1: Copy Template

```bash
cp conf/slurm_example.config conf/mycluster.config
```

### Step 2: Customize Settings

Edit `conf/mycluster.config`:

```groovy
params {
    // Set your container paths
    presto_container = "/your/path/presto_latest.sif"
    singularity_cachedir = "/your/cache"

    // Set resource limits
    max_cpus = 64
    max_memory = '512.GB'
    max_time = '72.h'
}

// Module loading (if needed)
process.beforeScript = """
module load singularity
module load cuda/11.8
"""

// Apptainer configuration
apptainer {
    enabled = true
    runOptions = '--env PYTHONNOUSERSITE=1 --nv -B /your/data'
}

// Executor
executor {
    name = 'slurm'  // or 'pbs', 'sge', 'condor'
    queueSize = 500
}

process {
    executor = 'slurm'
    queue = 'normal'
    scratch = '$TMPDIR'

    // Customize resources per process...
}
```

### Step 3: Add to Main Config

Edit `nextflow.config`:

```groovy
profiles {
    mycluster {
        includeConfig 'conf/mycluster.config'
    }
}
```

### Step 4: Test

```bash
nextflow run nexto_search.nf -profile mycluster --input test.fil
```

## Configuration Elements

### Container Settings

```groovy
params {
    presto_container = "/path/to/presto_latest.sif"
    singularity_cachedir = "/path/to/cache"
}

apptainer {
    enabled = true
    autoMounts = true
    runOptions = '--env PYTHONNOUSERSITE=1 --nv -B /data'
    cacheDir = params.singularity_cachedir
    envWhitelist = 'APPTAINER_BINDPATH,APPTAINER_LD_LIBRARY_PATH'
}
```

### Executor Settings

#### SLURM
```groovy
executor {
    name = 'slurm'
    pollInterval = '1 min'
    queueSize = 1000
    submitRateLimit = '20 sec'
}

process {
    executor = 'slurm'
    queue = 'normal'
    clusterOptions = '--account=proj123'
}
```

#### PBS/Torque
```groovy
executor {
    name = 'pbs'
    pollInterval = '1 min'
    queueSize = 500
}

process {
    executor = 'pbs'
    queue = 'batch'
    clusterOptions = '-A proj123'
}
```

#### HT-Condor
```groovy
executor {
    name = 'condor'
    pollInterval = '30 sec'
    queueSize = 1500
}

process {
    executor = 'condor'
    clusterOptions = 'request_GPUs = 1'  // For GPU jobs
}
```

### Resource Allocation

**NEXTO uses explicit process-specific resource allocation** (no label-based resources). Each process has explicit CPU, memory, and time allocations optimized for pulsar searching workloads:

```groovy
// Example: Process-specific resource allocation
withName: 'ACCELSEARCH' {
    cpus = {params.use_cuda ? 1 : 16}
    memory = { check_max(8.GB * task.attempt, 'memory') }
    time = { check_max(2.d * task.attempt, 'time') }
    queue = { params.use_cuda ? 'gpu' : 'normal' }
    clusterOptions = { params.use_cuda ? '--gres=gpu:1' : '' }
    maxForks = 200
}

withName: 'RFIFIND' {
    cpus = 1
    memory = { check_max(8.GB * task.attempt, 'memory') }
    time = { check_max(4.h * task.attempt, 'time') }
    maxForks = 400
}
```

**Standard Resource Allocations** (consistent across all HPC clusters):

| Process | CPUs | Memory | Time | maxForks |
|---------|------|--------|------|----------|
| FILTOOL | 16 | 8GB | 4h | 1 |
| RFIFIND | 1 | 8GB | 4h | 400 |
| PREPDATA.* | 1 | 4GB | 4h | 400 |
| ACCELSEARCH | 16 (1 if GPU) | 8GB | 2d | 200 |
| ACCELSEARCH_ZMAX0 | 8 | 8GB | 4h | 200 |
| PREPFOLD.* | 1 | 8GB | 4h | 400 |
| PSRFOLD_PULSARX | 16 | 8GB | 4h | 400 |
| SINGLE_PULSE_SEARCH | 4 | 8GB | 4h | 500 |
| MAKE_ZAPLIST\|COMBINE_CANDIDATES\|ACCELSIFT | 2 | 4GB | 1h | 500 |

### Queue Selection

**Static:**
```groovy
process.queue = 'normal'
```

**Dynamic (time-based):**
```groovy
queue = { task.time <= 4.h ? 'short' : 'long' }
```

**Process-specific:**
```groovy
withName: 'ACCELSEARCH' {
    queue = 'gpu'
}
```

### Error Handling

```groovy
process {
    errorStrategy = {
        task.exitStatus in 137..140 || task.exitStatus == 124 ? 'retry' : 'finish'
    }
    maxRetries = 3
    maxErrors = '-1'
}
```

**Exit codes**:
- `137-140`: Out of memory, killed
- `124`: Timeout
- Others: Job failed

**Strategies**:
- `retry`: Retry failed job
- `finish`: Continue pipeline
- `ignore`: Ignore error
- `terminate`: Stop pipeline

### Scratch Space

```groovy
// Use cluster scratch
process.scratch = '$TMPDIR'  // or '$JOBFS', '/tmp/$USER'

// Disable scratch
process.scratch = false

// Process-specific
withName: 'ACCELSIFT' {
    scratch = false
}
```

### Module Loading

```groovy
// Global
process.beforeScript = """
module load apptainer
module load cuda/11.8
"""

// Cluster-specific
if (System.getenv('HOSTNAME')?.startsWith('ozstar')) {
    process.module = 'apptainer'
}
```

### GPU Configuration

#### SLURM
```groovy
withName: 'ACCELSEARCH' {
    queue = 'gpu'
    clusterOptions = '--gres=gpu:1 --constraint=cuda'
}
```

#### HT-Condor
```groovy
withName: 'ACCELSEARCH' {
    clusterOptions = 'request_GPUs = 1'
}

apptainer.runOptions = '--env="CUDA_VISIBLE_DEVICES=${CUDA_VISIBLE_DEVICES}"'
```

### Auto-Scaling Resources

```groovy
// Scale resources on retries
cpus = { check_max(task.attempt * 2, 'cpus') }
memory = { check_max(4.GB * task.attempt, 'memory') }
time = { check_max(4.h * task.attempt, 'time') }

// Attempt 1: 2 CPUs, 4 GB, 4h
// Attempt 2: 4 CPUs, 8 GB, 8h
// Attempt 3: 8 CPUs, 16 GB, 16h
```

## Testing Your Configuration

### 1. Dry Run

```bash
nextflow run nexto_search.nf -profile mycluster --input test.fil -dry-run
```

### 2. Small Test

```bash
nextflow run nexto_search.nf \
    -profile mycluster,test \
    --input test.fil \
    --dm_high 10
```

### 3. Check Container

```bash
singularity exec ${params.presto_container} which rfifind
```

### 4. Monitor Execution

```bash
# Watch jobs
watch squeue -u $USER  # SLURM
watch qstat -u $USER   # PBS
condor_q              # Condor

# Check logs
tail -f .nextflow.log
```

### 5. Verify Results

```bash
# Check outputs
ls -lh results/*/

# View reports
firefox results/report.html
firefox results/timeline.html
```

## Troubleshooting

### Jobs Not Submitting

**Check executor:**
```groovy
executor.name = 'slurm'  // Correct
executor = 'slurm'       // Wrong
```

**Check queue exists:**
```bash
sinfo  # SLURM
qstat -Q  # PBS
```

### Out of Memory Errors

**Increase memory:**
```groovy
withName: 'ACCELSEARCH' {
    memory = '64.GB'  // Increase
}
```

**Check actual usage:**
```bash
grep memory results/report.html
```

### Container Not Found

**Check path:**
```bash
ls -lh /path/to/presto_latest.sif
```

**Set explicitly:**
```bash
nextflow run ... --presto_container /full/path/presto.sif
```

### Bind Mount Errors

**Add missing paths:**
```groovy
apptainer.runOptions = '-B /missing/path -B /another/path'
```

### Permission Errors

**Check cache directory:**
```bash
mkdir -p /path/to/cache
chmod 755 /path/to/cache
```

## Best Practices

### 1. ✅ Use Cluster-Specific Configs

Keep cluster settings isolated in `conf/` directory.

### 2. ✅ Test Before Production

Always test with minimal data first.

### 3. ✅ Monitor Resource Usage

Check reports to tune resource allocation.

### 4. ✅ Use Auto-Scaling

Let resources scale on retries:
```groovy
memory = { check_max(4.GB * task.attempt, 'memory') }
```

### 5. ✅ Set Appropriate Limits

Don't request more than cluster allows:
```groovy
params.max_cpus = 32  // Cluster limit
params.max_memory = '128.GB'
```

### 6. ✅ Use Meaningful Profile Names

```bash
-profile ozstar     # Clear
-profile cluster1   # Unclear
```

### 7. ✅ Document Your Config

Add comments explaining cluster-specific choices.

### 8. ✅ Version Control Configs

Track changes to cluster configurations.

## Summary

✅ **3 HPC cluster configs** - OzSTAR, Hercules, Contra
✅ **Clean separation** - Base vs cluster-specific settings
✅ **No cloud profiles** - Focused on HPC use cases
✅ **SLURM & Condor** - Both executors supported
✅ **Easy customization** - Template-based approach
✅ **Auto-scaling** - Resources scale on retries
✅ **Container-first** - Singularity/Apptainer throughout

Your NEXTO installation is now ready for multi-cluster deployment!
