#!/usr/bin/env python3
"""
Custom candidate sifting script for NEXTO pipeline
Based on PULSAR_MINER and PRESTO sifting logic
"""

import sys
import re
import glob
import argparse
from collections import defaultdict
import math


class Candidate:
    """Represents a pulsar candidate detection"""

    def __init__(self, candnum, sigma, ipow, cpow, numharm, r, z, filename, dm):
        self.candnum = int(candnum)
        self.sigma = float(sigma)
        self.ipow_det = float(ipow)
        self.cpow = float(cpow)
        self.numharm = int(numharm)
        self.r = float(r)  # Fourier bin
        self.z = float(z)  # Acceleration
        self.filename = filename
        self.DM = float(dm)

        # Will be set when we know observation time
        self.f = None  # Frequency
        self.p = None  # Period

        self.hits = []  # Duplicate detections at other DMs
        self.note = ""  # Rejection reason

    def set_period_from_tobs(self, tobs):
        """Calculate frequency and period from observation time"""
        self.f = self.r / tobs
        self.p = 1.0 / self.f if self.f > 0 else 0

    def __repr__(self):
        return f"Cand({self.candnum}, σ={self.sigma:.2f}, DM={self.DM:.2f}, P={self.p:.6f}s)"


def parse_accel_file(filename):
    """Parse an ACCEL candidate file and return list of candidates"""
    candidates = []

    # Extract DM from filename (format: DM##.##)
    dm_match = re.search(r'DM(\d+\.\d{2})', filename)
    if not dm_match:
        print(f"Warning: Could not extract DM from filename {filename}")
        return candidates

    dm = dm_match.group(1)

    # Read the file
    try:
        with open(filename, 'r') as f:
            lines = f.readlines()
    except Exception as e:
        print(f"Error reading {filename}: {e}")
        return candidates

    # Parse fundamental candidates (lines starting with digit)
    for line in lines:
        if not line.strip() or line.startswith('#'):
            continue

        # Check if it's a fundamental candidate line (starts with digit)
        if re.match(r'^\d', line):
            parts = line.split()
            if len(parts) < 10:
                continue

            try:
                candnum = parts[0]
                sigma = parts[1]
                ipow = parts[2]
                cpow = parts[3]
                numharm = parts[4]
                # Column 7 has format "123.45(0.12)" - extract first number
                r = parts[7].split('(')[0]
                # Column 9 has format "12.34(0.12)" - extract first number
                z = parts[9].split('(')[0]

                cand = Candidate(candnum, sigma, ipow, cpow, numharm, r, z, filename, dm)
                candidates.append(cand)

            except (ValueError, IndexError) as e:
                print(f"Warning: Could not parse line in {filename}: {line.strip()}")
                continue

    return candidates


def estimate_tobs_from_candidates(candidates):
    """Estimate observation time from candidates
    PRESTO uses T_obs from the inf file, but we can estimate from the data
    Typical pulsar searches have T_obs in the filename or we use a default
    """
    # Try to extract from filename patterns like "300s" or use default
    if candidates:
        filename = candidates[0].filename
        # Look for time in filename
        time_match = re.search(r'(\d+)s', filename)
        if time_match:
            return float(time_match.group(1))

    # Default: estimate from typical survey parameters
    # Most searches are 60-3600 seconds
    return 300.0  # Default 5 minutes


def reject_short_period(candidates, min_period):
    """Remove candidates with periods shorter than minimum"""
    good = []
    rejected = []

    for cand in candidates:
        if cand.p >= min_period:
            good.append(cand)
        else:
            cand.note = f"short_period (P={cand.p:.6f}s < {min_period}s)"
            rejected.append(cand)

    return good, rejected


def reject_long_period(candidates, max_period):
    """Remove candidates with periods longer than maximum"""
    good = []
    rejected = []

    for cand in candidates:
        if cand.p <= max_period:
            good.append(cand)
        else:
            cand.note = f"long_period (P={cand.p:.6f}s > {max_period}s)"
            rejected.append(cand)

    return good, rejected


def remove_duplicate_candidates(candidates, r_err=1.1):
    """Remove duplicate candidates (same Fourier bin, different DMs)

    Keeps the highest sigma detection and adds others as 'hits'
    """
    if not candidates:
        return []

    # Sort by Fourier bin
    candidates.sort(key=lambda c: c.r)

    unique = []
    i = 0

    while i < len(candidates):
        current = candidates[i]
        duplicates = [current]

        # Find all candidates within r_err bins
        j = i + 1
        while j < len(candidates) and abs(candidates[j].r - current.r) <= r_err:
            duplicates.append(candidates[j])
            j += 1

        # Keep the one with highest sigma
        best = max(duplicates, key=lambda c: c.sigma)

        # Add others as hits
        for dup in duplicates:
            if dup is not best:
                best.hits.append({
                    'DM': dup.DM,
                    'sigma': dup.sigma,
                    'filename': dup.filename
                })

        unique.append(best)
        i = j if j > i + 1 else i + 1

    return unique


