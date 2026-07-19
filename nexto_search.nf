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
    FILTOOL;
    RFIFIND;
    PREPDATA as PREPDATA_ZERODM;
    PREPDATA as PREPDATA_DMTRIALS;
    COMPUTE_BARYV;
    ACCELSEARCH_ZMAX0;
    ACCELSEARCH;
    ACCELSIFT;
    PREPFOLD_FROM_CANDFILE;
    PSRFOLD_PULSARX;
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
// Jerk searches (wmax > 0) only run on segments whose fraction is >= this
// value. 0.0 = no restriction (every search_params tuple runs on every
// segment); e.g. 0.5 restricts jerk searches to the full and half segments.
params.jerk_min_fraction = 0.0
params.numharm = 8
params.sigma_threshold = 2.0
params.sigma_birdies_threshold = 15.0
params.rfifind_time = 2.0
params.rfifind_freqsig = 4.0
params.rfifind_extra_flags = ""
params.prepdata_extra_flags = ""
params.accelsearch_extra_flags = ""
params.prepfold_extra_flags = ""
params.npart = 50
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
        --input                Path to input observation file(s) (.fil or .fits).
                               A glob pattern selects multiple observations/beams;
                               each is processed and published independently.

    Output:
        --outdir               Output directory (default: results)

    Filterbank Processing (PulsarX):
        --enable_filtool       Enable filtool preprocessing (default: true)
        --filtool_time_decimate    Time decimation factor (default: 1)
        --filtool_freq_decimate    Frequency decimation factor (default: 1)
        --filtool_telescope    Telescope name (default: "meerkat")
        --filtool_rfi_filter   RFI filter string (default: "kadaneF 8 4 zdot")
        --filtool_extra_args   Additional filtool arguments (default: "")

    Dedispersion:
        --dm_low               Minimum DM to search (default: 0.0)
        --dm_high              Maximum DM to search (default: 100.0)
        --dm_step              DM step size (default: 0.5)
        --downsample           Downsampling factor (default: 1)

    RFI removal:
        --rfifind_time         Time interval for rfifind (default: 2.0)
        --rfifind_freqsig      Freq sigma for rfifind (default: 4.0)
        --rfifind_extra_flags  Additional flags for rfifind (default: "")

    Segmentation:
        --segments             List of [name, fraction] tuples (default: [["full",1.0],["half",0.5]])
                               Each segment can be a fraction of the observation
        --publish_timeseries   Publish .dat/.inf files (default: false, can be large)

    Periodicity search:
        --search_params        List of [zmax,wmax] tuples (default: [[0,0],[50,0],[200,0]])
                               If wmax=0: acceleration search, if wmax>0: jerk search
        --jerk_min_fraction    Only run jerk searches (wmax>0) on segments whose
                               fraction is >= this value (default: 0.0 = all segments)
        --numharm              Number of harmonics (default: 8)
        --use_cuda             Enable GPU acceleration (default: false)
        --gpu_id               GPU device ID (default: 0)
        --prepdata_extra_flags Additional flags for prepdata (default: "")
        --accelsearch_extra_flags Additional flags for accelsearch (default: "")

    Candidate selection:
        --sigma_threshold      Minimum sigma for candidates (default: 6.0)
        --sigma_birdies_threshold  Minimum sigma for birdie detection (default: 15.0)
        --period_to_search_min Minimum period to search in seconds (default: 0.001)
        --period_to_search_max Maximum period to search in seconds (default: 15.0)
        --flag_remove_duplicates   Remove duplicate candidates (default: true)
        --flag_remove_harmonics    Remove harmonic candidates (default: true)
        --max_cands_to_fold    Maximum candidates to fold per segment (default: 100)

    Folding:
        --fold_with_psrfold    Use PulsarX psrfold instead of PRESTO prepfold (default: false)
        --npart                Number of subintegrations for PRESTO folding (default: 50)
        --prepfold_extra_flags Additional flags for prepfold (default: "")
        --psrfold_nbin         Number of phase bins for psrfold (default: 64)
        --psrfold_extra_flags  Additional flags for psrfold (default: "")

    Single pulse search:
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
    // Create input channel keyed by a canonical observation id: the file
    // basename with any pre-existing _filtool suffix stripped. Every process
    // publishes under this id, so all results of one observation land in a
    // single directory and multiple observations (beams) never mix.
    observation_ch = Channel.fromPath(params.input, checkIfExists: true)
        .map { obs -> [obs.baseName.split('_filtool')[0], obs] }

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

    // Step 1: RFI detection
    RFIFIND(
        processed_obs,
        params.rfifind_time,
        params.rfifind_freqsig,
        params.rfifind_extra_flags
    )

    // Step 2: Zero-DM prepdata with -nobary for birdie detection
    zero_dm_input = RFIFIND.out.rfi_products
        .map { obs_id, obs, rfi_products ->
            [obs_id, obs, rfi_products, 0.0, params.downsample, true, params.prepdata_extra_flags]
        }

    // Run prepdata with DM=0 and nobary=true
    PREPDATA_ZERODM(zero_dm_input)

    // Topocentric .inf of each observation: used for the barycentric velocity
    // and (with psrfold) for the topocentric pepoch of segment starts
    topo_inf_ch = PREPDATA_ZERODM.out.timeseries
        .map { obs_id, dm, datfile, inffile -> [obs_id, inffile] }

    // Average barycentric velocity (v/c) per observation, needed to apply the
    // topocentric zaplist to barycentered FFTs (zapbirds -baryv) and to
    // convert candidate frequencies for topocentric psrfold folding
    COMPUTE_BARYV(topo_inf_ch)
    baryv_ch = COMPUTE_BARYV.out.baryv

    // Step 3: Identify birdies (RFI lines) using z=0 search on zero-DM
    // ACCELSEARCH_ZMAX0 will do FFT, rednoise, and accelsearch internally
    ACCELSEARCH_ZMAX0(
        PREPDATA_ZERODM.out.timeseries,
        params.numharm
    )

    // Step 4: Create zaplist from birdies (per observation)
    MAKE_ZAPLIST(
        ACCELSEARCH_ZMAX0.out.accel_zero
            .map { obs_id, accel, cand, txtcand -> [obs_id, accel] }
            .join(topo_inf_ch),
        params.sigma_birdies_threshold
    )

    // Step 5: Now do the actual DM trials WITHOUT -nobary
    // Generate DM values as a list (BigDecimal arithmetic avoids float drift)
    def dm_values = []
    def dm = new BigDecimal(params.dm_low.toString())
    def dm_high = new BigDecimal(params.dm_high.toString())
    def dm_step = new BigDecimal(params.dm_step.toString())
    while (dm <= dm_high) {
        dm_values << dm
        dm = dm.add(dm_step)
    }

    // Combine observation with RFI products and DM values, with nobary=false
    dm_trials_input = RFIFIND.out.rfi_products
        .combine(Channel.from(dm_values))
        .map { obs_id, obs, rfi_products, dm_trial ->
            [obs_id, obs, rfi_products, dm_trial, params.downsample, false, params.prepdata_extra_flags]
        }

    // Run prepdata for all DM trials without -nobary
    PREPDATA_DMTRIALS(dm_trials_input)

    // Step 6: Create segment channel: each [name, fraction] tuple expands
    // into its chunks (e.g. ["half", 0.5] -> chunks 1 and 2)
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

    // Step 7: Acceleration/Jerk search (includes split, FFT, rednoise,
    // zapbirds, accelsearch). Fan out over segments and [zmax, wmax] search
    // tuples, then join the per-observation zaplist and baryv by obs_id.
    search_tuples_ch = Channel.from(params.search_params)

    accel_input = PREPDATA_DMTRIALS.out.timeseries
        .combine(segments_ch)
        .combine(search_tuples_ch)
        .filter { obs_id, dm_trial, datfile, inffile, segment_name, fraction, chunk_num, total_chunks, zmax, wmax ->
            wmax == 0 || (fraction as BigDecimal) >= (params.jerk_min_fraction as BigDecimal)
        }
        .combine(MAKE_ZAPLIST.out.zaplist, by: 0)
        .combine(baryv_ch, by: 0)
        .map { obs_id, dm_trial, datfile, inffile, segment_name, fraction, chunk_num, total_chunks, zmax, wmax, zaplist, baryv ->
            [obs_id, dm_trial, datfile, inffile, segment_name, fraction, chunk_num, total_chunks, zmax, wmax, zaplist, baryv]
        }

    ACCELSEARCH(
        accel_input,
        params.numharm,
        params.use_cuda,
        params.gpu_id,
        params.accelsearch_extra_flags
    )

    // Step 8: Sift candidates.
    // One sift job per (observation, segment chunk): all DM trials and all
    // zmax/wmax searches of that chunk are sifted together, so duplicates and
    // harmonics are removed across search configurations. Different
    // observations (beams) are never mixed.
    ACCELSIFT(
        ACCELSEARCH.out.candidates
            .map { obs_id, dm_trial, segment_name, fraction, chunk_num, zmax, wmax, accel, cand, txtcand, inffile ->
                def segment_label = "${segment_name}_${chunk_num}".toString()
                def start_frac = (chunk_num - 1) * fraction
                def end_frac = chunk_num * fraction
                [obs_id, segment_label, start_frac, end_frac, accel]
            }
            .groupTuple(by: [0, 1, 2, 3]),
        params.sigma_threshold,
        params.period_to_search_min,
        params.period_to_search_max,
        params.flag_remove_duplicates ? 1 : 0,
        params.flag_remove_harmonics ? 1 : 0
    )

    // Step 9: Fold top candidates
    if (params.fold_with_psrfold) {
        // PSRFOLD: one job per sifted candidate file (one per segment chunk).
        // The candfile spin parameters are converted to topocentric values
        // inside the process (psrfold folds the raw filterbank and does no
        // barycentric correction); pepoch is the topocentric segment start.
        fold_input_psrfold = RFIFIND.out.rfi_products
            .map { obs_id, obs, rfi_products -> [obs_id, obs] }
            .combine(ACCELSIFT.out.sifted_candidates, by: 0)
            .combine(topo_inf_ch, by: 0)
            .combine(baryv_ch, by: 0)

        PSRFOLD_PULSARX(fold_input_psrfold, params.psrfold_nbin, params.psrfold_nsubint, params.coherent_dm, params.psrfold_extra_flags)
    } else {
        // PREPFOLD: one job per candidate (per line in each sifted candfile)
        // candfile format: #id dm acc F0 F1 F2 S/N
        top_candidates = ACCELSIFT.out.sifted_candidates
            .flatMap { obs_id, segment_label, start_frac, end_frac, candfile ->
                candfile.splitCsv(sep: '\t', skip: 1).collect { row ->
                    [obs_id, segment_label, start_frac, end_frac, row]
                }
            }
            .map { obs_id, segment_label, start_frac, end_frac, row ->
                def cand_id = row[0] as Integer
                def cand_dm = row[1] as Double
                def f0 = row[3] as Double
                def f1 = row[4] as Double
                def f2 = row[5] as Double
                [obs_id, segment_label, start_frac, end_frac, cand_id, cand_dm, f0, f1, f2]
            }

        // Join each candidate with its own observation and RFI products
        fold_input_prepfold = RFIFIND.out.rfi_products
            .combine(top_candidates, by: 0)
            .map { obs_id, obs, rfi_products, segment_label, start_frac, end_frac, cand_id, cand_dm, f0, f1, f2 ->
                [obs_id, obs, rfi_products, segment_label, start_frac, end_frac, cand_id, cand_dm, f0, f1, f2]
            }

        PREPFOLD_FROM_CANDFILE(fold_input_prepfold, params.npart, params.prepfold_extra_flags)
    }

    // Step 10: Optional single pulse search (on barycentered DM trials)
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
