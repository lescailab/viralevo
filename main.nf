#!/usr/bin/env nextflow
/*
========================================================================================
                         nibscbioinformatics/viralevo
========================================================================================
 nibscbioinformatics/viralevo Analysis Pipeline.
 #### Homepage / Documentation
 https://github.com/nibscbioinformatics/viralevo
----------------------------------------------------------------------------------------
*/

// ######### DEFAULT PARAMS SETTINGS ##########################
params.genome = 'SARS-CoV-2'
params.adapter = 'https://raw.githubusercontent.com/nibscbioinformatics/testdata/master/covid19/nexteraPE.fasta'
params.ivar_calling_af_threshold = 0.001
params.ivar_calling_dp_threshold = 10
params.vaf_threshold = 0.01
params.alt_depth_threshold = 100
params.annotate = true

def helpMessage() {
    // TODO nf-core: Add to this help message with new command line parameters
    log.info nfcoreHeader()
    log.info"""

    Usage:

    The typical command for running the pipeline is as follows:

    nextflow run nibscbioinformatics/viralevo --input 'path/to/samples.tsv' -profile docker

    Mandatory arguments:
      --input [file]                TSV file indicating samples and corresponding reads
      -profile [str]                Configuration profile to use. Can use multiple (comma separated)
                                    Available: conda, docker, singularity, test, awsbatch, <institute> and more

    Options:
      --genome [str]                  Name of reference (SARS-CoV-2 or MT299802 to MT299805)

    References:                       If not specified in the configuration file or you wish to overwrite any of the references
      --adapter [file]                Path to fasta for adapter sequences to be trimmed

    Calling options (with default):
      --ivar_af_threshold [float]     Allele Frequency threshold for calling (default 0.001)
      --ivar_dp_threshold [int]       Minimum depth to call variants or to call consensus (default 10)
      --vaf_threshold                 Variant Allele Fraction threshold for filtering and consensus sequences (default 0.01)
      --alt_depth_threshold           Alt allele supporting read threshold for filtering and consensus variants (default 100)
      --annotate false                Optionally, turn off annotation with SnpEff where database unavailable for genome

    Other options:
      --outdir [file]                 The output directory where the results will be saved
      --email [email]                 Set this parameter to your e-mail address to get a summary e-mail with details of the run sent to you when the workflow exits
      --email_on_fail [email]         Same as --email, except only send mail if the workflow is not successful
      --max_multiqc_email_size [str]  Theshold size for MultiQC report to be attached in notification email. If file generated by pipeline exceeds the threshold, it will not be attached (Default: 25MB)
      -name [str]                     Name for the pipeline run. If not specified, Nextflow will automatically generate a random mnemonic

    AWSBatch options:
      --awsqueue [str]                The AWSBatch JobQueue that needs to be set when running on AWSBatch
      --awsregion [str]               The AWS Region for your AWS Batch job to run on
      --awscli [str]                  Path to the AWS CLI tool
    """.stripIndent()
}

// Show help message
if (params.help) {
    helpMessage()
    exit 0
}

/*
 * SET UP CONFIGURATION VARIABLES
 */

// Check if genome exists in the config file
if (params.virus_reference && params.genome && !params.virus_reference.containsKey(params.genome)) {
    exit 1, "The provided genome '${params.genome}' is not available in the iGenomes file. Currently the available genomes are ${params.genomes.keySet().join(", ")}"
}

//Creating value channels for reference files
params.anno = params.genome ? params.virus_reference[params.genome].gff ?: null : null
if (params.anno) { ch_annotation = Channel.value(file(params.anno, checkIfExists: true)) }

params.fasta = params.genome ? params.virus_reference[params.genome].fasta ?: null : null
if (params.fasta) { ch_fasta = Channel.value(file(params.fasta, checkIfExists: true)) }

params.phyref = params.genome ? params.virus_reference[params.genome].pyloref ?: null : null
if (params.phyref) { ch_phyloref = Channel.value(file(params.phyref, checkIfExists: true)) }

params.genome_rmodel = params.genome ? params.virus_reference[params.genome].rmodel ?: null : null
if (params.genome_rmodel) { ch_genome_rmodel = Channel.value(file(params.genome_rmodel, checkIfExists: true)) }

primers_ch = params.primers ? Channel.value(file(params.primers)) : "null"
ch_adapter = params.adapter ? Channel.value(file(params.adapter)) : "null"

// ### TOOLS Configuration
toolList = defaultToolList()
tools = params.tools ? params.tools.split(',').collect{it.trim().toLowerCase()} : []
if (!checkListMatch(tools, toolList)) exit 1, 'Unknown tool(s), see --help for more information'

// Has the run name been specified by the user?
//  this has the bonus effect of catching both -name and --name
custom_runName = params.name
if (!(workflow.runName ==~ /[a-z]+_[a-z]+/)) {
    custom_runName = workflow.runName
}

if (workflow.profile.contains('awsbatch')) {
    // AWSBatch sanity checking
    if (!params.awsqueue || !params.awsregion) exit 1, "Specify correct --awsqueue and --awsregion parameters on AWSBatch!"
    // Check outdir paths to be S3 buckets if running on AWSBatch
    // related: https://github.com/nextflow-io/nextflow/issues/813
    if (!params.outdir.startsWith('s3:')) exit 1, "Outdir not on S3 - specify S3 Bucket to run on AWSBatch!"
    // Prevent trace files to be stored on S3 since S3 does not support rolling files.
    if (params.tracedir.startsWith('s3:')) exit 1, "Specify a local tracedir or run without trace! S3 cannot be used for tracefiles."
}

