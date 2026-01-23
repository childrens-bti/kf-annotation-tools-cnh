# Custom gnomAD v4.1.0 Reference Creation

This documentation outlines how to create a gnomAD v4.1.0 annotation reference.
While the gnomAD source itself is very large and comprehensive, this reference is meant to add the "bare minimum" as a useful start for variant filtering out-of-the-box with a called VCF.

The main steps for reference creation are:
1. Download and pipe to bcftools and vt to grab desired fields and to normalize calls (see https://genome.sph.umich.edu/wiki/Vt#Normalization)
1. Use pysam to add custom fields including an INFO field for the `FILTER` value from the source file, a popmax AF for non-cancer populations with no bottlenecks (as defined [here](https://gnomad.broadinstitute.org/help/faf)) and a popmax __with__ bottleneck populations
1. Create an echtvar reference for blazing fast annotation of VCF files with this custom reference

## Prerequisites

### Docker Images
- `pgc-images.sbgenomics.com/d3b-bixu/vcfutils:latest` (for bcftools, vt, curl)
- `pgc-images.sbgenomics.com/d3b-bixu/echtvar:0.1.9` (for echtvar encoding)

### Python Dependencies
```bash
pip install pysam==0.22.0
```

### Reference Files
- `Homo_sapiens_assembly38.fasta` (reference genome for variant normalization)
- Chromosome list file (chr1-22, X, Y)

## Step 1: Download and Normalize

### Fields to Extract from gnomAD v4.1.0

The following INFO fields will be subset from the source VCF:

```
AC
AN
AF
nhomalt
AC_popmax
AN_popmax
AF_popmax
nhomalt_popmax
AC_controls_and_biobanks
AN_controls_and_biobanks
AF_controls_and_biobanks
AF_non_cancer
primate_ai_score
splice_ai_consequence
AF_non_cancer_afr
AF_non_cancer_ami
AF_non_cancer_asj
AF_non_cancer_eas
AF_non_cancer_fin
AF_non_cancer_mid
AF_non_cancer_nfe
AF_non_cancer_oth
AF_non_cancer_raw
AF_non_cancer_sas
AF_non_cancer_amr
```

**Note:** Verify these field names against the gnomAD v4.1.0 VCF header, as population labels or field names may have changed from v3.1.1.

### Download Script

Create `scripts/dl_subset_gnomad_v4.1.0.sh`:

```bash
#!/bin/bash
# Download, subset, and normalize gnomAD v4.1.0 VCF for a single chromosome
# Usage: ./dl_subset_gnomad_v4.1.0.sh chr1

CHR=$1

# Update this URL based on actual gnomAD v4.1.0 release path
# Check https://gnomad.broadinstitute.org/downloads for correct URLs
GNOMAD_URL="https://storage.googleapis.com/gcp-public-data--gnomad/release/4.1/vcf/genomes/gnomad.genomes.v4.1.sites.${CHR}.vcf.bgz"

curl -sL "${GNOMAD_URL}" | \
  bcftools annotate --threads 2 \
    -x '^INFO/AF_non_cancer,^INFO/AF_non_cancer_afr,^INFO/AF_non_cancer_ami,^INFO/AF_non_cancer_asj,^INFO/AF_non_cancer_eas,^INFO/AF_non_cancer_fin,^INFO/AF_non_cancer_mid,^INFO/AF_non_cancer_nfe,^INFO/AF_non_cancer_oth,^INFO/AF_non_cancer_raw,^INFO/AF_non_cancer_sas,^INFO/AF_non_cancer_amr,^INFO/AC,^INFO/AN,^INFO/AF,^INFO/nhomalt,^INFO/AC_popmax,^INFO/AN_popmax,^INFO/AF_popmax,^INFO/nhomalt_popmax,^INFO/AC_controls_and_biobanks,^INFO/AN_controls_and_biobanks,^INFO/AF_controls_and_biobanks,^INFO/AF_non_cancer,^INFO/primate_ai_score,^INFO/splice_ai_consequence' | \
  /vt/vt normalize - -n -r Homo_sapiens_assembly38.fasta | \
  bgzip -@4 -c > gnomad.genomes.v4.1.0.sites.${CHR}.bcftools_INFO_subset.vt_norm.vcf.gz

echo "Completed: ${CHR}"
```

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
# Make script executable
chmod +x scripts/dl_subset_gnomad_v4.1.0.sh

# Run in parallel (12 chromosomes at a time)
cat chr_list.txt | xargs -IFN -P 12 scripts/dl_subset_gnomad_v4.1.0.sh FN
```

**Expected output:** Per-chromosome VCF files:
- `gnomad.genomes.v4.1.0.sites.chr1.bcftools_INFO_subset.vt_norm.vcf.gz`
- `gnomad.genomes.v4.1.0.sites.chr2.bcftools_INFO_subset.vt_norm.vcf.gz`
- ... (24 files total)

## Step 2: Add Custom INFO Fields

### Custom Fields to Add

Use `scripts/custom_vcf_info.py` to add three calculated fields:

1. **`GNOMAD_FILTER`**: Copy of the FILTER column value (preserves quality info during annotation)

2. **`AF_non_cancer_popmax`**: Maximum allele frequency across **non-bottleneck populations**:
   ```
   AF_non_cancer_afr  (African/African American)
   AF_non_cancer_amr  (Latino/Admixed American)
   AF_non_cancer_eas  (East Asian)
   AF_non_cancer_nfe  (Non-Finnish European)
   AF_non_cancer_sas  (South Asian)
   ```

3. **`AF_non_cancer_all_popmax`**: Maximum allele frequency across **all populations** including bottleneck:
   ```
   AF_non_cancer_ami  (Amish)
   AF_non_cancer_asj  (Ashkenazi Jewish)
   AF_non_cancer_fin  (Finnish)
   AF_non_cancer_mid  (Middle Eastern)
   AF_non_cancer_oth  (Other)
   ```
   Set to the greater of `AF_non_cancer_popmax` or max(bottleneck populations).

**Note:** Verify that `scripts/custom_vcf_info.py` uses the correct population field names for v4.1.0. If gnomAD changed population labels, update the `pop_fields` and `pop_fields_bn` lists in the script.

### Run Custom INFO Addition

```bash
# Process all chromosomes in parallel (8 at a time, 2 threads each)
cat chr_list.txt | xargs -IFN -P 8 python3 scripts/custom_vcf_info.py \
  --input_vcf gnomad.genomes.v4.1.0.sites.FN.bcftools_INFO_subset.vt_norm.vcf.gz \
  --output_basename gnomad.genomes.v4.1.0.sites.FN.custom \
  --threads 2
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
# Encode all chromosome VCFs into a single echtvar zip
echtvar encode \
  gnomad.v4.1.0.custom.echtvar.zip \
  docs/gnomad_update_v4.1.0.json \
  gnomad.genomes.v4.1.0.sites.*.custom.INFO_added.vcf.gz
```

**Expected output:**
- `gnomad.v4.1.0.custom.echtvar.zip` (~few GB)

### Verify the Reference

```bash
# View encoded fields
echtvar view gnomad.v4.1.0.custom.echtvar.zip | head -50

# Test annotation on a sample VCF
echtvar anno \
  -e gnomad.v4.1.0.custom.echtvar.zip \
  sample.vcf.gz \
  | bcftools query -f '%CHROM\t%POS\t%INFO/gnomad_4_1_0_AF\t%INFO/gnomad_4_1_0_AF_non_cancer_popmax\n' \
  | head
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
comm -23 /tmp/fields.txt /tmp/header_info_ids.txt | grep -v -E "GNOMAD_FILTER|AF_non_cancer_popmax|AF_non_cancer_all_popmax"
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
bcftools query -f '%CHROM\t%POS\t%INFO/AF\t%INFO/AF_non_cancer_afr\t%FILTER\n' \
  gnomad.genomes.v4.1.0.sites.${CHROM}.vcf.bgz \
  -r ${CHROM}:${POS}-${POS}

# From custom VCF
bcftools query -f '%CHROM\t%POS\t%INFO/AF\t%INFO/AF_non_cancer_afr\t%INFO/GNOMAD_FILTER\t%INFO/AF_non_cancer_popmax\n' \
  gnomad.genomes.v4.1.0.sites.${CHROM}.custom.INFO_added.vcf.gz \
  -r ${CHROM}:${POS}-${POS}
```

## Integration into Workflow

### Reference Path

Copy the final echtvar reference to your references directory:

```bash
cp gnomad.v4.1.0.custom.echtvar.zip /path/to/references/
```

### Workflow Configuration

In your workflow inputs YAML (e.g., `params/kfdrc-germline-variant-wf_inputs.yml`):

```yaml
# Use gnomAD v4.1.0
gnomad_version: "v4.1.0"

echtvar_anno_zips:
  - class: File
    path: /path/to/references/gnomad.v4.1.0.custom.echtvar.zip
```

### Annotated Fields

After annotation, your VCF will contain INFO fields with the `gnomad_4_1_0_` prefix:

```
gnomad_4_1_0_AC
gnomad_4_1_0_AN
gnomad_4_1_0_AF
gnomad_4_1_0_AF_non_cancer_popmax
gnomad_4_1_0_AF_non_cancer_all_popmax
gnomad_4_1_0_FILTER
... (28 fields total)
```

## Notes

### Population Labels in v4.1.0

Verify population field names in gnomAD v4.1.0 match v3.1.1:
- If renamed or new populations added, update:
  - Field list in this doc
  - `scripts/dl_subset_gnomad_v4.1.0.sh` bcftools filter
  - `scripts/custom_vcf_info.py` population lists
  - `docs/gnomad_update_v4.1.0.json` config

### Storage Requirements

- Normalized VCFs: ~200-300 GB total
- Custom INFO VCFs: ~200-300 GB total
- Final echtvar zip: ~5-10 GB
- Recommend ~1 TB working space for intermediate files

### Compute Resources

- Download + normalize: ~4-8 hours with 12 parallel processes
- Custom INFO addition: ~2-4 hours with 8 parallel processes
- echtvar encoding: ~30-60 minutes

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
- [gnomAD v3.1.1 Reference Creation](CUSTOM_GNOMAD_REF.md) (original version)
