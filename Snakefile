import os


# Evolution
ACCESSION_NUMBERS = ['ERS6610%d' % i for i in range(87, 94)]
HYPHY_PATH = "/Users/stephenshank/Software/lib/hyphy"

rule reference_index:
  input:
    "input/references/{reference}.fasta"
  output:
    "output/references/{reference}.fasta"
  shell:
    """
      cp {input} {output}
      bwa index {output}
    """

rule extract_lanl:
  input:
    "input/LANL-HIV.fasta"
  output:
    "output/simulated/related_1/sequence.fasta",
    "output/simulated/related_2/sequence.fasta",
    "output/simulated/diverged_1/sequence.fasta",
    "output/simulated/diverged_2/sequence.fasta"
  shell:
    "python python/extract_sequences.py"

rule simulate_single:
  input:
    "output/simulated/{dataset}/sequence.fasta"
  output:
    reads="output/simulated/{dataset}/reads.fastq",
    qc="output/simulated/{dataset}/qc.fastq",
    json="output/simulated/{dataset}/qc.json",
    html="output/simulated/{dataset}/qc.html"
  shell:
    """
      art_illumina -ss HS25 -i {input} -l 120 -s 50 -c 15000 -o {output.reads}
      mv {output.reads}.fq {output.reads}
      fastp -A -q 10 -i {output.reads} -o {output.qc} -j {output.json} -h {output.html}
    """

rule simulate_mixed:
  input:
    "output/simulated/{dataset}_1/reads.fastq",
    "output/simulated/{dataset}_2/reads.fastq"
  output:
    reads="output/simulated/{dataset}_joint/reads.fastq",
    qc="output/simulated/{dataset}_joint/qc.fastq",
    json="output/simulated/{dataset}_joint/qc.json",
    html="output/simulated/{dataset}_joint/qc.html",
  shell:
    """
      cat {input[0]} {input[1]} > {output.reads}
      fastp -A -q 10 -i {output.reads} -o {output.qc} -j {output.json} -h {output.html}
    """
    
rule quality_control:
  input:
    "input/evolution/{accession}.fastq"
  output:
    fastq="output/{accession}/qc.fastq",
    json="output/{accession}/fastp.json",
    html="output/{accession}/fastp.html"
  shell:
    "fastp -A -q 10 -i {input} -o {output.fastq} -j {output.json} -h {output.html}"

rule map_reads:
  input:
    fastq=rules.quality_control.output[0],
    reference=rules.reference_index.output
  output:
    "output/{accession}/{reference}/mapped.sam"
  shell:
    "bwa mem {input.reference} {input.fastq} > {output}"

rule sort_and_index:
  input:
    rules.map_reads.output
  output:
    "output/{accession}/{reference}/sorted.bam"
  shell:
    """
      samtools sort {input} > {output}
      samtools index {output}
    """

rule reconstruct_haplotypes:
  input:
    rules.sort_and_index.output
  output:
    "output/{accession}/{reference}/haplotypes/final_haplo.fasta"
  script:
    "R/regress_haplo/full_pipeline.R"

rule concatenate:
  input:
    expand("output/{accession}/{{reference}}/haplotypes/final_haplo.fasta", accession=ACCESSION_NUMBERS)
  output:
    "output/{reference}/unaligned.fasta"
  params:
    lambda wildcards: ' '.join(["output/%s/%s/haplotypes/final_haplo.fasta" % (accession, wildcards.reference) for accession in ACCESSION_NUMBERS])
  shell:
    "cat {params} > {output}"

rule alignment:
  input:
    rules.concatenate.output[0]
  output:
    "output/{reference}/aligned.fasta"
  shell:
    "mafft {input} > {output}"

rule recombination_screening:
  input:
    rules.alignment.output[0]
  output:
    gard_json="output/{reference}/GARD.json",
    nexus="output/{reference}/seqs_and_trees.nex"
  params:
    gard_path="%s/TemplateBatchFiles/GARD.bf" % HYPHY_PATH,
    gard_output=os.getcwd() + "/output/{reference}/aligned.GARD",
    final_out=os.getcwd() + "/output/{reference}/aligned.GARD_finalout",
    translate_gard_j=os.getcwd() + "/output/{reference}/aligned.GARD.json",
    translated_json=os.getcwd() + "/output/{reference}/GARD.json",
    lib_path=HYPHY_PATH,
    alignment_path=os.getcwd() + "/output/{reference}/aligned.fasta"
  shell:
    """
      mpirun -np 2 HYPHYMPI LIBPATH={params.lib_path} {params.gard_path} {params.alignment_path} '010010' None {params.gard_output}
      translate-gard -i {params.gard_output} -j {params.translate_gard_j} -o {params.translated_json}
      mv {params.final_out} {output.nexus}
    """