// Stage config files
ch_multiqc_config = file("$baseDir/assets/multiqc_config.yaml", checkIfExists: true)
ch_multiqc_custom_config = params.multiqc_config ? Channel.fromPath(params.multiqc_config, checkIfExists: true) : Channel.empty()
ch_output_docs = file("$baseDir/docs/output.md", checkIfExists: true)

/* ############################################
 * Create a channel for input read files
 * ############################################
 */
inputSample = Channel.empty()
if (params.input) {
  tsvFile = file(params.input)
  inputSample = readInputFile(tsvFile)
}
else {
  log.info "No TSV file"
  exit 1, 'No sample were defined, see --help'
}

// splitting the reads into fastq and processing
(ch_read_files_fastqc, inputSample) = inputSample.into(2)

// Header log info
log.info nfcoreHeader()
def summary = [:]
if (workflow.revision) summary['Pipeline Release'] = workflow.revision
summary['Run Name']         = custom_runName ?: workflow.runName
summary['Input']            = params.input
summary['Genome']           = params.genome
summary['Fasta Ref']        = params.fasta
summary['Annotation file']  = params.anno
summary['Max Resources']    = "$params.max_memory memory, $params.max_cpus cpus, $params.max_time time per job"
if (workflow.containerEngine) summary['Container'] = "$workflow.containerEngine - $workflow.container"
summary['Output dir']       = params.outdir
summary['Launch dir']       = workflow.launchDir
summary['Working dir']      = workflow.workDir
summary['Script dir']       = workflow.projectDir
summary['User']             = workflow.userName
if (workflow.profile.contains('awsbatch')) {
    summary['AWS Region']   = params.awsregion
    summary['AWS Queue']    = params.awsqueue
    summary['AWS CLI']      = params.awscli
}
summary['Config Profile'] = workflow.profile
if (params.config_profile_description) summary['Config Description'] = params.config_profile_description
if (params.config_profile_contact)     summary['Config Contact']     = params.config_profile_contact
if (params.config_profile_url)         summary['Config URL']         = params.config_profile_url
if (params.email || params.email_on_fail) {
    summary['E-mail Address']    = params.email
    summary['E-mail on failure'] = params.email_on_fail
    summary['MultiQC maxsize']   = params.max_multiqc_email_size
}
log.info summary.collect { k,v -> "${k.padRight(18)}: $v" }.join("\n")
log.info "-\033[2m--------------------------------------------------\033[0m-"

// Check the hostnames against configured profiles
checkHostname()

Channel.from(summary.collect{ [it.key, it.value] })
    .map { k,v -> "<dt>$k</dt><dd><samp>${v ?: '<span style=\"color:#999999;\">N/A</a>'}</samp></dd>" }
    .reduce { a, b -> return [a, b].join("\n            ") }
    .map { x -> """
    id: 'nibscbioinformatics-viralevo-summary'
    description: " - this information is collected when the pipeline is started."
    section_name: 'nibscbioinformatics/viralevo Workflow Summary'
    section_href: 'https://github.com/nibscbioinformatics/viralevo'
    plot_type: 'html'
    data: |
        <dl class=\"dl-horizontal\">
            $x
        </dl>
    """.stripIndent() }
    .set { ch_workflow_summary }

/*
 * Parse software version numbers
 */
process get_software_versions {
    publishDir "${params.outdir}/pipeline_info", mode: 'copy',
        saveAs: { filename ->
                      if (filename.indexOf(".csv") > 0) filename
                      else null
                }

    output:
    file 'software_versions_mqc.yaml' into ch_software_versions_yaml
    file "software_versions.csv"

    script:
    // TODO nf-core: Get all tools to print their version number here
    """
    export LC_ALL=C.UTF-8
    export LANG=C.UTF-8
    echo $workflow.manifest.version > v_pipeline.txt
    echo $workflow.nextflow.version > v_nextflow.txt
    fastqc --version > v_fastqc.txt
    multiqc --version > v_multiqc.txt
    scrape_software_versions.py &> software_versions_mqc.yaml
    """
}


//FastQC from nf-core template
process fastqc {
    tag "$name"
    label 'process_medium'
    publishDir "${params.outdir}/fastqc", mode: 'copy',
        saveAs: { filename ->
                      filename.indexOf(".zip") > 0 ? "zips/$filename" : "$filename"
                }

    input:
    set val(name), file(read1), file(read2) from ch_read_files_fastqc

    output:
    file "*_fastqc.{zip,html}" into ch_fastqc_results

    script:
    """
    fastqc --quiet --threads $task.cpus $read1 $read2
    """
}

