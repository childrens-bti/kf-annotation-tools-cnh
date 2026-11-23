#!/usr/bin/env bash
# Build a REDIportal v3 (hg38) RNA-editing presence/absence echtvar reference.
#
# Usage:
#   bash scripts/build_rediportal_v3.sh /path/to/build-directory
#
# Optional environment variables:
#   INPUT_TABLE   Existing TABLE1_hg38_v3.txt.gz to use instead of downloading it.
#   TABLE_URL     Download URL (default: REDIportal v3 hg38 TABLE1).
#   OUTPUT_ZIP    Output ZIP path (default: <build-directory>/rediportal_v3_hg38.echtvar.zip).
#
# The ZIP adds one INFO field, REDIPORTAL (Integer): 1 when CHROM, POS, REF and
# ALT all match a REDIportal site and its edited base, 0 otherwise. echtvar 0.2.0
# (the version used by tools/echtvar_anno.cwl) cannot encode Flag fields, so
# absence is encoded as missing_value 0. Filter with INFO/REDIPORTAL=1.
#
# REDIportal's Ref/Ed bases are already on the genomic + strand (a minus-strand
# A-to-I edit is listed as T>C), so no strand conversion is done. Only
# presence/absence is kept; REDIportal's per-tissue and gene columns are dropped.
#
# The build fails on an unexpected header, malformed or unsorted rows, or an
# empty table. After encoding, every site is annotated back against the ZIP and
# the build fails unless all of them return REDIPORTAL=1. Intermediate files are
# left in the build directory.

set -euo pipefail

readonly ECHTVAR_IMAGE="pgc-images.sbgenomics.com/d3b-bixu/echtvar:0.2.0"
readonly TABLE_URL="${TABLE_URL:-https://rediportal.cloud.ba.infn.it/download/TABLE1_hg38_v3.txt.gz}"
readonly SITES_VCF="rediportal_v3_hg38.sites.vcf.gz"

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
OUTPUT_ZIP="${OUTPUT_ZIP:-${BUILD_DIR}/rediportal_v3_hg38.echtvar.zip}"

