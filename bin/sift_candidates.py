#!/usr/bin/env python3
"""
NEXTO candidate sifting script using PRESTO's sifting module
Based on PRESTO's ACCEL_sift.py
"""

import sys
import argparse
from operator import attrgetter
import sifting


# Speed of light in m/s (from PRESTO psr_constants)
SOL = 299792458.0

def z_to_accel(z, T, reffreq, harm=1):
    """Convert z (Fourier bins drifted) → acceleration (m/s^2)."""
    return z * SOL / (harm * reffreq * T**2)

def accel_to_z(accel, T, reffreq, harm=1):
    """Convert acceleration (m/s^2) → z (Fourier bins drifted)."""
    return accel * harm * reffreq * T**2 / SOL

def z_to_fdot(z, T):
    """Convert z → fdot (Hz/s)."""
    return z / T**2

def fdot_to_z(fdot, T):
    """Convert fdot (Hz/s) → z."""
    return fdot * T**2

def w_to_fddot(w, T):
    """Convert w → fddot (Hz/s^2)."""
    return w / T**3

def fddot_to_w(fddot, T):
    """Convert fddot (Hz/s^2) → w."""
    return fddot * T**3

def z_to_pdot(z, T, reffreq):
    """Convert z → pdot (s/s)."""
    return - (z / T**2) / (reffreq**2)

def pdot_to_z(pdot, T, reffreq):
    """Convert pdot → z."""
    return - pdot * (reffreq**2) * T**2

def w_to_pddot(w, T, reffreq):
    """Convert w → pddot (s/s^2)."""
    return - (w / T**3) / (reffreq**2)

def pddot_to_w(pddot, T, reffreq):
    """Convert pddot → w."""
    return - pddot * (reffreq**2) * T**3