//MultiQC from nf-core template (could add collection of other outputs)
process multiqc {
    publishDir "${params.outdir}/MultiQC", mode: 'copy'

    input:
    file (multiqc_config) from ch_multiqc_config
    file (mqc_custom_config) from ch_multiqc_custom_config.collect().ifEmpty([])
    // TODO nf-core: Add in log files from your new processes for MultiQC to find!
    file ('fastqc/*') from ch_fastqc_results.collect().ifEmpty([])
    file ('software_versions/*') from ch_software_versions_yaml.collect()
    file workflow_summary from ch_workflow_summary.collectFile(name: "workflow_summary_mqc.yaml")

    output:
    file "*multiqc_report.html" into ch_multiqc_report
    file "*_data"
    file "multiqc_plots"

    script:
    rtitle = custom_runName ? "--title \"$custom_runName\"" : ''
    rfilename = custom_runName ? "--filename " + custom_runName.replaceAll('\\W','_').replaceAll('_+','_') + "_multiqc_report" : ''
    custom_config_file = params.multiqc_config ? "--config $mqc_custom_config" : ''
    // TODO nf-core: Specify which MultiQC modules to use with -m for a faster run time
    """
    export LC_ALL=C.UTF-8
    export LANG=C.UTF-8
    multiqc -f $rtitle $rfilename $custom_config_file .
    """
}

//START OF NIBSC CUTADAPT-BWA-LOFREQ PIPELINE
//creating a value channel of BWA index files for the reference
process BuildBWAindexes {

    label 'process_medium'
    tag "BWA index"

    input:
        file(fasta) from ch_fasta

    output:
        file("${fasta}.*") into ch_bwaIndex

    script:
    """
    bwa index ${fasta}
    """
}

//Creating an fai index value channel from the reference
process buildsamtoolsindex {
  label 'process_medium'
  tag "Samtools index of fasta reference"

  input:
  file(fasta) from ch_fasta

  output:
  file("${fasta}.fai") into ch_samtoolsIndex

  script:
  """
  samtools faidx ${fasta}
  """
}

//Trimming of adapters and low-quality bases - note hardcoded parameters in command
process docutadapt {
  label 'process_medium'
  tag "trimming ${sampleprefix}"

  input:
  tuple sampleprefix, file(forward), file(reverse) from inputSample
  file(adapterfile) from ch_adapter

  output:
  set ( sampleprefix, file("${sampleprefix}.R1.trimmed.fastq.gz"), file("${sampleprefix}.R2.trimmed.fastq.gz") ) into (trimmingoutput1, trimmingoutput2)
  file("${sampleprefix}.trim.out") into trimouts

  script:
  """
  cutadapt -a file:${adapterfile} -A file:${adapterfile} -g file:${adapterfile} -G file:${adapterfile} -o ${sampleprefix}.R1.trimmed.fastq.gz -p ${sampleprefix}.R2.trimmed.fastq.gz $forward $reverse -q 30,30 --minimum-length 50 --times 40 -e 0.1 --max-n 0 > ${sampleprefix}.trim.out 2> ${sampleprefix}.trim.err
  """
}

//Produce output CSV table of trimming stats for reading in R
process dotrimlog {
  publishDir "$params.outdir/stats/trimming/", mode: "copy"
  label 'process_low'

  input:
  file "logdir/*" from trimouts.toSortedList()

  output:
  file("trimming-summary.csv") into trimlogend

  script:
  """
  python $baseDir/scripts/logger.py logdir trimming-summary.csv cutadapt
  """
}


//BWA alignment of samples, and sorting to BAM format
process doalignment {
  label 'process_high'

  input:
  set (sampleprefix, file(forwardtrimmed), file(reversetrimmed)) from trimmingoutput1
  file( fastaref ) from ch_fasta
  file ( bwaindex ) from ch_bwaIndex

  output:
  set (sampleprefix, file("${sampleprefix}_sorted.bam") ) into sortedbam

  script:
  """
  bwa mem \
  -t ${task.cpus} \
  -R '@RG\\tID:${sampleprefix}\\tSM:${sampleprefix}\\tPL:Illumina' \
  $fastaref \
  ${forwardtrimmed} ${reversetrimmed} \
  | samtools sort -@ ${task.cpus} \
  -o ${sampleprefix}_sorted.bam -O BAM
  """
}

//Addition of indel quality scores for LoFreq workflow
process indelqual {
  publishDir "$params.outdir/alignments/${sampleprefix}", mode: "copy"
  label 'process_singlecpu'

  input:
  set ( sampleprefix, file(sortedbamfile) ) from sortedbam
  file( fastaref ) from ch_fasta
  file ( bwaindex ) from ch_bwaIndex

  output:
  set ( sampleprefix, file("${sampleprefix}_indelqual.bam") ) into indelqualforindex

  """
  lofreq indelqual \
  --dindel \
  -f $fastaref \
  -o ${sampleprefix}_indelqual.bam $sortedbamfile
  """
}

//Build BAI indices for alignments, and also collect alignment statistics
process samtoolsindex {
  publishDir "$params.outdir/alignments/${sampleprefix}", mode: "copy"
  label 'process_medium'

  input:
  set ( sampleprefix, file(indelqualfile) ) from indelqualforindex

  output:
  tuple sampleprefix, file(indelqualfile), file("${indelqualfile}.bai") into (bam_for_call_ch, for_depth_ch, bam_for_report_ch)
  file("${sampleprefix}_flagstat.out") into flagstatouts

  """
  samtools index \
  -@ ${task.cpus} \
  $indelqualfile

  samtools flagstat \
  -@ ${task.cpus} \
  $indelqualfile > ${sampleprefix}_flagstat.out
  """
}

//Process alignment stats into CSV summary for R
process doalignmentlog {
  publishDir "$params.outdir/stats", mode: "copy"
  label 'process_low'

  input:
  file("logdir/*") from flagstatouts.toSortedList()

  output:
  file("alignment-summary.csv") into alignmentlogend

  script:
  """
  python $baseDir/scripts/logger.py logdir alignment-summary.csv flagstat
  """
}

