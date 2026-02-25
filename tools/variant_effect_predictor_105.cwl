cwlVersion: v1.2
class: CommandLineTool
id: kfdrc-vep105
label: VEP v105
doc: |
  Simplified description of what this tool does:
    1. Install needed plugins
    2. Untar cache if it is provided
    3. Run VEP on input VCF
    4. BGZIP output VCF
    5. TABIX output VCF

  VEP Parameters:
    1. input_file: Path to input file
    2. output_file: Path for output VCF or STDOUT
    3. stats_file: Path for output stats file
    4. warning_file: Path for output warnings file
    5. vcf: Writes output in VCF format
    6. offline: No database connections will be made, and a cache file or GFF/GTF file is required for annotation
    7. fork: Number of threads to run on
    8. ccds: Adds the CCDS transcript identifier
    9. uniprot: Adds best match accessions for translated protein products from three UniProt-related databases (SWISSPROT, TREMBL and UniParc)
    10. symbol: Adds the gene symbol (e.g. HGNC)
    11. numbers: Adds affected exon and intron numbering to to output. Format is Number/Total
    12. canonical: Adds a flag indicating if the transcript is the canonical transcript for the gene
    13. protein: Add the Ensembl protein identifier to the output where appropriate
    14. assembly: Select the assembly version to use if more than one available. If using the cache, you must have the appropriate assembly cache file installed
    15. dir_cache: Cache directory to use
    16. cache: Enables use of the cache
    17. merged: Use the merged Ensembl and RefSeq cache
    18. hgvs: Add HGVS nomenclature based on Ensembl stable identifiers to the output
    19. fasta: Specify a FASTA file or a directory containing FASTA files to use to look up reference sequence
    20. check_existing: Checks for the existence of known variants that are co-located with your input
    21. af_1kg: Add allele frequency from continental populations (AFR,AMR,EAS,EUR,SAS) of 1000 Genomes Phase 3 to the output
    22. af_esp: Include allele frequency from NHLBI-ESP populations
    23. af_gnomad: Include allele frequency from Genome Aggregation Database (gnomAD) exome populations
    24. plugin: Use named plugin
    25. custom: Add custom annotation to the output

  An example run of this tool will use a command like this:
    /bin/bash -c
    set -eo pipefail
    perl /opt/vep/src/ensembl-vep/INSTALL.pl
      --NO_TEST
      --NO_UPDATE
      --AUTO p
      --PLUGINS LoF,ExAC,gnomADc,CADD,dbNSFP,dbscSNV &&
    tar -xzf /path/to/cache.ext &&
    /opt/vep/src/ensembl-vep/vep
      --input_file /path/to/input_vcf.ext
      --output_file STDOUT
      --stats_file output_basename-string-value_stats.tool_name-string-value.html
      --warning_file output_basename-string-value_warnings.tool_name-string-value.txt
      --vcf
      --offline
      --fork $(inputs.cores)
      --ccds
      --uniprot
      --symbol
      --numbers
      --canonical
      --protein
      --assembly GRCh38
      --dir_cache $PWD
      --cache
      --merged
      --check_existing
      --af_1kg
      --af_esp
      --af_gnomad
      --hgvs
      --fasta /path/to/reference.ext
      --plugin CADD,/path/to/cadd_snvs.ext,/path/to/cadd_indels.ext
      --plugin dbNSFP,/path/to/dbnsfp.ext,ALL
      --plugin dbscSNV,/path/to/dbscsnv.ext
      --custom /path/to/phylop.ext,PhyloP,bigwig |
    bgzip -c > output_basename-string-value.tool_name-string-value.vep.vcf.gz &&
    tabix output_basename-string-value.tool_name-string-value.vep.vcf.gz

requirements:
  - class: ShellCommandRequirement
  - class: InlineJavascriptRequirement
  - class: ResourceRequirement
    ramMin: ${return inputs.ram * 1000}
    coresMin: $(inputs.cores)
  - class: DockerRequirement
    dockerPull: 'ensemblorg/ensembl-vep:release_105.0'
  - class: NetworkAccess
    networkAccess: true
