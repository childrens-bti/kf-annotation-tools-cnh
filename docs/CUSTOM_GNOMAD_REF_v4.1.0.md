# Custom gnomAD v4.1.0 Reference Creation

This documentation outlines how to create a gnomAD v4.1.0 annotation reference.
While the gnomAD source itself is very large and comprehensive, this reference is meant to add the "bare minimum" as a useful start for variant filtering out-of-the-box with a called VCF.

The main steps for reference creation are:
1. Download and pipe to bcftools and vt to grab desired fields and to normalize calls (see https://genome.sph.umich.edu/wiki/Vt#Normalization)
1. Use pysam to add custom fields including an INFO field for the `FILTER` value from the source file, a popmax AF for populations with no bottlenecks (as defined [here](https://gnomad.broadinstitute.org/help/faf)) and a popmax __with__ bottleneck populations
1. Create an echtvar reference for blazing fast annotation of VCF files with this custom reference

## gnomAD v3.1.1 → v4.1.0 Field Changes

gnomAD v4.1.0 introduces significant schema changes compared to v3.1.1. Understanding these changes is critical for proper reference creation and downstream annotation.

### Major Conceptual Changes

1. **Cancer/Non-Cancer Stratification Removed**: v4.1.0 no longer separates cancer and non-cancer cohorts. All `AF_non_cancer_*` fields are removed.
2. **Popmax → Grpmax**: The concept of "population with maximum AF" is renamed to "genetic ancestry group with maximum AF" (grpmax).
3. **Controls/Biobanks Cohort Removed**: v4.1.0 no longer provides separate statistics for controls and biobank samples.
4. **Filtering Allele Frequency (FAF)**: New quality metric at 95% confidence for variant filtering.
5. **Population Naming**: Simplified from `AF_non_cancer_<pop>` to `AF_<pop>`; "oth" (Other) renamed to "remaining".

### Fields Removed in v4.1.0

| v3.1.1 Field | Reason for Removal |
|--------------|-------------------|
| `AC_popmax`, `AN_popmax`, `AF_popmax`, `nhomalt_popmax` | Replaced by `*_grpmax` fields |
| `AC_controls_and_biobanks`, `AN_controls_and_biobanks`, `AF_controls_and_biobanks` | Cohort stratification discontinued |
| `AF_non_cancer` | Cancer/non-cancer split discontinued |
| `AF_non_cancer_afr`, `AF_non_cancer_ami`, `AF_non_cancer_asj`, etc. | Prefix removed; now `AF_afr`, `AF_ami`, etc. |
| `AF_non_cancer_oth` | Renamed to `AF_remaining` |
| `AF_non_cancer_raw` | Raw frequency calculation discontinued |
| `primate_ai_score` | Predictor no longer included |
| `splice_ai_consequence` | Replaced by `spliceai_ds_max` |

### Fields Added in v4.1.0

**Genetic Ancestry Group (Grpmax):**
- `grpmax` (string): Name of genetic ancestry group with maximum AF
- `AC_grpmax`, `AN_grpmax`, `AF_grpmax`, `nhomalt_grpmax`: Statistics for grpmax group

**Filtering Allele Frequency (FAF):**
- `fafmax_faf95_max` (float): Maximum filtering AF at 95% confidence across groups
- `fafmax_faf95_max_gen_anc` (string): Genetic ancestry group with maximum FAF

**Per-Population Statistics** (AC, AN, AF, nhomalt for each):
- `*_afr`: African/African American
- `*_ami`: Amish
- `*_amr`: Latino/Admixed American
- `*_asj`: Ashkenazi Jewish
- `*_eas`: East Asian
- `*_fin`: Finnish
- `*_mid`: Middle Eastern
- `*_nfe`: Non-Finnish European
- `*_sas`: South Asian
- `*_remaining`: Remaining ancestry groups (was "oth" in v3.1.1)

**Updated Predictors:**
- `cadd_phred`: CADD Phred-scaled deleteriousness score
- `revel_max`: Maximum REVEL score (missense pathogenicity)
- `polyphen_max`: Maximum PolyPhen score
- `sift_max`: Maximum SIFT score
- `spliceai_ds_max`: Maximum SpliceAI delta score (replaces `splice_ai_consequence`)
- `phylop`: PhyloP conservation score

### Custom Calculated Fields (Both Versions)

These fields are added by the Python script in Step 2:

| Field | v3.1.1 | v4.1.0 | Description |
|-------|--------|--------|-------------|
| `GNOMAD_FILTER` | ✓ | ✓ | Preserves original FILTER column value |
| `AF_popmax` / `AF_non_cancer_popmax` | ✓ | ✓ | Max AF across non-bottleneck populations |
| `AF_all_popmax` / `AF_non_cancer_all_popmax` | ✓ | ✓ | Max AF including bottleneck populations |

**Non-bottleneck populations:**
- v3.1.1: `AF_non_cancer_afr`, `AF_non_cancer_amr`, `AF_non_cancer_eas`, `AF_non_cancer_nfe`, `AF_non_cancer_sas`
- v4.1.0: `AF_afr`, `AF_amr`, `AF_eas`, `AF_nfe`, `AF_sas`

**Bottleneck populations:**
- v3.1.1: `AF_non_cancer_ami`, `AF_non_cancer_asj`, `AF_non_cancer_fin`, `AF_non_cancer_mid`, `AF_non_cancer_oth`
- v4.1.0: `AF_ami`, `AF_asj`, `AF_fin`, `AF_mid`, `AF_remaining`

### Field Count Summary

- **v3.1.1**: 28 fields total (26 from VCF + 2 custom calculated)
- **v4.1.0**: 63 fields total (60 from VCF + 3 custom calculated)

### Configuration Files

- v3.1.1: [gnomad_update.json](gnomad_update.json) - fields prefixed with `gnomad_3_1_1_`
- v4.1.0: [gnomad_update_v4.1.0.json](gnomad_update_v4.1.0.json) - fields prefixed with `gnomad_4_1_0_`

### Reference Documentation

- [gnomAD v4.1 Release Notes](https://gnomad.broadinstitute.org/news/2024-04-gnomad-v4-1/)
- [gnomAD v3.1.1 Custom Reference Creation](CUSTOM_GNOMAD_REF.md)

## Prerequisites

### Docker Images
- `pgc-images.sbgenomics.com/d3b-bixu/vcfutils:latest` (for bcftools, vt, curl)
- `pgc-images.sbgenomics.com/d3b-bixu/echtvar:0.1.9` (for echtvar encoding)

### Python Dependencies
```bash
pip install pysam==0.23.3
```

### Reference Files
- `Homo_sapiens_assembly38.fasta` (reference genome for variant normalization)
- Chromosome list file (chr1-22, X, Y)

## Step 1: Download and Normalize

### Fields to Extract from gnomAD v4.1.0

The following 57 INFO fields will be subset from the source VCF (based on v4.1.0 schema):

**Basic Allele Statistics:**
```
AC, AN, AF, nhomalt
```

**Genetic Ancestry Group Maximum (Grpmax):**
```
grpmax, AC_grpmax, AN_grpmax, AF_grpmax, nhomalt_grpmax
```

**Filtering Allele Frequency:**
```
fafmax_faf95_max, fafmax_faf95_max_gen_anc
```

**Per-Population Statistics** (AC, AN, AF, nhomalt for each of 10 populations):
```
*_afr (African/African American)
*_ami (Amish)
*_amr (Latino/Admixed American)
*_asj (Ashkenazi Jewish)
*_eas (East Asian)
*_fin (Finnish)
*_mid (Middle Eastern)
*_nfe (Non-Finnish European)
*_sas (South Asian)
*_remaining (Remaining ancestry groups)
```

**Predictor Scores:**
```
cadd_phred, revel_max, polyphen_max, sift_max, spliceai_ds_max, phylop
```

**Total: 57 fields** (4 basic + 5 grpmax + 2 fafmax + 40 population + 6 predictors)

### Download Script

Use the provided script: [scripts/dl_subset_gnomad_v4.1.0.sh](../scripts/dl_subset_gnomad_v4.1.0.sh)

This script:
- Downloads gnomAD v4.1.0 VCF for a given chromosome using `curl`
- Subsets to the desired INFO fields using `bcftools annotate`
- Normalizes variants using `vt normalize` with the GRCh38 reference
- Compresses output with `bgzip` using 12 threads
- Runs Docker for bcftools/vt steps (eliminates local dependency installation)

Usage: `./scripts/dl_subset_gnomad_v4.1.0.sh <chromosome>`

### Create Chromosome List

```bash
# Create chr_list.txt
cat > chr_list.txt << 'EOF'
chr1
chr2
chr3
chr4
chr5
chr6
chr7
chr8
chr9
chr10
chr11
chr12
chr13
chr14
chr15
chr16
chr17
chr18
chr19
chr20
chr21
chr22
chrX
chrY
EOF
```

### Run Parallel Download and Normalization

```bash
# Run in parallel (12 chromosomes at a time, ~1 hour on m6i.8xlarge)
cat chr_list.txt | xargs -IFN -P 12 ./scripts/dl_subset_gnomad_v4.1.0.sh FN
```

**Note:** The Docker-based script handles all dependencies (bcftools, vt, bgzip) internally. Ensure Docker is running and you have network access to Google Cloud Storage for gnomAD downloads.

**Expected output:** Per-chromosome VCF files:
- `gnomad.genomes.v4.1.0.sites.chr1.bcftools_INFO_subset.vt_norm.vcf.gz`
- `gnomad.genomes.v4.1.0.sites.chr2.bcftools_INFO_subset.vt_norm.vcf.gz`
- ... (24 files total)

## Step 2: Add Custom INFO Fields

### Custom Fields to Add

Use `scripts/custom_vcf_info_v4.1.0.py` to add three calculated fields:

1. **`GNOMAD_FILTER`**: Copy of the FILTER column value (preserves quality info during annotation)

2. **`AF_popmax`**: Maximum allele frequency across **non-bottleneck populations**:
   ```
   AF_afr  (African/African American)
   AF_amr  (Latino/Admixed American)
   AF_eas  (East Asian)
   AF_nfe  (Non-Finnish European)
   AF_sas  (South Asian)
   ```

3. **`AF_all_popmax`**: Maximum allele frequency across **all populations** including bottleneck:
   ```
   AF_ami  (Amish)
   AF_asj  (Ashkenazi Jewish)
   AF_fin  (Finnish)
   AF_mid  (Middle Eastern)
   AF_remaining  (Remaining ancestry groups)
   ```
   Set to the greater of `AF_popmax` or max(bottleneck populations).

### Run Custom INFO Addition

```bash
# Process all chromosomes in parallel (8 at a time, 4 threads each, ~30min on m6i.8xlarge)
cat chr_list.txt | xargs -IFN -P 8 python3 scripts/custom_vcf_info_v4.1.0.py \
  --input_vcf gnomad.genomes.v4.1.0.sites.FN.bcftools_INFO_subset.vt_norm.vcf.gz \
  --output_basename gnomad.genomes.v4.1.0.sites.FN.custom \
  --threads 4
```

**Expected output:** Per-chromosome VCF files with custom fields:
- `gnomad.genomes.v4.1.0.sites.chr1.custom.INFO_added.vcf.gz`
- `gnomad.genomes.v4.1.0.sites.chr1.custom.INFO_added.vcf.gz.tbi`
- ... (48 files total: 24 VCF + 24 index)

## Step 3: Create echtvar Reference

### Encode Configuration

Use the pre-configured JSON file: [gnomad_update_v4.1.0.json](gnomad_update_v4.1.0.json)

This config prepends `gnomad_4_1_0_` to all field names for source clarity upon annotation.

Example excerpt:
```json
[
    {"field": "AC", "alias": "gnomad_4_1_0_AC", "description": "Alternate allele count", "missing_value": -2147483648},
    {"field": "AF", "alias": "gnomad_4_1_0_AF", "description": "Alternate allele frequency", "multiplier": 2000000, "missing_value": 2139095041},
    ...
]
```

### Run echtvar Encoding

```bash
# Encode all chromosome VCFs into a single echtvar zip using Docker
docker run --rm -v $PWD:/work -w /work \
  pgc-images.sbgenomics.com/d3b-bixu/echtvar:0.1.9 \
  echtvar encode \
    gnomad.v4.1.0.custom.echtvar.zip \
    docs/gnomad_update_v4.1.0.json \
    gnomad.genomes.v4.1.0.sites.*.custom.INFO_added.vcf.gz
```

**Expected output:**
- `gnomad.v4.1.0.custom.echtvar.zip` (~few GB)

### Verify the Reference

```bash
# View encoded fields using Docker
docker run --rm -v $PWD:/work -w /work \
  pgc-images.sbgenomics.com/d3b-bixu/echtvar:0.1.9 \
  echtvar view gnomad.v4.1.0.custom.echtvar.zip | head -50

# Test annotation on a sample VCF using Docker
docker run --rm -v $PWD:/work -w /work \
  pgc-images.sbgenomics.com/d3b-bixu/echtvar:0.1.9 \
  bash -c "echtvar anno -e gnomad.v4.1.0.custom.echtvar.zip sample.vcf.gz | \
  bcftools query -f '%CHROM\t%POS\t%INFO/gnomad_4_1_0_AF\t%INFO/gnomad_4_1_0_AF_popmax\n' | head"
```

## Quality Control

### Validate Field Names

Check that all expected fields exist in the source VCF:

```bash
# Extract field names from config
jq -r '.[].field' docs/gnomad_update_v4.1.0.json > /tmp/fields.txt

# Extract INFO IDs from gnomAD VCF header
bcftools view -h gnomad.genomes.v4.1.0.sites.chr1.vcf.bgz \
  | awk '/^##INFO=/{match($0,/ID=([^,]+)/,a); if(a[1]!="") print a[1]}' \
  | sort -u > /tmp/header_info_ids.txt

# Find fields missing in VCF (excluding custom fields added by Python script)
comm -23 /tmp/fields.txt /tmp/header_info_ids.txt | grep -v -E "GNOMAD_FILTER|AF_popmax|AF_all_popmax"
```

If any fields are missing or renamed, update the config JSON and the `dl_subset_gnomad_v4.1.0.sh` script accordingly.

### Spot-Check Annotations

Compare a few variants against the source VCF to verify:
- AF/AN/AC values match
- FILTER values preserved
- Popmax calculations correct

```bash
# Example: check a known variant
CHROM="chr1"
POS="12345"

# From source
bcftools query -f '%CHROM\t%POS\t%INFO/AF\t%INFO/AF_afr\t%FILTER\n' \
  gnomad.genomes.v4.1.0.sites.${CHROM}.vcf.bgz \
  -r ${CHROM}:${POS}-${POS}

# From custom VCF
bcftools query -f '%CHROM\t%POS\t%INFO/AF\t%INFO/AF_afr\t%INFO/GNOMAD_FILTER\t%INFO/AF_popmax\n' \
  gnomad.genomes.v4.1.0.sites.${CHROM}.custom.INFO_added.vcf.gz \
  -r ${CHROM}:${POS}-${POS}
```

### Annotated Fields

After annotation, your VCF will contain INFO fields with the `gnomad_4_1_0_` prefix:

**Basic statistics (4):**
```
gnomad_4_1_0_AC, gnomad_4_1_0_AN, gnomad_4_1_0_AF, gnomad_4_1_0_nhomalt
```

**Grpmax statistics (5):**
```
gnomad_4_1_0_grpmax, gnomad_4_1_0_AC_grpmax, gnomad_4_1_0_AN_grpmax, 
gnomad_4_1_0_AF_grpmax, gnomad_4_1_0_nhomalt_grpmax
```

**Filtering AF (2):**
```
gnomad_4_1_0_fafmax_faf95_max, gnomad_4_1_0_fafmax_faf95_max_gen_anc
```

**Per-population (40):** AC, AN, AF, nhomalt for each of 10 populations (afr, ami, amr, asj, eas, fin, mid, nfe, sas, remaining)

**Predictors (6):**
```
gnomad_4_1_0_cadd_phred, gnomad_4_1_0_revel_max, gnomad_4_1_0_polyphen_max,
gnomad_4_1_0_sift_max, gnomad_4_1_0_spliceai_ds_max, gnomad_4_1_0_phylop
```

**Custom calculated (3):**
```
gnomad_4_1_0_FILTER, gnomad_4_1_0_AF_popmax, gnomad_4_1_0_AF_all_popmax
```

**Total: 60 fields** (57 from VCF + 3 custom calculated)

## Notes

### Storage Requirements

- Normalized VCFs: ~200-300 GB total
- Custom INFO VCFs: ~200-300 GB total
- Final echtvar zip: ~5-10 GB
- Recommend ~1 TB working space for intermediate files

### Compute Resources

- Download + normalize: ~4-8 hours with 12 parallel processes
- Custom INFO addition: ~2-4 hours with 8 parallel processes
- echtvar encoding: **2-4 hours** (single-threaded; processes all 24 chromosomes sequentially)

### Cleanup

After creating the echtvar reference, intermediate files can be removed:

```bash
# Keep only the final reference
rm gnomad.genomes.v4.1.0.sites.*.bcftools_INFO_subset.vt_norm.vcf.gz
rm gnomad.genomes.v4.1.0.sites.*.custom.INFO_added.vcf.gz*
```

## Related Documentation

- [gnomAD v4.1 Release Notes](https://gnomad.broadinstitute.org/news/2024-04-gnomad-v4-1/)
- [echtvar Documentation](https://github.com/brentp/echtvar)
- [vt Normalization](https://genome.sph.umich.edu/wiki/Vt#Normalization)
- [gnomAD v3.1.1 Custom Reference Creation](CUSTOM_GNOMAD_REF.md) (original version)