//Creating input channel of BAM files for ivar variant calling
if( 'ivar' in tools | 'all' in tools ){
  (bam_for_call_ch, bam_for_ivar_ch) = bam_for_call_ch.into(2)
} else {
bam_for_ivar_ch = Channel.empty()
}

//Calling variants with LoFreq if included in the tools list
process varcall {
  publishDir "$params.outdir/calling/lofreq/${sampleprefix}", mode: "copy"
  label 'process_high'

  input:
  set ( sampleprefix, file(indelqualfile), file(samindexfile) ) from bam_for_call_ch
  file( fastaref ) from ch_fasta
  file( fastafai ) from ch_samtoolsIndex

  output:
  tuple val(sampleprefix), val("lofreq"), file("${sampleprefix}_lofreq.vcf") into lofreq_vcf_ch

  when: 'lofreq' in tools | 'all' in tools

  """
  lofreq call-parallel \
  --pp-threads ${task.cpus} \
  -f $fastaref \
  -o ${sampleprefix}_lofreq.vcf \
  --call-indels $indelqualfile
  """
}

//putting the bam and bai files ready to be handled all together for depth
(bam_for_depth_ch, bai_for_depth_ch) = for_depth_ch.into(2)
bam_for_depth_ch = bam_for_depth_ch.map {it[1]}
bai_for_depth_ch = bai_for_depth_ch.map {it[2]}

//Producing table with depth at each position - not suitable for large genomes
process dodepth {
  publishDir "$params.outdir/alignments/", mode: "copy"
  label 'process_low'

  input:
  file("bamfiles/*") from bam_for_depth_ch.toSortedList()
  file("baifiles/*") from bai_for_depth_ch.toSortedList()

  output:
  file ( "merged_samtools.depth") into samdepthout

  """
  ln -s bamfiles/*.bam .
  ln -s baifiles/*.bai .
  bamfiles=`ls *.bam`
  samtools depth -aa -m 0 \$bamfiles > raw_samtools.depth
  echo Region Position `echo \$bamfiles | sed 's/_indelqual.bam//g'` > header.txt
  cat header.txt raw_samtools.depth > merged_samtools.depth
  """
}
//END OF NIBSC CUTADAPT-BWA-LOFREQ PIPELINE


/*
#############################################################
## IVAR AMPLICON SEQUENCING SPECIFIC CALLING ################
#############################################################
https://andersen-lab.github.io/ivar/html/manualpage.html
*/
//ivar step trimming primer sequences
process ivarTrimming {
  label 'process_low'
  tag "${sampleID}-ivarTrimming"

  input:
  tuple val(sampleID), file(bam), file(bai) from bam_for_ivar_ch
  file(primers) from primers_ch

  output:
  tuple val(sampleID), file("${sampleID}_primer_sorted.bam"), file("${sampleID}_primer_sorted.bam.bai") into (primer_trimmed_ch, ivar_prebam_ch)

  when: 'ivar' in tools | 'all' in tools

  script:
  """
  ivar trim \
  -i $bam \
  -b $primers \
  -e -p "${sampleID}_primer_trimmed"

  samtools sort -@ ${task.cpus} -o "${sampleID}_primer_sorted.bam" "${sampleID}_primer_trimmed.bam"
  samtools index -@ ${task.cpus} "${sampleID}_primer_sorted.bam"
  """
}

//ivar variant calling then conversion to VCF
process ivarCalling {
  label 'process_low'
  tag "${sampleID}-ivar-calling"

  publishDir "${params.outdir}/calling/ivar/${sampleID}", mode: 'copy'

  input:
  tuple val(sampleID), file(trimmedbam), file(trimmedbai) from primer_trimmed_ch
  file(fasta) from ch_fasta
  file(gff) from ch_annotation

  output:
  tuple val(sampleID), file("${sampleID}_variants.tsv") into ivar_vars_ch
  tuple val(sampleID), val ("ivar"), file("${sampleID}_ivar.vcf") into ivar_vcf_ch

  when: 'ivar' in tools | 'all' in tools

  script:
  """
  samtools mpileup \
  -aa -A -d 0 -B -Q 0 \
  --reference $fasta \
  $trimmedbam \
  | ivar variants -p "${sampleID}_variants" \
  -t ${params.ivar_calling_af_threshold} \
  -m ${params.ivar_calling_dp_threshold} \
  -r $fasta \
  -g $gff

  perl $baseDir/scripts/ivar2vcf.pl --ivar ${sampleID}_variants.tsv --vcf ${sampleID}_ivar.vcf
  """
}

//Merge the ivar and lofreq output variant calls files into one channel
mixedvars_ch = Channel.empty()
if( 'ivar' in tools | 'all' in tools ){
  mixedvars_ch = mixedvars_ch.mix(ivar_vcf_ch) //tuple val(sampleID), val ("ivar"), file("${sampleID}_ivar.vcf")
}
if ('lofreq' in tools | 'all' in tools){
  mixedvars_ch = mixedvars_ch.mix(lofreq_vcf_ch) //tuple val(sampleprefix), val("lofreq"), file("${sampleprefix}_lofreq.vcf")
}

