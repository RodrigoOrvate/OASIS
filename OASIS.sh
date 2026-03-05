#!/bin/bash

# --- 0. Smart Dependency Handlers (Rootless/Sudo-Free) ---
download_file() {
    local url="$1"
    local output="$2"
    if command -v curl &> /dev/null; then
        curl -s -L -o "$output" "$url"
    elif command -v wget &> /dev/null; then
        wget -q -O "$output" "$url"
    else
        echo "❌ Critical Error: Neither 'curl' nor 'wget' is installed."
        exit 1
    fi
}

download_text() {
    local url="$1"
    if command -v curl &> /dev/null; then
        curl -s "$url"
    elif command -v wget &> /dev/null; then
        wget -q -O - "$url"
    fi
}

extract_zip() {
    local zip_file="$1"
    local dest_dir="$2"
    if command -v unzip &> /dev/null; then
        unzip -q -o "$zip_file" -d "$dest_dir"
    elif command -v python3 &> /dev/null; then
        python3 -c "import zipfile; zipfile.ZipFile('$zip_file', 'r').extractall('$dest_dir')"
    else
        echo "❌ Critical Error: Neither 'unzip' nor 'python3' is installed."
        exit 1
    fi
}

# --- 1. Path Configuration (Centralized in HOME) ---
BLAST_DIR="$HOME/ncbi-blast-2.13.0+/bin"
DATASETS_PATH="$HOME/datasets"
export PATH="$BLAST_DIR:$HOME:$PATH"

install_tools() {
    if [ ! -f "$DATASETS_PATH" ]; then
        echo "📦 Downloading and installing datasets in $HOME..."
        download_file 'https://ftp.ncbi.nlm.nih.gov/pub/datasets/command-line/LATEST/linux-amd64/datasets' "$DATASETS_PATH"
        chmod +x "$DATASETS_PATH"
    fi

    if [ ! -d "$BLAST_DIR" ]; then
        echo "🛰️ Starting download of static binaries (Version 2.13.0)..."
        download_file 'https://ftp.ncbi.nlm.nih.gov/blast/executables/blast+/2.13.0/ncbi-blast-2.13.0+-x64-linux.tar.gz' "$HOME/blast.tar.gz"
        tar -xzf "$HOME/blast.tar.gz" -C "$HOME"
        rm "$HOME/blast.tar.gz"
    fi
}

# --- 2. Interactive Menu (OASIS) ---
echo "===================================================="
echo "    OASIS - Ortholog Alignment & Similarity Screener"
echo "===================================================="

read -p "🧬 Enter the Accession ID (e.g., NP_001416352.1 or NM_001429423.1): " ID
read -p "🔬 Is the query a [P]rotein or [N]ucleotide? (p/n): " MOL_TYPE

# --- 3. Input Validation (Sanity Checks) ---
if [[ "$ID" == NP_* || "$ID" == XP_* ]] && [[ "$MOL_TYPE" =~ ^[Nn]$ ]]; then
    echo "⚠️  Warning: You entered a PROTEIN ID ($ID) but selected [N]ucleotide."
    echo "❌ Please check if you chose the wrong option or entered the wrong Accession ID."
    exit 1
fi

if [[ "$ID" == NM_* || "$ID" == XM_* ]] && [[ "$MOL_TYPE" =~ ^[Pp]$ ]]; then
    echo "⚠️  Warning: You entered a NUCLEOTIDE ID ($ID) but selected [P]rotein."
    echo "❌ Please check if you chose the wrong option or entered the wrong Accession ID."
    exit 1
fi

read -p "📊 Enter the minimum Identity and Similarity desired (e.g., 90 95): " MIN_ID MIN_SIM

install_tools

FINAL_LIST="filtered_accessions_ID${MIN_ID}_SIM${MIN_SIM}_${ID}.txt"

# --- 4. Temporary Directory Setup ---
# Criamos uma pasta temporária única para esta execução baseada no ID e no PID do processo ($$)
TMP_DIR="tmp_OASIS_${ID}_$$"
mkdir -p "$TMP_DIR"

# O 'trap' garante que o TMP_DIR será deletado no final, mesmo se o script der erro ou for cancelado
trap 'rm -rf "$TMP_DIR"' EXIT

echo -e "\n🔍 Fetching sequences and orthologs from NCBI for ID: $ID..."

# Determining Program and Fetching Query Sequence based on molecule type
FASTA_QUERY="$TMP_DIR/query_${ID}.fasta"

if [[ "$MOL_TYPE" =~ ^[Nn]$ ]]; then
    BLAST_PROG="blastx"
    download_text "https://eutils.ncbi.nlm.nih.gov/entrez/eutils/efetch.fcgi?db=nuccore&id=${ID}&rettype=fasta&retmode=text" > "$FASTA_QUERY"
