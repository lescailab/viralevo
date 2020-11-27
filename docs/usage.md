# nibscbioinformatics/viralevo: Usage

## Table of contents

* [Table of contents](#table-of-contents)
* [Introduction](#introduction)
* [Running the pipeline](#running-the-pipeline)
  * [Updating the pipeline](#updating-the-pipeline)
  * [Reproducibility](#reproducibility)
* [Main arguments](#main-arguments)
  * [`-profile`](#-profile)
  * [`--reads`](#--reads)
  * [`--single_end`](#--single_end)
* [Reference genomes](#reference-genomes)
  * [`--genome` (using iGenomes)](#--genome-using-igenomes)
  * [`--fasta`](#--fasta)
  * [`--igenomes_ignore`](#--igenomes_ignore)
* [Job resources](#job-resources)
  * [Automatic resubmission](#automatic-resubmission)
  * [Custom resource requests](#custom-resource-requests)
* [AWS Batch specific parameters](#aws-batch-specific-parameters)
  * [`--awsqueue`](#--awsqueue)
  * [`--awsregion`](#--awsregion)
  * [`--awscli`](#--awscli)
* [Other command line parameters](#other-command-line-parameters)
  * [`--outdir`](#--outdir)
  * [`--email`](#--email)
  * [`--email_on_fail`](#--email_on_fail)
  * [`--max_multiqc_email_size`](#--max_multiqc_email_size)
  * [`-name`](#-name)
  * [`-resume`](#-resume)
  * [`-c`](#-c)
  * [`--custom_config_version`](#--custom_config_version)
  * [`--custom_config_base`](#--custom_config_base)
  * [`--max_memory`](#--max_memory)
  * [`--max_time`](#--max_time)
  * [`--max_cpus`](#--max_cpus)
  * [`--plaintext_email`](#--plaintext_email)
  * [`--monochrome_logs`](#--monochrome_logs)
  * [`--multiqc_config`](#--multiqc_config)

## Introduction

Nextflow handles job submissions on SLURM or other environments, and supervises running the jobs. Thus the Nextflow process must run until the pipeline is finished. We recommend that you put the process running in the background through `screen` / `tmux` or similar tool. Alternatively you can run nextflow within a cluster job submitted your job scheduler.

It is recommended to limit the Nextflow Java virtual machines memory. We recommend adding the following line to your environment (typically in `~/.bashrc` or `~./bash_profile`):

```bash
NXF_OPTS='-Xms1g -Xmx4g'
```

## Running the pipeline

The typical command for running the pipeline is as follows:

```bash
nextflow run nibscbioinformatics/viralevo -profile nibsc --outdir /output/folder --tools all --genome SARS-CoV-2 --input /path/to/sampleinfo.tsv
```

The pipeline requires an input TSV file giving sample information. Each sample is represented by a single row, and the columns consist of sample name, location of forward reads fastq.gz file, location of reverse reads fastq.gz file.

The test profile contains example input data and can be launched with:

```bash
nextflow run nibscbioinformatics/viralevo -profile test,nibsc --outdir /output/folder
```

This will launch the pipeline with the `nibsc` configuration profile. See below for more information about profiles.

Note that the pipeline will create the following files under the specified /output/folder:

* [alignments] - contains the depth table, and a subfolder for each sample containing aligned BAM files, consensus sequence and a SPADES output folder with de novo assembly files
* [calling] - contains variant caller output from LoFreq and iVar as well as an aggregate variant table
* [fastqc] - contains output from FastQC
* [MultiQC] - contains the MultiQC report
* [phylogenetic] - contains MUSCLE and jModelTest output files
* [pipeline_info] - automatically generated pipeline information
* [reports] - contains the analysis report
* [stats] - contains tables summarising alignment and trimming logs

* [work] - unless otherwise specified with -w /my/work/folder this will be placed in the working directory, and contain Nextflow working files from the run
* [.nextflow_log] - Log file from Nextflow

### Updating the pipeline

When you run the above command, Nextflow automatically pulls the pipeline code from GitHub and stores it as a cached version. When running the pipeline after this, it will always use the cached version if available - even if the pipeline has been updated since.
To make sure that you're running the latest version of the pipeline, make sure that you regularly update the cached version of the pipeline:

```bash
nextflow pull nibscbioinformatics/viralevo
```

### Reproducibility

It's a good idea to specify a pipeline version when running the pipeline on your data. This ensures that a specific version of the pipeline code and software are used when you run your pipeline. If you keep using the same tag, you'll be running the same version of the pipeline, even if there have been changes to the code since.

First, go to the [nibscbioinformatics/viralevo releases page](https://github.com/nibscbioinformatics/viralevo/releases) and find the latest version number - numeric only (eg. `1.3.1`). Then specify this when running the pipeline with `-r` (one hyphen) - eg. `-r 1.3.1`.

This version number will be logged in reports when you run the pipeline, so that you'll know what you used when you look back in the future.

## Output report

The key product of the pipeline is the analysis report generated under reports/analysis_report.html. This is automatically generated using R markdown based on the output from earlier steps in the pipeline. The key sections include Gviz plots giving the positions of variant calls and depth of coverage, phylogenetic trees, and QC and alignment assessments.

## Main arguments

### `-profile`

Use this parameter to choose a configuration profile. Profiles can give configuration presets for different compute environments.

Several generic profiles are bundled with the pipeline which instruct the pipeline to use software packaged using different methods (Docker, Singularity, Conda) - see below.

> We highly recommend the use of Docker or Singularity containers for full pipeline reproducibility, however when this is not possible, Conda is also supported.

The pipeline also dynamically loads configurations from [https://github.com/nf-core/configs](https://github.com/nf-core/configs) when it runs, making multiple config profiles for various institutional clusters available at run time. For more information and to see if your system is available in these configs please see the [nf-core/configs documentation](https://github.com/nf-core/configs#documentation).

Note that multiple profiles can be loaded, for example: `-profile test,docker` - the order of arguments is important!
They are loaded in sequence, so later profiles can overwrite earlier profiles.

If `-profile` is not specified, the pipeline will run locally and expect all software to be installed and available on the `PATH`. This is _not_ recommended.

* `docker`
  * A generic configuration profile to be used with [Docker](http://docker.com/)
  * Pulls software from dockerhub: [`nibscbioinformatics/viralevo`](http://hub.docker.com/r/nibscbioinformatics/viralevo/)
* `singularity`
  * A generic configuration profile to be used with [Singularity](http://singularity.lbl.gov/)
  * Pulls software from DockerHub: [`nibscbioinformatics/viralevo`](http://hub.docker.com/r/nibscbioinformatics/viralevo/)
* `conda`
  * Please only use Conda as a last resort i.e. when it's not possible to run the pipeline with Docker or Singularity.
  * A generic configuration profile to be used with [Conda](https://conda.io/docs/)
  * Pulls most software from [Bioconda](https://bioconda.github.io/)
* `test`
  * A profile with a complete configuration for automated testing
  * Includes links to test data so needs no other parameters
* `nibsc`
  * A profile set up to use the NIBSC SLURM environment with Singularity
  * Recommended for use at NIBSC

<!-- TODO nf-core: Document required command line parameters -->

### `--input`

Use this to specify the location of your input file data. A TSV file must be provided with columns giving sample name, forward fastq.gz reads, reverse fastq.gz reads respectively:

```bash
--input 'https://raw.githubusercontent.com/nibscbioinformatics/testdata/master/covid19/samples.tsv'
```

As an example for this file, the test profile input file contains the following lines:

SRR11494468 https://github.com/nibscbioinformatics/testdata/raw/master/covid19/SRR11494468_1.fastq.gz	https://github.com/nibscbioinformatics/testdata/raw/master/covid19/SRR11494468_2.fastq.gz
SRR11494508	https://github.com/nibscbioinformatics/testdata/raw/master/covid19/SRR11494508_1.fastq.gz	https://github.com/nibscbioinformatics/testdata/raw/master/covid19/SRR11494508_2.fastq.gz
SRR11577895	https://github.com/nibscbioinformatics/testdata/raw/master/covid19/SRR11577895_1.fastq.gz	https://github.com/nibscbioinformatics/testdata/raw/master/covid19/SRR11577895_2.fastq.gz

## Reference genomes `--genome`

The pipeline config files provide information on standard genomes for alignment, which are given in the file viralref.config. If you wish to use a reference genome not provided here, you must add it to this config file. To select a reference when running the pipeline, use the following:

```bash
--genome 'SARS-CoV-2'
```

The viralref.config file specifies other annotation data for each given genome. The Gviz code used in the automatic report generation relies on definition of an R object containing a genome model. If adding a new custom genome, this must be first generated and then specified in the viralref.config file. The following R code may be modified and used to generate a genome model, depending on specifics of the features that are required to be extracted:

```R
library(tidyr)
library(dplyr)
library(Gviz)
library(VariantAnnotation)
library(GenomicFeatures)
library(rtracklayer)
library(Biostrings)
library(stringr)
covid_gff_data <- as.data.frame(readGFF("construct.gff3")[-c(1),])
covid_gff_data$gene <- str_replace(covid_gff_data$Note, "similar to ","")
covidgr <- GRanges(covid_gff_data$seqid,
  IRanges(
    start = covid_gff_data$start,
    end = covid_gff_data$end
  ),
  strand = covid_gff_data$strand
)
elementMetadata(covidgr) <- covid_gff_data[c("type", "ID", "gene")]
saveRDS(covidgr, "construct.rds")
```

## Other parameters

The pipeline has several other parameters that are usually fixed but may be adjusted when running by a user.

--adapter [file]                Path to fasta for adapter sequences to be trimmed

Calling options (with default):

--ivar_af_threshold [float]     Allele Frequency threshold for calling (default 0.001)
--ivar_dp_threshold [int]       Minimum depth to call variants or to call consensus (default 10)
--vaf_threshold [float]         Variant Allele Fraction threshold for filtering and consensus sequences (default 0.01)
--alt_depth_threshold  [int]    Alt allele supporting read threshold for filtering and consensus variants (default 100)
--noannotation                  Optionally, turn off annotation with SnpEff where database unavailable for genome

## Job resources

### Automatic resubmission

Each step in the pipeline has a default set of requirements for number of CPUs, memory and time. For most of the steps in the pipeline, if the job exits with an error code of `143` (exceeded requested resources) it will automatically resubmit with higher requests (2 x original, then 3 x original). If it still fails after three times then the pipeline is stopped.

### Custom resource requests

Wherever process-specific requirements are set in the pipeline, the default value can be changed by creating a custom config file. See the files hosted at [`nf-core/configs`](https://github.com/nf-core/configs/tree/master/conf) for examples.

If you are likely to be running `nf-core` pipelines regularly it may be a good idea to request that your custom config file is uploaded to the `nf-core/configs` git repository. Before you do this please can you test that the config file works with your pipeline of choice using the `-c` parameter (see definition below). You can then create a pull request to the `nf-core/configs` repository with the addition of your config file, associated documentation file (see examples in [`nf-core/configs/docs`](https://github.com/nf-core/configs/tree/master/docs)), and amending [`nfcore_custom.config`](https://github.com/nf-core/configs/blob/master/nfcore_custom.config) to include your custom profile.

If you have any questions or issues please send us a message on [Slack](https://nf-co.re/join/slack).

## AWS Batch specific parameters

Running the pipeline on AWS Batch requires a couple of specific parameters to be set according to your AWS Batch configuration. Please use [`-profile awsbatch`](https://github.com/nf-core/configs/blob/master/conf/awsbatch.config) and then specify all of the following parameters.

### `--awsqueue`

The JobQueue that you intend to use on AWS Batch.

### `--awsregion`

The AWS region in which to run your job. Default is set to `eu-west-1` but can be adjusted to your needs.

### `--awscli`

The [AWS CLI](https://www.nextflow.io/docs/latest/awscloud.html#aws-cli-installation) path in your custom AMI. Default: `/home/ec2-user/miniconda/bin/aws`.

Please make sure to also set the `-w/--work-dir` and `--outdir` parameters to a S3 storage bucket of your choice - you'll get an error message notifying you if you didn't.

## Other command line parameters

<!-- TODO nf-core: Describe any other command line flags here -->

### `--outdir`

The output directory where the results will be saved.

### `--email`

Set this parameter to your e-mail address to get a summary e-mail with details of the run sent to you when the workflow exits. If set in your user config file (`~/.nextflow/config`) then you don't need to specify this on the command line for every run.

### `--email_on_fail`

This works exactly as with `--email`, except emails are only sent if the workflow is not successful.

### `--max_multiqc_email_size`

Threshold size for MultiQC report to be attached in notification email. If file generated by pipeline exceeds the threshold, it will not be attached (Default: 25MB).

### `-name`

Name for the pipeline run. If not specified, Nextflow will automatically generate a random mnemonic.

This is used in the MultiQC report (if not default) and in the summary HTML / e-mail (always).

**NB:** Single hyphen (core Nextflow option)

### `-resume`

Specify this when restarting a pipeline. Nextflow will used cached results from any pipeline steps where the inputs are the same, continuing from where it got to previously.

You can also supply a run name to resume a specific run: `-resume [run-name]`. Use the `nextflow log` command to show previous run names.

**NB:** Single hyphen (core Nextflow option)

### `-c`

Specify the path to a specific config file (this is a core NextFlow command).

**NB:** Single hyphen (core Nextflow option)

Note - you can use this to override pipeline defaults.

### `--custom_config_version`

Provide git commit id for custom Institutional configs hosted at `nf-core/configs`. This was implemented for reproducibility purposes. Default: `master`.

```bash
## Download and use config file with following git commid id
--custom_config_version d52db660777c4bf36546ddb188ec530c3ada1b96
```

### `--custom_config_base`

If you're running offline, nextflow will not be able to fetch the institutional config files
from the internet. If you don't need them, then this is not a problem. If you do need them,
you should download the files from the repo and tell nextflow where to find them with the
`custom_config_base` option. For example:

```bash
## Download and unzip the config files
cd /path/to/my/configs
wget https://github.com/nf-core/configs/archive/master.zip
unzip master.zip

## Run the pipeline
cd /path/to/my/data
nextflow run /path/to/pipeline/ --custom_config_base /path/to/my/configs/configs-master/
```

> Note that the nf-core/tools helper package has a `download` command to download all required pipeline
> files + singularity containers + institutional configs in one go for you, to make this process easier.

### `--max_memory`

Use to set a top-limit for the default memory requirement for each process.
Should be a string in the format integer-unit. eg. `--max_memory '8.GB'`

### `--max_time`

Use to set a top-limit for the default time requirement for each process.
Should be a string in the format integer-unit. eg. `--max_time '2.h'`

### `--max_cpus`

Use to set a top-limit for the default CPU requirement for each process.
Should be a string in the format integer-unit. eg. `--max_cpus 1`

### `--plaintext_email`

Set to receive plain-text e-mails instead of HTML formatted.

### `--monochrome_logs`

Set to disable colourful command line output and live life in monochrome.

### `--multiqc_config`

Specify a path to a custom MultiQC configuration file.
