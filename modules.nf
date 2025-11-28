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
// FILTERBANK PREPROCESSING
// ============================================================================
process FILTOOL {
    tag "$observation"
    label 'presto'
    label 'process_medium'
    container "${params.pulsarx_container}"
    publishDir "${params.outdir}/${observation.baseName}/00_FILTOOL", mode: 'copy'
    maxForks 1

    input:
    path observation
    val time_decimate
    val freq_decimate
    val telescope
    val rfi_filter
    val extra_args

    output:
    path "${basename}_filtool_01.fil", emit: filtered_observation

    script:
    basename = observation.baseName
    publishDir = "${params.outdir}/${basename}/00_FILTOOL"
    outfile = "${basename}_filtool"
    """
    # Create publish directory and write directly to it (file is too large for work directory)
    mkdir -p ${publishDir}

    # Run filtool with all parameters
    filtool -t ${task.cpus} --td ${time_decimate} --fd ${freq_decimate} \
        --telescope ${telescope} -z ${rfi_filter} \
        -o ${publishDir}/${outfile} ${extra_args} \
        -f ${observation}

    # Create symlink in work directory for Nextflow output handling
    ln -s ${publishDir}/${outfile}_01.fil ${outfile}_01.fil
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
    dm_str = String.format("%.2f", dm as Double)
    nobary_flag = nobary ? "-nobary" : ""
    mask_file = rfi_products.find { it.name.endsWith('.mask') }
    """
    prepdata ${nobary_flag} -dm ${dm} -downsamp ${downsample} -mask ${mask_file} ${extra_flags} -o ${basename}_DM${dm_str} ${observation}
    """
}

// ============================================================================
// BIRDIE/RFI MASKING
// ============================================================================

process ACCELSEARCH_ZMAX0 {
    tag "${datfile.baseName}_zmax0"
    label 'presto'
    label 'process_low'
    container "${params.presto_container}"
    publishDir "${params.outdir}/${datfile.name.split('_DM')[0]}/02_BIRDIES", mode: 'copy', pattern: "*_ACCEL_0*"
    scratch true  // Use scratch space for intermediate files

    input:
    tuple val(dm), path(datfile), path(inffile)
    val numharm

    output:
    tuple path("*_ACCEL_0"), path("*_ACCEL_0.cand"), path("*_ACCEL_0.txtcand"), emit: accel_zero

    script:
    basename = datfile.baseName
    """
    #!/bin/bash
    # Step 1: FFT (realfft creates .fft from .dat, .inf stays the same)
    realfft ${datfile}

    # Step 2: Rednoise (creates _red.fft, need to create _red.inf)
    rednoise ${basename}.fft
    cp ${inffile} ${basename}_red.inf
    rm -f ${basename}.fft

    # Step 3: Acceleration search with zmax=0 (no zapbirds for birdie detection)
    accelsearch -zmax 0 -numharm ${numharm} ${basename}_red.fft

    # Clean up intermediate files
    rm -f ${basename}_red.fft ${basename}_red.inf
    """
}

// ============================================================================
// ACCELERATION SEARCH
// ============================================================================

process ACCELSEARCH {
    tag "${datfile.baseName}_${segment_name}_${chunk_num}_z${zmax}_w${wmax}"
    label 'presto'
    label 'process_high'
    container "${params.presto_container}"
    publishDir {
        def obs_name = datfile.name.split('_DM')[0]
        "${params.outdir}/${obs_name}/03_DEDISPERSION/${segment_name}"
    }, mode: 'copy', pattern: "*_ACCEL_*"
    scratch true  // Use scratch space for intermediate files

    input:
    tuple val(dm), path(datfile), path(inffile), val(segment_name), val(fraction), val(chunk_num), val(total_chunks), path(zaplist)
    tuple val(zmax), val(wmax)
    val numharm
    val use_cuda
    val gpu_id
    val extra_flags

    output:
    tuple val(dm), val(zmax), val(wmax), path("*_ACCEL_${zmax}"), path("*_ACCEL_${zmax}.cand"), path("*_ACCEL_${zmax}.txtcand"), path("*_ACCEL_${zmax}.inf"), emit: candidates
    tuple val(dm), val(segment_name), val(chunk_num), path("${basename}_${segment_name}_${chunk_num}.dat"), path("${basename}_${segment_name}_${chunk_num}.inf"), emit: segment_timeseries optional true

    script:
    basename = datfile.baseName
    cuda_flag = use_cuda ? "-cuda ${gpu_id}" : ""
    wmax_flag = wmax > 0 ? "-wmax ${wmax}" : ""

    if (fraction == 1.0) {
        // Full observation - no splitting
        outname = "${basename}"
        """
        #!/bin/bash
        # Step 1: FFT (realfft creates .fft from .dat, .inf stays the same)
        realfft ${datfile}

        # Step 2: Rednoise (creates _red.fft, need to create _red.inf)
        rednoise ${outname}.fft
        cp ${inffile} ${outname}_red.inf
        rm -f ${outname}.fft  # Clean up intermediate FFT

        # Step 3: Zapbirds (only if zaplist is provided and not empty)
        if [ -f "${zaplist}" ] && [ -s "${zaplist}" ]; then
            # zapbirds creates new .fft file, need to rename _red.fft to match
            zapbirds -zap -zapfile ${zaplist} ${outname}_red.fft
            # zapbirds outputs ${outname}_red.fft (overwrites input), so rename to final name
            mv ${outname}_red.fft ${outname}.fft
            cp ${outname}_red.inf ${outname}.inf
            rm -f ${outname}_red.inf
        else
            # No zaplist - rename rednoise output to final name
            mv ${outname}_red.fft ${outname}.fft
            mv ${outname}_red.inf ${outname}.inf
        fi

        # Step 4: Acceleration search
        accelsearch -zmax ${zmax} -wmax ${wmax} -numharm ${numharm} ${cuda_flag} ${extra_flags} ${outname}.fft

        # Keep inf file for output (ACCEL file is named ${outname}_ACCEL_${zmax})
        cp ${outname}.inf ${outname}_ACCEL_${zmax}.inf

        # Clean up FFT and original inf files (keep only ACCEL results and matching inf)
        rm -f ${outname}.fft ${outname}.inf
        """
    } else {
        // Segmented observation
        outname = "${basename}_${segment_name}_${chunk_num}"
        """
        #!/bin/bash

        # Step 1: Split the timeseries (prepdata creates .dat and .inf files)
        num_samples=\$(grep "Number of bins in the time series" ${inffile} | awk -F'=' '{print \$2}' | tr -d ' ')
        samples_per_chunk=\$(awk "BEGIN {printf \\"%.0f\\", \$num_samples * ${fraction}}")

        # Ensure even number of samples
        if [ \$((samples_per_chunk % 2)) -ne 0 ]; then
            samples_per_chunk=\$((samples_per_chunk - 1))
        fi

        # Calculate starting fraction
        start_fraction=\$(awk "BEGIN {printf \\"%.6f\\", (${chunk_num} - 1) * ${fraction}}")

        # Split using prepdata (creates segment .dat and .inf files automatically)
        prepdata -nobary -dm 0 -start \$start_fraction -numout \$samples_per_chunk -o ${outname} ${datfile}

        # Step 2: FFT (realfft creates .fft from .dat, .inf stays the same)
        realfft ${outname}.dat
        # Keep segment dat file for prepfold (don't delete)

        # Step 3: Rednoise (creates _red.fft, need to create _red.inf)
        rednoise ${outname}.fft
        cp ${outname}.inf ${outname}_red.inf
        rm -f ${outname}.fft  # Clean up intermediate FFT

        # Step 4: Zapbirds (only if zaplist is provided and not empty)
        if [ -f "${zaplist}" ] && [ -s "${zaplist}" ]; then
            # zapbirds creates new .fft file
            zapbirds -zap -zapfile ${zaplist} ${outname}_red.fft
            # Rename to final name
            mv ${outname}_red.fft ${outname}.fft
            cp ${outname}_red.inf ${outname}.inf
            rm -f ${outname}_red.inf
        else
            # No zaplist - rename rednoise output to final name
            mv ${outname}_red.fft ${outname}.fft
            mv ${outname}_red.inf ${outname}.inf
        fi

        # Step 5: Acceleration search
        accelsearch -zmax ${zmax} -wmax ${wmax} -numharm ${numharm} ${cuda_flag} ${extra_flags} ${outname}.fft

        # Keep inf file for output (ACCEL file is named ${outname}_ACCEL_${zmax})
        cp ${outname}.inf ${outname}_ACCEL_${zmax}.inf

        # Keep segment timeseries files for prepfold (dat and inf with segment name)
        # These were created by prepdata -start in Step 1
        # They should already be named ${outname}.dat and ${outname}.inf
        # Just need to keep them (don't delete)

        # Clean up FFT files only (keep segment timeseries dat/inf for prepfold)
        rm -f ${outname}.fft
        """
    }
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
    tuple path(observation), path(rfi_products), path(accelfile), path(candfile), path(accel_inffile), path(timeseries_datfile), path(timeseries_inffile), val(cand_num), val(dm)
    val npart
    val extra_flags

    output:
    tuple val(cand_num), path("*.pfd"), path("*.pfd.ps"), path("*.bestprof"), emit: folded_candidates

    script:
    basename = observation.baseName
    // Find the mask file from rfi_products
    mask_file = rfi_products.find { it.name.endsWith('.mask') }
    """
    # Stage timeseries files so prepfold can find them
    # (prepfold with -accelfile will look for dedispersed timeseries)

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

    publishDir {
        def first_file = accel_files instanceof List ? accel_files[0] : accel_files
        "${params.outdir}/${first_file.name.split('_DM')[0]}/02_BIRDIES"
    }, mode: 'copy'

    input:
    path accel_files
    path inf_file
    val sigma_threshold

    output:
    path "birdies.zaplist", emit: zaplist
    path "birdies.birds", emit: birds optional true

    script:
    """
    #!/usr/bin/env python3
    import os
    import sys
    import glob
    from presto import sifting
    from presto import infodata

    def get_Fourier_bin_width(inf_filename):
        \"\"\"Calculate Fourier bin width from .inf file\"\"\"
        inffile = infodata.infodata(inf_filename)
        Tobs_s = inffile.dt * inffile.N
        fourier_bin_width_Hz = 1.0 / Tobs_s
        return fourier_bin_width_Hz

    def make_birds_file(ACCEL_0_filename, width_Hz, sigma_threshold=4.0, flag_grow=1, flag_barycentre=0):
        \"\"\"Create birds file from ACCEL_0 candidates\"\"\"
        birds_filename = "birdies.birds"

        print(f"Processing ACCEL_0 file: {ACCEL_0_filename}")

        # Load candidates using PRESTO sifting module
        try:
            candidate_birdies = sifting.candlist_from_candfile(ACCEL_0_filename)
            candidate_birdies.reject_threshold(sigma_threshold)

            # Get candidates above threshold
            list_birdies = candidate_birdies.cands
            print(f"Number of birdies above sigma={sigma_threshold}: {len(list_birdies)}")

            # Write birds file
            with open(birds_filename, "a") as file_birdies:
                for cand in list_birdies:
                    file_birdies.write(f"{cand.f:.3f}     {width_Hz:.20f}     {cand.numharm}     {flag_grow}     {flag_barycentre}\\n")

            return len(list_birdies)
        except Exception as e:
            print(f"Error processing {ACCEL_0_filename}: {e}")
            return 0

    # Get Fourier bin width from the inf file
    inf_file = "${inf_file}"
    width_Hz = get_Fourier_bin_width(inf_file)
    print(f"Fourier bin width: {width_Hz} Hz")

    # Process all ACCEL_0 files
    accel_files = glob.glob("*_ACCEL_0")
    total_birdies = 0

    if not accel_files:
        print("No ACCEL_0 files found")
        # Create empty zaplist
        open("birdies.zaplist", "w").close()
        sys.exit(0)

    print(f"Found {len(accel_files)} ACCEL_0 file(s)")

    for accel_file in accel_files:
        count = make_birds_file(accel_file, width_Hz, sigma_threshold=${sigma_threshold})
        total_birdies += count

    print(f"Total birdies found: {total_birdies}")

    # Create zaplist from birds file using makezaplist.py
    if total_birdies > 0 and os.path.exists("birdies.birds"):
        import subprocess
        try:
            # Copy inf file for makezaplist.py
            subprocess.run(["cp", inf_file, "birdies.inf"], check=True)

            # Run makezaplist.py
            result = subprocess.run(["makezaplist.py", "birdies.birds"],
                                  capture_output=True, text=True)

            if result.returncode == 0:
                print("Successfully created zaplist")
                # makezaplist.py should create birdies.zaplist
                if not os.path.exists("birdies.zaplist"):
                    print("Warning: makezaplist.py did not create zaplist, creating empty one")
                    open("birdies.zaplist", "w").close()
            else:
                print(f"makezaplist.py failed: {result.stderr}")
                print("Creating empty zaplist")
                open("birdies.zaplist", "w").close()
        except Exception as e:
            print(f"Error running makezaplist.py: {e}")
            print("Creating empty zaplist")
            open("birdies.zaplist", "w").close()
    else:
        print("No birdies found, creating empty zaplist")
        open("birdies.zaplist", "w").close()
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
