// PULSAR_MINER Nextflow Modules
// Each module wraps a PRESTO subprocess for distributed cluster execution

// ============================================================================
// INPUT VALIDATION & METADATA EXTRACTION
// ============================================================================

process READFILE {
    tag "$observation"
    label 'presto'
    container "${params.presto_container}"

    input:
    path observation

    output:
    tuple path(observation), path("${observation}.info"), emit: obs_with_info

    script:
    """
    readfile ${observation} > ${observation}.info
    """
}

// ============================================================================
// RFI DETECTION & MITIGATION
// ============================================================================

process RFIFIND {
    tag "$observation"
    label 'presto'
    label 'process_medium'
    container "${params.presto_container}"
    publishDir "${params.outdir}/01_RFIFIND", mode: 'copy'

    input:
    path observation
    val time_interval
    val freq_interval
    val extra_flags

    output:
    tuple path(observation), path("${basename}_rfifind.*"), emit: rfi_products
    path "${basename}_rfifind.mask", emit: mask
    path "*.ps", emit: plots optional true

    script:
    basename = observation.baseName
    """
    rfifind -time ${time_interval} -freqsig ${freq_interval} ${extra_flags} -o ${basename} ${observation}
    """
}

// ============================================================================
// DEDISPERSION
// ============================================================================

process PREPDATA {
    tag "${observation}_DM${dm}_nobary${nobary}"
    label 'presto'
    label 'process_high'
    container "${params.presto_container}"
    maxForks 2

    input:
    tuple path(observation), path(rfi_products), val(dm), val(downsample), val(nobary), val(extra_flags)

    output:
    tuple val(dm), path("*.dat"), path("*.inf"), emit: timeseries

    script:
    basename = observation.baseName
    dm_str = String.format("%.2f", dm).replace('.', 'p')
    nobary_flag = nobary ? "-nobary" : ""
    // Find the mask file from rfi_products
    mask_file = rfi_products.find { it.name.endsWith('.mask') }
    """
    prepdata ${nobary_flag} -dm ${dm} -downsamp ${downsample} -mask ${mask_file} ${extra_flags} -o ${basename}_DM${dm_str} ${observation}
    """
}

// ============================================================================
// FFT PROCESSING
// ============================================================================

process REALFFT {
    tag "${datfile.baseName}"
    label 'presto'
    label 'process_high'
    container "${params.presto_container}"

    input:
    tuple val(dm), path(datfile), path(inffile)

    output:
    tuple val(dm), path("*.fft"), path(inffile), emit: fft_products

    script:
    """
    realfft ${datfile}
    """
}

process REDNOISE {
    tag "${fftfile.baseName}"
    label 'presto'
    label 'process_medium'
    container "${params.presto_container}"

    input:
    tuple val(dm), path(fftfile), path(inffile)

    output:
    tuple val(dm), path("*_red.fft"), path("*_red.inf"), emit: rednoise_fft

    script:
    """
    rednoise ${fftfile}
    cp ${inffile} ${fftfile.baseName}_red.inf
    """
}

// ============================================================================
// BIRDIE/RFI MASKING
// ============================================================================

process ZAPBIRDS {
    tag "${fftfile.baseName}"
    label 'presto'
    container "${params.presto_container}"
    publishDir "${params.outdir}/02_BIRDIES", mode: 'copy', pattern: "*.zaplist"

    input:
    tuple val(dm), path(fftfile), path(inffile)
    path zaplist

    output:
    tuple val(dm), path("*_zapped.fft"), path("*_zapped.inf"), emit: zapped_fft
    path "*.zaplist", emit: zaplist_used

    script:
    """
    # Use the zaplist directly with zapbirds
    zapbirds -zap -zapfile ${zaplist} ${fftfile}
    # Rename the output FFT file
    mv ${fftfile.baseName}.fft ${fftfile.baseName}_zapped.fft
    # Copy and rename the inf file to match
    cp ${inffile} ${fftfile.baseName}_zapped.inf
    # Copy zaplist for publishDir
    cp ${zaplist} ${fftfile.baseName}.zaplist
    """
}

process ACCELSEARCH_ZMAX0 {
    tag "${fftfile.baseName}_zmax0"
    label 'presto'
    label 'process_low'
    container "${params.presto_container}"
    publishDir "${params.outdir}/02_BIRDIES", mode: 'copy', pattern: "*_ACCEL_0.cand"

    input:
    tuple val(dm), path(fftfile), path(inffile)
    val numharm

    output:
    tuple val(dm), path("*_ACCEL_0"), path("*_ACCEL_0.cand"), emit: accel_zero

    script:
    """
    accelsearch -zmax 0 -numharm ${numharm} ${fftfile}
    """
}

// ============================================================================
// ACCELERATION SEARCH
// ============================================================================

process ACCELSEARCH {
    tag "${fftfile.baseName}_z${zmax}_w${wmax}"
    label 'presto'
    label 'process_high'
    container "${params.presto_container}"
    publishDir "${params.outdir}/03_DEDISPERSION", mode: 'copy', pattern: "*_ACCEL_*"

    input:
    tuple val(dm), path(fftfile), path(inffile)
    tuple val(zmax), val(wmax)
    val numharm
    val use_cuda
    val gpu_id
    val extra_flags

    output:
    tuple val(dm), val(zmax), val(wmax), path("*_ACCEL_${zmax}"), path("*_ACCEL_${zmax}.cand"), emit: candidates

    script:
    cuda_flag = use_cuda ? "-cuda ${gpu_id}" : ""
    wmax_flag = wmax > 0 ? "-wmax ${wmax}" : ""
    """
    accelsearch -zmax ${zmax} ${wmax_flag} -numharm ${numharm} ${cuda_flag} ${extra_flags} ${fftfile}
    """
}