rule site_selection:
  input:
    rules.recombination_screening.output.nexus
  output:
    "output/{reference}/seqs_and_trees.nex.FUBAR.json"
  params:
    full_nexus_path=os.getcwd() + "/" + rules.recombination_screening.output.nexus,
    fubar_path="%s/TemplateBatchFiles/SelectionAnalyses/FUBAR.bf" % HYPHY_PATH,
    lib_path=HYPHY_PATH
  shell:
    "(echo 1; echo {params.full_nexus_path}; echo 20; echo 1; echo 5; echo 2000000; echo 1000000; echo 100; echo .5;) | HYPHYMP LIBPATH={params.lib_path} {params.fubar_path}"

rule gene_selection:
  input:
    rules.recombination_screening.output.nexus
  output:
    "output/{reference}/seqs_and_trees.nex.BUSTED.json"
  params:
    full_nexus_path=os.getcwd() + "/" + rules.recombination_screening.output.nexus,
    busted_path="%s/TemplateBatchFiles/SelectionAnalyses/BUSTED.bf" % HYPHY_PATH,
    lib_path=HYPHY_PATH
  shell:
    "(echo 1; echo {params.full_nexus_path}; echo 2;) | HYPHYMP LIBPATH={params.lib_path} {params.busted_path}"

rule full_analysis:
  input:
    rules.site_selection.output[0],
    rules.gene_selection.output[0]
  output:
    "output/{reference}/results.tar.gz"
  shell:
    "tar cvzf {output} {input[0]} {input[1]}"


# Reconstruction
rule regress_haplo_full_pipeline:
  input:
    "input/haplotypes/{dataset}/reads.bam",
    "input/haplotypes/{dataset}/reads.bam.bai"
  output:
    "output/haplotypes/{dataset}/full/final_haplo.fasta"
  script:
    "R/invoke_regress_haplo.R"

rule regress_haplo_bam_to_variant_calls:
  input:
    "input/haplotypes/{dataset}/reads.bam",
    "input/haplotypes/{dataset}/reads.bam.bai"
  output:
    "output/haplotypes/{dataset}/variant_calls.csv"
  script:
    "R/regress_haplo/bam_to_variant_calls.R"
   
rule regress_haplo_variant_calls_to_read_table:
  input:
    rules.regress_haplo_full_pipeline.input[0],
    rules.regress_haplo_bam_to_variant_calls.output[0]
  output:
    "output/haplotypes/{dataset}/read_table.csv"
  script:
    "R/regress_haplo/variant_calls_to_read_table.R"

rule regress_haplo_read_table_to_loci:
  input:
    rules.regress_haplo_variant_calls_to_read_table.output[0]
  output:
    "output/haplotypes/{dataset}/loci.csv"
  script:
    "R/regress_haplo/read_table_to_loci.R"

rule regress_haplo_loci_to_haplotypes:
  input:
    rules.regress_haplo_read_table_to_loci.output[0]
  output:
    "output/haplotypes/{dataset}/h.csv"
  script:
    "R/regress_haplo/loci_to_haplotypes.R"

rule regress_haplo_haplotypes_to_parameters:
  input:
    rules.regress_haplo_loci_to_haplotypes.output[0]
  output:
    "output/haplotypes/{dataset}/P.csv"
  script:
    "R/regress_haplo/haplotypes_to_parameters.R"

rule regress_haplo_parameters_to_solutions:
  input:
    rules.regress_haplo_haplotypes_to_parameters.output[0]
  output:
    "output/haplotypes/{dataset}/solutions.csv"
  script:
    "R/regress_haplo/parameters_to_solutions.R"

rule regress_haplo_solutions_to_haplotypes:
  input:
    rules.regress_haplo_parameters_to_solutions.output[0]
  output:
    "output/haplotypes/{dataset}/final_haplo.csv"
  script:
    "R/regress_haplo/solutions_to_haplotypes.R"

rule regress_haplo_haplotypes_to_fasta:
  input:
    rules.regress_haplo_bam_to_variant_calls.input[0],
    rules.regress_haplo_solutions_to_haplotypes.output[0]
  output:
    "output/haplotypes/{dataset}/final_haplo.fasta"
  script:
    "R/regress_haplo/haplotypes_to_fasta.R"

