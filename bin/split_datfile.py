#!/usr/bin/env python3
"""
Split PRESTO .dat files into segments
Based on PULSAR_MINER's pm_split_datfile approach
"""

import sys
import argparse
import struct
import os


def read_inf_file(inf_file):
    """Read key parameters from .inf file"""
    params = {}
    with open(inf_file, 'r') as f:
        for line in f:
            line = line.strip()
            if '=' in line:
                key, value = line.split('=', 1)
                key = key.strip()
                value = value.strip()

                # Extract key parameters
                if key == 'Number of bins in the time series':
                    params['num_samples'] = int(value)
                elif key == 'Width of each time series bin (sec)':
                    params['dt'] = float(value)
                elif key == 'Telescope used':
                    params['telescope'] = value
                elif key == 'Instrument used':
                    params['instrument'] = value
                elif key == 'Object being observed':
                    params['object'] = value
                elif key == 'J2000 Right Ascension (hh:mm:ss.ssss)':
                    params['ra'] = value
                elif key == 'J2000 Declination     (dd:mm:ss.ssss)':
                    params['dec'] = value
                elif key == 'Data observed by':
                    params['observer'] = value
                elif key == 'Epoch of observation (MJD)':
                    params['mjd'] = float(value)
                elif key == 'Barycentered?           (1=yes, 0=no)':
                    params['barycentered'] = int(value)
                elif key == 'Source name (J2000)':
                    params['source'] = value
                elif key == 'Dispersion measure (pc/cm^3)':
                    params['dm'] = float(value)
                elif key == 'Central freq of low channel (MHz)':
                    params['freq_low'] = float(value)
                elif key == 'Total bandwidth (MHz)':
                    params['bandwidth'] = float(value)
                elif key == 'Number of channels':
                    params['num_channels'] = int(value)
                elif key == 'Channel bandwidth (MHz)':
                    params['chan_bandwidth'] = float(value)
                elif key == 'Data analyzed by':
                    params['analyzed_by'] = value

    return params


def write_inf_file(inf_file, params, basename, start_sample, num_samples):
    """Write updated .inf file for segment"""
    dt = params['dt']
    total_time = num_samples * dt
    start_time = start_sample * dt

    with open(inf_file, 'w') as f:
        f.write(f" Data file name without suffix          =  {basename}\n")
        f.write(f" Telescope used                         =  {params.get('telescope', 'Unknown')}\n")
        f.write(f" Instrument used                        =  {params.get('instrument', 'Unknown')}\n")
        f.write(f" Object being observed                  =  {params.get('object', params.get('source', 'Unknown'))}\n")
        f.write(f" J2000 Right Ascension (hh:mm:ss.ssss)  =  {params.get('ra', '00:00:00.0000')}\n")
        f.write(f" J2000 Declination     (dd:mm:ss.ssss)  =  {params.get('dec', '00:00:00.0000')}\n")
        f.write(f" Data observed by                       =  {params.get('observer', 'Unknown')}\n")
        f.write(f" Epoch of observation (MJD)             =  {params.get('mjd', 0.0):.15f}\n")
        f.write(f" Barycentered?           (1=yes, 0=no)  =  {params.get('barycentered', 0)}\n")
        f.write(f" Number of bins in the time series      =  {num_samples}\n")
        f.write(f" Width of each time series bin (sec)    =  {dt:.15g}\n")
        f.write(f" Any breaks in the data? (1=yes, 0=no)  =  0\n")
        f.write(f" Type of observation (EM band)          =  Radio\n")
        f.write(f" Dispersion measure (pc/cm^3)           =  {params.get('dm', 0.0):.12g}\n")
        f.write(f" Central freq of low channel (MHz)      =  {params.get('freq_low', 0.0):.12g}\n")
        f.write(f" Total bandwidth (MHz)                  =  {params.get('bandwidth', 0.0):.12g}\n")
        f.write(f" Number of channels                     =  {params.get('num_channels', 1)}\n")
        f.write(f" Channel bandwidth (MHz)                =  {params.get('chan_bandwidth', 0.0):.12g}\n")
        f.write(f" Data analyzed by                       =  {params.get('analyzed_by', 'NEXTO')}\n")


def split_datfile(dat_file, fraction, chunk_num, total_chunks):
    """
    Split a .dat file into segments

    Args:
        dat_file: Path to .dat file
        fraction: Fraction of file to extract (e.g., 0.5 for half, 1.0 for full)
        chunk_num: Which chunk this is (1-indexed)
        total_chunks: Total number of chunks
    """
    # Read corresponding .inf file
    base = dat_file.rsplit('.dat', 1)[0]
    inf_file = base + '.inf'

    if not os.path.exists(inf_file):
        print(f"Error: .inf file not found: {inf_file}")
        return None

    params = read_inf_file(inf_file)
    total_samples = params['num_samples']

    # Calculate segment parameters
    samples_per_chunk = int(total_samples * fraction)
    # Ensure even number of samples
    if samples_per_chunk % 2 != 0:
        samples_per_chunk -= 1

    # Calculate starting sample for this chunk
    start_sample = (chunk_num - 1) * samples_per_chunk

    # Ensure we don't exceed file bounds
    if start_sample + samples_per_chunk > total_samples:
        samples_per_chunk = total_samples - start_sample
        if samples_per_chunk % 2 != 0:
            samples_per_chunk -= 1

    if samples_per_chunk <= 0:
        print(f"Warning: No samples for chunk {chunk_num}")
        return None

    # Create output filenames
    if fraction == 1.0:
        # Full file, no suffix
        out_base = base
    else:
        out_base = f"{base}_ck{chunk_num:02d}of{total_chunks:02d}"

    out_dat = out_base + '.dat'
    out_inf = out_base + '.inf'

    # Read and write segment from .dat file
    with open(dat_file, 'rb') as f_in:
        # Seek to starting sample (4 bytes per float sample)
        f_in.seek(start_sample * 4)

        # Read segment data
        data = f_in.read(samples_per_chunk * 4)

        # Write segment
        with open(out_dat, 'wb') as f_out:
            f_out.write(data)

    # Write corresponding .inf file
    write_inf_file(out_inf, params, out_base, start_sample, samples_per_chunk)

    print(f"Created segment: {out_dat} ({samples_per_chunk} samples)")
    return out_dat


def main():
    parser = argparse.ArgumentParser(description='Split PRESTO .dat file into segments')
    parser.add_argument('datfile', help='Input .dat file')
    parser.add_argument('--fraction', type=float, required=True, help='Fraction of file per segment (e.g., 0.5)')
    parser.add_argument('--chunk', type=int, required=True, help='Chunk number (1-indexed)')
    parser.add_argument('--total-chunks', type=int, required=True, help='Total number of chunks')

    args = parser.parse_args()

    if not os.path.exists(args.datfile):
        print(f"Error: File not found: {args.datfile}")
        sys.exit(1)

    if args.fraction <= 0 or args.fraction > 1:
        print(f"Error: Fraction must be between 0 and 1")
        sys.exit(1)

    split_datfile(args.datfile, args.fraction, args.chunk, args.total_chunks)


if __name__ == '__main__':
    main()