//annotate with snpEff if requested by default params.annotate = true
process annotate {
  publishDir "$params.outdir/calling/$caller/$sampleID", mode: "copy"
  tag "snpEff $caller $sampleID"
  label 'process_low'

  input:
  tuple sampleID, caller, file(vcf) from mixedvars_ch

  output:
  file("${sampleID}_${caller}_annotated.vcf") into annotatedfortable

  when: ('lofreq' in tools | 'ivar' in tools | 'all' in tools) && (params.annotate)

  script:
  """
  snpEff -ud 1 NC_045512.2 ${vcf} > ${sampleID}_${caller}_annotated.vcf
  """
}

//take output from annotation or otherwise take unannotated VCF for table generation
varsfortable = Channel.empty()
if (params.annotate) {
  varsfortable = varsfortable.mix(annotatedfortable)
} else {
  varsfortable = varsfortable.mix( mixedvars_ch.map{it[2]} )
}

//Make a table for R display of the combined variant calls with filter pass column
//Also write out a filtered VCF file for each input VCF file
//script relies on filenames which must be of the form
//${sampleID}_${caller}_annotated.vcf or ${sampleID}_ivar.vcf or ${sampleprefix}_lofreq.vcf
process makevartable {
  publishDir "$params.outdir/calling/", mode: "copy"
  label 'process_low'

  input:
  file "varcalls/*" from varsfortable.toSortedList()

  output:
  file("varianttable.csv") into nicetable
  file("*_filtered.vcf") into filteredvars

  when: 'lofreq' in tools | 'ivar' in tools | 'all' in tools

  """
  python $baseDir/scripts/tablefromvcf.py varcalls varianttable.csv ${params.alt_depth_threshold} ${params.vaf_threshold}
  """
}

//Now build a consensus using bcftools from the filtered vcfs
//Note that filenames must be in correct form as they are used to extract sampleprefix and caller
process buildconsensus {
  publishDir "$params.outdir/calling/${caller}/${sampleprefix}", mode: "copy"
  label 'process_medium'

  input:
  file(vcfin) from filteredvars.flatten() //"${sampleprefix}_${caller}_filtered.vcf"
  file(fastaref) from ch_fasta

  output:
  tuple val(sampleprefix), val(caller), file("${sampleprefix}_${caller}_consensus.fa") into consensus_ch
  tuple val(sampleprefix), val(caller), file("${vcfin}") into annotated_vcf_ch

  when: 'lofreq' in tools | 'ivar' in tools | 'all' in tools

  script:
  sampleprefix = (vcfin.name).replace("_lofreq_filtered.vcf","").replace("_ivar_filtered.vcf","")
  caller = (vcfin.name).repace(sampleprefix+"_","").replace("_filtered.vcf","")
  """
  cut -f 1-8 $vcfin > ${sampleprefix}_${caller}.cutup.vcf
  bcftools view ${sampleprefix}_${caller}.cutup.vcf -Oz -o ${sampleprefix}_${caller}.vcf.gz
  bcftools index ${sampleprefix}_${caller}.vcf.gz
  cat $fastaref | bcftools consensus ${sampleprefix}_${caller}.vcf.gz > ${sampleprefix}_${caller}.consensus.fasta

  perl $baseDir/scripts/change_fasta_name.pl \
  -fasta ${sampleprefix}_${caller}.consensus.fasta \
  -name ${sampleprefix}L \
  -out ${sampleprefix}_${caller}_consensus.fa
  """
}


/*
####################################################################
###### PHYLOGENETIC ANALYSIS ON CONSENSUS STARTS HERE ##############
####################################################################
*/

mixed_consensus_ch = consensus_ch.map {it[2]}

process MuscleMSA {
  publishDir "$params.outdir/phylogenetic/", mode: "copy"
  tag "muscle alignment"
  label 'process_low'
  label 'genomeFinish'

  input:
  file(consensus) from mixed_consensus_ch.collect()
  file(phyloref) from ch_phyloref

  output:
  tuple file("muscle_multiple_alignment.fasta"), file("muscle_multiple_alignment.phyi"), file("muscle_nj-tree.tree") into muscle_alignment_ch
  file("muscle_multiple_alignment.phyi") into multiple_align_for_jmodel_ch
  file("muscle_multiple_alignment.clw")
  file("names_conversion_table.txt") into aligned_names_ch

  when: 'lofreq' in tools | 'ivar' in tools | 'all' in tools

  script:
  """
  cat $consensus $phyloref >to_be_aligned.fa

  perl $baseDir/scripts/trim_fasta_names.pl \
  -fasta to_be_aligned.fa \
  -out to_be_aligned_trimmed.fa

  muscle \
  -in to_be_aligned_trimmed.fa \
  -out muscle_multiple_alignment.afa \
  -phyi -phyiout muscle_multiple_alignment.phyi \
  -clw -clwout muscle_multiple_alignment.clw \
  -fasta -fastaout muscle_multiple_alignment.fasta

  muscle -maketree \
  -in muscle_multiple_alignment.afa \
  -out muscle_nj-tree.tree \
  -cluster neighborjoining
  """
}


