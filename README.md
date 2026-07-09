# OASIS 🌴 (Ortholog Alignment & Similarity Screener)

OASIS is a robust, interactive command-line pipeline designed for bioinformatics researchers to effortlessly fetch, align, and strictly filter orthologous sequences from NCBI.

Unlike web-based BLAST searches that query entire databases (introducing noise from paralogs and synthetic sequences), OASIS uses NCBI's evolutionary curation to download true orthologs and applies rigorous dual-filtering thresholds (Identity and Similarity/Positives) to generate highly reliable datasets for multiple sequence alignments (MSA) and phylogenetic analyses.

---

## Key Features

- **Flexible input:** accepts a single accession, multiple accessions (space-separated), or a batch file — one per line.
- **Multiple accession types:** RefSeq protein (`NP_`, `XP_`, `WP_`), RefSeq nucleotide/transcript (`NM_`, `XM_`), UniProtKB accessions, and numeric NCBI Gene IDs.
- **Automatic Gene ID resolution** from any of the accession types above, with multiple fallback strategies (elink, GenPept parsing, esummary).
- **Ortholog retrieval** via the NCBI Datasets CLI (`--ortholog`), for vertebrates and insects.
- **BLAST-based filtering** (`blastp`/`blastx`) by minimum Identity and Similarity thresholds you define.
- **Optional taxonomic scoping** to narrow the ortholog set to a clade of interest (e.g. `Mammalia`, `Actinopterygii`), which also serves as a batching strategy for very large ortholog sets.
- **Isoform screening** (flag or remove) to reduce redundant/alternatively-spliced entries in the ortholog pool before BLAST.
- **Optional protein and/or CDS FASTA export** per accession, with dynamic warnings if sequence/accession counts don't match.
- **Batch-friendly:** ortholog downloads and BLAST databases are cached per Gene ID and shared across accessions in the same run.

---

## Getting Started

### Requirements

- Linux/macOS shell (bash), `python3`
- Internet access to NCBI E-utilities, NCBI Datasets, and (for UniProt accessions) `rest.uniprot.org`
- The script auto-installs the NCBI Datasets CLI (`datasets`) and BLAST+ binaries into your home directory / a local `blast_bin` folder on first run if they aren't already present.

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
# Fully interactive
./OASIS.sh
```

You can also pass all parameters directly as arguments to skip the interactive prompts — useful when running via Docker or in automated workflows:

```bash
./OASIS.sh
or
./OASIS.sh <ACCESSION_ID> <MIN_IDENTITY> <MIN_SIMILARITY>

# Single accession, inline thresholds
./OASIS.sh NP_001416352.1 90 95

# Multiple accessions inline
./OASIS.sh NP_001416352.1 NM_001429423.1 90 95

# Batch file (one accession per line)
./OASIS.sh my_accessions.txt 90 95
```

You'll be prompted (once per run, applied to the whole batch) for:
- Whether to export protein FASTA and/or CDS FASTA per result.
- An **optional taxonomic scope** (e.g. `Mammalia`, or `Mammalia,Aves` to fetch and merge multiple clades).
- An **isoform handling mode**: keep all / flag only (default) / remove.

### Output Files

For each accession, under `OASIS_results_<timestamp>/<accession>/`:
- `filtered_accessions_ID<x>_SIM<y>_<accession>.txt` — accessions passing your Identity/Similarity thresholds.
- `sequences_PROT_OASIS_<accession>.fasta` — protein FASTA (if requested).
- `sequences_CDS_OASIS_<accession>.fasta` — CDS FASTA (if requested).
- `isoforms_flagged_<gene_id>.tsv` — report of sequences flagged as likely isoforms/redundant accessions (if isoform screening found any).

---

## Google Colab

A ready-to-run Google Colab notebook (`OASIS_Colab.ipynb`) is included for users who don't want to set up a local environment. It mirrors the CLI script's behavior with form-based inputs:

1. Open `OASIS_Colab.ipynb` in [Google Colab](https://colab.research.google.com/).
2. Run cells top to bottom. Cell 1 exposes form fields for the accession ID, molecule type, Identity/Similarity thresholds, an **optional taxonomic scope**, and an **isoform handling mode** (keep/flag/remove) — the same options available in the CLI script.
3. The final cell downloads the filtered accession list, protein FASTA, CDS FASTA, and (if applicable) the isoform report `.tsv` to your machine.

> Note: the Colab notebook processes **one accession per run** (no batch mode). For batch processing, use `OASIS.sh` locally or in a container.

---

## Docker / Singularity

A `Dockerfile` is included to run OASIS in a self-contained environment with the NCBI Datasets CLI and BLAST+ pre-installed.

### Build and run with Docker

```bash
docker build -t oasis:latest .

