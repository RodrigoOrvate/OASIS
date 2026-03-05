#!/bin/bash

if [ "$#" -lt 2 ]; then
    echo "=============================================================="
    echo "Uso: $0 <ACCESSION_ID> <IDENTIDADE_MINIMA>"
    echo "Exemplo: $0 NP_001416352.1 90"
    echo "Identidade Mínima: Digite 100, 90, 50 (ou qualquer outro valor)"
    echo "=============================================================="
    exit 1
fi

QUERY_ID=$1
MIN_IDENT=$2
FASTA_OUT="${QUERY_ID}.fasta"
BLAST_OUT="${QUERY_ID}_vs_RefSeq_raw.tsv"
FILTERED_OUT="${QUERY_ID}_vs_RefSeq_${MIN_IDENT}ident.tsv"

echo "🔍 Analisando o ID de entrada: $QUERY_ID..."

# 1. Obter a sequência
if [[ "$QUERY_ID" == NM_* ]]; then
    PROGRAMA="blastx"
    echo "▶ Tipo: Nucleotídeo (NM_). Ferramenta: BLASTX."
    curl -s "https://eutils.ncbi.nlm.nih.gov/entrez/eutils/efetch.fcgi?db=nuccore&id=${QUERY_ID}&rettype=fasta&retmode=text" > "$FASTA_OUT"
elif [[ "$QUERY_ID" == NP_* ]]; then
    PROGRAMA="blastp"
    echo "▶ Tipo: Proteína (NP_). Ferramenta: BLASTP."
    curl -s "https://eutils.ncbi.nlm.nih.gov/entrez/eutils/efetch.fcgi?db=protein&id=${QUERY_ID}&rettype=fasta&retmode=text" > "$FASTA_OUT"
else
    PROGRAMA="blastp"
    echo "▶ Tipo: UniProt ID. Ferramenta: BLASTP."
    curl -s "https://rest.uniprot.org/uniprotkb/${QUERY_ID}.fasta" > "$FASTA_OUT"
fi

if [ ! -s "$FASTA_OUT" ] || grep -q "Error" "$FASTA_OUT"; then
    echo "❌ Erro ao obter a sequência. Verifique o ID."
    rm -f "$FASTA_OUT"
    exit 1
fi

# 2. Executar o BLAST nos servidores do NCBI
echo "🚀 Enviando para os supercomputadores do NCBI na nuvem (-remote)..."
echo "⚠️ Isso NÃO vai baixar nenhum banco de dados na sua máquina."
echo "⏳ Pode levar alguns minutos dependendo da fila do servidor..."

$PROGRAMA -query "$FASTA_OUT" \
          -db "refseq_protein" \
          -out "$BLAST_OUT" \
          -evalue 1e-5 \
          -outfmt "6 qseqid sseqid pident length mismatch gapopen qstart qend sstart send evalue bitscore stitle" \
          -remote

# 3. Filtrar os resultados
if [ $? -eq 0 ]; then
    echo "✅ Alinhamento concluído! Filtrando resultados com similaridade >= ${MIN_IDENT}%..."
    
    # O comando awk avalia a 3ª coluna (pident) e salva apenas as linhas correspondentes
    awk -v min="$MIN_IDENT" '$3 >= min' "$BLAST_OUT" > "$FILTERED_OUT"
    
    # Opcional: apagar o arquivo bruto para poupar espaço
    rm -f "$BLAST_OUT"
    
    echo "🎯 Pronto! O resultado filtrado está salvo em: $FILTERED_OUT"
else
    echo "❌ Erro na execução do BLAST remoto. O servidor pode estar indisponível."
fi

rm -f "$FASTA_OUT"