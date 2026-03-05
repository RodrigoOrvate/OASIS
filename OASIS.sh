#!/bin/bash

BLAST_DIR="$HOME/ncbi-blast-2.13.0+/bin"
DATASETS_PATH="$HOME/datasets"
export PATH="$BLAST_DIR:$HOME:$PATH"

install_tools() {
    if [ ! -f "$DATASETS_PATH" ]; then
        echo "🚀 'datasets' utility not found."
        echo "📦 Downloading and installing datasets in $HOME..."
        curl -s -L -o "$DATASETS_PATH" 'https://ftp.ncbi.nlm.nih.gov/pub/datasets/command-line/LATEST/linux-amd64/datasets'
        chmod +x "$DATASETS_PATH"
        echo "✅ Datasets successfully installed."
    fi

    if [ ! -d "$BLAST_DIR" ]; then
        echo "🧬 NCBI-BLAST+ not detected in $HOME."
        echo "🛰️ Starting download of static binaries (Version 2.13.0)..."
        curl -s -L -o "$HOME/blast.tar.gz" 'https://ftp.ncbi.nlm.nih.gov/blast/executables/blast+/2.13.0/ncbi-blast-2.13.0+-x64-linux.tar.gz'
        tar -xzf "$HOME/blast.tar.gz" -C "$HOME"
        rm "$HOME/blast.tar.gz"
        echo "✅ BLAST+ 2.13.0 successfully installed."
    fi
}

echo "===================================================="
echo "    OASIS - Ortholog Alignment & Similarity Screener"
echo "===================================================="

read -p "🧬 Enter the Accession ID (e.g., NP_001416352.1): " ID
read -p "📊 Enter the minimum Identity and Similarity desired (e.g., 90 95): " MIN_ID MIN_SIM

install_tools

FINAL_LIST="filtered_accessions_ID${MIN_ID}_SIM${MIN_SIM}_${ID}.txt"

echo -e "\n🔍 Fetching sequences and orthologs from NCBI for ID: $ID..."

FASTA_QUERY="query_${ID}.fasta"
if [[ "$ID" == NM_* ]]; then
    curl -s "https://eutils.ncbi.nlm.nih.gov/entrez/eutils/efetch.fcgi?db=nuccore&id=${ID}&rettype=fasta&retmode=text" > "$FASTA_QUERY"
elif [[ "$ID" == NP_* ]]; then
    curl -s "https://eutils.ncbi.nlm.nih.gov/entrez/eutils/efetch.fcgi?db=protein&id=${ID}&rettype=fasta&retmode=text" > "$FASTA_QUERY"
else
    curl -s "https://rest.uniprot.org/uniprotkb/${ID}.fasta" > "$FASTA_QUERY"
fi

"$DATASETS_PATH" download gene accession "$ID" --ortholog all --include protein --filename "ortho.zip" > /dev/null 2>&1
unzip -q -o "ortho.zip" -d "ortho_temp"
ORTHO_FAA=$(find ortho_temp -name "protein.faa" | head -n 1)

if [ -f "$ORTHO_FAA" ] && [ -f "$FASTA_QUERY" ]; then
    echo "⚙️ Configuring local database and running alignments..."
    
    "$BLAST_DIR/makeblastdb" -in "$ORTHO_FAA" -dbtype prot -out "temp_db" -parse_seqids -logfile /dev/null
    
    "$BLAST_DIR/blastp" -query "$FASTA_QUERY" -db "temp_db" \
                        -outfmt "6 saccver pident ppos" \
                        -evalue 1e-5 | \
                        awk -v id_min="$MIN_ID" -v sim_min="$MIN_SIM" \
                        '$2 >= id_min && $3 >= sim_min {print $1}' | \
                        grep -v "$ID" | sort -u > "$FINAL_LIST"
    
    COUNT=$(wc -l < "$FINAL_LIST")
    echo "🎯 Success! Found $COUNT accessions meeting your criteria."
else
    echo "❌ Critical Error: Could not locate the required FASTA files."
    exit 1
fi

echo "----------------------------------------------------"
read -p "📥 Do you want to extract the protein FASTA file for these $COUNT sequences? (y/n): " DOWNLOAD_FASTA

if [[ "$DOWNLOAD_FASTA" =~ ^[YySs]$ ]]; then
    FASTA_FINAL="sequences_PROT_OASIS_${ID}.fasta"
    echo "🚀 Extracting proteins from the local database..."
    "$BLAST_DIR/blastdbcmd" -db "temp_db" -entry_batch "$FINAL_LIST" -out "$FASTA_FINAL" 2>/dev/null
    
    if [ -s "$FASTA_FINAL" ]; then
        echo "✅ Protein FASTA successfully generated! ($FASTA_FINAL)"
    else
        echo "❌ Error extracting proteins."
    fi
else
    echo "🛑 Protein extraction skipped."
fi

echo "----------------------------------------------------"
read -p "🧬 Do you want to download the nucleotide sequences (CDS) for these orthologs? (y/n): " DOWNLOAD_CDS

if [[ "$DOWNLOAD_CDS" =~ ^[YySs]$ ]]; then
    CDS_FINAL="sequences_CDS_OASIS_${ID}.fasta"
    echo "🚀 Downloading gene packages via NCBI Datasets to extract CDS..."
    
    "$DATASETS_PATH" download gene accession --inputfile "$FINAL_LIST" --include cds --filename "cds_filtered.zip" > /dev/null 2>&1
    
    if [ -f "cds_filtered.zip" ]; then
        unzip -q -o "cds_filtered.zip" -d "cds_temp"
        
        # Merges all downloaded CDS files
        cat $(find cds_temp -name "cds.fna" -o -name "*.fna") > "$CDS_FINAL" 2>/dev/null
        
        rm -rf "cds_filtered.zip" "cds_temp"
        echo "✅ CDS FASTA (Nucleotides) successfully generated! ($CDS_FINAL)"
    else
        echo "❌ Error: Could not download the CDS package from NCBI."
    fi
else
    echo "🛑 CDS download skipped."
fi

rm -rf ortho_temp ortho.zip temp_db.* "$FASTA_QUERY"
rm -f sequences_OASIS_${ID}.fasta 2>/dev/null

echo "===================================================="
echo "🏁 OASIS Pipeline finished successfully."
echo "📋 Your ID list is safely stored at: $FINAL_LIST"
echo "===================================================="