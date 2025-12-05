# Workflow Corrections - NEXTO Pipeline

## Summary of Changes

The workflow has been corrected to follow the proper PRESTO pulsar search methodology, matching the standard PULSAR_MINER approach.

## Key Changes Made

### 1. Added `nobary` Parameter to PREPDATA Process

**File**: `modules.nf`

**Change**: The `PREPDATA` process now accepts a `nobary` boolean parameter that controls whether the `-nobary` flag is used.

```groovy
// Before
tuple path(observation), path(mask), val(dm), val(downsample)

// After
tuple path(observation), path(mask), val(dm), val(downsample), val(nobary)
```

**Script modification**:
```groovy
nobary_flag = nobary ? "-nobary" : ""
prepdata ${nobary_flag} -dm ${dm} -downsamp ${downsample} -mask ${mask} -o ${basename}_DM${dm_str} ${observation}
```

### 2. Corrected Workflow Order

**File**: `nexto_search.nf`

The workflow now follows this correct sequence:

## Corrected Pipeline Flow

```
Step 1: RFIFIND
   ↓
Step 2: Zero-DM prepdata WITH -nobary (DM=0, nobary=true)
   ↓
Step 3: REALFFT (zero-DM)
   ↓
Step 4: REDNOISE (zero-DM)
   ↓
Step 5: ACCELSEARCH with zmax=0 (identify birdies/RFI lines)
   ↓
Step 6: MAKE_ZAPLIST (create frequency mask from birdies)
   ↓
Step 7: DM trials prepdata WITHOUT -nobary (DM range, nobary=false)
   ↓
Step 8: REALFFT (all DM trials)
   ↓
Step 9: REDNOISE (all DM trials)
   ↓
Step 10: ZAPBIRDS (apply zaplist to all DM trial FFTs)
   ↓
Step 11: ACCELSEARCH with zmax>0 (actual search on zapped FFTs)
   ↓
Step 12: Candidate sifting and folding
```

## Why These Changes Matter

### The `-nobary` Flag

**Purpose**: Controls whether barycentering is applied during dedispersion.

- **With `-nobary`** (zero-DM birdie detection):
  - Faster processing
  - Suitable for RFI identification (RFI is local, not astronomical)
  - Creates a representative FFT for finding persistent interference

- **Without `-nobary`** (actual DM trials):
  - Applies barycentric correction
  - Essential for accurate pulsar timing
  - Corrects for Earth's motion around solar system barycenter
  - Required for detecting real astrophysical signals

### Two-Stage Processing

#### Stage 1: Birdie Detection (Zero-DM with nobary)

1. **Why zero-DM?** - RFI affects all DMs equally, so DM=0 is sufficient
2. **Why -nobary?** - Faster, and RFI doesn't need barycentric correction
3. **Purpose** - Create a frequency mask (zaplist) of persistent RFI lines

#### Stage 2: Actual Search (DM trials without nobary)

1. **Why multiple DMs?** - Unknown pulsar distances require DM search
2. **Why no -nobary?** - Proper barycentric correction needed for real signals
3. **Why zapbirds?** - Remove identified RFI before searching for pulsars

## Implementation Details

### Process Aliasing

To run `PREPDATA`, `REALFFT`, and `REDNOISE` twice with different inputs, we use Nextflow's aliasing feature:

```groovy
include {
    PREPDATA as PREPDATA_ZERODM;
    PREPDATA as PREPDATA_DMTRIALS;
    REALFFT as REALFFT_ZERODM;
    REALFFT as REALFFT_DMTRIALS;
    REDNOISE as REDNOISE_ZERODM;
    REDNOISE as REDNOISE_DMTRIALS;
    // ...
} from './modules.nf'
```

This allows:
- Independent execution of zero-DM and DM-trial branches
- Separate work directories for each process instance
- Clear channel routing without conflicts

### Channel Flow

#### Zero-DM Branch
```groovy
RFIFIND.out.rfi_products
    → [obs, mask, 0.0, downsample, true]  // nobary=true
    → PREPDATA_ZERODM
    → REALFFT_ZERODM
    → REDNOISE_ZERODM
    → ACCELSEARCH_ZMAX0
    → MAKE_ZAPLIST
```

#### DM Trials Branch
```groovy
RFIFIND.out.rfi_products
    → [obs, mask, DM_i, downsample, false]  // nobary=false, for each DM
    → PREPDATA_DMTRIALS
    → REALFFT_DMTRIALS
    → REDNOISE_DMTRIALS
    → (combine with zaplist)
    → ZAPBIRDS
    → ACCELSEARCH
```

## Comparison: Old vs New

### Old (Incorrect) Workflow

