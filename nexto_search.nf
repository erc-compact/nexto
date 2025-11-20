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
    REALFFT as REALFFT_ZERODM;
    REALFFT as REALFFT_DMTRIALS;
    REDNOISE as REDNOISE_ZERODM;
    REDNOISE as REDNOISE_DMTRIALS;
    ZAPBIRDS;
    ACCELSEARCH_ZMAX0;
    ACCELSEARCH;
    ACCELSIFT;
    PREPFOLD;
    PREPFOLD_TIMESERIES;
    SINGLE_PULSE_SEARCH;
    MAKE_ZAPLIST;
    COMBINE_CANDIDATES
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

    // Step 7: FFT processing for DM trials
    REALFFT_DMTRIALS(PREPDATA_DMTRIALS.out.timeseries)
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

    candidates_ch.view()

    // Step 11: Sift candidates
    // Group by DM and collect all accel/cand files
    ACCELSIFT(
        candidates_ch
            .groupTuple(by: 0)
            .map { dm, zmax_list, wmax_list, accel_list, cand_list ->
                [dm, accel_list.flatten(), cand_list.flatten()]
            },
        params.sigma_threshold
    )

    // Step 12: Combine all candidates
    COMBINE_CANDIDATES(
        candidates_ch
            .map { dm, zmax, wmax, accel, cand -> cand }
            .collect()
    )

    // Step 13: Fold top candidates
    // Parse top candidates and fold them
    top_candidates = ACCELSIFT.out.sifted_candidates
        .flatMap { dm, sift, cands ->
            // Parse candidate file and extract top candidates
            // This is simplified - in practice you'd parse the .cands file
            // For now, we'll create a simple channel structure
            []
        }

    // Combine with original observation for folding
    fold_input = RFIFIND.out.rfi_products
        .combine(top_candidates)

    // PREPFOLD(fold_input, params.npart, params.dmstep)

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
