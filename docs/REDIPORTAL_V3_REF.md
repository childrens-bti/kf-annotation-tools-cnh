# REDIportal v3 RNA-Editing echtvar Reference

This reference marks variants that match a known RNA-editing site in
REDIportal v3 (hg38). It is meant for
RNA-seq variant calls, where A-to-I editing shows up as A>G (or T>C on the minus
strand) and can be mistaken for a DNA variant. Only presence/absence is encoded;
REDIportal's per-tissue, per-sample and gene columns are not carried over.

## Output field

| Field | Type | Values |
|---|---|---|
| `REDIPORTAL_V3` | Integer | `1` if CHROM, POS, REF and ALT all match a REDIportal v3 site and its edited base; `0` otherwise |

echtvar 0.2.0, the version used by [`tools/echtvar_anno.cwl`](../tools/echtvar_anno.cwl),
cannot encode `Flag` fields, so absence is stored as `missing_value: 0` rather
than a missing flag. Every variant annotated with this ZIP therefore carries
`REDIPORTAL_V3=0` or `REDIPORTAL_V3=1`. Select likely editing sites with
`INFO/REDIPORTAL_V3=1` (bcftools) or `REDIPORTAL_V3 == 1` (GATK JEXL).

The field name carries the REDIportal version, in line with the
`gnomad_3_1_1_` prefix, so a later release can be added as a separate field
without changing what existing `retain_info` lists and MAF columns mean.

Matching is allele-specific: a variant at a REDIportal position with a different
alternate base (for example A>T at an A>G editing site) gets `0`.

## Source

- REDIportal v3, hg38: `https://rediportal.cloud.ba.infn.it/download/TABLE1_hg38_v3.txt.gz`
- Columns used: `Region` (CHROM), `Position` (POS), `Ref` (REF), `Ed` (ALT).
  `Ref` and `Ed` are already on the genomic + strand, so no strand conversion is
  done.

## Build

Requirements: Docker (pulls `pgc-images.sbgenomics.com/d3b-bixu/echtvar:0.2.0`,
which also provides bcftools), `gzip`, `awk`, and `curl` if downloading.

Download the table and build:

```bash
bash scripts/build_rediportal_v3.sh /path/to/rediportal-build
```

Or reuse a table that is already downloaded and choose the output path:

```bash
INPUT_TABLE=/path/to/TABLE1_hg38_v3.txt.gz \
OUTPUT_ZIP=/path/to/rediportal_v3_hg38.echtvar.zip \
  bash scripts/build_rediportal_v3.sh /path/to/rediportal-build
```

Optional environment variables:

- `INPUT_TABLE`: existing `TABLE1_hg38_v3.txt.gz` to use instead of downloading it.
- `TABLE_URL`: download URL (default: the REDIportal v3 hg38 URL above).
- `OUTPUT_ZIP`: output ZIP path (default: `<build-directory>/rediportal_v3_hg38.echtvar.zip`).
  The script refuses to overwrite an existing ZIP.

The script:

1. Converts the table to a sites-only VCF with `REDIPORTAL_V3=1` on every record and
   one `##contig` line per contig (echtvar crashes without them).
2. Stops if the header is not as expected, if any row is malformed (REF or ALT not
   a single A/C/G/T base, REF equal to ALT, non-numeric position), if rows are not
   sorted, or if the table has no sites.
3. Encodes the VCF with `echtvar encode` to a temporary
   `<name>.unverified.zip` next to `OUTPUT_ZIP`, using this config:

   ```json
   [
     {"field": "REDIPORTAL_V3", "alias": "REDIPORTAL_V3", "missing_value": 0}
   ]
   ```

4. Strips `REDIPORTAL_V3` from the sites VCF, annotates every site back against
   the unverified ZIP, and fails unless all of them return `REDIPORTAL_V3=1`.
5. Renames the unverified ZIP to `OUTPUT_ZIP`. If any earlier step fails,
   `OUTPUT_ZIP` is not created, so a re-run is not blocked; a leftover
   `.unverified.zip` is kept for inspection and replaced by the next run.

The sites VCF (`rediportal_v3_hg38.sites.vcf.gz`, about 50 MB) and the echtvar
config are left in the build directory.

### v3 build

REDIportal serves the table from a fixed URL, so the URL alone does not identify
the version. Check the MD5 of a downloaded `TABLE1_hg38_v3.txt.gz` against the
one below before comparing counts; a different MD5 means the file has changed
since this build.

| | Value |
|---|---|
| Input downloaded | 2026-11-18 |
| Input MD5 (`TABLE1_hg38_v3.txt.gz`) | `e861984b3cc959936c21a76fed30bc82` |
| Table rows | 15,680,832 |
| Sites encoded | 15,680,832 |
| Malformed rows | 0 |
| Distinct CHROM/POS | 15,680,832 (one edited base per position) |
| Contigs | 44 (chr1-22, X, Y, M and 19 alt/random contigs) |
| Round-trip `REDIPORTAL_V3=1` | 15,680,832 |
| ZIP size | about 18 MB |

## Use in the annotation workflows

Add the ZIP to `echtvar_anno_zips` alongside the gnomAD ZIP. The list replaces the
suggested default, so keep gnomAD in it or the `GNOMAD_AF_HIGH` filter has no
`gnomad_3_1_1_AF` to read:

```yaml
echtvar_anno_zips:
  - {class: File, path: gnomad.v3.1.1.custom.echtvar.zip}
  - {class: File, path: rediportal_v3_hg38.echtvar.zip}
```

All ZIPs in the list go to a single `echtvar anno` call, so no workflow change is
needed. The field is added to the VCF outputs automatically; to also get it as a
MAF column, append `REDIPORTAL_V3` to `retain_info`.

`REDIPORTAL_V3` does not affect the default soft filters or the public filter
(`FILTER="PASS"|INFO/HotSpotAllele=1`), so editing sites are tagged, not removed.

The ZIP uses `chr`-prefixed contig names. Input VCFs with `1`, `2`, ... contigs
will match nothing.
