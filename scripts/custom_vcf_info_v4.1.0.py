#!/usr/bin/env python3
"""
Add custom INFO fields to gnomAD v4.1.0 VCF using pysam
"""
import pysam
import argparse


def create_mod_vcf(output_path, input_path, threads):
    """ Create a new VCF in which new INFO fields have been
            calculated and added based on those provided natively by gnomAD v4.1.0

        Args:
            output_path (str): path to the VCF being created
            input_path (str): path to the gnomAD VCF
            threads: num threads to use for read/write

        Raises:
            The reported error and what contig and position it happened at
    """

    input_vcf = pysam.VariantFile(input_path, 'r', threads=threads)

    input_vcf.header.info.add('GNOMAD_FILTER', '.', 'String',
            'Value of FILTER for gnomAD variant. Use to include/exclude non-PASS variants')
    input_vcf.header.info.add('AF_popmax', 'A', 'Float',
            ('Max AF of non-bottleneck populations (afr, amr, eas, nfe, sas)'))
    input_vcf.header.info.add('AF_all_popmax', 'A', 'Float',
            ('Max AF of all populations INCLUDING bottleneck (ami, asj, fin, mid, remaining)'))

    output = pysam.VariantFile(output_path, 'w', header=input_vcf.header)
    
    # Non-bottleneck population fields for popmax (v4.1.0 format: AF_<pop> not AF_non_cancer_<pop>)
    pop_fields = ['AF_afr', 'AF_amr', 'AF_eas', 'AF_nfe', 'AF_sas']
    # Bottleneck population fields
    pop_fields_bn = ['AF_ami', 'AF_asj', 'AF_fin', 'AF_mid', 'AF_remaining']
    
    for record in input_vcf.fetch():
        try:
            record.info['GNOMAD_FILTER'] = record.filter.keys()
            
            # Get non-bottleneck pop max
            pop_values = [record.info[pop] for pop in pop_fields if pop in record.info]
            if len(pop_values) > 0:
                record.info['AF_popmax'] = max(pop_values)
            
            # Get pop max with bottleneck populations
            pop_values_bn = [record.info[pop] for pop in pop_fields_bn if pop in record.info]
            if len(pop_values_bn) > 0:
                if len(pop_values) > 0:
                    record.info['AF_all_popmax'] = max(max(pop_values), max(pop_values_bn))
                else:
                    record.info['AF_all_popmax'] = max(pop_values_bn)
            
            output.write(record)
        except Exception as e:
            print(e)
            print("Failed at {} {}".format(record.contig, record.pos))
            exit(1)


def main():
    parser = argparse.ArgumentParser(
            description = 'Add custom fields to gnomAD v4.1.0 VCF. Limited scope')

    parser.add_argument('--input_vcf', 
            help='gnomAD v4.1.0 VCF to add INFO to')
    parser.add_argument('--output_basename',
            help='String to use as basename for output file [e.g.] task ID')
    parser.add_argument('--threads',
            help='Num threads to use for read/write', default=1)

    args = parser.parse_args()

    output_vcf_name = args.output_basename + ".INFO_added.vcf.gz"

    # Create and index the modified VCF
    create_mod_vcf(output_vcf_name, args.input_vcf, int(args.threads))
    pysam.tabix_index(output_vcf_name, preset="vcf", force=True)


if __name__ == '__main__':
    main()