if [[ "${OUTPUT_ZIP}" != /* ]]; then
  OUTPUT_ZIP="${PWD}/${OUTPUT_ZIP}"
fi

if [[ -n "${INPUT_TABLE:-}" && "${INPUT_TABLE}" != /* ]]; then
  INPUT_TABLE="${PWD}/${INPUT_TABLE}"
fi

command -v docker >/dev/null
command -v gzip >/dev/null
command -v awk >/dev/null
[[ -n "${INPUT_TABLE:-}" ]] || command -v curl >/dev/null

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

if [[ -n "${INPUT_TABLE:-}" ]]; then
  if [[ ! -r "${INPUT_TABLE}" ]]; then
    echo "Cannot read INPUT_TABLE: ${INPUT_TABLE}" >&2
    exit 1
  fi
  table="${INPUT_TABLE}"
else
  table="${BUILD_DIR}/TABLE1_hg38_v3.txt.gz"
  if [[ ! -s "${table}" ]]; then
    echo "Downloading ${TABLE_URL}"
    curl -fL --retry 3 -o "${table}.part" "${TABLE_URL}"
    mv "${table}.part" "${table}"
  fi
fi
gzip -t "${table}"

echtvar_docker() {
  docker run --rm -i \
    --platform linux/amd64 \
    --user "$(id -u):$(id -g)" \
    -v "${BUILD_DIR}":/work \
    -v "${OUTPUT_DIR}":/output \
    -w /work \
    "${ECHTVAR_IMAGE}" \
    "$@"
}

cat > rediportal_v3.echtvar.json <<'EOF'
[
  {"field": "REDIPORTAL", "alias": "REDIPORTAL", "missing_value": 0}
]
EOF

# TABLE1 columns: 2=Region 3=Position 4=Ref 5=Ed. Records go to stdout; the
# header (one ##contig line per contig, in order of appearance) is written at
# the end, once all contigs are known.
echo "Converting ${table} to a sites-only VCF"
gzip -cd "${table}" | LC_ALL=C awk -v hdr=header.vcf -v stats=convert_stats.txt '
  BEGIN { FS = OFS = "\t" }
  NR == 1 {
    if ($2 != "Region" || $3 != "Position" || $4 != "Ref" || $5 != "Ed") {
      print "Unexpected header; expected columns 2-5 to be Region, Position, Ref, Ed" > "/dev/stderr"
      err = 1; exit 1
    }
    next
  }
  $4 !~ /^[ACGT]$/ || $5 !~ /^[ACGT]$/ || $3 !~ /^[0-9]+$/ || $4 == $5 {
    if (bad < 5) print "Malformed row " NR ": " $2 ":" $3 " " $4 ">" $5 > "/dev/stderr"
    bad++; next
  }
  {
    if ($2 != chrom) {
      if ($2 in seen) { print "Unsorted input: " $2 " reappears at line " NR > "/dev/stderr"; err = 1; exit 1 }
      seen[$2] = 1; order[++n] = $2; chrom = $2; last = 0
    }
    if ($3 + 0 < last) { print "Unsorted positions at line " NR > "/dev/stderr"; err = 1; exit 1 }
    last = $3 + 0
    print $2, $3, ".", $4, $5, ".", ".", "REDIPORTAL=1"
    kept++
  }
  END {
    if (err) exit 1
    print "##fileformat=VCFv4.2" > hdr
    print "##source=REDIportal v3 hg38 (TABLE1_hg38_v3.txt.gz)" > hdr
    for (i = 1; i <= n; i++) print "##contig=<ID=" order[i] ">" > hdr
    print "##INFO=<ID=REDIPORTAL,Number=1,Type=Integer,Description=\"1 if site and edited allele are present in REDIportal v3 (hg38)\">" > hdr
    print "#CHROM", "POS", "ID", "REF", "ALT", "QUAL", "FILTER", "INFO" > hdr
    print (NR - 1), kept + 0, bad + 0, n > stats
  }
' > body.vcf

read -r table_rows kept_rows bad_rows n_contigs < convert_stats.txt
echo "Table rows: ${table_rows}; VCF records: ${kept_rows}; malformed: ${bad_rows}; contigs: ${n_contigs}"

if [[ "${bad_rows}" -ne 0 ]]; then
  echo "Found ${bad_rows} malformed rows; refusing to build an incomplete reference." >&2
  exit 1
fi
if [[ "${kept_rows}" -eq 0 ]]; then
  echo "No sites found in ${table}." >&2
  exit 1
fi

cat header.vcf body.vcf | echtvar_docker bcftools view -Oz -o "${SITES_VCF}" -
rm body.vcf

echtvar_docker echtvar encode \
  "/output/${OUTPUT_BASENAME}" \
  rediportal_v3.echtvar.json \
  "${SITES_VCF}"

# Round trip: strip REDIPORTAL, re-annotate every site from the ZIP, and require
# that all of them come back as 1.
echtvar_docker sh -c "
  set -eu
  bcftools annotate -x INFO/REDIPORTAL -Oz -o roundtrip_input.vcf.gz ${SITES_VCF}
  echtvar anno -e '/output/${OUTPUT_BASENAME}' roundtrip_input.vcf.gz roundtrip_annotated.vcf.gz >/dev/null 2>&1
  bcftools view -H -i 'INFO/REDIPORTAL=1' roundtrip_annotated.vcf.gz | wc -l > roundtrip_hits.txt
"
read -r roundtrip_hits < roundtrip_hits.txt
rm -f roundtrip_input.vcf.gz roundtrip_annotated.vcf.gz

if [[ "${roundtrip_hits}" -ne "${kept_rows}" ]]; then
  echo "Round-trip check failed: ${roundtrip_hits} of ${kept_rows} sites returned REDIPORTAL=1." >&2
  exit 1
fi

echo "Reference build complete; all ${kept_rows} sites verified: ${OUTPUT_ZIP}"
