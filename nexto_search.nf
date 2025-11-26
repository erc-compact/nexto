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
    RFIFIND;
    PREPDATA as PREPDATA_ZERODM;
    PREPDATA as PREPDATA_DMTRIALS;
    SPLIT_DATFILE;
    REALFFT as REALFFT_ZERODM;
    REALFFT as REALFFT_DMTRIALS;
    REDNOISE as REDNOISE_ZERODM;
    REDNOISE as REDNOISE_DMTRIALS;
    ZAPBIRDS;
    ACCELSEARCH_ZMAX0;
    ACCELSEARCH;
    ACCELSIFT;
    PARSE_SIFTED_CANDIDATES;
    PREPFOLD;
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

    // Step 1: RFI detection
    RFIFIND(
        observation_ch,
        params.rfifind_time,
        params.rfifind_freqsig,
        params.rfifind_extra_flags
    )

    // Step 2: Zero-DM prepdata with -nobary for birdie detection
    // Create zero-DM input channel
    zero_dm_input = RFIFIND.out.rfi_products
        .map { obs, rfi_products ->
            [obs, rfi_products, 0.0, params.downsample, true, params.prepdata_extra_flags]
        }

    // Run prepdata with DM=0 and nobary=true
    PREPDATA_ZERODM(zero_dm_input)

    // Step 3: FFT processing for zero-DM
    REALFFT_ZERODM(PREPDATA_ZERODM.out.timeseries)
    REDNOISE_ZERODM(REALFFT_ZERODM.out.fft_products)

    // Step 4: Identify birdies (RFI lines) using z=0 search on zero-DM
    ACCELSEARCH_ZMAX0(
        REDNOISE_ZERODM.out.rednoise_fft,
        params.numharm
    )

    // Step 5: Create zaplist from birdies
    MAKE_ZAPLIST(
        ACCELSEARCH_ZMAX0.out.accel_zero
            .map { dm, accel, cand -> cand }
            .collect(),
        1.0
    )

    // Step 6: Now do the actual DM trials WITHOUT -nobary
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
        .map { obs, rfi_products, dm -> [obs, rfi_products, dm, params.downsample, false, params.prepdata_extra_flags] }

    // Run prepdata for all DM trials without -nobary
    PREPDATA_DMTRIALS(dm_trials_input)

    // Step 6b: Split timeseries into segments
    // Create segment channel: for each [name, fraction], calculate number of chunks
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

    // Split timeseries into full vs. segments to split
    timeseries_with_segments = PREPDATA_DMTRIALS.out.timeseries
        .combine(segments_ch)

    // For fraction=1.0, pass through without splitting
    full_timeseries = timeseries_with_segments
        .filter { dm, datfile, inffile, segment_name, fraction, chunk_num, total_chunks -> fraction == 1.0 }
        .map { dm, datfile, inffile, segment_name, fraction, chunk_num, total_chunks ->
            [dm, segment_name, chunk_num, datfile, inffile]
        }

    // For fraction<1.0, run SPLIT_DATFILE
    split_input = timeseries_with_segments
        .filter { dm, datfile, inffile, segment_name, fraction, chunk_num, total_chunks -> fraction < 1.0 }
        .map { dm, datfile, inffile, segment_name, fraction, chunk_num, total_chunks ->
            [dm, datfile, inffile, segment_name, fraction, chunk_num, total_chunks]
        }

    SPLIT_DATFILE(split_input)

    // Combine full and split segments
    all_segments = full_timeseries.mix(SPLIT_DATFILE.out.segments)

    // Step 7: FFT processing for DM trials (now on segments)
    REALFFT_DMTRIALS(
        all_segments
            .map { dm, segment_name, chunk_num, datfile, inffile ->
                [dm, datfile, inffile]
            }
    )
    REDNOISE_DMTRIALS(REALFFT_DMTRIALS.out.fft_products)

    // Step 8: Apply birdie mask to all DM trial FFTs
    ZAPBIRDS(
        REDNOISE_DMTRIALS.out.rednoise_fft,
        MAKE_ZAPLIST.out.zaplist
    )

    // Step 9: Acceleration/Jerk search on zapped FFTs
    // Create channel of search tuples from params
    search_tuples_ch = Channel.from(params.search_params)

    // Combine each zapped FFT with all search tuples
    search_input = ZAPBIRDS.out.zapped_fft
        .combine(search_tuples_ch)

    // Run ACCELSEARCH for each (zmax, wmax) tuple
    ACCELSEARCH(
        search_input.map { dm, fft, inf, zmax, wmax -> [dm, fft, inf] },
        search_input.map { dm, fft, inf, zmax, wmax -> [zmax, wmax] },
        params.numharm,
        params.use_cuda,
        params.gpu_id,
        params.accelsearch_extra_flags
    )

    candidates_ch = ACCELSEARCH.out.candidates

    // Step 11: Sift candidates
    // Group by zmax and wmax (indices 1 and 2), collect all ACCEL files across all DMs
    ACCELSIFT(
        candidates_ch
            .map { dm, zmax, wmax, accel, cand, inffile -> [zmax, wmax, accel] }
            .groupTuple(by: [0, 1]),
        params.sigma_threshold,
        params.period_to_search_min,
        params.period_to_search_max,
        params.flag_remove_duplicates ? 1 : 0,
        params.flag_remove_harmonics ? 1 : 0
    )

    // Step 12: Combine fold parameters from all (zmax, wmax) combinations
    PARSE_SIFTED_CANDIDATES(
        ACCELSIFT.out.fold_params.collect()
    )

    // Step 13: Fold top candidates
    // Parse the fold_params.txt file and create fold inputs
    top_candidates = PARSE_SIFTED_CANDIDATES.out.fold_params
        .splitCsv(sep: '\t')
        .map { accelfile_name, candnum, dm ->
            [accelfile_name, candnum as Integer, dm as Double]
        }

    // Create a channel of [accelfile_name, accelfile_path, candfile_path, inffile_path] from ACCELSEARCH output
    accel_file_map = candidates_ch
        .map { dm, zmax, wmax, accel, cand, inffile ->
            [accel.name, accel, cand, inffile]
        }
        .unique()

    // Combine top candidates with their actual ACCEL, CAND, and INF file paths
    candidates_with_files = top_candidates
        .combine(accel_file_map)
        .filter { accelfile_name, candnum, dm, accel_name, accel_path, cand_path, inffile_path ->
            accelfile_name == accel_name
        }
        .map { accelfile_name, candnum, dm, accel_name, accel_path, cand_path, inffile_path ->
            [accel_path, cand_path, inffile_path, candnum, dm]
        }

    // Combine with original observation and all RFI products for folding
    fold_input = RFIFIND.out.rfi_products
        .combine(candidates_with_files)
        .map { obs, rfi_products, accelfile, candfile, inffile, candnum, dm ->
            [obs, rfi_products, accelfile, candfile, inffile, candnum, dm]
        }

    PREPFOLD(fold_input, params.npart, params.prepfold_extra_flags)

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
