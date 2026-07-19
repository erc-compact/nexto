// NEXTO Nextflow Modules
// Each module wraps a PRESTO/PulsarX subprocess for distributed cluster execution
//
// Convention: every process takes the canonical observation id (obs_id) as the
// first tuple element and uses it for publishDir paths and downstream joins.
// obs_id is derived once in the workflow (input basename with any _filtool
// suffix stripped) so all outputs of one observation land in one directory
// and multiple observations (beams) never mix.

// ============================================================================
// FILTERBANK PREPROCESSING
// ============================================================================

process FILTOOL {
    tag "$obs_id"
    label 'pulsarx'
    label 'process_medium'
    container "${params.pulsarx_container}"
    maxForks 1

    input:
    tuple val(obs_id), path(observation)
    val time_decimate
    val freq_decimate
    val telescope
    val rfi_filter
    val extra_args

    output:
    tuple val(obs_id), path("${outfile}_01.fil"), emit: filtered_observation

    script:
    outfile = "${obs_id}_filtool"
    // `observation` may be a single file or a list of time-contiguous chunks
    // (merge_input mode). filtool concatenates multiple -f inputs in the order
    // given; the input channel already sorted them into time order.
    input_files = (observation instanceof List ? observation : [observation]).join(' ')
    // The filtered file is too large for the work directory: write it straight
    // to its final location and symlink it back for Nextflow output handling.
    // file() makes the path absolute even when --outdir is relative.
    publish_dir = "${file(params.outdir)}/${obs_id}/00_FILTOOL"
    """
    mkdir -p ${publish_dir}

    filtool -t ${task.cpus} --td ${time_decimate} --fd ${freq_decimate} \
        --telescope ${telescope} -z ${rfi_filter} \
        -o ${publish_dir}/${outfile} ${extra_args} \
        -f ${input_files}

    ln -s ${publish_dir}/${outfile}_01.fil ${outfile}_01.fil
    """
}

// ============================================================================
// RFI DETECTION & MITIGATION
// ============================================================================