process JModelTest {
  publishDir "$params.outdir/phylogenetic/", mode: "copy"
  tag "jmodel eval"
  label 'process_low'
  label 'genomeFinish'

  input:
  file(alignment) from multiple_align_for_jmodel_ch

  output:
  file("${alignment}.jmodeltest.*.html")
  file("jmodel_tree_selection.txt")
  path("images", type: 'dir')
  path("resources", type: 'dir')
  tuple file("jmodel_tree_selection_aic.tree"), file("jmodel_tree_selection_bic.tree") into jmodel_trees_ch

  when: 'lofreq' in tools | 'ivar' in tools | 'all' in tools

  script:
  """
  java -jar /jmodeltest-2.1.10/jModelTest.jar -d ${alignment} \
  -tr ${task.cpus} \
  -g 4 \
  -i \
  -f \
  -AIC \
  -BIC \
  -a \
  -o ./jmodel_tree_selection.txt \
  --set-property log-dir=`pwd` \
  -w

  perl $baseDir/scripts/extract_jmodel.pl \
  -jmodel jmodel_tree_selection.txt \
  -aictree jmodel_tree_selection_aic.tree \
  -bictree jmodel_tree_selection_bic.tree
  """

}


/*
####################################################################
###### ASSEMBLY BASED PIPELINE #### from here ######################
####################################################################
*/
//Use spades for de novo assembly with isolate flag
process dospades {
  publishDir "$params.outdir/alignments/${sampleprefix}", mode: "copy"
  label 'process_high'

  input:
  set ( sampleprefix, file(forwardfile), file(reversefile) ) from trimmingoutput2

  output:
  set ( sampleprefix, file("${sampleprefix}_spades") ) into spadesoutputgeneral
  file("${sampleprefix}_contigs.fasta") into spadescontigs

  when: 'spades' in tools | 'all' in tools

  """
  spades.py -o ${sampleprefix}_spades -1 $forwardfile -2 $reversefile -t ${task.cpus} -m 120 --isolate
  cp ${sampleprefix}_spades/contigs.fasta ${sampleprefix}_contigs.fasta
  """
}

// ### GENOME FINISHING BLOCK GOES FROM here

//THIS NEEDS TO BE MODIFIED IN ORDER TO TAKE INPUT FROM gapfilled genomes
process mauvemsa {
  label 'process_high'
  publishDir "$params.outdir/alignments"

  input:
  file("samplecontigs/*") from spadescontigs.toSortedList()
  file(fastaref) from ch_fasta

  output:
  tuple ( file("covid_assembly_alignment.xmfa"), file("covid_alignment.tree"), file("covid_alignment.backbone") ) into mauveout

  when:
  'spades' in tools | 'all' in tools

  """
  progressiveMauve \
  --output=covid_assembly_alignment.xmfa \
  --output-guide-tree=covid_alignment.tree \
  --backbone-output=covid_alignment.backbone \
  $fastaref samplecontigs/*_contigs.fasta
  """
}





/*
#####################################################################
############## REPORTING BLOCKS GO HERE #############################
#####################################################################
*/

process Reporting {
  publishDir "${params.outdir}/reports", mode: 'copy'
  tag "reporting"
  label 'process_low'
  label 'reporting'

  input:
  val vcfData from annotated_vcf_ch.toList()
  file(rmodel) from ch_genome_rmodel
  val bamData from bam_for_report_ch.toList()
  tuple file(muscleFastaAln), file(musclePhyiAln), file(muscleTree) from muscle_alignment_ch
  tuple file(aicTree), file(bicTree) from jmodel_trees_ch
  file(trimsummary) from trimlogend
  file(alignmentsummary) from alignmentlogend
  file(treeNames) from aligned_names_ch
  file(samdepth) from samdepthout
  file(varianttable) from nicetable

  output:
  file("analysis_report.html")
  file("analysis_report.RData")

  script:
  // handling here the VCF files and metadata
  def sampleNamesList = []
  def callersList = []
  def vcfList = []
  vcfData.each() { sample,caller,vcf ->
    sampleNamesList.add(sample)
    callersList.add(caller)
    vcfList.add(vcf)
  }
  sampleNames = sampleNamesList.join(",")
  callerLabels = callersList.join(",")
  vcfFiles = vcfList.join(",")

  // handling the BAM files and metadata
  def bamSampleList = []
  def bamList = []
  def baiList = []
  bamData.each() { sample,bam,bai ->
    bamSampleList.add(sample)
    bamList.add(bam)
    baiList.add(bai)
  }
  bamSamples = bamSampleList.join(",")
  bamFiles = bamList.join(",")
  baiFiles = baiList.join(",")

  """
  ln -s $baseDir/assets/nibsc_report.css .

  Rscript -e "workdir<-getwd()
    rmarkdown::render('$baseDir/docs/analysis_report.Rmd',
    params = list(
      vcf = \\\"$vcfFiles\\\",
      callers = \\\"$callerLabels\\\",
      samples = \\\"$sampleNames\\\",
      genome = \\\"${params.genome}\\\",
      genemodel = \\\"$rmodel\\\",
      baseDir = \\\"$baseDir\\\",
      bamSamples = \\\"$bamSamples\\\",
      bamFiles = \\\"$bamFiles\\\",
      aicTree = \\\"$aicTree\\\",
      bicTree = \\\"$bicTree\\\",
      msaFasta = \\\"$muscleFastaAln\\\",
      msaPhylip = \\\"$musclePhyiAln\\\",
      trimsummarytable = \\\"$trimsummary\\\",
      alignmentsummarytable = \\\"$alignmentsummary\\\",
      samdepthtable = \\\"$samdepth\\\",
      varianttable = \\\"$varianttable\\\",
      treeNames = \\\"$treeNames\\\"
      ),
    knit_root_dir=workdir,
    output_dir=workdir)"
  """


}






/*
 * STEP 3 - Output Description HTML (from template)
 */