def main():
    parser = argparse.ArgumentParser(
        description='Sift pulsar candidates using PRESTO sifting module'
    )
    parser.add_argument('accel_files', nargs='+',
                        help='ACCEL candidate files to sift')
    parser.add_argument('--min-period', type=float, default=0.0005,
                        help='Minimum period in seconds (default: 0.0005)')
    parser.add_argument('--max-period', type=float, default=15.0,
                        help='Maximum period in seconds (default: 15.0)')
    parser.add_argument('--sigma-threshold', type=float, default=6.0,
                        help='Minimum sigma threshold (default: 6.0)')
    parser.add_argument('--cpow-threshold', type=float, default=100.0,
                        help='Minimum coherent power threshold (default: 100.0)')
    parser.add_argument('--min-num-dms', type=int, default=1,
                        help='Minimum number of DMs for detection (default: 1)')
    parser.add_argument('--low-dm-cutoff', type=float, default=2.0,
                        help='Lowest DM to consider as real pulsar (default: 2.0)')
    parser.add_argument('--remove-duplicates', action='store_true',
                        help='Remove duplicate candidates')
    parser.add_argument('--remove-harmonics', action='store_true',
                        help='Remove harmonic candidates')
    parser.add_argument('--max-cands-to-fold', type=int, default=100,
                        help='Maximum candidates to fold (default: 100)')
    parser.add_argument('--output', default='sifted_candidates.txt',
                        help='Output file for sifted candidates')
    parser.add_argument('--fold-params', default='fold_params.txt',
                        help='Output file for fold parameters')
    parser.add_argument('--tobs', type=float, default=None,
                        help='Observation time in seconds (auto-detected if not provided)')

    args = parser.parse_args()

    # Configure PRESTO sifting thresholds
    sifting.sigma_threshold = args.sigma_threshold
    sifting.c_pow_threshold = args.cpow_threshold
    sifting.short_period = args.min_period
    sifting.long_period = args.max_period

    # Set other sifting parameters (using PRESTO defaults)
    sifting.r_err = 1.1  # Fourier bin proximity for duplicates
    sifting.harm_pow_cutoff = 8.0  # Minimum harmonic power
    sifting.known_birds_p = []  # Known RFI periods
    sifting.known_birds_f = []  # Known RFI frequencies

    print(f"Reading {len(args.accel_files)} ACCEL files...")

    # Read all candidates using PRESTO's sifting module
    cands = sifting.read_candidates(args.accel_files)
    print(f"Total candidates read: {len(cands)}")

    if not cands:
        print("No candidates found!")
        open(args.output, 'w').close()
        open(args.fold_params, 'w').close()
        return

    # Extract DM strings for DM problem checking
    # DMs are stored in candidate objects
    dm_set = set()
    for cand in cands:
        dm_set.add(cand.DM)
    dmstrs = ["%.2f" % dm for dm in sorted(dm_set)]

    print(f"Found {len(dmstrs)} unique DM values: {', '.join(dmstrs[:5])}{'...' if len(dmstrs) > 5 else ''}")

    # Apply sifting filters (following PRESTO ACCEL_sift.py logic)

    # Remove duplicate candidates
    if args.remove_duplicates and len(cands):
        print(f"\nRemoving duplicate candidates...")
        before = len(cands)
        cands = sifting.remove_duplicate_candidates(cands)
        print(f"  Removed {before - len(cands)} duplicates")
        print(f"  Remaining: {len(cands)} candidates")

    # Remove candidates with DM problems
    if len(cands) and args.min_num_dms > 1:
        print(f"\nRemoving candidates with DM problems (min_num_DMs={args.min_num_dms})...")
        before = len(cands)
        cands = sifting.remove_DM_problems(cands, args.min_num_dms, dmstrs, args.low_dm_cutoff)
        print(f"  Removed {before - len(cands)} candidates")
        print(f"  Remaining: {len(cands)} candidates")

    # Remove harmonically related candidates
    if args.remove_harmonics and len(cands):
        print(f"\nRemoving harmonic candidates...")
        before = len(cands)
        cands = sifting.remove_harmonics(cands)
        print(f"  Removed {before - len(cands)} harmonics")
        print(f"  Remaining: {len(cands)} candidates")

    if not cands:
        print("\nNo candidates passed all filters!")
        open(args.output, 'w').close()
        open(args.fold_params, 'w').close()
        return

    # Sort by sigma (descending)
    cands.sort(key=attrgetter('sigma'), reverse=True)

    # Determine observation time (needed for z to accel conversion)
    if args.tobs is not None:
        tobs = args.tobs
        print(f"\nUsing provided T_obs = {tobs:.1f} seconds")
    else:
        # Try to get from first candidate's inf file
        # PRESTO candidate objects have T attribute from inf file
        if hasattr(cands[0], 'T'):
            tobs = cands[0].T
            print(f"\nExtracted T_obs = {tobs:.1f} seconds from candidate inf data")
        else:
            # Fallback: estimate from first candidate
            print("\nWARNING: Could not determine T_obs, using default 300s")
            tobs = 300.0

    # Write sifted candidates to output file
    print(f"\nWriting sifted candidates to {args.output}...")     


    if len(cands):
        with open(args.output, 'w') as psrfold_file:

            cands.sort(key=attrgetter('sigma'), reverse=True)
            psrfold_file.write("#id   dm acc  F0 F1 F2 S/N\n")
            for k,cand in enumerate(cands):
                z0 = cand.z - 0.5 * cand.w
                r0 = cand.r - 0.5 * z0 - cand.w / 6.
                f = r0 / cand.T
                fd = z0 / (cand.T * cand.T)
                fdd = cand.w / (cand.T * cand.T * cand.T)
                f0 = f #+ fd * (cand.T / 2.) + 0.5 * fdd * (cand.T / 2.)**2
                f1 = fd #+ fdd * (cand.T / 2.)
                f2 = fdd
                psrfold_file.write("%d\t%.3f\t%.15f\t%.15f\t%.15f\t%.15f\t%.2f\n" % (k+1, cand.DM, 0., f0, f1, f2, cand.snr))
    

    # Write fold parameters

    print(f"\nSifting complete! {len(cands)} candidates passed all filters.")
    print(f"Top 10 candidates by sigma:")
    for i, cand in enumerate(cands[:10]):
        period_ms = (1.0 / (cand.r / tobs)) * 1000.0 if cand.r > 0 else 0.0
        print(f"  {i+1}. σ={cand.sigma:7.2f}  DM={cand.DM:7.2f}  P={period_ms:10.3f} ms  {cand.filename}")


if __name__ == '__main__':
    main()
