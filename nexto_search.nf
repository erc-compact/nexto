#!/usr/bin/env nextflow

/*
 * NEXTO: Nextflow Execution of PRESTO pulsar search pipeline
 *
 * A scalable Nextflow implementation of PULSAR_MINER for cluster multi HPC computing
 * Main credits to alex88ridolfi/PULSAR_MINER
 * Author: Vivek Venkatraman Krishnan
 */

nextflow.enable.dsl=2

// Import modules
include {
    READFILE;
    FILTOOL;
    RFIFIND;
    PREPDATA as PREPDATA_ZERODM;
    PREPDATA as PREPDATA_DMTRIALS;
    ACCELSEARCH_ZMAX0;
    ACCELSEARCH;
    ACCELSIFT;
    PREPFOLD_FROM_CANDFILE;
    PSRFOLD_PULSARX;
    PREPFOLD_TIMESERIES;
    SINGLE_PULSE_SEARCH;
    MAKE_ZAPLIST
} from './modules.nf'

/*
 * Default parameters
 */
params.input = null
params.outdir = "results"
params.dm_low = 0.0
params.dm_high = 100.0
params.dm_step = 0.5
params.downsample = 1
params.search_params = [[0,0], [50,0], [200,0]]  // List of [zmax, wmax] tuples
params.numharm = 8
params.sigma_threshold = 6.0
params.sigma_birdies_threshold = 15.0
params.rfifind_time = 2.0
params.rfifind_freqsig = 4.0
params.rfifind_extra_flags = ""
params.prepdata_extra_flags = ""
params.accelsearch_extra_flags = ""
params.prepfold_extra_flags = ""
params.npart = 50
params.dmstep = 1
params.use_cuda = false
params.gpu_id = 0
params.sp_threshold = 5.0
params.enable_single_pulse = true
params.help = false

/*
 * Help message
 */
def helpMessage() {
    log.info"""
    ====================================
    NEXTO - Nextflow Pulsar Search
    ====================================

    Usage:
        nextflow run nexto_search.nf --input <obs.fil> [options]

    Required arguments:
        --input                Path to input observation file (.fil or .fits)

    Output:
        --outdir               Output directory (default: results)

    Dedispersion:
        --dm_low               Minimum DM to search (default: 0.0)
        --dm_high              Maximum DM to search (default: 100.0)
        --dm_step              DM step size (default: 0.5)
        --downsample           Downsampling factor (default: 1)

    RFI removal:
        --rfifind_time         Time interval for rfifind (default: 2.0)
        --rfifind_freqsig      Freq sigma for rfifind (default: 4.0)
        --rfifind_extra_flags  Additional flags for rfifind (default: "")

    Periodicity search:
        --search_params        List of [zmax,wmax] tuples (default: [[0,0],[50,0],[200,0]])
                               If wmax=0: acceleration search, if wmax>0: jerk search
        --numharm              Number of harmonics (default: 8)
        --use_cuda             Enable GPU acceleration (default: false)
        --gpu_id               GPU device ID (default: 0)
        --prepdata_extra_flags Additional flags for prepdata (default: "")
        --accelsearch_extra_flags Additional flags for accelsearch (default: "")

    Candidate selection:
        --sigma_threshold      Minimum sigma for candidates (default: 6.0)
        --sigma_birdies_threshold  Minimum sigma for birdie detection (default: 4.0)
        --npart                Number of phase bins for folding (default: 50)
        --dmstep               DM step for prepfold (default: 1)
        --prepfold_extra_flags Additional flags for prepfold (default: "")

    Optional searches:
        --enable_single_pulse  Enable single pulse search (default: true)
        --sp_threshold         Single pulse threshold (default: 5.0)

    Other:
        --help                 Show this help message
    """.stripIndent()
}

if (params.help) {
    helpMessage()
    exit 0
}

if (!params.input) {
    log.error "Error: --input parameter is required"
    helpMessage()
    exit 1
}

/*
 * Main workflow
 */
