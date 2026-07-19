#!/usr/bin/env python3
"""
Compute the average barycentric velocity (v/c) of an observation from a
PRESTO .inf file, using presto.presto.get_baryv (same approach as
PULSAR_MINER).

The value is needed to:
  - apply topocentric birdie zaplists to barycentered FFTs
    (zapbirds -baryv), and
  - convert barycentric candidate frequencies to topocentric ones for
    PulsarX psrfold_fil, which folds raw (topocentric) filterbank data.

The .inf file must be TOPOCENTRIC (e.g. from the prepdata -nobary zero-DM
run) so that its epoch is a topocentric MJD.

Prints the (v/c) value to stdout.
"""

import argparse
import sys

try:
    from presto import infodata
    from presto.presto import get_baryv
except ImportError:
    print("ERROR: PRESTO python module not found; run inside the PRESTO container.",
          file=sys.stderr)
    sys.exit(1)

# Telescope name (lowercased substring) -> TEMPO observatory code
OBS_CODES = {
    "gbt": "GB",
    "green bank": "GB",
    "arecibo": "AO",
    "vla": "VL",
    "parkes": "PK",
    "jodrell": "JB",
    "lovell": "JB",
    "nancay": "NC",
    "effelsberg": "EF",
    "srt": "SR",
    "sardinia": "SR",
    "fast": "FA",
    "meerkat": "MK",
    "gmrt": "GM",
    "chime": "CH",
    "lofar": "LF",
    "mwa": "MW",
    "geocenter": "0 ",
}


def telescope_to_code(name):
    lname = name.lower()
    for key, code in OBS_CODES.items():
        if key in lname:
            return code
    return None


def main():
    parser = argparse.ArgumentParser(
        description="Compute average barycentric velocity (v/c) from a topocentric .inf file")
    parser.add_argument("inf_file", help="PRESTO .inf file (topocentric)")
    args = parser.parse_args()

    inf = infodata.infodata(args.inf_file)

    if int(getattr(inf, "bary", 0)):
        print(f"ERROR: {args.inf_file} is barycentered; a topocentric .inf "
              "(e.g. from the zero-DM -nobary prepdata run) is required.",
              file=sys.stderr)
        sys.exit(1)

    obs_code = telescope_to_code(inf.telescope)
    if obs_code is None:
        print(f"ERROR: unknown telescope '{inf.telescope}' - add it to "
              "OBS_CODES in bin/compute_baryv.py", file=sys.stderr)
        sys.exit(1)

    tobs = inf.dt * inf.N
    baryv = get_baryv(inf.RA, inf.DEC, inf.epoch, tobs, obs=obs_code)

    print(f"Telescope: {inf.telescope} (code {obs_code})", file=sys.stderr)
    print(f"Epoch (topo MJD): {inf.epoch}, Tobs: {tobs:.3f} s", file=sys.stderr)
    print(f"Average barycentric velocity (v/c): {baryv:.10e}", file=sys.stderr)

    print(f"{baryv:.10e}")


if __name__ == "__main__":
    main()