def remove_harmonics(candidates):
    """Remove candidates that are harmonics of stronger candidates"""
    if not candidates:
        return []

    # Sort by sigma (descending) to process strongest first
    candidates.sort(key=lambda c: c.sigma, reverse=True)

    good = []

    for i, cand in enumerate(candidates):
        is_harmonic = False

        # Check against all stronger candidates already added
        for other in good:
            if other.sigma <= cand.sigma:
                continue

            # Check if cand is a harmonic of other
            ratio = cand.f / other.f if other.f > 0 else 0

            # Check integer harmonics (2, 3, 4, ...)
            for n in range(2, 17):  # Check up to 16th harmonic
                if abs(ratio - n) < 0.01 or abs(1.0/ratio - n) < 0.01:
                    is_harmonic = True
                    cand.note = f"harmonic_{n}x of {other.filename}:cand{other.candnum}"
                    break

            # Check fractional harmonics (3/2, 5/2, 5/3, etc.)
            if not is_harmonic:
                for num in [3, 5, 7]:
                    for denom in [2, 3, 4]:
                        if num > denom:
                            frac = num / denom
                            if abs(ratio - frac) < 0.01 or abs(1.0/ratio - frac) < 0.01:
                                is_harmonic = True
                                cand.note = f"harmonic_{num}/{denom} of {other.filename}:cand{other.candnum}"
                                break
                    if is_harmonic:
                        break

            if is_harmonic:
                break

        if not is_harmonic:
            good.append(cand)

    return good


def write_candlist(candidates, output_file):
    """Write candidates to output file in PRESTO format"""
    with open(output_file, 'w') as f:
        f.write("# DM      Sigma      Period(ms)     FFT_bin    Accel(m/s/s)  NumHarm  FileName\n")
        for cand in candidates:
            f.write(f"{cand.DM:8.2f}  {cand.sigma:8.2f}  {cand.p*1000:12.6f}  "
                   f"{cand.r:10.2f}  {cand.z:12.2f}  {cand.numharm:4d}     {cand.filename}\n")


def write_fold_params(candidates, output_file, max_cands):
    """Write folding parameters for top candidates"""
    with open(output_file, 'w') as f:
        for i, cand in enumerate(candidates[:max_cands]):
            # Format: accelfile, candnum, dm
            f.write(f"{cand.filename}\t{cand.candnum}\t{cand.DM}\n")


def main():
    parser = argparse.ArgumentParser(description='Sift pulsar candidates from ACCEL files')
    parser.add_argument('accel_files', nargs='+', help='ACCEL candidate files to sift')
    parser.add_argument('--min-period', type=float, default=0.001, help='Minimum period (s)')
    parser.add_argument('--max-period', type=float, default=15.0, help='Maximum period (s)')
    parser.add_argument('--sigma-threshold', type=float, default=6.0, help='Sigma threshold')
    parser.add_argument('--remove-duplicates', action='store_true', help='Remove duplicate candidates')
    parser.add_argument('--remove-harmonics', action='store_true', help='Remove harmonic candidates')
    parser.add_argument('--max-cands-to-fold', type=int, default=100, help='Max candidates for folding')
    parser.add_argument('--output', default='sifted_candidates.txt', help='Output file')
    parser.add_argument('--fold-params', default='fold_params.txt', help='Fold parameters output')

    args = parser.parse_args()

    # Read all ACCEL files
    print(f"Reading {len(args.accel_files)} ACCEL files...")
    all_candidates = []

    for accel_file in args.accel_files:
        cands = parse_accel_file(accel_file)
        all_candidates.extend(cands)
        print(f"  {accel_file}: {len(cands)} candidates")

    print(f"\nTotal candidates read: {len(all_candidates)}")

    if not all_candidates:
        print("No candidates found!")
        # Create empty output files
        open(args.output, 'w').close()
        open(args.fold_params, 'w').close()
        return

    # Estimate observation time and set periods
    tobs = estimate_tobs_from_candidates(all_candidates)
    print(f"Using T_obs = {tobs:.1f} seconds")

    for cand in all_candidates:
        cand.set_period_from_tobs(tobs)

    # Apply period filters
    print(f"\nApplying period filter: {args.min_period} < P < {args.max_period} seconds...")
    candidates, rejected = reject_short_period(all_candidates, args.min_period)
    print(f"  Rejected {len(rejected)} short-period candidates")

    candidates, rejected = reject_long_period(candidates, args.max_period)
    print(f"  Rejected {len(rejected)} long-period candidates")
    print(f"  Remaining: {len(candidates)} candidates")

    # Remove duplicates if requested
    if args.remove_duplicates and len(candidates) > 0:
        print(f"\nRemoving duplicate candidates...")
        before = len(candidates)
        candidates = remove_duplicate_candidates(candidates)
        print(f"  Removed {before - len(candidates)} duplicates")
        print(f"  Remaining: {len(candidates)} candidates")

    # Remove harmonics if requested
    if args.remove_harmonics and len(candidates) > 0:
        print(f"\nRemoving harmonic candidates...")
        before = len(candidates)
        candidates = remove_harmonics(candidates)
        print(f"  Removed {before - len(candidates)} harmonics")
        print(f"  Remaining: {len(candidates)} candidates")

    # Sort by sigma (descending)
    candidates.sort(key=lambda c: c.sigma, reverse=True)

    # Write output
    print(f"\nWriting sifted candidates to {args.output}...")
    write_candlist(candidates, args.output)

    print(f"Writing fold parameters to {args.fold_params}...")
    write_fold_params(candidates, args.fold_params, args.max_cands_to_fold)

    print(f"\nSifting complete! {len(candidates)} candidates passed all filters.")
    print(f"Top 10 candidates by sigma:")
    for i, cand in enumerate(candidates[:10]):
        print(f"  {i+1}. {cand}")


if __name__ == '__main__':
    main()
