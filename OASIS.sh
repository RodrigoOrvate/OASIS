#!/bin/bash

# --- 1. Instalação Automática das Ferramentas ---
if ! command -v datasets &> /dev/null; then
    echo "🚀 Instalando utilitário 'datasets' oficial do NCBI..."
    curl -o datasets 'https://ftp.ncbi.nlm.nih.gov/pub/datasets/command-line/LATEST/linux-amd64/datasets'
    chmod +x datasets
    export PATH=$PATH:$(pwd)
fi

if ! command -v efetch &> /dev/null; then
    echo "❌ Erro: EDirect (efetch) não encontrado."
    exit 1
fi

if [ "$#" -lt 1 ]; then
    echo "Uso: ./run_orthologs.sh <ID_DE_ACESSO>"
    exit 1
fi

QUERY_ID=$1
OUTPUT_ZIP="ortholog_data_${QUERY_ID}.zip"
EXTRACT_DIR="ortholog_data_${QUERY_ID}"
FASTA_QUERY="${QUERY_ID}.query.fasta"
LISTA_FINAL="acesso_versoes_homologos.txt"

echo "🔍 Analisando ID: $QUERY_ID..."

# --- 2. Obter Sequência e Definir Programa ---
if [[ "$QUERY_ID" == NM_* ]]; then
    PROGRAM="blastx"
    efetch -db nuccore -id "$QUERY_ID" -format fasta > "$FASTA_QUERY"
else
    PROGRAM="blastp"
    efetch -db protein -id "$QUERY_ID" -format fasta > "$FASTA_QUERY"
fi

# --- 3. Baixar Ortólogos ---
echo "🚀 Baixando pacote de ortólogos..."
./datasets download gene accession "$QUERY_ID" --ortholog all --include protein --filename "$OUTPUT_ZIP"

if [ $? -eq 0 ]; then
    unzip -q -o "$OUTPUT_ZIP" -d "$EXTRACT_DIR"
    PROTEIN_FAA="${EXTRACT_DIR}/ncbi_dataset/data/protein.faa"

    # --- 4. BLAST Local com Saída de Apenas Accession ---
    if [ -f "$PROTEIN_FAA" ]; then
        echo "⚙️ Criando banco local e gerando lista de códigos..."
        makeblastdb -in "$PROTEIN_FAA" -dbtype prot -out "db_temp" -logfile /dev/null
        
        # Ajustamos o outfmt para '6 saccver' que traz apenas o Accession.Version
        $PROGRAM -query "$FASTA_QUERY" \
                 -db "db_temp" \
                 -outfmt "6 saccver" \
                 -num_threads $(nproc) | grep -v "$QUERY_ID" | sort -u > "$LISTA_FINAL"
        
        echo "🔥 Lista gerada com sucesso!"
        echo "📂 Arquivo: $LISTA_FINAL"
        echo "--------------------------------------------------------------"
        head -n 10 "$LISTA_FINAL"
        echo "..."
        
        rm db_temp.*
    fi
    rm "$FASTA_QUERY"
else
    echo "❌ Erro ao baixar ortólogos."
fi