// ============================================================================
// CANDIDATE SIFTING
// ============================================================================

process ACCELSIFT {
    tag "sift_DM${dm}"
    label 'presto'
    container "${params.presto_container}"
    publishDir "${params.outdir}/04_SIFTING", mode: 'copy'

    input:
    tuple val(dm), path(accel_files), path(cand_files)
    val sigma_threshold

    output:
    tuple val(dm), path("*.sift"), path("*.cands"), emit: sifted_candidates

    script:
    """
    #!/bin/bash
    # Sift candidates by sigma threshold
    # Extract candidates with sigma >= threshold (sigma is 2nd column)

    # Process all ACCEL candidate files
    for cand_file in *_ACCEL_*.cand; do
        if [ -f "\$cand_file" ]; then
            grep -v "^#" "\$cand_file" | awk -v thresh=${sigma_threshold} '\$2 >= thresh {print}' >> sifted.cands
        fi
    done

    # If no candidates found, create empty file
    if [ ! -f sifted.cands ]; then
        touch sifted.cands
    fi

    # Create sift summary
    num_cands=\$(wc -l < sifted.cands 2>/dev/null || echo 0)
    echo "Sifted candidates with sigma >= ${sigma_threshold}" > sifted.sift
    echo "Total candidates: \$num_cands" >> sifted.sift
    """
}

// ============================================================================
// CANDIDATE FOLDING
// ============================================================================

process PREPFOLD {
    tag "${observation.baseName}_cand${cand_num}"
    label 'presto'
    label 'process_high'
    container "${params.presto_container}"
    publishDir "${params.outdir}/05_FOLDING", mode: 'copy'

    input:
    tuple path(observation), path(mask), val(cand_num), val(dm), val(period), val(accel)
    val npart
    val dmstep
    val extra_flags

    output:
    tuple val(cand_num), path("*.pfd"), path("*.pfd.ps"), path("*.bestprof"), emit: folded_candidates

    script:
    basename = observation.baseName
    """
    prepfold -noxwin -accelcand ${cand_num} -dm ${dm} -dmstep ${dmstep} -npart ${npart} -mask ${mask} ${extra_flags} -o ${basename}_cand${cand_num} ${observation}
    """
}

process PREPFOLD_TIMESERIES {
    tag "${datfile.baseName}_cand${cand_num}"
    label 'presto'
    label 'process_high'
    container "${params.presto_container}"
    publishDir "${params.outdir}/05_FOLDING", mode: 'copy'

    input:
    tuple val(dm), path(datfile), path(inffile), val(cand_num), val(period), val(accel)
    val npart
    val extra_flags

    output:
    tuple val(cand_num), path("*.pfd"), path("*.pfd.ps"), path("*.bestprof"), emit: folded_candidates

    script:
    basename = datfile.baseName
    """
    prepfold -noxwin -p ${period} -pd ${accel} -npart ${npart} ${extra_flags} -o ${basename}_cand${cand_num} ${datfile}
    """
}

// ============================================================================
// SINGLE PULSE SEARCH
// ============================================================================

process SINGLE_PULSE_SEARCH {
    tag "${datfile.baseName}"
    label 'presto'
    label 'process_medium'
    container "${params.presto_container}"
    publishDir "${params.outdir}/06_SINGLE_PULSES", mode: 'copy'

    input:
    tuple val(dm), path(datfile), path(inffile)
    val threshold

    output:
    tuple val(dm), path("*.singlepulse"), emit: single_pulses

    script:
    """
    single_pulse_search.py --noplot --threshold ${threshold} ${datfile}
    """
}

// ============================================================================
// UTILITY PROCESSES
// ============================================================================

process MAKE_ZAPLIST {
    tag "create_zaplist"
    label 'presto'
    container "${params.presto_container}"
    publishDir "${params.outdir}/02_BIRDIES", mode: 'copy'

    input:
    path accel_cand_files
    val freq_tolerance

    output:
    path "birdies.zaplist", emit: zaplist

    script:
    """
    #!/bin/bash
    # Create birds file from ACCEL_0 candidate files
    # Extract: sigma, frequency, bin_width, numharm, ipow, cpow, periods (columns from .cand file)

    # Process all ACCEL_0 candidate files and extract relevant columns
    for cand_file in *_ACCEL_0.cand; do
        if [ -f "\$cand_file" ]; then
            # Skip header lines and extract: frequency (col 3), bin_width can be calculated or approximated
            # For simplicity, we output frequency and other key parameters
            grep -v "^#" "\$cand_file" | awk '{print \$3, \$4, \$5, 1, 0}' >> birdies.birds
        fi
    done

    # Use makezaplist.py to create the zaplist from the birds file
    # If makezaplist.py is not available, fallback to simple frequency list
    if command -v makezaplist.py &> /dev/null; then
        makezaplist.py birdies.birds -o birdies.zaplist
    else
        # Fallback: just extract unique frequencies
        awk '{print \$1}' birdies.birds 2>/dev/null | sort -u > birdies.zaplist
    fi

    # If no candidates found, create empty zaplist
    if [ ! -f birdies.zaplist ] || [ ! -s birdies.zaplist ]; then
        touch birdies.zaplist
    fi
    """
}

process COMBINE_CANDIDATES {
    tag "combine_all_dms"
    label 'presto'
    container "${params.presto_container}"
    publishDir "${params.outdir}/04_SIFTING", mode: 'copy'

    input:
    path all_cand_files

    output:
    path "all_candidates.txt", emit: combined_cands

    script:
    """
    cat *_ACCEL_*.cand | grep -v "^#" | sort -k2 -rn > all_candidates.txt
    """
}
