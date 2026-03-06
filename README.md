# OASIS 🌴 (Ortholog Alignment & Similarity Screener)

OASIS is a robust, interactive command-line pipeline designed for bioinformatics researchers to effortlessly fetch, align, and strictly filter orthologous sequences from NCBI. 

Unlike web-based BLAST searches that query entire databases (introducing noise from paralogs and synthetic sequences), OASIS uses NCBI's evolutionary curation to download true orthologs and applies rigorous dual-filtering thresholds (Identity and Similarity/Positives) to generate highly reliable datasets for multiple sequence alignments (MSA) and phylogenetic analyses.

---

## ✨ Key Features

* **Strict Dual-Filtering:** Filters orthologs mathematically by both `% Identity` and `% Similarity` simultaneously.
* **Molecule Flexibility:** Automatically handles both Protein (`NP_`, `XP_`) and Nucleotide (`NM_`, `XM_`) queries, adjusting the internal engine (`blastp` or `blastx`) accordingly.
* **Sudo-Free (Rootless) Architecture:** Perfect for university lab environments. It relies on native Linux tools (`curl`/`wget`, `unzip`/`python3`) and installs required bioinformatics tools locally without needing administrator privileges.
* **Zero-Config Dependencies:** Automatically downloads and configures **NCBI BLAST+ (v2.13.0)** and **NCBI Datasets CLI** in the user's `$HOME` directory.
* **Batch Extraction:** Instantly generates ready-to-use multifasta files for both Proteins and Coding DNA Sequences (CDS).
* **Clean Execution:** Uses isolated, process-specific temporary directories that self-destruct upon completion or cancellation, leaving your workspace completely clean.

---

## 🚀 Getting Started

### Prerequisites
OASIS is designed to run on Linux/Unix-based systems. It requires an active internet connection to query NCBI databases.

### Installation
Clone this repository and make the script executable:

```bash
git clone https://github.com/RodrigoOrvate/OASIS.git
cd OASIS
chmod +x OASIS.sh
```

### Running the Pipeline
Simply execute the script. It will guide you through an interactive menu:

```bash
./OASIS.sh
```

---

## 🛠️ Usage Example

When you run OASIS, you will be prompted to provide your parameters:

1. **Accession ID:** Provide a valid NCBI RefSeq ID (e.g., `NP_001416352.1`).
2. **Molecule Type:** Specify if your query is a Protein (`p`) or Nucleotide (`n`).
3. **Thresholds:** Provide the minimum Identity and Similarity percentages (e.g., `90 95`).

**Interactive Prompts:**
After the alignment and filtering steps, OASIS will ask if you want to automatically extract the output files:
* *Do you want to extract the protein FASTA file for these sequences? (y/n)*
* *Do you want to download the nucleotide sequences (CDS) for these orthologs? (y/n)*

---

## 📂 Output Files

Depending on your choices, OASIS will generate up to three files in your current directory:

1. `filtered_accessions_ID{min}_SIM{max}_{ID}.txt`: A raw text file containing the accession numbers of the orthologs that survived the strict filtering process.
2. `sequences_PROT_OASIS_{ID}.fasta`: A multifasta file containing the full amino acid sequences for all filtered orthologs.
3. `sequences_CDS_OASIS_{ID}.fasta`: A multifasta file containing the nucleotide Coding DNA Sequences (CDS) for all filtered orthologs.

---

## ⚠️ Important Notes (UniProt vs. RefSeq)

OASIS relies on the `ncbi-datasets-cli` to fetch pre-curated ortholog families. Because of this, **it does not accept UniProt IDs (e.g., P09217)** or AlphaFold IDs directly. 

If you have a UniProt ID, perform an **ID Mapping** to find its corresponding RefSeq Accession (starts with `NP_` or `XP_`) before running the script.

---

## 🌐 Web Version (No Installation)

Don't have access to a Linux terminal? You can run the entire OASIS pipeline directly in your browser using Google Colab. No installation, configuration, or powerful hardware required.

<a href="https://colab.research.google.com/github/RodrigoOrvate/OASIS/blob/main/OASIS_Colab.ipynb" target="_parent"><img src="https://colab.research.google.com/assets/colab-badge.svg" alt="Open In Colab"/></a>

---

## ⚖️ License

This project is licensed under the **MIT License**. You are free to use, modify, and distribute this software for academic or commercial purposes, provided that proper credit is given to the original author. 

## 🏛️ Acknowledgments & Disclaimer

* **NCBI Data & Tools:** OASIS is an independent, open-source wrapper script. It heavily relies on the [NCBI Datasets CLI](https://www.ncbi.nlm.nih.gov/datasets/) and [BLAST+ executables](https://blast.ncbi.nlm.nih.gov/Blast.cgi). This project is **not** officially affiliated with, maintained, or endorsed by the National Center for Biotechnology Information (NCBI) or the National Institutes of Health (NIH).
* **Academic Context:** This tool was developed to support computational biology and bioinformatics research initiatives (PIBIC) at the Federal University of Rio Grande do Norte (UFRN).

---

## 🔬 Developed For
Developed to streamline rigorous ortholog retrieval for phylogenetic and evolutionary conservation analyses.




