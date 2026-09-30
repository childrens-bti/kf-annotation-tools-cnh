#!/bin/bash
# Docker-based download, subset, and normalize gnomAD v4.1.0 VCF
# Usage: ./dl_subset_gnomad_v4.1.0.sh chr1

set -euo pipefail

CHR=$1
REFERENCE_DIR=${REFERENCE_DIR:-/home/ubuntu/kf-germline-workflow-cnh/data/references}
DOWNLOAD_THREADS=${DOWNLOAD_THREADS:-12}

if [ -z "$CHR" ]; then
    echo "Usage: $0 <chromosome>"
    echo "Example: $0 chr1"
    exit 1
fi

GNOMAD_URL="https://storage.googleapis.com/gcp-public-data--gnomad/release/4.1/vcf/genomes/gnomad.genomes.v4.1.sites.${CHR}.vcf.bgz"
DOWNLOADED_FILE="gnomad.genomes.v4.1.0.sites.${CHR}.vcf.bgz"
SUBSET_FILE="gnomad.genomes.v4.1.0.sites.${CHR}.bcftools_INFO_subset.vcf.gz"
OUTPUT_FILE="gnomad.genomes.v4.1.0.sites.${CHR}.bcftools_INFO_subset.vt_norm.vcf.gz"

echo "Downloading gnomAD v4.1.0 for ${CHR}..."
curl -fsSL -o "${DOWNLOADED_FILE}" "${GNOMAD_URL}"

if [ ! -f "${DOWNLOADED_FILE}" ]; then
    echo "✗ Failed to download: ${CHR}"
    exit 1
fi

echo "Processing with Docker: subset and normalize..."

docker run --rm -v "$PWD":/work -v "${REFERENCE_DIR}":/refs:ro -w /work \
  pgc-images.sbgenomics.com/d3b-bixu/vcfutils:latest \
  bash -c "
    set -eo pipefail
    bcftools annotate --threads ${DOWNLOAD_THREADS} \
      -x '^INFO/AC,^INFO/AN,^INFO/AF,^INFO/nhomalt,^INFO/grpmax,^INFO/AC_grpmax,^INFO/AN_grpmax,^INFO/AF_grpmax,^INFO/nhomalt_grpmax,^INFO/fafmax_faf95_max,^INFO/fafmax_faf95_max_gen_anc,^INFO/AC_afr,^INFO/AN_afr,^INFO/AF_afr,^INFO/nhomalt_afr,^INFO/AC_ami,^INFO/AN_ami,^INFO/AF_ami,^INFO/nhomalt_ami,^INFO/AC_amr,^INFO/AN_amr,^INFO/AF_amr,^INFO/nhomalt_amr,^INFO/AC_asj,^INFO/AN_asj,^INFO/AF_asj,^INFO/nhomalt_asj,^INFO/AC_eas,^INFO/AN_eas,^INFO/AF_eas,^INFO/nhomalt_eas,^INFO/AC_fin,^INFO/AN_fin,^INFO/AF_fin,^INFO/nhomalt_fin,^INFO/AC_mid,^INFO/AN_mid,^INFO/AF_mid,^INFO/nhomalt_mid,^INFO/AC_nfe,^INFO/AN_nfe,^INFO/AF_nfe,^INFO/nhomalt_nfe,^INFO/AC_sas,^INFO/AN_sas,^INFO/AF_sas,^INFO/nhomalt_sas,^INFO/AC_remaining,^INFO/AN_remaining,^INFO/AF_remaining,^INFO/nhomalt_remaining,^INFO/cadd_phred,^INFO/revel_max,^INFO/polyphen_max,^INFO/sift_max,^INFO/spliceai_ds_max,^INFO/phylop' \
      ${DOWNLOADED_FILE} | \
    /vt/vt normalize - -n -r /refs/Homo_sapiens_assembly38.fasta | \
    bgzip -@${DOWNLOAD_THREADS} -c > ${OUTPUT_FILE}
  "

# Clean up intermediate file only after successful normalization.
rm -f "${DOWNLOADED_FILE}"
echo "✓ Completed: ${CHR} → ${OUTPUT_FILE}"
