# NEXTO - Nextflow PRESTO pipeline

A scalable Nextflow implementation of [PULSAR_MINER](https://github.com/alex88ridolfi/PULSAR_MINER) for distributed cluster computing.

## Overview

NEXTO converts the Python-based PULSAR_MINER pipeline into modular Nextflow processes, enabling:
- **Parallelization**: Run hundreds of DM trials simultaneously across cluster nodes
- **Scalability**: Scale from laptops to HPC clusters to cloud platforms
- **Reproducibility**: Containerized execution with Docker/Singularity
- **Resume capability**: Automatic resume from failed/interrupted runs
- **Resource optimization**: Dynamic resource allocation per process

## Architecture

### Pipeline Stages

1. **Optional Filterbank Processing** (`FILTOOL`) - Time/freq decimation and RFI filtering (PulsarX)
2. **RFI Detection** (`RFIFIND`) - Identifies and masks radio frequency interference
3. **Dedispersion** (`PREPDATA`) - Creates DM trial timeseries (highly parallelized)
4. **Birdie Detection & Zaplist Creation** (`ACCELSEARCH_ZMAX0`, `MAKE_ZAPLIST`) - RFI line identification (runs once to create frequency mask)
5. **Acceleration Search** (`ACCELSEARCH`) - Periodic signal detection with acceleration (parallelized per DM, uses zaplist)
6. **Candidate Sifting** (`ACCELSIFT`) - Candidate filtering by sigma threshold and harmonic removal
7. **Folding** (`PREPFOLD_FROM_CANDFILE`, `PSRFOLD_PULSARX`) - Creates phase-folded profiles for top candidates
8. **Single Pulse Search** (`SINGLE_PULSE_SEARCH`) - Transient detection

### Module Structure

All processes are defined in `modules.nf` with clear separation of concerns:
- Each PRESTO/PulsarX tool has its own process
- Input/output channels clearly defined
- Explicit resource requirements per process (no label-based allocation)
- Publishing strategies for intermediate results
- Support for both PRESTO and PulsarX folding backends

## Requirements

### Software Dependencies

- Nextflow ≥23.04.0
- PRESTO 3.0 or 4.0 (incompatible with PRESTO 5.0.0+)
- Python 3.8+ with NumPy
- Optional: NVIDIA CUDA ≤11.8 for GPU acceleration

### Hardware Recommendations

- **CPU**: Multi-core processor (≥8 cores recommended)
- **Memory**: ≥32 GB RAM
- **Storage**: SSD/NVMe for reduced I/O latency
- **GPU**: NVIDIA GPU for accelerated searches (optional)

## Installation

### 1. Install Nextflow

```bash
curl -s https://get.nextflow.io | bash
chmod +x nextflow
sudo mv nextflow /usr/local/bin/
```

### 2. Install PRESTO

Follow the [PRESTO installation guide](https://www.cv.nrao.edu/~sransom/presto/).

### 3. Clone NEXTO

```bash
git clone <repository-url> nexto
cd nexto
```

### 4. Configure PRESTO Path

Edit `nextflow.config` and set:

```groovy
params.presto_path = "/path/to/your/presto"
```

## Usage

### Basic Usage

```bash
nextflow run nexto_search.nf --input observation.fil --outdir results
```

### Common Options

```bash
nextflow run nexto_search.nf \
    --input observation.fil \
    --outdir results \
    --dm_low 0 \
    --dm_high 200 \
    --dm_step 0.5 \
    --zmax 100 \
    --numharm 16 \
    --sigma_threshold 7.0
```

### Cluster Execution

NEXTO includes pre-configured profiles for three HPC clusters. See [CLUSTER_CONFIGS.md](CLUSTER_CONFIGS.md) for detailed documentation.

#### OzSTAR (Swinburne)

```bash
nextflow run nexto_search.nf \
    -profile ozstar \
    --input observation.fil \
    --outdir results
```

#### Hercules (MPIfR Bonn)

```bash
nextflow run nexto_search.nf \
    -profile hercules \
    --input observation.fil \
    --outdir results
```

#### Contra (MPIfR Bonn)

```bash
nextflow run nexto_search.nf \
    -profile contra \
    --input observation.fil \
    --outdir results
```

#### GPU Acceleration

Enable GPU acceleration on supported clusters:

```bash
nextflow run nexto_search.nf \
    -profile hercules \
    --input observation.fil \
    --use_cuda true
```

### Resume Failed Runs

Nextflow automatically resumes from the last successful step:

```bash
nextflow run nexto_search.nf --input observation.fil -resume
```

## Configuration

### Parameters

| Parameter | Default | Description |
|-----------|---------|-------------|
| `--input` | *required* | Input observation file (.fil or .fits) |
| `--outdir` | `results` | Output directory |
| `--dm_low` | `0.0` | Minimum DM to search |
| `--dm_high` | `100.0` | Maximum DM to search |
| `--dm_step` | `0.5` | DM step size |
| `--downsample` | `1` | Downsampling factor |
| `--zmax` | `50` | Maximum acceleration |
| `--wmax` | `0` | Maximum jerk (0 = disabled) |
| `--numharm` | `8` | Number of harmonics to sum |
| `--sigma_threshold` | `6.0` | Minimum sigma for candidates |
| `--rfifind_time` | `2.0` | Time interval for rfifind (sec) |
| `--rfifind_freqsig` | `4.0` | Frequency sigma for rfifind |
| `--npart` | `50` | Number of phase bins for folding |
| `--use_cuda` | `false` | Enable GPU acceleration |
| `--gpu_id` | `0` | GPU device ID |
| `--enable_jerk` | `false` | Enable jerk search |
| `--enable_single_pulse` | `true` | Enable single pulse search |
| `--sp_threshold` | `5.0` | Single pulse sigma threshold |

### Profiles

**HPC Cluster Profiles:**
- `ozstar` - OzSTAR (Swinburne) SLURM cluster
- `hercules` - Hercules (MPIfR Bonn) SLURM cluster
- `contra` - Contra (MPIfR Bonn) HT-Condor cluster

**Local Profiles:**
- `standard` - Local execution (single CPU)
- `local` - Local execution (multi-core with Apptainer)

See [CLUSTER_CONFIGS.md](CLUSTER_CONFIGS.md) for detailed cluster configuration documentation.

## Output Structure

```
results/
├── 01_RFIFIND/          # RFI detection masks and plots
├── 02_BIRDIES/          # RFI line lists (zapfiles)
├── 03_DEDISPERSION/     # Dedispersed timeseries and FFTs
├── 04_SIFTING/          # Sifted candidate lists
├── 05_FOLDING/          # Folded profiles and plots (.pfd, .ps, .bestprof)
├── 06_SINGLE_PULSES/    # Single pulse detections
├── pipeline_trace.txt   # Execution trace
├── timeline.html        # Execution timeline
├── report.html          # Execution report
└── pipeline_dag.svg     # Pipeline DAG visualization
```

## Performance Optimization

### Parallelization Strategy

NEXTO achieves massive parallelization through:

1. **DM trials**: Each DM is processed independently (200 DMs = 200 parallel jobs)
2. **Acceleration search**: Each DM's FFT searched independently
3. **Single pulse search**: Each dedispersed timeseries searched in parallel

Example: For 200 DM trials with 100 available CPUs:
- Original PULSAR_MINER: ~10-20 hours (sequential)
- NEXTO: ~1-2 hours (parallel)

### Resource Tuning

NEXTO uses explicit resource allocation for all processes. Resources are standardized across all HPC clusters:

| Process | CPUs | Memory | Time | maxForks |
|---------|------|--------|------|----------|
| FILTOOL | 16 | 8GB | 4h | 1 |
| RFIFIND | 1 | 8GB | 4h | 400 |
| PREPDATA | 1 | 4GB | 4h | 400 |
| ACCELSEARCH | 16 (1 if GPU) | 8GB | 2d | 200 |
| ACCELSEARCH_ZMAX0 | 8 | 8GB | 4h | 200 |
| PREPFOLD | 1 | 8GB | 4h | 400 |
| PSRFOLD_PULSARX | 16 | 8GB | 4h | 400 |
| SINGLE_PULSE_SEARCH | 4 | 8GB | 4h | 500 |

Resources scale automatically on retries using `check_max()` with task.attempt multiplier.

To customize resources for your cluster, edit the appropriate config file in `conf/` directory. See [CLUSTER_CONFIGS.md](CLUSTER_CONFIGS.md) for details.

## Containerization

### Docker

Build a PRESTO Docker image:

```dockerfile
FROM ubuntu:22.04

RUN apt-get update && apt-get install -y \
    build-essential \
    git \
    python3 \
    python3-numpy \
    pgplot5 \
    libfftw3-dev \
    libglib2.0-dev

# Install PRESTO
RUN git clone https://github.com/scottransom/presto /opt/presto
WORKDIR /opt/presto/src
RUN make && make prep && make clean

ENV PRESTO=/opt/presto
ENV PATH=$PRESTO/bin:$PATH
ENV LD_LIBRARY_PATH=$PRESTO/lib:$LD_LIBRARY_PATH
ENV PYTHONPATH=$PRESTO/lib/python:$PYTHONPATH
```

Run with Docker:

```bash
nextflow run nexto_search.nf -profile docker --input observation.fil
```

### Singularity

```bash
singularity build presto.sif docker://your-presto-image:latest
nextflow run nexto_search.nf -profile singularity --input observation.fil
```

## Advanced Usage

### Custom DM Trials

Create a custom DM list file:

```python
# generate_dms.py
import numpy as np
dms = np.concatenate([
    np.arange(0, 50, 0.3),
    np.arange(50, 200, 1.0),
    np.arange(200, 500, 2.0)
])
np.savetxt('dm_list.txt', dms, fmt='%.2f')
```

Modify the workflow to read from file instead of generating range.

### Batch Processing

Process multiple observations:

```bash
#!/bin/bash
for obs in observations/*.fil; do
    nextflow run nexto_search.nf \
        -profile slurm \
        --input $obs \
        --outdir results/$(basename $obs .fil) \
        -resume
done
```

## Comparison with PULSAR_MINER

| Feature | PULSAR_MINER | NEXTO |
|---------|--------------|-------|
| Language | Python | Nextflow DSL2 |
| Execution | Sequential with threading | Fully parallel |
| Cluster support | Manual scripting | Native (10+ schedulers) |
| Resume | Checkpoint-based | Automatic |
| Scalability | Limited by threads | Unlimited |
| Monitoring | Log files | HTML reports + timeline |
| Resource management | Manual | Dynamic per-process |
| Cloud support | Manual | Native (AWS, GCP, Azure) |

## Troubleshooting

### Common Issues

**Issue**: `command not found: rfifind`
**Solution**: Ensure PRESTO is in PATH. Check `params.presto_path` in config.

**Issue**: Out of memory errors
**Solution**: Increase memory allocation in `nextflow.config` for specific processes.

**Issue**: Too many jobs submitted
**Solution**: Adjust `executor.queueSize` and `submitRateLimit` in config.

### Debug Mode

Run with debug output:

```bash
nextflow run nexto_search.nf --input observation.fil -with-trace -with-dag dag.html
```

## Citation

If you use NEXTO, please cite:

1. Original PULSAR_MINER: [alex88ridolfi/PULSAR_MINER](https://github.com/alex88ridolfi/PULSAR_MINER)
2. PRESTO: Ransom, S. M. (2001), PhD thesis, Harvard University
3. Nextflow: Di Tommaso et al. (2017) Nature Biotechnology

## License

Same as PULSAR_MINER.

## Contributing

Contributions welcome! Please open issues or pull requests.

## Contact

For questions or issues, please open a GitHub issue.