```
RFIFIND → PREPDATA (all DMs with -nobary) → REALFFT → REDNOISE
   → ACCELSEARCH_ZMAX0 (all DMs) → MAKE_ZAPLIST
   → ZAPBIRDS → ACCELSEARCH
```

**Problems**:
1. Used `-nobary` for actual search (incorrect for pulsar timing)
2. Did zmax=0 search on all DMs (inefficient, only need DM=0)
3. No clear separation between birdie detection and actual search

### New (Correct) Workflow

```
RFIFIND
   ├─→ PREPDATA_ZERODM (DM=0, -nobary) → REALFFT → REDNOISE
   │     → ACCELSEARCH_ZMAX0 → MAKE_ZAPLIST
   │
   └─→ PREPDATA_DMTRIALS (all DMs, no -nobary) → REALFFT → REDNOISE
         → ZAPBIRDS → ACCELSEARCH
```

**Advantages**:
1. Correct barycentric correction for actual search
2. Efficient birdie detection (only at DM=0)
3. Clear two-stage process
4. Matches PULSAR_MINER methodology

## Usage Examples

### Standard Search (with barycentric correction)

```bash
nextflow run nexto_search.nf \
    --input observation.fil \
    --dm_low 0 \
    --dm_high 100 \
    --dm_step 0.5 \
    --zmax 50
```

This will:
1. Run zero-DM with `-nobary` to find RFI
2. Run all DM trials **without** `-nobary` for proper pulsar search

### The nobary Parameter is Automatic

Users don't need to specify the `nobary` parameter - the workflow handles it automatically:
- Zero-DM birdie detection: `nobary=true` (automatic)
- DM trials for search: `nobary=false` (automatic)

## Performance Impact

### Efficiency Gains

**Old approach**:
- Zero-DM search on N DM trials = wasted computation
- Example: 200 DMs × birdie detection = 200 unnecessary jobs

**New approach**:
- Zero-DM search only once
- Example: 1 birdie detection + 200 DM searches = more efficient

### Parallelization Unchanged

The parallelization strategy remains the same:
- **Birdie detection**: 1 job (DM=0)
- **DM trials**: N parallel jobs (one per DM)
- **Total parallelism**: Still massive (hundreds of parallel searches)

## Testing Recommendations

### 1. Verify Zero-DM Processing

Check that zero-DM timeseries is created with `-nobary`:

```bash
# In work directory for PREPDATA_ZERODM
grep "nobary" .command.sh  # Should show -nobary flag
```

### 2. Verify DM Trials Processing

Check that DM trials are created **without** `-nobary`:

```bash
# In work directory for PREPDATA_DMTRIALS
grep "nobary" .command.sh  # Should NOT show -nobary flag
```

### 3. Check Zaplist Creation

Verify zaplist is created before DM trials are searched:

```bash
# Timeline should show:
# PREPDATA_ZERODM → ACCELSEARCH_ZMAX0 → MAKE_ZAPLIST → ZAPBIRDS
```

## Migration Notes

### If You Were Using the Old Workflow

**No action needed** - the workflow automatically handles everything correctly now.

### Output Structure Unchanged

The output directory structure remains the same:
```
results/
├── 01_RFIFIND/
├── 02_BIRDIES/        # Contains zaplist from zero-DM
├── 03_DEDISPERSION/   # Contains DM trial candidates
├── 04_SIFTING/
├── 05_FOLDING/
└── 06_SINGLE_PULSES/
```

## Technical Notes

### Why Not Make nobary a Pipeline Parameter?

The `nobary` flag is workflow logic, not a user choice:
- Zero-DM birdie detection always needs `-nobary` (efficiency)
- Real DM searches never need `-nobary` (accuracy)

Making it a parameter would allow users to make incorrect choices.

### Future Enhancements

Potential improvements:
1. **Optional full barycentric search**: Add `--full_bary` flag for users who want `-nobary` on all DMs
2. **Custom birdie DM**: Allow `--birdie_dm` parameter (default 0.0)
3. **Skip birdie detection**: Add `--skip_birdies` for clean observing sites

## References

- **PRESTO documentation**: https://github.com/scottransom/presto
- **PULSAR_MINER**: https://github.com/alex88ridolfi/PULSAR_MINER
- **Barycentering explanation**: Lorimer & Kramer, "Handbook of Pulsar Astronomy"

## Summary

✅ **Corrected workflow order**: Zero-DM birdie detection → DM trials search
✅ **Proper `-nobary` usage**: On for birdie detection, off for actual search
✅ **Maintained parallelization**: Still scales massively across cluster
✅ **Improved efficiency**: Only one zero-DM search instead of N
✅ **Correct physics**: Barycentric correction applied to real searches

The workflow now correctly implements the standard pulsar search methodology!
