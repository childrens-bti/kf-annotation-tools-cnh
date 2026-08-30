#!/usr/bin/env bash
# Build a gnomAD v4.1.0 echtvar reference in a dedicated working directory.
#
# Usage:
#   bash scripts/build_gnomad_v4_echtvar_reference.sh /path/to/build-directory
#
# Optional environment variables:
#   REFERENCE_DIR       Directory containing Homo_sapiens_assembly38.fasta.
#   DOWNLOAD_WORKERS    Parallel chromosome downloads/normalizations (default: 12).
#   DOWNLOAD_THREADS    Threads per download/normalization job (default: 12).
#   INFO_WORKERS        Parallel custom-INFO jobs (default: 8).
#   INFO_THREADS        Threads per custom-INFO job (default: 4).
#   PYTHON_BIN          Python interpreter with pysam installed (default: python3).
#   OUTPUT_ZIP          Output ZIP path (default: <build-directory>/gnomad.v4.1.0.custom.echtvar.zip).
#   RESUME=1            Reuse completed per-chromosome intermediate VCFs.
#
# The script intentionally does not replace the active reference ZIP or delete
# intermediate files. Inspect the completed ZIP before moving it into service.

set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
readonly REFERENCE_DIR="${REFERENCE_DIR:-/home/ubuntu/kf-germline-workflow-cnh/data/references}"
readonly DOWNLOAD_WORKERS="${DOWNLOAD_WORKERS:-12}"
readonly DOWNLOAD_THREADS="${DOWNLOAD_THREADS:-12}"
readonly INFO_WORKERS="${INFO_WORKERS:-8}"
readonly INFO_THREADS="${INFO_THREADS:-4}"
readonly PYTHON_BIN="${PYTHON_BIN:-python3}"

usage() {
  echo "Usage: bash $0 BUILD_DIRECTORY" >&2
}

if [[ $# -ne 1 ]]; then
  usage
  exit 2
fi

BUILD_DIR="$1"
mkdir -p "${BUILD_DIR}"
readonly BUILD_DIR="$(cd "${BUILD_DIR}" && pwd)"
OUTPUT_ZIP="${OUTPUT_ZIP:-${BUILD_DIR}/gnomad.v4.1.0.custom.echtvar.zip}"

if [[ "${OUTPUT_ZIP}" != /* ]]; then
  OUTPUT_ZIP="${PWD}/${OUTPUT_ZIP}"
fi

readonly CHROMOSOMES=(chr{1..22} chrX chrY)

command -v docker >/dev/null
command -v "${PYTHON_BIN}" >/dev/null
command -v unzip >/dev/null
command -v jq >/dev/null
"${PYTHON_BIN}" -c 'import pysam'

if [[ ! -r "${REFERENCE_DIR}/Homo_sapiens_assembly38.fasta" ]]; then
  echo "Missing reference FASTA: ${REFERENCE_DIR}/Homo_sapiens_assembly38.fasta" >&2
  exit 1
fi

if [[ -e "${OUTPUT_ZIP}" ]]; then
  echo "Refusing to overwrite existing output ZIP: ${OUTPUT_ZIP}" >&2
  echo "Choose a different OUTPUT_ZIP or move the existing file first." >&2
  exit 1
fi

readonly OUTPUT_DIR="$(dirname "${OUTPUT_ZIP}")"
readonly OUTPUT_BASENAME="$(basename "${OUTPUT_ZIP}")"

if [[ ! -d "${OUTPUT_DIR}" ]]; then
  echo "Output directory does not exist: ${OUTPUT_DIR}" >&2
  exit 1
fi

cd "${BUILD_DIR}"

printf '%s\n' "${CHROMOSOMES[@]}" > chr_list.txt

download_chromosome() {
  local chrom="$1"
  local normalized="gnomad.genomes.v4.1.0.sites.${chrom}.bcftools_INFO_subset.vt_norm.vcf.gz"

  if [[ "${RESUME:-0}" == "1" && -s "${normalized}" ]]; then
    echo "Reusing ${normalized}"
  else
    REFERENCE_DIR="${REFERENCE_DIR}" "${REPO_DIR}/scripts/dl_subset_gnomad_v4.1.0.sh" "${chrom}"
  fi
}

customize_chromosome() {
  local chrom="$1"
  local normalized="gnomad.genomes.v4.1.0.sites.${chrom}.bcftools_INFO_subset.vt_norm.vcf.gz"
  local customized="gnomad.genomes.v4.1.0.sites.${chrom}.custom.INFO_added.vcf.gz"

  if [[ "${RESUME:-0}" == "1" && -s "${customized}" && -s "${customized}.tbi" ]]; then
    echo "Reusing ${customized}"
  else
    "${PYTHON_BIN}" "${REPO_DIR}/scripts/custom_vcf_info_v4.1.0.py" \
      --input_vcf "${normalized}" \
      --output_basename "gnomad.genomes.v4.1.0.sites.${chrom}.custom" \
      --threads "${INFO_THREADS}"
  fi
}

export -f download_chromosome customize_chromosome
export REFERENCE_DIR REPO_DIR DOWNLOAD_THREADS INFO_THREADS PYTHON_BIN RESUME

printf '%s\n' "${CHROMOSOMES[@]}" \
  | xargs -r -n 1 -P "${DOWNLOAD_WORKERS}" bash -c 'download_chromosome "$1"' _

printf '%s\n' "${CHROMOSOMES[@]}" \
  | xargs -r -n 1 -P "${INFO_WORKERS}" bash -c 'customize_chromosome "$1"' _

docker run --rm \
  -v "${BUILD_DIR}":/work \
  -v "${OUTPUT_DIR}":/output \
  -v "${REPO_DIR}":/repo:ro \
  -w /work \
  pgc-images.sbgenomics.com/d3b-bixu/echtvar:0.2.0 \
  echtvar encode \
    "/output/${OUTPUT_BASENAME}" \
    /repo/docs/gnomad_update_v4.1.0.json \
    gnomad.genomes.v4.1.0.sites.*.custom.INFO_added.vcf.gz

unzip -p "${OUTPUT_ZIP}" echtvar/config.json \
  | jq -e 'all(.[]; has("number") and (.number | length > 0))' >/dev/null

echo "Reference build complete and metadata verified: ${OUTPUT_ZIP}"