baseCommand: ["/bin/bash", "-c"]
arguments:
  - position: 0
    shellQuote: false
    valueFrom: >-
      'set -eo pipefail

      ${
        var plugins = ["LoF","gnomADc"];
        if (inputs.cadd_indels) {
          plugins.push("CADD")
        }
        if (inputs.dbnsfp) {
          plugins.push("dbNSFP")
        }
        if (inputs.dbscsnv) {
          plugins.push("dbscSNV")
        }
        return "perl /opt/vep/src/ensembl-vep/INSTALL.pl --NO_TEST --NO_UPDATE --AUTO p --PLUGINS "+plugins.join(',')+" &&"
      }
      ${if(inputs.cache) {return "tar -xzf "+inputs.cache.path} else {return '>&2 echo "Warning: No cache provided. Some options may be incompatible"'}} &&
      perl /opt/vep/src/ensembl-vep/vep
  - position: 2
    shellQuote: false
    valueFrom: >-
      --warning_file $(inputs.output_basename)_warnings.$(inputs.tool_name).txt
      ${
        if (inputs.run_stats){
          var arg = "--stats_file " + inputs.output_basename + "_stats." + inputs.tool_name + ".html";
          return arg;
        }
        else{
          return "--no_stats";
        }
      }
      ${if(inputs.reference) {return "--hgvs --hgvsg --fasta " + inputs.reference.path} else {return ""}}
      ${if(inputs.cache) {return "--cache --dir_cache ."} else {return ""}}
      ${if(inputs.cadd_indels && inputs.cadd_snvs) {return "--plugin CADD,"+inputs.cadd_snvs.path+","+inputs.cadd_indels.path} else {return ""}}
      ${if(inputs.run_cache_af) {return "--af_1kg --af_esp --af_gnomad"} else {return ""}}
      ${if(inputs.dbnsfp) {return "--plugin dbNSFP," + inputs.dbnsfp.path + "," + inputs.dbnsfp_fields} else {return ""}}
      ${if(inputs.dbscsnv) {return "--plugin dbscSNV,"+inputs.dbscsnv.path} else {return ""}}
      ${if(inputs.intervar) {return "--custom "+inputs.intervar.path+",Intervar,vcf,exact,0,STATUS"} else {return ""}}
  - position: 3
    shellQuote: false
    valueFrom: >-
      | bgzip -c -@ ${ return inputs.cores >= 8 ? 4 : 1; } > $(inputs.output_basename).$(inputs.tool_name).vep.vcf.gz &&
      tabix $(inputs.output_basename).$(inputs.tool_name).vep.vcf.gz'

