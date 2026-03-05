#!/bin/bash

# --- 1. Configuração de Caminhos (Centralizado no HOME) ---
BLAST_DIR="$HOME/ncbi-blast-2.13.0+/bin"
DATASETS_PATH="$HOME/datasets"
export PATH="$BLAST_DIR:$HOME:$PATH"

install_tools() {
    if [ ! -f "$DATASETS_PATH" ]; then
        echo "🚀 O utilitário 'datasets' não foi encontrado no seu diretório de usuário."
        echo "📦 Baixando e instalando datasets em $HOME..."
        curl -s -L -o "$DATASETS_PATH" 'https://ftp.ncbi.nlm.nih.gov/pub/datasets/command-line/LATEST/linux-amd64/datasets'
        chmod +x "$DATASETS_PATH"
        echo "✅ Datasets instalado com sucesso."
    else
        echo "✅ O utilitário 'datasets' já está presente no seu sistema."
    fi

    if [ ! -d "$BLAST_DIR" ]; then
        echo "🧬 O NCBI-BLAST+ não foi detectado em $HOME."
        echo "🛰️ Iniciando o download dos binários estáticos (Versão 2.13.0)..."
        curl -s -L -o "$HOME/blast.tar.gz" 'https://ftp.ncbi.nlm.nih.gov/blast/executables/blast+/2.13.0/ncbi-blast-2.13.0+-x64-linux.tar.gz'
        
        echo "📂 Extraindo binários para a pasta pessoal..."
        tar -xzf "$HOME/blast.tar.gz" -C "$HOME"
        rm "$HOME/blast.tar.gz"
        echo "✅ BLAST+ 2.13.0 instalado com sucesso em: $BLAST_DIR"
    else
        echo "✅ O NCBI-BLAST+ 2.13.0 já está configurado no seu diretório."
    fi
}

# --- 2. Menu Interativo (PIBIC UFRN) ---
echo "===================================================="
echo "      PIBIC UFRN - PROCESSAMENTO DE ORTÓLOGOS      "
echo "===================================================="

read -p "🧬 Digite o ID de Acesso (ex: NP_001416352.1): " ID
read -p "📊 Digite a Identidade e Similaridade mínima desejada (ex: 90 95): " MIN_ID MIN_SIM

install_tools

LISTA_FINAL="acessos_filtrados_ID${MIN_ID}_SIM${MIN_SIM}_${ID}.txt"

echo -e "\n🔍 Buscando sequências e ortólogos no NCBI para o ID: $ID..."

# Obtendo EXATAMENTE a sequência Query alvo
FASTA_QUERY="query_${ID}.fasta"
if [[ "$ID" == NM_* ]]; then
    curl -s "https://eutils.ncbi.nlm.nih.gov/entrez/eutils/efetch.fcgi?db=nuccore&id=${ID}&rettype=fasta&retmode=text" > "$FASTA_QUERY"
elif [[ "$ID" == NP_* ]]; then
    curl -s "https://eutils.ncbi.nlm.nih.gov/entrez/eutils/efetch.fcgi?db=protein&id=${ID}&rettype=fasta&retmode=text" > "$FASTA_QUERY"
else
    curl -s "https://rest.uniprot.org/uniprotkb/${ID}.fasta" > "$FASTA_QUERY"
fi

"$DATASETS_PATH" download gene accession "$ID" --ortholog all --include protein --filename "ortho.zip"
unzip -q -o "ortho.zip" -d "ortho_temp"
ORTHO_FAA=$(find ortho_temp -name "protein.faa" | head -n 1)

# --- 3. Processamento BLAST ---
# CORREÇÃO 1: Verificando a variável FASTA_QUERY correta
if [ -f "$ORTHO_FAA" ] && [ -f "$FASTA_QUERY" ]; then
    echo "⚙️ Configurando banco de dados local e executando alinhamentos..."
    
    "$BLAST_DIR/makeblastdb" -in "$ORTHO_FAA" -dbtype prot -out "temp_db" -logfile /dev/null
    
    # CORREÇÃO 2: Bloco completo do awk restaurado e evalue adicionado
    "$BLAST_DIR/blastp" -query "$FASTA_QUERY" -db "temp_db" \
                        -outfmt "6 saccver pident ppos" \
                        -evalue 1e-5 | \
                        awk -v id_min="$MIN_ID" -v sim_min="$MIN_SIM" \
                        '$2 >= id_min && $3 >= sim_min {print $1}' | \
                        grep -v "$ID" | sort -u > "$LISTA_FINAL"
    
    COUNT=$(wc -l < "$LISTA_FINAL")
    echo "🎯 Sucesso! Foram encontrados $COUNT acessos que atendem aos seus critérios."
    echo "📂 O resultado foi salvo em: $LISTA_FINAL"
    
    # CORREÇÃO 3: Limpando a query do curl também
    rm -rf ortho_temp ortho.zip temp_db.* "$FASTA_QUERY"
else
    echo "❌ Erro Crítico: Não foi possível localizar os arquivos FASTA necessários."
fi

echo -e "\n🏁 Workflow finalizado."