process output_documentation {
    publishDir "${params.outdir}/pipeline_info", mode: 'copy'

    input:
    file output_docs from ch_output_docs

    output:
    file "results_description.html"

    script:
    """
    markdown_to_html.py $output_docs -o results_description.html
    """
}

/*
 * Completion e-mail notification
 */
workflow.onComplete {

    // Set up the e-mail variables
    def subject = "[nibscbioinformatics/viralevo] Successful: $workflow.runName"
    if (!workflow.success) {
        subject = "[nibscbioinformatics/viralevo] FAILED: $workflow.runName"
    }
    def email_fields = [:]
    email_fields['version'] = workflow.manifest.version
    email_fields['runName'] = custom_runName ?: workflow.runName
    email_fields['success'] = workflow.success
    email_fields['dateComplete'] = workflow.complete
    email_fields['duration'] = workflow.duration
    email_fields['exitStatus'] = workflow.exitStatus
    email_fields['errorMessage'] = (workflow.errorMessage ?: 'None')
    email_fields['errorReport'] = (workflow.errorReport ?: 'None')
    email_fields['commandLine'] = workflow.commandLine
    email_fields['projectDir'] = workflow.projectDir
    email_fields['summary'] = summary
    email_fields['summary']['Date Started'] = workflow.start
    email_fields['summary']['Date Completed'] = workflow.complete
    email_fields['summary']['Pipeline script file path'] = workflow.scriptFile
    email_fields['summary']['Pipeline script hash ID'] = workflow.scriptId
    if (workflow.repository) email_fields['summary']['Pipeline repository Git URL'] = workflow.repository
    if (workflow.commitId) email_fields['summary']['Pipeline repository Git Commit'] = workflow.commitId
    if (workflow.revision) email_fields['summary']['Pipeline Git branch/tag'] = workflow.revision
    email_fields['summary']['Nextflow Version'] = workflow.nextflow.version
    email_fields['summary']['Nextflow Build'] = workflow.nextflow.build
    email_fields['summary']['Nextflow Compile Timestamp'] = workflow.nextflow.timestamp

    // TODO nf-core: If not using MultiQC, strip out this code (including params.max_multiqc_email_size)
    // On success try attach the multiqc report
    def mqc_report = null
    try {
        if (workflow.success) {
            mqc_report = ch_multiqc_report.getVal()
            if (mqc_report.getClass() == ArrayList) {
                log.warn "[nibscbioinformatics/viralevo] Found multiple reports from process 'multiqc', will use only one"
                mqc_report = mqc_report[0]
            }
        }
    } catch (all) {
        log.warn "[nibscbioinformatics/viralevo] Could not attach MultiQC report to summary email"
    }

    // Check if we are only sending emails on failure
    email_address = params.email
    if (!params.email && params.email_on_fail && !workflow.success) {
        email_address = params.email_on_fail
    }

    // Render the TXT template
    def engine = new groovy.text.GStringTemplateEngine()
    def tf = new File("$baseDir/assets/email_template.txt")
    def txt_template = engine.createTemplate(tf).make(email_fields)
    def email_txt = txt_template.toString()

    // Render the HTML template
    def hf = new File("$baseDir/assets/email_template.html")
    def html_template = engine.createTemplate(hf).make(email_fields)
    def email_html = html_template.toString()

    // Render the sendmail template
    def smail_fields = [ email: email_address, subject: subject, email_txt: email_txt, email_html: email_html, baseDir: "$baseDir", mqcFile: mqc_report, mqcMaxSize: params.max_multiqc_email_size.toBytes() ]
    def sf = new File("$baseDir/assets/sendmail_template.txt")
    def sendmail_template = engine.createTemplate(sf).make(smail_fields)
    def sendmail_html = sendmail_template.toString()

    // Send the HTML e-mail
    if (email_address) {
        try {
            if (params.plaintext_email) { throw GroovyException('Send plaintext e-mail, not HTML') }
            // Try to send HTML e-mail using sendmail
            [ 'sendmail', '-t' ].execute() << sendmail_html
            log.info "[nibscbioinformatics/viralevo] Sent summary e-mail to $email_address (sendmail)"
        } catch (all) {
            // Catch failures and try with plaintext
            [ 'mail', '-s', subject, email_address ].execute() << email_txt
            log.info "[nibscbioinformatics/viralevo] Sent summary e-mail to $email_address (mail)"
        }
    }

    // Write summary e-mail HTML to a file
    def output_d = new File("${params.outdir}/pipeline_info/")
    if (!output_d.exists()) {
        output_d.mkdirs()
    }
    def output_hf = new File(output_d, "pipeline_report.html")
    output_hf.withWriter { w -> w << email_html }
    def output_tf = new File(output_d, "pipeline_report.txt")
    output_tf.withWriter { w -> w << email_txt }

    c_green = params.monochrome_logs ? '' : "\033[0;32m";
    c_purple = params.monochrome_logs ? '' : "\033[0;35m";
    c_red = params.monochrome_logs ? '' : "\033[0;31m";
    c_reset = params.monochrome_logs ? '' : "\033[0m";

    if (workflow.stats.ignoredCount > 0 && workflow.success) {
        log.info "-${c_purple}Warning, pipeline completed, but with errored process(es) ${c_reset}-"
        log.info "-${c_red}Number of ignored errored process(es) : ${workflow.stats.ignoredCount} ${c_reset}-"
        log.info "-${c_green}Number of successfully ran process(es) : ${workflow.stats.succeedCount} ${c_reset}-"
    }

    if (workflow.success) {
        log.info "-${c_purple}[nibscbioinformatics/viralevo]${c_green} Pipeline completed successfully${c_reset}-"
    } else {
        checkHostname()
        log.info "-${c_purple}[nibscbioinformatics/viralevo]${c_red} Pipeline completed with errors${c_reset}-"
    }

}


