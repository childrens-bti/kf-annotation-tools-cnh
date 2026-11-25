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
# The ZIP adds one INFO field, REDIPORTAL_V3 (Integer): 1 when CHROM, POS, REF
# and ALT all match a REDIportal v3 site and its edited base, 0 otherwise.
# echtvar 0.2.0 (the version used by tools/echtvar_anno.cwl) cannot encode Flag
# fields, so absence is encoded as missing_value 0. Filter with
# INFO/REDIPORTAL_V3=1.
#
# REDIportal's Ref/Ed bases are already on the genomic + strand (a minus-strand
# A-to-I edit is listed as T>C), so no strand conversion is done. Only
# presence/absence is kept; REDIportal's per-tissue and gene columns are dropped.
#
# The build fails on an unexpected header, malformed or unsorted rows, or an
# empty table. The ZIP is encoded as <name>.unverified.zip next to OUTPUT_ZIP;
# every site is annotated back against it, and it is renamed to OUTPUT_ZIP only
# if all of them return REDIPORTAL_V3=1 and up to 20 off-site records (10 site
# positions with a different ALT base, 10 positions with no REDIportal row,
# taken from primary chromosomes spread through the table) all return
# REDIPORTAL_V3=0. On
# failure OUTPUT_ZIP is not created and the unverified ZIP is left for
# inspection (a re-run replaces it).
#
# Intermediate and check files (sites VCF, header, echtvar config, round-trip
# and negative-check files) are written to a temporary directory under $TMPDIR
# (or /tmp) and removed on exit. The build directory receives only the
# downloaded table and, by default, the ZIP.

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
# The ZIP is encoded under this name and renamed to OUTPUT_ZIP only after the
# round-trip check passes, so a failed build never leaves a file at OUTPUT_ZIP.
readonly UNVERIFIED_BASENAME="${OUTPUT_BASENAME%.zip}.unverified.zip"
readonly UNVERIFIED_ZIP="${OUTPUT_DIR}/${UNVERIFIED_BASENAME}"

if [[ ! -d "${OUTPUT_DIR}" ]]; then
  echo "Output directory does not exist: ${OUTPUT_DIR}" >&2
  exit 1
fi

# Intermediate and check files are written to a temporary work directory that is
# removed when the script exits, whether it succeeds or fails. Only the
# downloaded table (if any) and the ZIP are written outside it.
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/rediportal_v3.XXXXXX")"
readonly WORK_DIR
trap 'rm -rf "${WORK_DIR}"' EXIT
cd "${WORK_DIR}"

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
    -v "${WORK_DIR}":/work \
    -v "${OUTPUT_DIR}":/output \
    -w /work \
    "${ECHTVAR_IMAGE}" \
    "$@"
}

cat > rediportal_v3.echtvar.json <<'EOF'
[
  {"field": "REDIPORTAL_V3", "alias": "REDIPORTAL_V3", "missing_value": 0}
]
EOF