process RFIFIND {
    tag "$obs_id"
    label 'presto'
    label 'process_medium'
    container "${params.presto_container}"
    publishDir "${params.outdir}/${obs_id}/01_RFIFIND", mode: 'copy'

    input:
    tuple val(obs_id), path(observation)
    val time_interval
    val freq_interval
    val extra_flags

    output:
    tuple val(obs_id), path(observation), path("${basename}_rfifind.*"), emit: rfi_products
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
    tag "${obs_id}_DM${dm}_nobary${nobary}"
    label 'presto'
    label 'process_high'
    container "${params.presto_container}"
    publishDir "${params.outdir}/${obs_id}/02_TIMESERIES", mode: 'copy', enabled: params.publish_timeseries

    input:
    tuple val(obs_id), path(observation), path(rfi_products), val(dm), val(downsample), val(nobary), val(extra_flags)

    output:
    tuple val(obs_id), val(dm), path("*.dat"), path("*.inf"), emit: timeseries

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
// BARYCENTRIC VELOCITY
// ============================================================================

process COMPUTE_BARYV {
    tag "$obs_id"
    label 'presto'
    container "${params.presto_container}"
    publishDir "${params.outdir}/${obs_id}/02_BIRDIES", mode: 'copy', pattern: "baryv.txt"

    input:
    tuple val(obs_id), path(inf_file)

    output:
    tuple val(obs_id), env(BARYV), emit: baryv
    path "baryv.txt"

    script:
    """
    compute_baryv.py ${inf_file} > baryv.txt
    BARYV=\$(cat baryv.txt)
    """
}

// ============================================================================
// BIRDIE/RFI MASKING
// ============================================================================

process ACCELSEARCH_ZMAX0 {
    tag "${obs_id}_zmax0"
    label 'presto'
    label 'process_low'
    container "${params.presto_container}"
    publishDir "${params.outdir}/${obs_id}/02_BIRDIES", mode: 'copy', pattern: "*_ACCEL_0*"
    scratch true  // Use scratch space for intermediate files

    input:
    tuple val(obs_id), val(dm), path(datfile), path(inffile)
    val numharm

    output:
    tuple val(obs_id), path("*_ACCEL_0"), path("*_ACCEL_0.cand"), path("*_ACCEL_0.txtcand"), emit: accel_zero

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

    # When nothing exceeds -sigma, PRESTO writes an empty .txtcand but no
    # ACCEL_0 / .cand file at all, which would fail the required output glob.
    # An observation with no zero-DM birdies is legitimate: emit empty files
    # and let MAKE_ZAPLIST produce an empty zaplist.
    for f in ${basename}_red_ACCEL_0 ${basename}_red_ACCEL_0.cand ${basename}_red_ACCEL_0.txtcand; do
        [ -f "\$f" ] || touch "\$f"
    done

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
    publishDir "${params.outdir}/${obs_id}/03_DEDISPERSION/${segment_name}/${segment_name}_${chunk_num}", mode: 'copy', pattern: "*_ACCEL_*"
    scratch true  // Use scratch space for intermediate files

    input:
    tuple val(obs_id), val(dm), path(datfile), path(inffile), val(segment_name), val(fraction), val(chunk_num), val(total_chunks), val(zmax), val(wmax), path(zaplist), val(baryv)
    val numharm
    val use_cuda
    val gpu_id
    val extra_flags

    output:
    tuple val(obs_id), val(dm), val(segment_name), val(fraction), val(chunk_num), val(zmax), val(wmax), path("*_ACCEL_${zmax}${wmax > 0 ? "_JERK_${wmax}" : ""}"), path("*_ACCEL_${zmax}${wmax > 0 ? "_JERK_${wmax}" : ""}.cand"), path("*_ACCEL_${zmax}${wmax > 0 ? "_JERK_${wmax}" : ""}.txtcand"), path("*_ACCEL_${zmax}${wmax > 0 ? "_JERK_${wmax}" : ""}.inf"), emit: candidates
    tuple val(obs_id), val(dm), val(segment_name), val(chunk_num), path("*_${segment_name}_${chunk_num}.dat"), path("*_${segment_name}_${chunk_num}.inf"), emit: segment_timeseries, optional: true

    script:
    basename = datfile.baseName
    accelsearch_binary = use_cuda ? "accelsearch_cu" : "accelsearch"
    wmax_flag = wmax > 0 ? "-wmax ${wmax}" : "-wmax 0"
    // Construct proper output suffix for jerk searches
    jerk_suffix = wmax > 0 ? "_JERK_${wmax}" : ""

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
        # The zaplist frequencies are topocentric (from the -nobary zero-DM
        # search) while this FFT is barycentered: -baryv shifts each birdie
        # to its apparent barycentric frequency before zapping.
        if [ -f "${zaplist}" ] && [ -s "${zaplist}" ]; then
            zapbirds -zap -zapfile ${zaplist} -baryv ${baryv} ${outname}_red.fft
            mv ${outname}_red.fft ${outname}.fft
            cp ${outname}_red.inf ${outname}.inf
            rm -f ${outname}_red.inf
        else
            # No zaplist - rename rednoise output to final name
            mv ${outname}_red.fft ${outname}.fft
            mv ${outname}_red.inf ${outname}.inf
        fi

        # Step 4: Acceleration search
        ${accelsearch_binary} -zmax ${zmax} ${wmax_flag} -numharm ${numharm} ${extra_flags} ${outname}.fft 2>&1 | tee accelsearch_run.log

        # accelsearch_cu prints "CUDA Error: out of memory" but may exit 0,
        # which the empty-output fallback below would otherwise mask as a
        # legitimate no-candidate result. Fail loudly so the search is not
        # silently skipped (a large zmax*wmax jerk search can exceed GPU RAM).
        if grep -qiE "CUDA Error|out of memory|cudaError" accelsearch_run.log; then
            echo "ERROR: accelsearch GPU failure (zmax=${zmax} wmax=${wmax}); see accelsearch_run.log" >&2
            exit 1
        fi

        # A search that finds nothing above -sigma is a normal result (common
        # for short segments at an offset DM), but PRESTO then writes no
        # ACCEL/.cand file at all. Emit empty ones so this task succeeds and
        # only contributes no candidates; ACCELSIFT skips empty ACCEL files.
        for f in ${outname}_ACCEL_${zmax}${jerk_suffix} ${outname}_ACCEL_${zmax}${jerk_suffix}.cand ${outname}_ACCEL_${zmax}${jerk_suffix}.txtcand; do
            [ -f "\$f" ] || touch "\$f"
        done

        # Keep inf file for output (ACCEL file is named ${outname}_ACCEL_${zmax}${jerk_suffix})
        cp ${outname}.inf ${outname}_ACCEL_${zmax}${jerk_suffix}.inf

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
        # See full-observation branch: -baryv corrects the topocentric
        # birdie frequencies for this barycentered FFT.
        if [ -f "${zaplist}" ] && [ -s "${zaplist}" ]; then
            zapbirds -zap -zapfile ${zaplist} -baryv ${baryv} ${outname}_red.fft
            mv ${outname}_red.fft ${outname}.fft
            cp ${outname}_red.inf ${outname}.inf
            rm -f ${outname}_red.inf
        else
            # No zaplist - rename rednoise output to final name
            mv ${outname}_red.fft ${outname}.fft
            mv ${outname}_red.inf ${outname}.inf
        fi

        # Step 5: Acceleration search
        ${accelsearch_binary} -zmax ${zmax} ${wmax_flag} -numharm ${numharm} ${extra_flags} ${outname}.fft 2>&1 | tee accelsearch_run.log

        # accelsearch_cu prints "CUDA Error: out of memory" but may exit 0,
        # which the empty-output fallback below would otherwise mask as a
        # legitimate no-candidate result. Fail loudly so the search is not
        # silently skipped (a large zmax*wmax jerk search can exceed GPU RAM).
        if grep -qiE "CUDA Error|out of memory|cudaError" accelsearch_run.log; then
            echo "ERROR: accelsearch GPU failure (zmax=${zmax} wmax=${wmax}); see accelsearch_run.log" >&2
            exit 1
        fi

        # A search that finds nothing above -sigma is a normal result (common
        # for short segments at an offset DM), but PRESTO then writes no
        # ACCEL/.cand file at all. Emit empty ones so this task succeeds and
        # only contributes no candidates; ACCELSIFT skips empty ACCEL files.
        for f in ${outname}_ACCEL_${zmax}${jerk_suffix} ${outname}_ACCEL_${zmax}${jerk_suffix}.cand ${outname}_ACCEL_${zmax}${jerk_suffix}.txtcand; do
            [ -f "\$f" ] || touch "\$f"
        done

        # Keep inf file for output (ACCEL file is named ${outname}_ACCEL_${zmax}${jerk_suffix})
        cp ${outname}.inf ${outname}_ACCEL_${zmax}${jerk_suffix}.inf

        # Keep segment timeseries files (dat and inf) for later folding.
        # Clean up FFT files only.
        rm -f ${outname}.fft
        """
    }
}

// ============================================================================
// CANDIDATE SIFTING
// ============================================================================

process ACCELSIFT {
    tag "${obs_id}_${segment_label}"
    label 'presto'
    container "${params.presto_container}"
    publishDir {
        def segment_parts = segment_label.split('_')
        def segment_name = segment_parts[0..-2].join('_')
        "${params.outdir}/${obs_id}/04_SIFTING/${segment_name}/${segment_label}"
    }, mode: 'copy', pattern: "*.txt"

    input:
    tuple val(obs_id), val(segment_label), val(start_frac), val(end_frac), path(accel_files)
    val sigma_threshold
    val period_min
    val period_max
    val flag_remove_duplicates
    val flag_remove_harmonics

    output:
    tuple val(obs_id), val(segment_label), val(start_frac), val(end_frac), path(outfile), emit: sifted_candidates

    script:
    outfile = "best_candidates_${obs_id}_${segment_label}.txt"
    dup_flag = flag_remove_duplicates ? "--remove-duplicates" : ""
    harm_flag = flag_remove_harmonics ? "--remove-harmonics" : ""
    """
    # All staged files are ACCEL result files for this (observation, segment
    # chunk): every DM trial and every zmax/wmax search is sifted together so
    # duplicates and harmonics are removed across search configurations.
    # Skip empty ACCEL files: ACCELSEARCH emits one whenever a search found
    # nothing above -sigma, and PRESTO's sifting cannot parse a file with no
    # header (it dies on an unset numsamp).
    shopt -s nullglob
    accel_list=()
    for f in *_ACCEL_*; do
        [ -s "\$f" ] && accel_list+=("\$f")
    done

    if [ \${#accel_list[@]} -eq 0 ]; then
        echo "#id   dm acc  F0 F1 F2 S/N" > ${outfile}
        exit 0
    fi

    ${projectDir}/bin/sift_candidates.py \
        \${accel_list[@]} \
        --min-period ${period_min} \
        --max-period ${period_max} \
        --sigma-threshold ${sigma_threshold} \
        ${dup_flag} \
        ${harm_flag} \
        --max-cands-to-fold ${params.max_cands_to_fold} \
        --output ${outfile}
    """
}

// ============================================================================
// CANDIDATE FOLDING
// ============================================================================

process PREPFOLD_FROM_CANDFILE {
    tag "${obs_id}_${segment_label}_cand${cand_id}"
    label 'presto'
    label 'process_high'
    container "${params.presto_container}"
    publishDir {
        def segment_parts = segment_label.split('_')
        def segment_name = segment_parts[0..-2].join('_')
        "${params.outdir}/${obs_id}/05_FOLDING/${segment_name}/${segment_label}"
    }, mode: 'copy'

    input:
    tuple val(obs_id), path(observation), path(rfi_products), val(segment_label), val(start_frac), val(end_frac), val(cand_id), val(dm), val(f0), val(f1), val(f2)
    val npart
    val extra_flags

    output:
    tuple val(cand_id), path("*.pfd"), path("*.pfd.ps"), path("*.pfd.bestprof"), emit: folded_candidates
    path "*.pfd.png", optional: true, emit: folded_pngs

    script:
    // Find the mask file from rfi_products
    mask_file = rfi_products.find { it.name.endsWith('.mask') }
    """
    # Fold using frequency and derivatives from the candfile.
    # F0/F1/F2 are barycentric, referenced to the start of the folded section;
    # prepfold barycenters raw data by default, so they can be used directly.
    prepfold -noxwin \\
        -f ${f0} \\
        -fd ${f1} \\
        -fdd ${f2} \\
        -dm ${dm} \\
        -npart ${npart} \\
        -mask ${mask_file} \\
        -start ${start_frac} \\
        -end ${end_frac} \\
        ${extra_flags} \\
        -o ${obs_id}_${segment_label}_cand${cand_id} \\
        ${observation}

    # Convert PS files to PNG
    for psfile in *.pfd.ps; do
        if [ -f "\${psfile}" ]; then
            pngfile="\${psfile%.ps}.png"
            if command -v gs &> /dev/null; then
                # Use ghostscript to convert PS to PNG with 90 degree clockwise rotation
                gs -dSAFER -dBATCH -dQUIET -dNOPAUSE -dEPSCrop \\
                   -dAutoRotatePages=/None -dPDFFitPage=false \\
                   -r300 -sDEVICE=png16m \\
                   -sOutputFile="\${pngfile}" \\
                   -c "<</Orientation 3>> setpagedevice" \\
                   -f "\${psfile}"
            else
                echo "gs not found, skipping PNG conversion"
                break
            fi
        fi
    done
    """
}

process PSRFOLD_PULSARX {
    tag "${obs_id}_${segment_label}"
    label 'pulsarx'
    label 'process_high'
    container "${params.pulsarx_container}"
    publishDir {
        def segment_parts = segment_label.split('_')
        def segment_name = segment_parts[0..-2].join('_')
        "${params.outdir}/${obs_id}/05_FOLDING/${segment_name}/${segment_label}"
    }, mode: 'copy'

    input:
    tuple val(obs_id), path(observation), val(segment_label), val(start_frac), val(end_frac), path(candfile), path(topo_inf), val(baryv)
    val nbin
    val nsubint
    val coherent_dm
    val extra_flags

    output:
    path "*.ar", optional: true, emit: folded_archives
    path "*.png", optional: true, emit: folded_plots
    path "*.cands", optional: true, emit: folded_cand_files

    script:
    topo_candfile = "${candfile.baseName}_topo.candfile"
    """
    #!/bin/bash
    set -euo pipefail

    ncands=\$(grep -c -v '^#' ${candfile} || true)
    if [ "\${ncands}" -eq 0 ]; then
        echo "No candidates to fold for ${obs_id} ${segment_label}"
        exit 0
    fi

    # The candfile F0/F1/F2 are barycentric and referenced to the segment
    # start; psrfold_fil folds the raw topocentric filterbank. Convert the
    # spin parameters to topocentric and compute the topocentric pepoch of
    # the segment start (topo obs start + start_frac * Tobs).
    pepoch=\$(prepare_psrfold_cands.py ${candfile} ${topo_inf} --start-frac=${start_frac} --baryv=${baryv} --output ${topo_candfile})

    echo "Pepoch (topocentric MJD of segment start): \${pepoch}"
    echo "Folding \${ncands} candidates, fraction ${start_frac} to ${end_frac}"

    # Subint length so every plot has a constant ${nsubint} subintegrations
    # regardless of segment length: L = (segment duration) / nsubint, where
    # the segment duration is (end_frac - start_frac) * Tobs of the full
    # observation, taken from the topocentric .inf (dt * N).
    dt=\$(awk -F'=' '/Width of each time series bin/ {gsub(/ /,"",\$2); print \$2}' ${topo_inf})
    nbins=\$(awk -F'=' '/Number of bins in the time series/ {gsub(/ /,"",\$2); print \$2}' ${topo_inf})
    tsubint=\$(awk "BEGIN {printf \\"%.6f\\", \$dt * \$nbins * (${end_frac} - ${start_frac}) / ${nsubint}}")
    echo "Subint length: \${tsubint} s (segment duration / ${nsubint})"

    psrfold_fil \\
        --render \\
        --candfile ${topo_candfile} \\
        --pepoch \${pepoch} \\
        --rootname ${obs_id}_${segment_label} \\
        --nbin ${nbin} \\
        -L \${tsubint} \\
        --cdm ${coherent_dm} \\
        --threads ${task.cpus} \\
        --template ${params.fold_template} \\
        --frac ${start_frac} ${end_frac} \\
        ${extra_flags} \\
        -f ${observation}

    # psrfold_fil exits 0 even on fatal errors - fail loudly if no archives
    if ! ls *.ar > /dev/null 2>&1; then
        echo "ERROR: psrfold_fil produced no archives" >&2
        exit 1
    fi
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
    publishDir "${params.outdir}/${obs_id}/06_SINGLE_PULSES", mode: 'copy'

    input:
    tuple val(obs_id), val(dm), path(datfile), path(inffile)
    val threshold

    output:
    tuple val(obs_id), val(dm), path("*.singlepulse"), emit: single_pulses

    script:
    """
    # Some PRESTO images ship a copy of this script without the exec bit
    # early in PATH; bash aborts on it instead of skipping it (unlike dash
    # and execvp), so resolve a usable copy manually and run it via python3.
    sps=""
    IFS=':'
    for d in \$PATH; do
        if [ -f "\$d/single_pulse_search.py" ]; then
            [ -z "\$sps" ] && sps="\$d/single_pulse_search.py"
            [ -x "\$d/single_pulse_search.py" ] && { sps="\$d/single_pulse_search.py"; break; }
        fi
    done
    unset IFS
    if [ -z "\$sps" ]; then
        echo "ERROR: single_pulse_search.py not found in PATH" >&2
        exit 1
    fi

    python3 "\$sps" --noplot --threshold ${threshold} ${datfile}
    """
}

// ============================================================================
// UTILITY PROCESSES
// ============================================================================

process MAKE_ZAPLIST {
    tag "$obs_id"
    label 'presto'
    container "${params.presto_container}"
    publishDir "${params.outdir}/${obs_id}/02_BIRDIES", mode: 'copy'

    input:
    tuple val(obs_id), path(accel_files), path(inf_file)
    val sigma_threshold

    output:
    tuple val(obs_id), path("birdies.zaplist"), emit: zaplist
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
