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
    publishDir "${params.outdir}/${observation.baseName}/01_RFIFIND", mode: 'copy'

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
    publishDir "${params.outdir}/${observation.baseName}/02_TIMESERIES", mode: 'copy', enabled: params.publish_timeseries
    maxForks 2

    input:
    tuple path(observation), path(rfi_products), val(dm), val(downsample), val(nobary), val(extra_flags)

    output:
    tuple val(dm), path("*.dat"), path("*.inf"), emit: timeseries

    script:
    basename = observation.baseName
    dm_str = String.format("%.2f", dm as Double)  // Keep decimal point for PRESTO sifting compatibility
    nobary_flag = nobary ? "-nobary" : ""
    // Find the mask file from rfi_products
    mask_file = rfi_products.find { it.name.endsWith('.mask') }
    """
    prepdata ${nobary_flag} -dm ${dm} -downsamp ${downsample} -mask ${mask_file} ${extra_flags} -o ${basename}_DM${dm_str} ${observation}
    """
}

process SPLIT_DATFILE {
    tag "${datfile.baseName}_${segment_name}_${chunk_num}"
    label 'presto'
    container "${params.presto_container}"

    input:
    tuple val(dm), path(datfile), path(inffile), val(segment_name), val(fraction), val(chunk_num), val(total_chunks)

    output:
    tuple val(dm), val(segment_name), val(chunk_num), path("*_${segment_name}_*.dat"), path("*_${segment_name}_*.inf"), emit: segments

    script:
    basename = datfile.baseName
    """
    #!/bin/bash

    # Read number of samples from .inf file
    num_samples=\$(grep "Number of bins in the time series" ${inffile} | awk -F'=' '{print \$2}' | tr -d ' ')

    # Calculate samples per segment (using awk instead of bc)
    samples_per_chunk=\$(awk "BEGIN {printf \\"%.0f\\", \$num_samples * ${fraction}}")

    # Ensure even number of samples
    if [ \$((samples_per_chunk % 2)) -ne 0 ]; then
        samples_per_chunk=\$((samples_per_chunk - 1))
    fi

    # Calculate starting fraction (prepdata -start expects fraction, not sample number)
    start_fraction=\$(awk "BEGIN {printf \\"%.6f\\", (${chunk_num} - 1) * ${fraction}}")

    # Use prepdata to split the file (it will create the .inf automatically)
    prepdata -nobary -dm 0 -start \$start_fraction -numout \$samples_per_chunk -o ${basename}_${segment_name}_${chunk_num} ${datfile}
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
    publishDir "${params.outdir}/${fftfile.name.split('_DM')[0]}/02_BIRDIES", mode: 'copy', pattern: "*.zaplist"

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
    publishDir "${params.outdir}/${fftfile.name.split('_DM')[0]}/02_BIRDIES", mode: 'copy', pattern: "*_ACCEL_0.cand"

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
    publishDir {
        def obs_name = fftfile.name.split('_DM')[0]
        // Extract segment label from filename (e.g., _half_1 or _full)
        def segment_label = 'full'
        if (fftfile.name.contains('_half_')) {
            def chunk = fftfile.name.split('_half_')[1].split('_')[0]
            segment_label = "half_${chunk}"
        } else if (fftfile.name.contains('_quarter_')) {
            def chunk = fftfile.name.split('_quarter_')[1].split('_')[0]
            segment_label = "quarter_${chunk}"
        } else if (fftfile.name.contains('_third_')) {
            def chunk = fftfile.name.split('_third_')[1].split('_')[0]
            segment_label = "third_${chunk}"
        }
        "${params.outdir}/${obs_name}/03_DEDISPERSION/${segment_label}"
    }, mode: 'copy', pattern: "*_ACCEL_*"

    input:
    tuple val(dm), path(fftfile), path(inffile)
    tuple val(zmax), val(wmax)
    val numharm
    val use_cuda
    val gpu_id
    val extra_flags

    output:
    tuple val(dm), val(zmax), val(wmax), path("*_ACCEL_${zmax}"), path("*_ACCEL_${zmax}.cand"), path(inffile), emit: candidates

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
    tag "sift_z${zmax}_w${wmax}"
    label 'presto'
    container "${params.presto_container}"

    // Extract observation basename and segment from first accel file
    publishDir {
        def first_file = accel_files instanceof List ? accel_files[0] : accel_files
        def obs_name = first_file.name.split('_DM')[0]
        // Extract segment label from filename (e.g., _half_1 or _full)
        def segment_label = 'full'
        if (first_file.name.contains('_half_')) {
            def chunk = first_file.name.split('_half_')[1].split('_')[0]
            segment_label = "half_${chunk}"
        } else if (first_file.name.contains('_quarter_')) {
            def chunk = first_file.name.split('_quarter_')[1].split('_')[0]
            segment_label = "quarter_${chunk}"
        } else if (first_file.name.contains('_third_')) {
            def chunk = first_file.name.split('_third_')[1].split('_')[0]
            segment_label = "third_${chunk}"
        }
        "${params.outdir}/${obs_name}/04_SIFTING/${segment_label}"
    }, mode: 'copy', pattern: "*.txt"

    input:
    tuple val(zmax), val(wmax), path(accel_files)
    val sigma_threshold
    val period_min
    val period_max
    val flag_remove_duplicates
    val flag_remove_harmonics

    output:
    path "best_candidates_z${zmax}_w${wmax}.txt", emit: sifted_candidates
    path "fold_params_z${zmax}_w${wmax}.txt", emit: fold_params

    script:
    wmax_suffix = wmax > 0 ? "_JERK_${wmax}" : ""
    dup_flag = flag_remove_duplicates ? "--remove-duplicates" : ""
    harm_flag = flag_remove_harmonics ? "--remove-harmonics" : ""
    """
    # Find all ACCEL files for this zmax/wmax combination
    accel_list=(*_ACCEL_${zmax}${wmax_suffix})

    if [ \${#accel_list[@]} -eq 0 ]; then
        echo "No candidates found" > best_candidates_z${zmax}_w${wmax}.txt
        touch fold_params_z${zmax}_w${wmax}.txt
        exit 0
    fi

    # Run custom sifting script
    ${projectDir}/bin/sift_candidates.py \
        \${accel_list[@]} \
        --min-period ${period_min} \
        --max-period ${period_max} \
        --sigma-threshold ${sigma_threshold} \
        ${dup_flag} \
        ${harm_flag} \
        --max-cands-to-fold ${params.max_cands_to_fold} \
        --output best_candidates_z${zmax}_w${wmax}.txt \
        --fold-params fold_params_z${zmax}_w${wmax}.txt
    """
}

// ============================================================================
// CANDIDATE PARSING
// ============================================================================

process PARSE_SIFTED_CANDIDATES {
    tag "combine_fold_params"
    label 'presto'
    container "${params.presto_container}"

    input:
    path fold_param_files

    output:
    path "fold_params.txt", emit: fold_params

    script:
    """
    # Combine all fold_params files from different (zmax, wmax) combinations
    cat fold_params_z*.txt > fold_params.txt

    echo "Combined fold parameters from \$(ls fold_params_z*.txt | wc -l) files"
    echo "Total candidates to fold: \$(wc -l < fold_params.txt)"
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
    publishDir {
        def obs_name = observation.baseName
        // Extract segment label from accelfile name (e.g., _half_1 or _full)
        def segment_label = 'full'
        if (accelfile.name.contains('_half_')) {
            def chunk = accelfile.name.split('_half_')[1].split('_')[0]
            segment_label = "half_${chunk}"
        } else if (accelfile.name.contains('_quarter_')) {
            def chunk = accelfile.name.split('_quarter_')[1].split('_')[0]
            segment_label = "quarter_${chunk}"
        } else if (accelfile.name.contains('_third_')) {
            def chunk = accelfile.name.split('_third_')[1].split('_')[0]
            segment_label = "third_${chunk}"
        }
        "${params.outdir}/${obs_name}/05_FOLDING/${segment_label}"
    }, mode: 'copy'

    input:
    tuple path(observation), path(rfi_products), path(accelfile), path(candfile), path(inffile), val(cand_num), val(dm)
    val npart
    val extra_flags

    output:
    tuple val(cand_num), path("*.pfd"), path("*.pfd.ps"), path("*.bestprof"), emit: folded_candidates

    script:
    basename = observation.baseName
    // Find the mask file from rfi_products
    mask_file = rfi_products.find { it.name.endsWith('.mask') }
    """
    prepfold -noxwin -accelcand ${cand_num} -accelfile ${candfile} -dm ${dm} -npart ${npart} -mask ${mask_file} ${extra_flags} -o ${basename}_cand${cand_num} ${observation}
    """
}

process PREPFOLD_TIMESERIES {
    tag "${datfile.baseName}_cand${cand_num}"
    label 'presto'
    label 'process_high'
    container "${params.presto_container}"
    publishDir "${params.outdir}/${datfile.name.split('_DM')[0]}/05_FOLDING", mode: 'copy'

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
    publishDir "${params.outdir}/${datfile.name.split('_DM')[0]}/06_SINGLE_PULSES", mode: 'copy'

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

    // Extract observation basename from first cand file
    publishDir {
        def first_file = accel_cand_files instanceof List ? accel_cand_files[0] : accel_cand_files
        "${params.outdir}/${first_file.name.split('_DM')[0]}/02_BIRDIES"
    }, mode: 'copy'

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

    // Extract observation basename from first cand file
    publishDir {
        def first_file = all_cand_files instanceof List ? all_cand_files[0] : all_cand_files
        "${params.outdir}/${first_file.name.split('_DM')[0]}/04_SIFTING"
    }, mode: 'copy'

    input:
    path all_cand_files

    output:
    path "all_candidates.txt", emit: combined_cands

    script:
    """
    cat *_ACCEL_*.cand | grep -v "^#" | sort -k2 -rn > all_candidates.txt
    """
}
