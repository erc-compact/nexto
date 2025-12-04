#!/usr/bin/env python3
"""
Generate PulsarX candidate files from PRESTO ACCEL search results.
Based on one_ring/scripts/fold_peasoup_candidates.py

This script reads fold_params files and ACCEL files from PRESTO acceleration
search and converts them into the format required by psrfold_fil2 for batch
candidate folding.
"""

import sys
import re
import argparse
from pathlib import Path


def parse_number(token):
    """Parse a number from a token, handling parenthesized uncertainties.

    ACCEL files contain values like "123.45(0.12)" where the parentheses
    contain the uncertainty. This function extracts just the value.
    """
    token = token.strip()
    if '(' in token:
        token = token.split('(')[0]
    try:
        return float(token)
    except ValueError:
        return 0.0


def get_valid_lines_count(accel_path):
    """Determine how many lines in the ACCEL file contain valid candidates.

    ACCEL files have candidate lines followed by harmonic information.
    We only want the fundamental candidates, which appear before the
    second "Harm" marker.
    """
    with open(accel_path) as f:
        harm_count = 0
        for line_num, line in enumerate(f, 1):
            if 'Harm' in line:
                harm_count += 1
                if harm_count == 2:
                    return line_num - 2
    return None


def parse_accel_candidate(accel_path, cand_num, valid_lines):
    """Parse a specific candidate from an ACCEL file.

    Returns a tuple of (sigma, f0, accel_val) or None if not found.
    """
    with open(accel_path) as f:
        for idx, line in enumerate(f):
            if idx >= valid_lines:
                break
            if not line.strip() or not line.lstrip()[0].isdigit():
                continue

            parts = line.split()
            if len(parts) < 11:
                continue

            try:
                cand_id = int(parts[0])
            except ValueError:
                continue

            if cand_id != cand_num:
                continue

            # ACCEL file format:
            # 0:cand_id 1:sigma 2:ipow 3:cpow 4:numharm 5:period 6:p_err 7:frequency 8:f_err 9:fdot 10:fdot_err
            sigma = parse_number(parts[1])
            f0 = parse_number(parts[7])      # Frequency (column 7)
            accel_val = parse_number(parts[9])  # Fdot/accel (column 9)

            print(f"DEBUG: Parsed candidate {cand_id} from {accel_path}: "
                  f"sigma={sigma}, f0={f0}, accel={accel_val}", file=sys.stderr)

            return sigma, f0, accel_val

    return None


def get_pepoch_from_inf(inf_path):
    """Extract the observation epoch (MJD) from a PRESTO .inf file.

    The .inf file contains a line like:
    " Epoch of observation (MJD)             =  58937.198334493004950"
    """
    with open(inf_path) as f:
        for line in f:
            if 'Epoch of observation' in line and 'MJD' in line:
                parts = line.split('=')
                if len(parts) == 2:
                    try:
                        return float(parts[1].strip())
                    except ValueError:
                        continue
    return None


def generate_pulsarx_cand_file_batch(output_file, candidates):
    """Generate candidate file in PulsarX format for multiple candidates.

    Format: #id DM accel F0 F1 F2 S/N
    where F1 and F2 are set to 0 for acceleration search.

    Args:
        output_file: Path to output file
        candidates: List of tuples (cand_id, dm, accel, f0, sigma)
    """
    with open(output_file, 'w') as f:
        f.write("#id DM accel F0 F1 F2 S/N\n")
        for cand_id, dm, accel, f0, sigma in candidates:
            f.write(f"{cand_id} {dm} {accel} {f0} 0 0 {sigma}\n")


def main():
    parser = argparse.ArgumentParser(
        description='Generate PulsarX candidate files from PRESTO fold_params'
    )
    parser.add_argument('fold_params', help='fold_params file with candidate list')
    parser.add_argument('inf_file', help='PRESTO .inf file (for pepoch)')
    parser.add_argument('--output', default='pulsarx.candfile',
                        help='Output candidate file name')

    args = parser.parse_args()

    # Get pepoch first (same for all candidates)
    pepoch = get_pepoch_from_inf(args.inf_file)
    if pepoch is None:
        print(f"ERROR: Could not extract pepoch from {args.inf_file}", file=sys.stderr)
        sys.exit(1)

    # Parse fold_params file
    # Format: accelfile\tcandnum\tdm\taccel\tf0\tsigma (extended format from sift_candidates.py)
    candidates = []

    with open(args.fold_params) as f:
        for line_num, line in enumerate(f, 1):
            line = line.strip()
            if not line:
                continue

            parts = line.split('\t')

            # Support both old format (3 fields) and new extended format (6 fields)
            if len(parts) == 6:
                # New extended format: accelfile, candnum, dm, accel, f0, sigma
                try:
                    accel_file = parts[0]
                    cand_num = int(parts[1])
                    dm = float(parts[2])
                    accel_val = float(parts[3])
                    f0 = float(parts[4])
                    sigma = float(parts[5])
                except ValueError as e:
                    print(f"WARNING: Skipping line {line_num} due to parse error: {e}", file=sys.stderr)
                    continue

                candidates.append((cand_num, dm, accel_val, f0, sigma))
                print(f"  Loaded candidate {cand_num}: DM={dm}, F0={f0} Hz, Accel={accel_val}, S/N={sigma}",
                      file=sys.stderr)

            elif len(parts) == 3:
                # Old format: accelfile, candnum, dm - need to read ACCEL file
                print(f"WARNING: Old format detected on line {line_num}, reading from ACCEL file", file=sys.stderr)
                accel_file = parts[0]
                try:
                    cand_num = int(parts[1])
                    dm = float(parts[2])
                except ValueError as e:
                    print(f"WARNING: Skipping line {line_num} due to parse error: {e}", file=sys.stderr)
                    continue

                # Check if ACCEL file exists
                if not Path(accel_file).exists():
                    print(f"WARNING: ACCEL file not found: {accel_file}", file=sys.stderr)
                    continue

                # Get valid lines count
                valid_lines = get_valid_lines_count(accel_file)
                if valid_lines is None:
                    print(f"WARNING: Could not determine valid lines in {accel_file}", file=sys.stderr)
                    continue

                # Parse candidate
                result = parse_accel_candidate(accel_file, cand_num, valid_lines)
                if result is None:
                    print(f"WARNING: Could not find candidate {cand_num} in {accel_file}",
                          file=sys.stderr)
                    continue

                sigma, f0, accel_val = result
                candidates.append((cand_num, dm, accel_val, f0, sigma))
                print(f"  Parsed candidate {cand_num}: DM={dm}, F0={f0} Hz, Accel={accel_val}, S/N={sigma}",
                      file=sys.stderr)
            else:
                print(f"WARNING: Skipping malformed line {line_num}: expected 3 or 6 fields, got {len(parts)}", file=sys.stderr)
                continue

    if not candidates:
        print("ERROR: No valid candidates found", file=sys.stderr)
        sys.exit(1)

    # Generate candidate file
    generate_pulsarx_cand_file_batch(args.output, candidates)

    # Print pepoch to stdout for bash to capture
    print(f"{pepoch}")
    print(f"\nGenerated candidate file: {args.output}", file=sys.stderr)
    print(f"  Total candidates: {len(candidates)}", file=sys.stderr)
    print(f"  Pepoch (MJD): {pepoch}", file=sys.stderr)


if __name__ == '__main__':
    main()