# TABLE1 columns: 2=Region 3=Position 4=Ref 5=Ed. Records go to stdout; the
# header (one ##contig line per contig, in order of appearance) is written at
# the end, once all contigs are known.
#
# The converter also picks off-site records for the negative check, written as
# CHROM POS REF ALT KIND to negative_sites.txt. It keeps the first candidate of
# each kind on every contig:
#   wrong_alt  a site position with an ALT that is neither its REF nor any
#              edited base listed there (rows are sorted, so all rows for a
#              position are adjacent).
#   non_site   a position with no REDIportal row: POS+1 of a site whose next
#              site on the same contig is further than one base away. These use
#              A>G, the editing change most likely to falsely match; REF need
#              not match the genome, since echtvar compares only CHROM, POS, REF
#              and ALT against what it encoded.
# At the end it takes up to MAX_NEG of each kind from primary chromosomes
# (chr1-22, X, Y) spaced evenly through the table, so the check is not
# confined to the start of chr1.
echo "Converting ${table} to a sites-only VCF"
gzip -cd "${table}" | LC_ALL=C awk -v hdr=header.vcf -v stats=convert_stats.txt -v neg=negative_sites.txt -v MAX_NEG=10 '
  # Called when leaving the position in negkey: keep it as the wrong_alt
  # candidate for its contig if the contig has none yet and a base is free.
  function finish_position(   i, b) {
    if (negkey == "" || (negchrom in wrong_alt)) return
    for (i = 1; i <= 4; i++) {
      b = substr("ACGT", i, 1)
      if (b != negref && index(negalts, b) == 0) {
        wrong_alt[negchrom] = negchrom OFS negpos OFS negref OFS b OFS "wrong_alt"
        return
      }
    }
  }
  # Marks in picked[] up to MAX_NEG contigs that have a candidate in cand[],
  # spaced evenly through the contigs in table order. Only primary chromosomes
  # (chr1-22, X, Y, with or without the chr prefix) are used, so picks land
  # where most calls are rather than on alt, random, unplaced or chrM contigs;
  # if none of them has a candidate, all contigs are used instead.
  function pick_spread(cand, picked,   i, m, k, c) {
    m = 0
    for (i = 1; i <= n; i++) {
      if ((order[i] in cand) && order[i] ~ /^(chr)?([1-9]|1[0-9]|2[0-2]|X|Y)$/) c[++m] = order[i]
    }
    if (m == 0) for (i = 1; i <= n; i++) if (order[i] in cand) c[++m] = order[i]
    if (m <= MAX_NEG) {
      for (i = 1; i <= m; i++) picked[c[i]] = 1
    } else {
      for (k = 0; k < MAX_NEG; k++) picked[c[int(k * (m - 1) / (MAX_NEG - 1) + 0.5) + 1]] = 1
    }
  }
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
    # Track candidates until this contig has one of each kind. A new contig has
    # none yet, so its first row always gets here, and finish_position then
    # closes the last tracked position of the previous contig.
    if (!($2 in wrong_alt) || !($2 in non_site)) {
      if ($2 ":" $3 != negkey) {
        finish_position()
        # last is 0 at the start of a contig, so gaps never span contigs.
        if (!($2 in non_site) && last > 0 && $3 + 0 > last + 1) {
          non_site[$2] = $2 OFS (last + 1) OFS "A" OFS "G" OFS "non_site"
        }
        negkey = $2 ":" $3; negchrom = $2; negpos = $3; negref = $4; negalts = $5
      } else {
        negalts = negalts $5
      }
    }
    last = $3 + 0
    print $2, $3, ".", $4, $5, ".", ".", "REDIPORTAL_V3=1"
    kept++
  }
  END {
    if (err) exit 1
    finish_position()
    pick_spread(wrong_alt, pick_w)
    pick_spread(non_site, pick_n)
    # Write per contig in table order, by position within a contig, so the
    # negative-check VCF is sorted.
    for (i = 1; i <= n; i++) {
      c = order[i]; w = (c in pick_w) ? wrong_alt[c] : ""; s = (c in pick_n) ? non_site[c] : ""
      if (w != "" && s != "") {
        split(w, wf, OFS); split(s, sf, OFS)
        if (sf[2] + 0 < wf[2] + 0) { t = w; w = s; s = t }
      }
      if (w != "") print w > neg
      if (s != "") print s > neg
    }
    print "##fileformat=VCFv4.2" > hdr
    print "##source=REDIportal v3 hg38 (TABLE1_hg38_v3.txt.gz)" > hdr
    for (i = 1; i <= n; i++) print "##contig=<ID=" order[i] ">" > hdr
    print "##INFO=<ID=REDIPORTAL_V3,Number=1,Type=Integer,Description=\"1 if site and edited allele are present in REDIportal v3 (hg38)\">" > hdr
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
touch negative_sites.txt
read -r n_wrong_alt n_non_site < <(awk -F'\t' '{ c[$5]++ } END { print c["wrong_alt"] + 0, c["non_site"] + 0 }' negative_sites.txt)
if [[ "${n_wrong_alt}" -eq 0 ]]; then
  echo "Could not pick a wrong-ALT record for the negative check (every site position lists all three ALT bases)." >&2
  exit 1
fi
if [[ "${n_non_site}" -eq 0 ]]; then
  echo "Could not pick a non-site position for the negative check (no gaps between sites on any contig)." >&2
  exit 1
fi
readonly n_negatives=$((n_wrong_alt + n_non_site))
echo "Negative check records: ${n_wrong_alt} wrong-ALT, ${n_non_site} non-site, on contigs: $(cut -f1 negative_sites.txt | uniq | paste -sd ' ' -)"

cat header.vcf body.vcf | echtvar_docker bcftools view -Oz -o "${SITES_VCF}" -
rm body.vcf

rm -f "${UNVERIFIED_ZIP}"
echtvar_docker echtvar encode \
  "/output/${UNVERIFIED_BASENAME}" \
  rediportal_v3.echtvar.json \
  "${SITES_VCF}"

# Round trip: strip REDIPORTAL_V3, re-annotate every site from the ZIP, and require
# that all of them come back as 1.
echtvar_docker sh -c "
  set -eu
  bcftools annotate -x INFO/REDIPORTAL_V3 -Oz -o roundtrip_input.vcf.gz ${SITES_VCF}
  echtvar anno -e '/output/${UNVERIFIED_BASENAME}' roundtrip_input.vcf.gz roundtrip_annotated.vcf.gz >/dev/null 2>&1
  bcftools view -H -i 'INFO/REDIPORTAL_V3=1' roundtrip_annotated.vcf.gz | wc -l > roundtrip_hits.txt
"
read -r roundtrip_hits < roundtrip_hits.txt
rm -f roundtrip_input.vcf.gz roundtrip_annotated.vcf.gz

if [[ "${roundtrip_hits}" -ne "${kept_rows}" ]]; then
  echo "Round-trip check failed: ${roundtrip_hits} of ${kept_rows} sites returned REDIPORTAL_V3=1." >&2
  echo "Unverified ZIP left at ${UNVERIFIED_ZIP}; ${OUTPUT_ZIP} was not written." >&2
  exit 1
fi

# Negative check: every record in negative_sites.txt (not REDIportal sites) must
# come back as REDIPORTAL_V3=0, not 1 and not missing. Results are written to
# negative_results.txt as CHROM POS REF ALT VALUE.
{
  grep -v '^##INFO=<ID=REDIPORTAL_V3,' header.vcf
  awk -F'\t' -v OFS='\t' '{ print $1, $2, ".", $3, $4, ".", ".", "." }' negative_sites.txt
} > negative_input.vcf
echtvar_docker sh -c "
  set -eu
  echtvar anno -e '/output/${UNVERIFIED_BASENAME}' negative_input.vcf negative_annotated.vcf.gz >/dev/null 2>&1
  bcftools query -f '%CHROM\t%POS\t%REF\t%ALT\t%INFO/REDIPORTAL_V3\n' negative_annotated.vcf.gz > negative_results.txt
"
rm -f negative_input.vcf negative_annotated.vcf.gz
read -r negative_returned negative_bad < <(awk -F'\t' '{ n++ } $5 != "0" { bad++ } END { print n + 0, bad + 0 }' negative_results.txt)

if [[ "${negative_returned}" -ne "${n_negatives}" || "${negative_bad}" -ne 0 ]]; then
  echo "Negative check failed: ${negative_bad} of ${negative_returned} returned records (${n_negatives} checked) did not return REDIPORTAL_V3=0:" >&2
  awk -F'\t' '$5 != "0" { print "  " $1 ":" $2 " " $3 ">" $4 " returned " $5 }' negative_results.txt | head -5 >&2
  echo "Unverified ZIP left at ${UNVERIFIED_ZIP}; ${OUTPUT_ZIP} was not written." >&2
  exit 1
fi

mv "${UNVERIFIED_ZIP}" "${OUTPUT_ZIP}"
echo "Reference build complete; all ${kept_rows} sites returned 1 and all ${n_negatives} off-site records returned 0: ${OUTPUT_ZIP}"
