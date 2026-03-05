#!/bin/bash

if [ "$#" -lt 2 ]; then
    echo "=============================================================="
    echo "Uso: $0 <ACCESSION_ID> <BANCO_DE_DADOS>"
    echo "Exemplo: $0 NP_001416352.1 uniref90"
    echo "Databases suportados para auto-download: uniref100, uniref90, uniref50"
    echo "=============================================================="
    exit 1
fi

QUERY_ID=$1
DB_NAME=$2
THREADS=$(nproc 2>/dev/null || echo 4) # Usa todos os núcleos disponíveis automaticamente
FASTA_OUT="${QUERY_ID}.fasta"
BLAST_OUT="${QUERY_ID}_vs_${DB_NAME}_results.tsv"

# ==============================================================================
# FUNÇÃO: PREPARAR BANCO DE DADOS
# ==============================================================================
preparar_banco() {
    local db=$1
    echo "⚠️ Banco de dados '$db' não encontrado localmente."
    echo "⬇️ Iniciando o download automático do servidor oficial do UniProt..."
    
    local url=""
    case $db in
        uniref100) url="https://ftp.uniprot.org/pub/databases/uniprot/uniref/uniref100/uniref100.fasta.gz" ;;
        uniref90) url="https://ftp.uniprot.org/pub/databases/uniprot/uniref/uniref90/uniref90.fasta.gz" ;;
        uniref50) url="https://ftp.uniprot.org/pub/databases/uniprot/uniref/uniref50/uniref50.fasta.gz" ;;
        *) echo "❌ Erro: Auto-download não configurado para o banco '$db'. Use uniref100, uniref90 ou uniref50."; exit 1 ;;
    esac

    # Baixa o arquivo
    wget --continue "$url" -O "${db}.fasta.gz" || curl -C - -O "$url" > "${db}.fasta.gz"
    
    echo "📦 Descompactando ${db}.fasta.gz (isso pode demorar bastante)..."
    gzip -d -f "${db}.fasta.gz"

    echo "⚙️ Formatando o banco para o BLAST (makeblastdb)..."
    makeblastdb -in "${db}.fasta" -dbtype prot -out "$db" -title "$db" -parse_seqids
    
    echo "✅ Banco de dados '$db' preparado com sucesso!"
}

# Verifica se o banco já está formatado (procura pelo arquivo .phr gerado pelo makeblastdb)
if [ ! -f "${DB_NAME}.phr" ]; then
    preparar_banco "$DB_NAME"
else
    echo "✅ Banco de dados '$DB_NAME' já existe localmente. Pulando etapa de download."
fi

# ==============================================================================
# FUNÇÃO: OBTER SEQUÊNCIA DO USUÁRIO E IDENTIFICAR PROGRAMA
# ==============================================================================
echo "🔍 Analisando o ID de entrada: $QUERY_ID..."

if [[ "$QUERY_ID" == NM_* ]]; then
    PROGRAMA="blastx"
    echo "▶ Tipo: Nucleotídeo RefSeq (NM_). Ferramenta selecionada: BLASTX."
    curl -s "https://eutils.ncbi.nlm.nih.gov/entrez/eutils/efetch.fcgi?db=nuccore&id=${QUERY_ID}&rettype=fasta&retmode=text" > "$FASTA_OUT"
elif [[ "$QUERY_ID" == NP_* ]]; then
    PROGRAMA="blastp"
    echo "▶ Tipo: Proteína RefSeq (NP_). Ferramenta selecionada: BLASTP."
    curl -s "https://eutils.ncbi.nlm.nih.gov/entrez/eutils/efetch.fcgi?db=protein&id=${QUERY_ID}&rettype=fasta&retmode=text" > "$FASTA_OUT"
else
    PROGRAMA="blastp"
    echo "▶ Tipo: ID genérico/UniProt. Ferramenta selecionada: BLASTP."
    curl -s "https://rest.uniprot.org/uniprotkb/${QUERY_ID}.fasta" > "$FASTA_OUT"
fi

if [ ! -s "$FASTA_OUT" ] || grep -q "Error" "$FASTA_OUT"; then
    echo "❌ Erro ao obter a sequência. Verifique se o ID está correto."
    rm -f "$FASTA_OUT"
    exit 1
fi

# ==============================================================================
# EXECUÇÃO DO ALINHAMENTO LOCAL
# ==============================================================================
echo "🚀 Iniciando o alinhamento ($PROGRAMA) usando $THREADS threads..."

$PROGRAMA -query "$FASTA_OUT" \
          -db "$DB_NAME" \
          -out "$BLAST_OUT" \
          -evalue 1e-5 \
          -outfmt "6 qseqid sseqid pident length mismatch gapopen qstart qend sstart send evalue bitscore stitle" \
          -num_threads $THREADS

if [ $? -eq 0 ]; then
    echo "🎯 Concluído! Resultados salvos em: $BLAST_OUT"
else
    echo "❌ Erro durante a execução do $PROGRAMA."
fi

# Limpeza
rm -f "$FASTA_OUT"