workflow {
    // Create input channel
    observation_ch = Channel.fromPath(params.input, checkIfExists: true)

    // Capture original observation basename before any processing
    original_basename_ch = observation_ch.map { obs -> obs.baseName }.first()

    // Step 0: Optional filtool preprocessing
    if (params.enable_filtool) {
        FILTOOL(
            observation_ch,
            params.filtool_time_decimate,
            params.filtool_freq_decimate,
            params.filtool_telescope,
            params.filtool_rfi_filter,
            params.filtool_extra_args
        )
        processed_obs = FILTOOL.out.filtered_observation
    } else {
        processed_obs = observation_ch
    }

    // Extract metadata using readfile (needed for pepoch when folding with psrfold)
    READFILE(processed_obs)
    def obs_info_ch = READFILE.out.obs_with_info
    processed_obs = obs_info_ch.map { obs, info -> obs }
    def info_pair = obs_info_ch.first()

    // Step 1: RFI detection
    RFIFIND(
        processed_obs,
        original_basename_ch,
        params.rfifind_time,
        params.rfifind_freqsig,
        params.rfifind_extra_flags
    )

    // Step 2: Zero-DM prepdata with -nobary for birdie detection
    zero_dm_input = RFIFIND.out.rfi_products
        .map { obs, rfi_products, original_basename ->
            [obs, rfi_products, 0.0, params.downsample, true, params.prepdata_extra_flags]
        }

    // Run prepdata with DM=0 and nobary=true
    PREPDATA_ZERODM(zero_dm_input)

    // Step 3: Identify birdies (RFI lines) using z=0 search on zero-DM
    // ACCELSEARCH_ZMAX0 will do FFT, rednoise, and accelsearch internally
    ACCELSEARCH_ZMAX0(
        PREPDATA_ZERODM.out.timeseries,
        params.numharm
    )

    // Step 4: Create zaplist from birdies (use ACCEL_0 files)
    MAKE_ZAPLIST(
        ACCELSEARCH_ZMAX0.out.accel_zero
            .map { accel, cand, txtcand -> accel }
            .collect(),
        PREPDATA_ZERODM.out.timeseries
            .map { dm, datfile, inffile -> inffile }
            .first(),
        params.sigma_birdies_threshold
    )

    // Step 5: Now do the actual DM trials WITHOUT -nobary
    // Generate DM values as a list
    def dm_start = params.dm_low
    def dm_end = params.dm_high
    def dm_increment = params.dm_step
    dm_values = []
    for (def dm = dm_start; dm <= dm_end; dm += dm_increment) {
        dm_values.add(dm)
    }

    // Combine observation with RFI products and DM values, with nobary=false
    dm_trials_input = RFIFIND.out.rfi_products
        .combine(Channel.from(dm_values))
        .map { obs, rfi_products, original_basename, dm -> [obs, rfi_products, dm, params.downsample, false, params.prepdata_extra_flags] }

    // Run prepdata for all DM trials without -nobary
    PREPDATA_DMTRIALS(dm_trials_input)

    // Step 6: Create segment channel and combine with timeseries
    segments_ch = Channel.from(params.segments)
        .map { name_fraction ->
            def segment_name = name_fraction[0]
            def fraction = name_fraction[1]
            def total_chunks = fraction == 1.0 ? 1 : Math.ceil(1.0 / fraction) as int
            [segment_name, fraction, total_chunks]
        }
        .flatMap { segment_name, fraction, total_chunks ->
            (1..total_chunks).collect { chunk_num -> [segment_name, fraction, chunk_num, total_chunks] }
        }

    // Combine timeseries with segments and zaplist for acceleration search
    accel_input = PREPDATA_DMTRIALS.out.timeseries
        .combine(segments_ch)
        .combine(MAKE_ZAPLIST.out.zaplist)
        .map { dm, datfile, inffile, segment_name, fraction, chunk_num, total_chunks, zaplist ->
            [dm, datfile, inffile, segment_name, fraction, chunk_num, total_chunks, zaplist]
        }

    // Step 7: Acceleration/Jerk search (includes split, FFT, rednoise, zapbirds, accelsearch)
    // Create channel of search tuples from params
    search_tuples_ch = Channel.from(params.search_params)

    // Combine each timeseries with all search tuples
    search_input = accel_input.combine(search_tuples_ch)

    // Run ACCELSEARCH for each (zmax, wmax) tuple
    ACCELSEARCH(
        search_input.map { dm, datfile, inffile, segment_name, fraction, chunk_num, total_chunks, zaplist, zmax, wmax ->
            [dm, datfile, inffile, segment_name, fraction, chunk_num, total_chunks, zaplist]
        },
        search_input.map { dm, datfile, inffile, segment_name, fraction, chunk_num, total_chunks, zaplist, zmax, wmax ->
            [zmax, wmax]
        },
        params.numharm,
        params.use_cuda,
        params.gpu_id,
        params.accelsearch_extra_flags
    )

    candidates_ch = ACCELSEARCH.out.candidates

    // Step 11: Sift candidates
    // Group by segment, zmax and wmax - each segment should be sifted independently
    // Use the original observation basename (before filtool processing)
    obs_basename_ch = original_basename_ch

    ACCELSIFT(
        candidates_ch
            .map { dm, segment_name, chunk_num, zmax, wmax, accel, cand, txtcand, inffile ->
                // Create unique segment label combining name and chunk number
                def segment_label = "${segment_name}_${chunk_num}"
                [segment_label, zmax, wmax, accel]  // Only pass the accel file
            }
            .groupTuple(by: [0, 1, 2])  // Group by segment_label, zmax, wmax
            .map { segment_label, zmax, wmax, accel_list ->
                [zmax, wmax, accel_list, segment_label]  // Reorder for ACCELSIFT input
            }
            .combine(obs_basename_ch),
        params.sigma_threshold,
        params.period_to_search_min,
        params.period_to_search_max,
        params.flag_remove_duplicates ? 1 : 0,
        params.flag_remove_harmonics ? 1 : 0
    )

    // Step 12: Fold top candidates
    if (params.fold_with_psrfold) {
        // PSRFOLD: One process per sifted candidate file (one per zmax/wmax/segment combination)
        // Each candfile is processed independently
        // candfile format: #id dm acc F0 F1 F2 S/N

        // Get any inf file for pepoch extraction (all have same pepoch)
        any_inf_file = PREPDATA_DMTRIALS.out.timeseries
            .map { dm, datfile, inffile -> inffile }
            .first()

        // For each sifted candidate file, create a PSRFOLD job
        fold_input_psrfold = RFIFIND.out.rfi_products
            .map { obs, rfi_products, original_basename -> obs }
            .combine(ACCELSIFT.out.sifted_candidates)
            .map { obs, segment_label, candfile -> [obs, segment_label, candfile] }
            .combine(any_inf_file)

        PSRFOLD_PULSARX(fold_input_psrfold, params.psrfold_nbin, params.psrfold_extra_flags)
    } else {
        // PREPFOLD: Parse each sifted candidate file line-by-line
        // Create one PREPFOLD job per candidate (per line in each candfile)
        // candfile format: #id dm acc F0 F1 F2 S/N

        // Parse each candfile line-by-line
        top_candidates = ACCELSIFT.out.sifted_candidates
            .flatMap { segment_label, candfile ->
                // Read the file and parse each line (skip header)
                candfile.splitCsv(sep: '\t', skip: 1).collect { row ->
                    [segment_label, row]
                }
            }
            .map { segment_label, row ->
                def cand_id = row[0] as Integer
                def dm = row[1] as Double
                def acc = row[2] as Double
                def f0 = row[3] as Double
                def f1 = row[4] as Double
                def f2 = row[5] as Double
                def snr = row[6] as Double
                [segment_label, cand_id, dm, f0, f1, f2]
            }

        // Combine with observation and RFI products
        fold_input_prepfold = RFIFIND.out.rfi_products
            .map { obs, rfi_products, original_basename -> [obs, rfi_products] }
            .combine(top_candidates)

        PREPFOLD_FROM_CANDFILE(fold_input_prepfold, params.npart, params.prepfold_extra_flags)
    }

    // Step 14: Optional single pulse search (on DM trials without nobary)
    if (params.enable_single_pulse) {
        SINGLE_PULSE_SEARCH(
            PREPDATA_DMTRIALS.out.timeseries,
            params.sp_threshold
        )
    }
}

/*
 * Workflow completion
 */
workflow.onComplete {
    log.info """
    ====================================
    Pipeline completed!
    ====================================
    Status:    ${workflow.success ? 'SUCCESS' : 'FAILED'}
    Duration:  ${workflow.duration}
    Output:    ${params.outdir}
    ====================================
    """.stripIndent()
}

workflow.onError {
    log.error "Pipeline failed with error: ${workflow.errorMessage}"
}
