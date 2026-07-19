#!/usr/bin/env python3
"""
Prepare a PRESTO-derived candidate file for PulsarX psrfold_fil.

The candfiles written by sift_candidates.py contain BARYCENTRIC spin
parameters (the search ran on barycentered timeseries), referenced to the
START of the searched segment. psrfold_fil folds the raw (topocentric)
filterbank and does no barycentric correction, so this script:

  1. converts F0/F1/F2 to average topocentric values (baryv = average
     barycentric velocity v/c from compute_baryv.py). PRESTO's convention,
     the same one zapbirds -baryv relies on, is

         f_bary = f_topo * (1 + baryv)   =>   f_topo = f_bary / (1 + baryv)

     Topocentric time intervals are stretched by the same factor
     (dt_topo = dt_bary * (1 + baryv)), so the nth frequency derivative picks
     up one extra power: F1_topo = F1_bary / (1+baryv)^2, F2 / (1+baryv)^3.
  2. computes the TOPOCENTRIC pepoch of the segment start:
     pepoch = topocentric obs start (from the -nobary zero-DM .inf)
              + start_frac * Tobs.

The residual error from using the average baryv (Earth's velocity changes
during the observation) is small and absorbed by psrfold's f0/f1 search.

Writes the converted candfile and prints the pepoch (MJD) to stdout.
Uses only the python standard library (runs inside the PulsarX container).
"""

import argparse
import sys
from decimal import Decimal


def read_inf(inf_path):
    """Extract epoch (MJD), bin width (s) and number of bins from a .inf file."""
    epoch = dt = nbins = bary = None
    with open(inf_path) as f:
        for line in f:
            if '=' not in line:
                continue
            key, _, value = line.partition('=')
            key = key.strip()
            value = value.strip()
            if key.startswith('Epoch of observation'):
                epoch = Decimal(value)
            elif key.startswith('Width of each time series bin'):
                dt = Decimal(value)
            elif key.startswith('Number of bins in the time series'):
                nbins = int(value)
            elif key.startswith('Barycentered?'):
                bary = int(value)
    if epoch is None or dt is None or nbins is None:
        sys.exit(f"ERROR: could not parse epoch/dt/N from {inf_path}")
    if bary:
        sys.exit(f"ERROR: {inf_path} is barycentered; the topocentric "
                 "(zero-DM -nobary) .inf is required for the psrfold pepoch.")
    return epoch, dt, nbins


def main():
    parser = argparse.ArgumentParser(
        description='Convert a barycentric PRESTO candfile for topocentric psrfold_fil folding')
    parser.add_argument('candfile', help='candfile from sift_candidates.py (#id dm acc F0 F1 F2 S/N)')
    parser.add_argument('topo_inf', help='topocentric .inf of the full observation')
    # options (use --opt=value form: baryv is usually negative and argparse
    # would otherwise mistake it for a flag)
    parser.add_argument('--start-frac', required=True, type=str,
                        help='segment start fraction (0-1)')
    parser.add_argument('--baryv', required=True, type=str,
                        help='average barycentric velocity v/c')
    parser.add_argument('--output', required=True, help='output candfile for psrfold')
    args = parser.parse_args()

    epoch, dt, nbins = read_inf(args.topo_inf)
    tobs_s = dt * nbins
    start_frac = Decimal(args.start_frac)
    baryv = float(args.baryv)

    pepoch = epoch + start_frac * tobs_s / Decimal(86400)

    # f_bary = f_topo * (1 + baryv)  =>  divide to go barycentric -> topocentric.
    # Each time derivative gains another factor because topocentric time
    # intervals are stretched by the same (1 + baryv).
    doppler = 1.0 + baryv

    n_out = 0
    with open(args.candfile) as fin, open(args.output, 'w') as fout:
        fout.write("#id dm acc F0 F1 F2 S/N\n")
        for line in fin:
            line = line.strip()
            if not line or line.startswith('#'):
                continue
            fields = line.split()
            if len(fields) < 7:
                print(f"WARNING: skipping malformed candfile line: {line}",
                      file=sys.stderr)
                continue
            cand_id, dm, acc = fields[0], fields[1], fields[2]
            f0 = float(fields[3]) / doppler
            f1 = float(fields[4]) / doppler**2
            f2 = float(fields[5]) / doppler**3
            snr = fields[6]
            fout.write(f"{cand_id}\t{dm}\t{acc}\t{f0:.15f}\t{f1:.15e}\t{f2:.15e}\t{snr}\n")
            n_out += 1

    print(f"Converted {n_out} candidates (baryv={baryv:.6e}, "
          f"pepoch={pepoch})", file=sys.stderr)

    # stdout: pepoch for the psrfold command line
    print(pepoch)


if __name__ == '__main__':
    main()