def nfcoreHeader() {
    // Log colors ANSI codes
    c_black = params.monochrome_logs ? '' : "\033[0;30m";
    c_blue = params.monochrome_logs ? '' : "\033[0;34m";
    c_cyan = params.monochrome_logs ? '' : "\033[0;36m";
    c_dim = params.monochrome_logs ? '' : "\033[2m";
    c_green = params.monochrome_logs ? '' : "\033[0;32m";
    c_purple = params.monochrome_logs ? '' : "\033[0;35m";
    c_reset = params.monochrome_logs ? '' : "\033[0m";
    c_white = params.monochrome_logs ? '' : "\033[0;37m";
    c_yellow = params.monochrome_logs ? '' : "\033[0;33m";

    return """    -${c_dim}--------------------------------------------------${c_reset}-
                                            ${c_green},--.${c_black}/${c_green},-.${c_reset}
    ${c_blue}        ___     __   __   __   ___     ${c_green}/,-._.--~\'${c_reset}
    ${c_blue}  |\\ | |__  __ /  ` /  \\ |__) |__         ${c_yellow}}  {${c_reset}
    ${c_blue}  | \\| |       \\__, \\__/ |  \\ |___     ${c_green}\\`-._,-`-,${c_reset}
                                            ${c_green}`._,._,\'${c_reset}
    ${c_purple}  nibscbioinformatics/viralevo v${workflow.manifest.version}${c_reset}
    -${c_dim}--------------------------------------------------${c_reset}-
    """.stripIndent()
}

def checkHostname() {
    def c_reset = params.monochrome_logs ? '' : "\033[0m"
    def c_white = params.monochrome_logs ? '' : "\033[0;37m"
    def c_red = params.monochrome_logs ? '' : "\033[1;91m"
    def c_yellow_bold = params.monochrome_logs ? '' : "\033[1;93m"
    if (params.hostnames) {
        def hostname = "hostname".execute().text.trim()
        params.hostnames.each { prof, hnames ->
            hnames.each { hname ->
                if (hostname.contains(hname) && !workflow.profile.contains(prof)) {
                    log.error "====================================================\n" +
                            "  ${c_red}WARNING!${c_reset} You are running with `-profile $workflow.profile`\n" +
                            "  but your machine hostname is ${c_white}'$hostname'${c_reset}\n" +
                            "  ${c_yellow_bold}It's highly recommended that you use `-profile $prof${c_reset}`\n" +
                            "============================================================"
                }
            }
        }
    }
}


// ############## UTILITIES AND SAMPLE LOADING ######################

def readInputFile(tsvFile) {
    Channel.from(tsvFile)
        .splitCsv(sep: '\t')
        .map { row ->
            def idSample  = row[0]
            def file1      = returnFile(row[1])
            def file2      = "null"
            if (hasExtension(file1, "fastq.gz") || hasExtension(file1, "fq.gz")) {
                checkNumberOfItem(row, 3)
                file2 = returnFile(row[2])
                if (!hasExtension(file2, "fastq.gz") && !hasExtension(file2, "fq.gz")) exit 1, "File: ${file2} has the wrong extension. See --help for more information"
            }
            // else if (hasExtension(file1, "bam")) checkNumberOfItem(row, 5)
            // here we only use this function for fastq inputs and therefore we suppress bam files
            else "No recognisable extension for input file: ${file1}"
            [idSample, file1, file2]
        }
}

// #### SAREK FUNCTIONS #########################
def checkNumberOfItem(row, number) {
    if (row.size() != number) exit 1, "Malformed row in TSV file: ${row}, see --help for more information"
    return true
}

def hasExtension(it, extension) {
    it.toString().toLowerCase().endsWith(extension.toLowerCase())
}

// Return file if it exists
def returnFile(it) {
    if (!file(it).exists()) exit 1, "Missing file in TSV file: ${it}, see --help for more information"
    return file(it)
}

// Return status [0,1]
// 0 == Control, 1 == Case
def returnStatus(it) {
    if (!(it in [0, 1])) exit 1, "Status is not recognized in TSV file: ${it}, see --help for more information"
    return it
}

// ############### OTHER UTILS ##########################

// Example usage: defaultIfInexistent({myVar}, "default")
def defaultIfInexistent(varNameExpr, defaultValue) {
    try {
        varNameExpr()
    } catch (exc) {
        defaultValue
    }
}


// ########## DEFINES TOOLS TO BE USED IN THIS PIPELINE #########

def defaultToolList() {
    return [
        'lofreq',
        'ivar',
        'snpeff',
        'spades',
        'mauve',
        'all'
    ]
}


// Check if match existence
def checkIfExists(it, list) {
    if (!list.contains(it)) {
        log.warn "Unknown parameter: ${it}"
        return false
    }
    return true
}


/// check if present
// Compare each parameter with a list of parameters
def checkListMatch(allList, listToCheck) {
    return allList.every{ checkIfExists(it, listToCheck) }
}
