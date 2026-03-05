#!/bin/bash

# --- 1. Instalação Automática das Ferramentas ---
if ! command -v datasets &> /dev/null; then
    echo "🚀 Instalando utilitário 'datasets' oficial do NCBI..."
    # Link direto para o binário estável (Linux x64)
    curl -o datasets 'https://ftp.ncbi.nlm.nih.gov/pub/datasets/command-line/LATEST/linux-amd64/datasets'
    chmod +x datasets
    export PATH=$PATH:$(pwd)
    echo "✅ 'datasets' instalado com sucesso."
fi

if ! command -v efetch &> /dev/null; then
    echo "❌ Erro: EDirect (efetch) não encontrado. Ele é necessário para obter sua sequência."
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
LISTA_OUT="lista_ortologos_version.txt"

echo "🔍 Analisando ID: $QUERY_ID..."

# --- 2. Obter Sequência e Definir Programa ---
if [[ "$QUERY_ID" == NM_* ]]; then
    PROGRAM="blastx"
    efetch -db nuccore -id "$QUERY_ID" -format fasta > "$FASTA_QUERY"
    echo "🧬 Tipo: Nucleotídeo. Preparado para $PROGRAM."
else
    PROGRAM="blastp"
    efetch -db protein -id "$QUERY_ID" -format fasta > "$FASTA_QUERY"
    echo "🧪 Tipo: Proteína. Preparado para $PROGRAM."
fi

# --- 3. Baixar Ortólogos ---
echo "🚀 Baixando ortólogos do NCBI Datasets..."
# O comando datasets agora baixará o grupo correto
./datasets download gene accession "$QUERY_ID" --ortholog all --include protein --filename "$OUTPUT_ZIP"

if [ $? -eq 0 ]; then
    echo "✅ Download concluído. Extraindo..."
    unzip -q -o "$OUTPUT_ZIP" -d "$EXTRACT_DIR"
    
    PROTEIN_FAA="${EXTRACT_DIR}/ncbi_dataset/data/protein.faa"
    REPORT_FILE="${EXTRACT_DIR}/ncbi_dataset/data/data_report.jsonl"

    # --- 4. Gerar Lista de VERSIONs ---
    if [ -f "$REPORT_FILE" ]; then
        echo "📄 Extraindo VERSIONs (Accession.Version)..."
        grep -oP '"accession":"\K[^"]+' "$REPORT_FILE" | sort -u > "$LISTA_OUT"
        echo "🎯 Lista salva em: $LISTA_OUT"
    fi

    # --- 5. BLAST Local ---
    if [ -f "$PROTEIN_FAA" ]; then
        echo "⚙️ Criando banco local e rodando BLAST..."
        makeblastdb -in "$PROTEIN_FAA" -dbtype prot -out "db_temp" -logfile /dev/null
        
        $PROGRAM -query "$FASTA_QUERY" \
                 -db "db_temp" \
                 -out "${QUERY_ID}_vs_orthologs.tsv" \
                 -outfmt "6 qseqid sseqid pident length mismatch gapopen qstart qend sstart send evalue bitscore stitle" \
                 -num_threads $(nproc)
        
        echo "🔥 BLAST concluído! Tabela gerada: ${QUERY_ID}_vs_orthologs.tsv"
        rm db_temp.*
    fi
    
    rm "$FASTA_QUERY"
else
    echo "❌ Erro ao baixar ortólogos. Verifique sua conexão ou o ID."
fi