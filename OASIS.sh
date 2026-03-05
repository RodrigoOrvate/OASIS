#!/bin/bash

# --- 1. Configuração de Caminhos ---
BLAST_DIR="$(pwd)/ncbi-blast-2.13.0+/bin"
export PATH="$BLAST_DIR:$(pwd):$PATH"

install_tools() {
    if [ ! -f "./datasets" ]; then
        curl -s -L -o datasets 'https://ftp.ncbi.nlm.nih.gov/pub/datasets/command-line/LATEST/linux-amd64/datasets'
        chmod +x datasets
    fi

    if [ ! -d "$BLAST_DIR" ]; then
        curl -s -L -o blast.tar.gz 'https://ftp.ncbi.nlm.nih.gov/blast/executables/blast+/2.13.0/ncbi-blast-2.13.0+-x64-linux.tar.gz'
        tar -xzf blast.tar.gz
        rm blast.tar.gz
    fi
}

# --- 2. Execução ---
# Agora aceitamos um terceiro argumento opcional para similaridade (ex: 95)
if [ "$#" -lt 2 ]; then
    echo "Uso: ./run.sh <ID> <IDENTIDADE_MIN> <SIMILARIDADE_MIN (opcional)>"
    exit 1
fi

install_tools

ID=$1
MIN_ID=$2
MIN_SIM=${3:-0} # Se não for passado, o padrão é 0
LISTA_FINAL="acessos_filtrados_ID${MIN_ID}_SIM${MIN_SIM}_${ID}.txt"

echo "🔍 Buscando dados para $ID (ID >= $MIN_ID% | SIM >= $MIN_SIM%)..."

./datasets download gene accession "$ID" --include protein --filename "query.zip"
unzip -q -o "query.zip" -d "query_temp"
QUERY_FAA=$(find query_temp -name "protein.faa" | head -n 1)

./datasets download gene accession "$ID" --ortholog all --include protein --filename "ortho.zip"
unzip -q -o "ortho.zip" -d "ortho_temp"
ORTHO_FAA=$(find ortho_temp -name "protein.faa" | head -n 1)

if [ -f "$ORTHO_FAA" ] && [ -f "$QUERY_FAA" ]; then
    echo "⚙️ Rodando BLAST local com extração de Similaridade..."
    
    "$BLAST_DIR/makeblastdb" -in "$ORTHO_FAA" -dbtype prot -out "temp_db" -logfile /dev/null
    
    # EXPLICAÇÃO DO FORMATO 6:
    # saccver = Accession.Version
    # pident  = Porcentagem de Identidade
    # ppos    = Porcentagem de Positivos (Similaridade)
    "$BLAST_DIR/blastp" -query "$QUERY_FAA" -db "temp_db" \
                        -outfmt "6 saccver pident ppos" | \
                        awk -v id_min="$MIN_ID" -v sim_min="$MIN_SIM" \
                        '$2 >= id_min && $3 >= sim_min {print $1}' | \
                        grep -v "$ID" | sort -u > "$LISTA_FINAL"
    
    COUNT=$(wc -l < "$LISTA_FINAL")
    echo "🎯 Sucesso! Encontrados $COUNT acessos que atendem aos critérios."
    echo "📂 Lista salva em: $LISTA_FINAL"
    
    rm -rf query_temp ortho_temp query.zip ortho.zip temp_db.*
else
    echo "❌ Erro: Arquivos FASTA não localizados."
fi