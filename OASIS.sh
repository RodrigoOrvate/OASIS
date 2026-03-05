#!/bin/bash

# --- Configuração de Ferramentas ---
# Instala o 'datasets' localmente se não existir no PATH
if ! command -v datasets &> /dev/null; then
    echo "🚀 Utilitário 'datasets' não encontrado. Instalando localmente..."
    curl -o datasets 'https://ftp.ncbi.nlm.nih.gov/pub/databases/datasets/command-line/LATEST/linux-amd64/datasets'
    chmod +x datasets
    export PATH=$PATH:$(pwd)
    echo "✅ 'datasets' instalado com sucesso."
fi

if [ "$#" -lt 1 ]; then
    echo "=============================================================="
    echo "Uso: ./run_orthologs.sh <ID_DE_ACESSO>"
    echo "Exemplo: ./run_orthologs.sh NP_001416352.1"
    echo "=============================================================="
    exit 1
fi

QUERY_ID=$1
OUTPUT_ZIP="ortholog_data_${QUERY_ID}.zip"
EXTRACT_DIR="ortholog_data_${QUERY_ID}"
LISTA_OUT="lista_ortologos_version.txt"

echo "🔍 Analisando ID: $QUERY_ID..."

# 1. Identificação do tipo para o BLAST local posterior
if [[ "$QUERY_ID" == NM_* ]]; then
    PROGRAM="blastx"
    echo "🧬 Tipo detectado: Nucleotídeo (NM). Preparado para $PROGRAM."
else
    PROGRAM="blastp"
    echo "🧪 Tipo detectado: Proteína (NP/UniProt). Preparado para $PROGRAM."
fi

# 2. Download do Data Package de Ortólogos
echo "🚀 Baixando pacote de ortólogos do NCBI Datasets..."
datasets download gene accession "$QUERY_ID" --ortholog all --include protein --filename "$OUTPUT_ZIP"

if [ $? -eq 0 ]; then
    echo "✅ Download concluído."
    
    # 3. Extração e Captura do VERSION
    unzip -q -o "$OUTPUT_ZIP" -d "$EXTRACT_DIR"
    REPORT_FILE="${EXTRACT_DIR}/ncbi_dataset/data/data_report.jsonl"
    
    if [ -f "$REPORT_FILE" ]; then
        echo "📄 Extraindo Accession.Version para a lista..."
        # Extrai o campo 'accession' que contém o código.versão (ex: NP_001034168.1)
        grep -oP '"accession":"\K[^"]+' "$REPORT_FILE" | sort -u > "$LISTA_OUT"
        
        COUNT=$(wc -l < "$LISTA_OUT")
        echo "🎯 Sucesso! $COUNT VERSIONs salvos em: $LISTA_OUT"
        echo "--------------------------------------------------------------"
        head -n 5 "$LISTA_OUT"
        echo "..."
    fi
else
    echo "❌ Erro ao baixar ortólogos. Verifique se o ID possui grupo de ortólogos no NCBI."
fi

# Limpeza opcional
# rm "$OUTPUT_ZIP"