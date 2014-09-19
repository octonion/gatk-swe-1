#!/bin/bash
set -e
set -x
set -o pipefail

input=$(./swe get input | ./swe fetch -)
gatk_jar=$(./swe get gatk_jar)
gatk_data=$(./swe get GATK_DATA)
analysis=$(./swe get ANALYSIS)

[[ $analysis =~ exome ]] || [[ $analysis =~ WGS ]]

cpu_cores=32


zcat $input  >unsorted.vcf
vcfsorter.pl $gatk_data/hg19/ucsc.hg19.dict unsorted.vcf > input.vcf


############################### SNPS ###########################################
select_snps.pl < input.vcf > snps.raw.vcf

variants=$( cat snps.raw.vcf |grep -vc "^\#")

echo "raw.vcf: Total $variants SNPS found "

#    die "Not enough variants to run recalibration" if $variants < 10000;



if [ "$analysis" == "exome" ]
    then
        min_variants=3000 
        snp_annotations=" -an QD -an MQRankSum -an FS "
    else  
        min_variants=$[$variants/50]
        snp_annotations=" -an MQ0 -an QD -an MQRankSum -an FS -an DP"  
fi


#    foreach my $extra_options ("" , " --maxGaussians 4 "," --maxGaussians 2 ")

if [[ $gatk_jar =~ GenomeAnalysisTKLite ]] ;
then
    bad_variants="--minNumBadVariants $min_variants "
else
    bad_variants="--numBadVariants $min_variants "
fi


set +e
for extra_options in " "  " --maxGaussians 4 "  " --maxGaussians 2 "
do
    if [ ! -e indels.recal ]
    then
	java -Xmx7g -jar $gatk_jar \
	    -T VariantRecalibrator \
	    -R $gatk_data/hg19/ucsc.hg19.fasta \
	    -input snps.raw.vcf \
	    $bad_variants \
	    -resource:hapmap,VCF,known=false,training=true,truth=true,prior=15.0 $gatk_data/hapmap_3.3.hg19.vcf.gz \
	    -resource:omni,VCF,known=false,training=true,truth=false,prior=12.0 $gatk_data/1000G_omni2.5.hg19.vcf.gz \
	    -resource:dbsnp,VCF,known=true,training=false,truth=false,prior=2.0 $gatk_data/dbsnp_137.hg19.vcf.gz \
	    $snp_annotations \
	    -mode SNP \
	    -recalFile snps.recal.tmp \
	    -tranchesFile snps.tranches \
	    -rscriptFile snps.plots.R \
	    -nt $cpu_cores && mv snps.recal.tmp snps.recal
    fi
done
set -e

[ -e snps.recal ] # indel recalibration failed
        
mv snps.recal.tmp snps.recal

java  -Xmx7g  -jar $gatk_jar \
    -T ApplyRecalibration \
    -R $gatk_data/hg19/ucsc.hg19.fasta \
    -input snps.raw.vcf \
    --ts_filter_level 99.0 \
    -tranchesFile snps.tranches \
    -recalFile snps.recal \
    -mode SNP \
    -o snps.recalibrated.filtered.vcf 
  
  ############################################ Indels
  
select_indels.pl < input.vcf > indels.raw.vcf
 
 variants=$( cat indels.raw.vcf |grep -vc "^\#")

echo "raw.vcf: Total $variants indels found\n";


if [ "$analysis" == "exome" ]
    then
        min_variants=3000 
        indel_annotations=" -an QD -an MQRankSum -an FS -an ReadPosRankSum "
    else  
        min_variants=$[$variants/50]
        indel_annotations=" -an QD -an MQRankSum -an FS -an DP -an ReadPosRankSum "  
fi


if [[ $gatk_jar =~ GenomeAnalysisTKLite ]] ;
then
    bad_variants="--minNumBadVariants $min_variants "
else
    bad_variants="--numBadVariants $min_variants "
fi



    variants=$(grep -vPc "\^\#" < indels.raw.vcf)
    echo  "raw.vcf: Total $variants indels found "
    
#    die "Not enough variants to run recalibration" if $variants < 3000;

#try variant recalibration with succesively more relaxed parameters to go around numerical instabilities
set +e
for extra_options in " "  " --maxGaussians 4 "  " --maxGaussians 2 "
do
    if [ ! -e indels.recal ]
    then
    java -Xmx7g  -jar $gatk_jar \
	-T VariantRecalibrator \
	-R $gatk_data/hg19/ucsc.hg19.fasta \
	-input indels.raw.vcf \
	$indel_annotations \
	$bad_variants \
	$extra_options \
	-resource:mills,VCF,known=false,training=true,truth=true,prior=12.0 $gatk_data/Mills_and_1000G_gold_standard.indels.hg19.vcf.gz \
	-resource:dbsnp,VCF,known=true,training=false,truth=false,prior=2.0 $gatk_data/dbsnp_137.hg19.vcf.gz \
	-mode INDEL \
	-recalFile indels.recal.tmp \
	-tranchesFile indels.tranches \
	-rscriptFile indels.plots.R \
	-nt $cpu_cores && mv indels.recal.tmp indels.recal
    fi

done
set -e

[ -e indels.recal ] # indel recalibration failed

# Apply recalibration
java -Xmx7g -jar $gatk_jar \
    -T ApplyRecalibration \
    -R $gatk_data/hg19/ucsc.hg19.fasta \
    -input indels.raw.vcf \
    --ts_filter_level 95.0 \
    -tranchesFile indels.tranches \
    -recalFile    indels.recal \
    -mode INDEL \
    -o indels.recalibrated.filtered.vcf

# Combine variants 

java -Xmx7g -jar $gatk_jar \
    -T CombineVariants  \
    -R $gatk_data/hg19/ucsc.hg19.fasta \
    --variant snps.recalibrated.filtered.vcf \
    --variant indels.recalibrated.filtered.vcf \
    -o recalibrated.filtered.vcf 

bgzip recalibrated.filtered.vcf
tabix -p vcf recalibrated.filtered.vcf.gz

./swe emit file recalibrated.filtered.vcf.gz
./swe emit file recalibrated.filtered.vcf.gz.tbi