else
    BLAST_PROG="blastp"
    download_text "https://eutils.ncbi.nlm.nih.gov/entrez/eutils/efetch.fcgi?db=protein&id=${ID}&rettype=fasta&retmode=text" > "$FASTA_QUERY"
fi

# Fetching Orthologs into temp directory
"$DATASETS_PATH" download gene accession "$ID" --ortholog all --include protein --filename "$TMP_DIR/ortho.zip" > /dev/null 2>&1

if [ ! -s "$TMP_DIR/ortho.zip" ]; then
    echo "❌ Critical Error: Could not download ortholog package."
    echo "💡 Note: The NCBI Datasets tool does not support UniProt IDs. Please use a valid NCBI RefSeq ID (NP_, XP_, NM_, XM_)."
    exit 1
fi

extract_zip "$TMP_DIR/ortho.zip" "$TMP_DIR/ortho_temp"
ORTHO_FAA=$(find "$TMP_DIR/ortho_temp" -name "protein.faa" | head -n 1)

# --- 5. BLAST Processing ---
if [ -f "$ORTHO_FAA" ] && [ -f "$FASTA_QUERY" ]; then
    echo "⚙️ Configuring local database and running alignments using $BLAST_PROG..."
    
    "$BLAST_DIR/makeblastdb" -in "$ORTHO_FAA" -dbtype prot -out "$TMP_DIR/temp_db" -parse_seqids -logfile /dev/null
    
    "$BLAST_DIR/$BLAST_PROG" -query "$FASTA_QUERY" -db "$TMP_DIR/temp_db" \
                        -outfmt "6 saccver pident ppos" \
                        -evalue 1e-5 | \
                        awk -v id_min="$MIN_ID" -v sim_min="$MIN_SIM" \
                        '($2+0) >= (id_min+0) && ($3+0) >= (sim_min+0) {print $1}' | \
                        grep -v "$ID" | sort -u > "$FINAL_LIST"
    
    COUNT=$(wc -l < "$FINAL_LIST")
    echo "🎯 Success! Found $COUNT accessions meeting your criteria."
else
    echo "❌ Critical Error: Could not locate the required FASTA files after extraction."
    exit 1
fi

# --- 6. Protein FASTA Extraction ---
echo "----------------------------------------------------"
read -p "📥 Do you want to extract the protein FASTA file for these $COUNT sequences? (y/n): " DOWNLOAD_FASTA

if [[ "$DOWNLOAD_FASTA" =~ ^[YySs]$ ]]; then
    FASTA_FINAL="sequences_PROT_OASIS_${ID}.fasta"
    echo "🚀 Extracting proteins from the local database..."
    "$BLAST_DIR/blastdbcmd" -db "$TMP_DIR/temp_db" -entry_batch "$FINAL_LIST" -out "$FASTA_FINAL" 2>/dev/null
    
    if [ -s "$FASTA_FINAL" ]; then
        echo "✅ Protein FASTA successfully generated! ($FASTA_FINAL)"
    else
        echo "❌ Error extracting proteins."
    fi
else
    echo "🛑 Protein extraction skipped."
fi

# --- 7. Nucleotide FASTA (CDS) Download ---
echo "----------------------------------------------------"
read -p "🧬 Do you want to download the nucleotide sequences (CDS) for these orthologs? (y/n): " DOWNLOAD_CDS

if [[ "$DOWNLOAD_CDS" =~ ^[YySs]$ ]]; then
    CDS_FINAL="sequences_CDS_OASIS_${ID}.fasta"
    echo "🚀 Downloading gene packages via NCBI Datasets to extract CDS..."
    
    "$DATASETS_PATH" download gene accession --inputfile "$FINAL_LIST" --include cds --filename "$TMP_DIR/cds_filtered.zip" > /dev/null 2>&1
    
    if [ -f "$TMP_DIR/cds_filtered.zip" ]; then
        extract_zip "$TMP_DIR/cds_filtered.zip" "$TMP_DIR/cds_temp"
        
        cat $(find "$TMP_DIR/cds_temp" -name "cds.fna" -o -name "*.fna") > "$CDS_FINAL" 2>/dev/null
        
        echo "✅ CDS FASTA (Nucleotides) successfully generated! ($CDS_FINAL)"
    else
        echo "❌ Error: Could not download the CDS package from NCBI."
    fi
else
    echo "🛑 CDS download skipped."
fi

# --- 8. Summary ---
# Não precisamos mais do 'rm -rf' manual no final porque o 'trap' configurado na linha 83 fará a limpeza automática!

echo "===================================================="
echo "🏁 OASIS Pipeline finished successfully."
echo "📋 Your ID list is safely stored at: $FINAL_LIST"
echo "===================================================="