# Interactive run, mounting a local folder for output
docker run -it --rm -v "$(pwd)/data:/data" oasis:latest
```

The container's entrypoint runs `OASIS.sh` directly; any arguments you pass to `docker run` after the image name are forwarded to the script, e.g.:

```bash
docker run -it --rm -v "$(pwd)/data:/data" oasis:latest NP_001416352.1 90 95
```

### Build and run with Singularity / Apptainer

Singularity/Apptainer can build directly from the Dockerfile-based image without a separate `.def` file:

```bash
# Build a .sif image from the local Docker image (requires Docker daemon access)
apptainer build oasis.sif docker-daemon://oasis:latest

# ...or build directly from a registry image if you've pushed one, e.g.:
# apptainer build oasis.sif docker://<your-registry>/oasis:latest

# Run
apptainer run --bind "$(pwd)/data:/data" oasis.sif NP_001416352.1 90 95
```

> If you don't have Docker available on the build host, ask your HPC administrator whether `apptainer build --fakeroot` from a `.def` file is preferred instead — a `Dockerfile`-derived `.def` can be generated with tools like `spython recipe Dockerfile > oasis.def`.

---

## Important Notes

- **Query retrieval:** the NCBI Datasets CLI is now the **primary** path for fetching RefSeq protein/nucleotide query sequences, with `efetch` kept only as an automatic fallback. UniProt accessions still go through the UniProt REST API.
- **Accession/sequence count mismatches** (e.g. multiple isoforms mapping to one locus) trigger an explicit runtime warning showing the exact counts involved.
- **Isoform screening is heuristic** (organism-based, longest-sequence-kept) and not a substitute for manual curation before MSA or phylogenetic analysis.
- Manual curation is still recommended before downstream MSA/phylogenetic analysis.

---

## Roadmap / TO DO status

| Item | Status |
|---|---|
| Replace `efetch` with `ncbi-datasets-cli` for query sequence retrieval | ✅ Implemented (datasets CLI primary, efetch fallback) |
| Isoform filtering strategy (flag/remove alternatively spliced isoforms) | ✅ Implemented (heuristic, organism/longest-sequence based) |
| Lift the 499-sequence cap | ⚠️ Mitigated via taxon-scoped batched requests + truncation heuristic notice — not a guaranteed complete pagination solution |
| Taxonomic filter option | ✅ Implemented (`--ortholog <taxon>`, comma-separated for multiple clades) |
| Accession count mismatch warning | ✅ Implemented (dynamic comparison, warns only when counts actually differ) |

---

## ⚖️ License

This project is licensed under the **MIT License**. You are free to use, modify, and distribute this software for academic or commercial purposes, provided that proper credit is given to the original author.

---

## 🏛️ Acknowledgments & Disclaimer

- **Rodrigo Orvate** ([RodrigoOrvate](https://github.com/RodrigoOrvate)) — original author and creator of OASIS.
- **BaskervilleDog** ([BaskervilleDog](https://github.com/BaskervilleDog)) — maintenance, UniProt/Gene ID support, batch processing, taxonomic scoping, isoform screening, and the Datasets-CLI migration in this version.

- **NCBI Data & Tools:** OASIS is an independent, open-source wrapper script. It heavily relies on the [NCBI Datasets CLI](https://www.ncbi.nlm.nih.gov/datasets/) and [BLAST+ executables](https://blast.ncbi.nlm.nih.gov/Blast.cgi). This project is **not** officially affiliated with, maintained, or endorsed by the National Center for Biotechnology Information (NCBI) or the National Institutes of Health (NIH).
- **Academic Context:** This tool was developed to support computational biology and bioinformatics research initiatives (PIBIC) at the Federal University of Rio Grande do Norte (UFRN).

---

## 🔬 Developed For

Developed to streamline rigorous ortholog retrieval for phylogenetic and evolutionary conservation analyses.
---
EvoMol — Laboratório de Evolução Molecular e Sistemas.