inputs:
  input_vcf: { type: File, secondaryFiles: [.tbi], doc: "VCF file (with associated index) to be annotated",
    inputBinding: { position: 0, prefix: "--input_file"} }
  output_file: { type: 'string?', doc: "Output name of main result file. Use STDOUT to pipe to something else", default: "STDOUT",
    inputBinding: { position: 0, prefix: "--output_file" } }
  input_format: { type: ['null', {type: enum, name: input_format, symbols: ["ensembl", "vcf", "hgvs", "id", "region", "spdi"]}], doc: "Select only a certain type of variants from the input file", default: "vcf",
    inputBinding: { position: 1, prefix: "--format"} }
  ram: {type: 'int?', default: 32, doc: "In GB, may need to increase this value depending on the size/complexity of input"}
  cores: {type: 'int?', default: 16, doc: "Number of cores to use. May need to increase for really large inputs",
    inputBinding: { position: 0, prefix: "--fork" } }
  buffer_size: {type: 'int?', doc: "Increase or decrease to balance speed and memory usage", default: 5000,
    inputBinding: { position: 0, prefix: "--buffer_size"} }
  out_vcf_flag: { type: 'boolean?', doc: " Writes output in VCF format. Consequences are added in the INFO field of the VCF file, using the key 'CSQ'. Data fields are encoded separated by '|'; the order of
    fields is written in the VCF header. Output fields in the 'CSQ' INFO field can be selected by using --fields.If the input format was VCF, the file will remain unchanged save for the addition of the CSQ 
    field (unless using any filtering)",
    default: true, inputBinding: { position: 1, prefix: "--vcf"} }
  assembly: { type: 'string?', doc: "Select the assembly version to use if more than one available. If using the cache, you must have the appropriate assembly's cache file installed. If not specified and you have only 1 assembly version installed, this will be chosen by default", default: "GRCh38",
    inputBinding: { position: 1, prefix: "--assembly"} }
  domains: { type: 'boolean?', doc: "Adds names of overlapping protein domains to output. Not used by default", default: true,
    inputBinding: { position: 1, prefix: "--domains"} }
  failed: { type: ['null', {type: enum, name: failed, symbols: ["0", "1"]}], doc: "When checking for co-located variants, by default VEP will exclude variants that have been flagged as failed. Set this flag to include such variants. 0 is exclude", default: "1",
    inputBinding: { position: 1, prefix: "--failed"} }
  pick_order: { type: 'string?', doc: "Customise the order of criteria (and the list of criteria) applied when choosing a block of annotation data with one of the following options: --pick, --pick_allele, --per_gene, --pick_allele_gene, --flag_pick, --flag_pick_allele, --flag_pick_allele_gene.",
    default: "canonical,tsl,biotype,rank,ccds,length", inputBinding: { position: 1, prefix: "--pick_order" } }
  flag_pick_allele: { type: 'boolean?', doc: "As per --pick_allele, but adds the PICK flag to the chosen block of consequence data and retains others", default: true,
    inputBinding: {position: 2, prefix: "--flag_pick_allele" } }
  protein: { type: 'boolean?', doc: "Add the Ensembl protein identifier to the output where appropriate", default: true,
    inputBinding: {position: 2, prefix: "--protein" } }
  gene_phenotype: { type: 'boolean?', doc: "Indicates if the overlapped gene is associated with a phenotype, disease or trait", default: true,
    inputBinding: {position: 2, prefix: "--gene_phenotype" } }
  no_escape: { type: 'boolean?', doc: "Don't URI escape HGVS strings", default: true,
    inputBinding: {position: 2, prefix: "--no_escape" } }
  polyphen: { type: ['null', {type: enum, name: polyphen, symbols: ["p", "s", "b"]}], doc: "is a tool which predicts possible impact of an amino acid substitution on the structure and function of a human protein using straightforward physical and comparative considerations. VEP can output the _p_rediction term, _s_core or _b_oth", default: "b",
    inputBinding: { position: 1, prefix: "--polyphen"} }
  sift: { type: ['null', {type: enum, name: sift, symbols: ["p", "s", "b"]}], doc: "predicts whether an amino acid substitution affects protein function based on sequence homology and the physical properties of amino acids. VEP can output the _p_rediction term, _s_core or _b_oth", default: "b",
    inputBinding: { position: 1, prefix: "--sift"} }
  pubmed: { type: 'boolean?', doc: "Report Pubmed IDs for publications that cite existing variant. Must be used with --cache", default: true,
    inputBinding: {position: 2, prefix: "--pubmed" } }
  regulatory: { type: 'boolean?', doc: "Look for overlaps with regulatory regions. VEP can also report if a variant falls in a high information position within a transcription factor binding site. Output lines have a Feature type of RegulatoryFeature or MotifFeature", default: true,
    inputBinding: {position: 2, prefix: "--regulatory" } }
  shift_hgvs: { type: ['null', { type: enum, name: shift_hgvs, symbols: ["0", "1"] }], doc: "Enable or disable 3' shifting of HGVS notations. HGVS nomenclature requires an ambiguous sequence change to be described at the most 3' possible location. When enabled, this causes 'shifting' to the most 3' possible coordinates (relative to the transcript sequence and strand) before the HGVS notations are calculated; the flag HGVS_OFFSET is set to the number of bases by which the variant has shifted, relative to the input genomic coordinates. If HGVS_OFFSET is equals to 0, no value will be added to HGVS_OFFSET column. To disable the changing of location at transcript level set --shift_hgvs to 0.", default: "1",
    inputBinding: { position: 1, prefix: "--shift_hgvs"} }
  total_length: { type: 'boolean?', doc: "Give cDNA, CDS and protein positions as Position/Length", default: true,
    inputBinding: {position: 2, prefix: "--total_length" } }
  tsl: { type: 'boolean?', doc: "Adds the transcript support level for this transcript to the output", default: true,
    inputBinding: {position: 2, prefix: "--tsl" } }
  xref_refseq: { type: 'boolean?', doc: "Output aligned RefSeq mRNA identifier for transcript", default: true,
    inputBinding: {position: 2, prefix: "--xref_refseq" } }
  variant_class: { type: 'boolean?', doc: "Output the Sequence Ontology variant class", default: true,
    inputBinding: {position: 2, prefix: "--variant_class" } }
  offline: { type: 'boolean?', doc: "Enable offline mode. No database connections will be made, and a cache file or GFF/GTF file is required for annotation. Add --refseq to use the refseq cache (if installed)", default: true,
    inputBinding: {position: 2, prefix: "--offline" } }
  ccds: { type: 'boolean?', doc: "Adds the CCDS transcript identifer (where available) to the output", default: true,
    inputBinding: {position: 2, prefix: "--ccds" } }
  uniprot: { type: 'boolean?', doc: "Adds best match accessions for translated protein products from three UniProt-related databases (SWISSPROT, TREMBL and UniParc) to the output", default: true,
    inputBinding: {position: 2, prefix: "--uniprot" } }
  symbol: { type: 'boolean?', doc: "Adds the gene symbol (e.g. HGNC) (where available) to the output. Some gene symbol, e.g. HGNC, are only available in merged cache and therefore should be used with --merged option while using cache to get result.", default: true,
    inputBinding: {position: 2, prefix: "--symbol" } }
  numbers: { type: 'boolean?', doc: "Adds affected exon and intron numbering to to output. Format is Number/Total.", default: true,
    inputBinding: {position: 2, prefix: "--numbers" } }
  canonical: { type: 'boolean?', doc: "Adds a flag indicating if the transcript is the canonical transcript for the gene.", default: true,
    inputBinding: {position: 2, prefix: "--canonical" } }
  allele_number: { type: 'boolean?', doc: "Identify allele number from VCF input, where 1 = first ALT allele, 2 = second ALT allele etc. Useful when using --minimal.", default: true,
    inputBinding: {position: 2, prefix: "--allele_number" } }
  dont_skip: { type: 'boolean?', doc: "Don't skip input variants that fail validation, e.g. those that fall on unrecognised sequences. Combining --check_ref with --dont_skip will add a CHECK_REF output field when the given reference does not match the underlying reference sequence.", default: true,
    inputBinding: {position: 2, prefix: "--dont_skip" } }
  allow_non_variant: { type: 'boolean?', doc: "Don't skip input variants that fail validation, e.g. those that fall on unrecognised sequences. Combining --check_ref with --dont_skip will add a CHECK_REF output field when the given reference does not match the underlying reference sequence.", default: true,
    inputBinding: {position: 2, prefix: "--allow_non_variant" } }
  species: {type: 'string?', doc: "Refer to the cache dir structure to set this", default: "homo_sapiens",
    inputBinding: { position: 2, prefix: "--species" } }
  merged: { type: 'boolean?', doc: "Use the merged Ensembl and RefSeq cache. Consequences are flagged with the SOURCE of each transcript used.", default: true,
    inputBinding: {position: 2, prefix: "--merged" } }
  reference: { type: 'File?',  secondaryFiles: [.fai], doc: "Fasta genome assembly with indexes" }
  cache: { type: 'File?', doc: "tar gzipped cache from ensembl/local converted cache" }
  verbose: { type: 'boolean?', doc: "Turn on verbose logging for debug purposes", default: false,
    inputBinding: {position: 2, prefix: "--verbose" } }
  run_cache_existing: { type: 'boolean?', doc: "Checks for the existence of known variants that are co-located with your input. By default the alleles are compared and variants on an allele-specific basis - to compare only coordinates, use --no_check_alleles. ", default: true, 
    inputBinding: {position: 2, prefix: "--check_existing" } }
  run_cache_af: { type: 'boolean?', doc: "Run the allele frequency flags for cache", default: true }
  run_stats: { type: 'boolean?', doc: "Create stats file? Disable for speed", default: false }
  cadd_indels: { type: 'File?', secondaryFiles: [.tbi], doc: "VEP-formatted plugin file and index containing CADD indel annotations" }
  cadd_snvs: { type: 'File?', secondaryFiles: [.tbi], doc: "VEP-formatted plugin file and index containing CADD SNV annotations" }
  dbnsfp: { type: 'File?', secondaryFiles: [.tbi,^.readme.txt], doc: "VEP-formatted plugin file, index, and readme file containing dbNSFP annotations" }
  dbnsfp_fields: { type: 'string?', doc: "csv string with desired fields to annotate. Use ALL to grab all" }
  dbscsnv: { type: 'File?', secondaryFiles: [.tbi], doc: "VEP-formatted plugin file and index containing dbscSNV annotations" }
  intervar: { type: 'File?', doc: "Intervar vcf-formatted file. See docs for custom build instructions", secondaryFiles: [.tbi] }
  extra_args: { type: 'string?', inputBinding: { position: 2, shellQuote: false }, doc: "Any additional arguments for this tool. See VEP Documentation for complete list of options. Example input: --clin_sig_allele 1" }
  output_basename: { type: string, doc: "String that will be used in the output filenames" }
  tool_name: { type: string, doc: "Tool name to be used in output filenames" }

outputs:
  output_vcf: { type: File, outputBinding: { glob: '*.vcf.gz' }, secondaryFiles: ['.tbi'] }
  output_html: { type: 'File?', outputBinding: { glob: '*.html' }}
  warn_txt: { type: 'File?', outputBinding: { glob: '*.txt' }}
