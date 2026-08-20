#!/bin/bash

# =============================================================================
#  OASIS — Ortholog Alignment & Similarity Screener
#  Supports: single or multiple accessions, auto-detected molecule type,
#            protein (NP_/XP_/WP_), nucleotide (NM_/XM_/NG_), and numeric
#            NCBI Gene IDs as input.
# Usage:
#   ./OASIS.sh                              (fully interactive)
#   ./OASIS.sh NP_001416352.1 90 95        (single accession, CLI args)
#   ./OASIS.sh accessions.txt  90 95       (batch file, one accession per line)
#   ./OASIS.sh NP_123.1 NM_456.1 90 95    (multiple accessions inline)
# =============================================================================

# --- 0. Helper utilities (rootless / sudo-free) ---

download_file() {
    local url="$1" output="$2"
    if command -v curl &>/dev/null; then
        curl -s -L -o "$output" "$url"
    elif command -v wget &>/dev/null; then
        wget -q -O "$output" "$url"
    else
        echo "❌ Critical Error: Neither 'curl' nor 'wget' found." >&2
        exit 1
    fi
}

download_text() {
    local url="$1"
    local result

    for attempt in 1 2 3 4 5; do

        if command -v curl &>/dev/null; then
            result=$(curl \
                --silent \
                --globoff \
                --location \
                --fail \
                --retry 3 \
                --retry-delay 2 \
                "$url" 2>/dev/null)

        elif command -v wget &>/dev/null; then
            result=$(wget -q -O - "$url" 2>/dev/null)
        fi

        if [ -n "$result" ]; then
            printf '%s' "$result"
            return 0
        fi

        echo "  ⚠️ Retry $attempt/5..." >&2
        sleep 2
    done

    return 1
}

extract_zip() {
    local zip_file="$1" dest_dir="$2"
    if command -v unzip &>/dev/null; then
        unzip -q -o "$zip_file" -d "$dest_dir"
    elif command -v python3 &>/dev/null; then
        python3 -c "import zipfile; zipfile.ZipFile('$zip_file','r').extractall('$dest_dir')"
    else
        echo "❌ Critical Error: Neither 'unzip' nor 'python3' found." >&2
        exit 1
    fi
}

# --- 0b. Dependency pre-flight check ---
#
# OASIS relies on python3 for JSON/XML parsing throughout resolve_gene_id(),
# flag_isoforms(), and as a zip-extraction fallback — but until now this was
# never verified up front. On a "clean" system without python3, the script
# used to fail deep inside resolve_gene_id() with a cryptic shell error
# ("python3: command not found") followed by a misleading "Failed to
# resolve protein UID" message, making the root cause hard to diagnose.
#
# This check runs once, at the very start of execution, and fails fast with
# a clear, actionable message — mirroring the pattern already used for
# curl/wget in download_file() above, for consistency across the script.

check_dependencies() {
    local missing=()

    # Hard requirement: python3 is used for JSON/XML parsing in
    # resolve_gene_id(), flag_isoforms(), and as an unzip fallback.
    if ! command -v python3 &>/dev/null; then
        missing+=("python3")
    fi

    # Hard requirement: at least one HTTP client (curl preferred, wget fallback).
    if ! command -v curl &>/dev/null && ! command -v wget &>/dev/null; then
        missing+=("curl (or wget)")
    fi

    # Hard requirement: tar is used to unpack the BLAST+ archive on first run.
    if ! command -v tar &>/dev/null; then
        missing+=("tar")
    fi

    # Soft requirement: unzip is preferred for ortholog archives; python3's
    # zipfile module is an accepted fallback (see extract_zip above), so we
    # only warn here instead of failing, and only if python3 is ALSO missing.
    if ! command -v unzip &>/dev/null && ! command -v python3 &>/dev/null; then
        missing+=("unzip (or python3)")
    fi

    if [ "${#missing[@]}" -gt 0 ]; then
        echo "❌ Critical Error: missing required dependencies:" >&2
        for dep in "${missing[@]}"; do
            echo "     • $dep" >&2
        done
        echo "" >&2
        echo "   OASIS needs these tools available on PATH before it can run." >&2
        echo "   On Debian/Ubuntu:  sudo apt-get install -y python3 curl tar unzip" >&2
        echo "   On Fedora/RHEL:    sudo dnf install -y python3 curl tar unzip" >&2
        echo "   On macOS (brew):   brew install python3 curl unzip   (tar is preinstalled)" >&2
        echo "" >&2
        echo "   If you cannot install system packages (e.g. shared HPC login node)," >&2
        echo "   ask your administrator to load a python3 module, or run OASIS inside" >&2
        echo "   the provided Docker/Apptainer container instead (see README)." >&2
        exit 1
    fi
}

# --- 1. Tool installation ---

BLAST_DIR="$HOME/ncbi-blast-2.13.0+/bin"
DATASETS_PATH="$HOME/datasets"
export PATH="$BLAST_DIR:$HOME:$PATH"

# --- 1a. CPU architecture detection ---
#
# NCBI publishes native Linux binaries for both x86_64 (amd64) and ARM64
# (aarch64) for the Datasets CLI, and for BLAST+ since v2.13.0 — but the
# script used to hardcode the amd64 URLs unconditionally. On an ARM64 host
# (e.g. a phone terminal app, Raspberry Pi, or Apple Silicon VM), the amd64
# binaries would download "successfully" but fail to execute (wrong ELF
# machine type), and every command downstream that used $DATASETS_PATH or
# the BLAST_DIR binaries would fail SILENTLY (their output is redirected to
# /dev/null), surfacing only as confusing, unrelated-looking errors several
# steps later — e.g. "No ortholog data returned" instead of the real cause.
#
# detect_arch() maps `uname -m` to the NCBI download naming convention.
# Unsupported architectures (32-bit ARM, x86, etc.) fail fast here instead
# of silently downloading a binary that will never run.

detect_arch() {
    local machine
    machine=$(uname -m)
    case "$machine" in
    x86_64 | amd64)
        echo "amd64"
        ;;
    aarch64 | arm64)
        echo "arm64"
        ;;
    *)
        echo "❌ Critical Error: unsupported CPU architecture '$machine'." >&2
        echo "   NCBI only publishes Linux binaries for x86_64 (amd64) and" >&2
        echo "   aarch64 (arm64). OASIS cannot auto-install its dependencies" >&2
        echo "   on this machine." >&2
        echo "   Consider installing the Datasets CLI and BLAST+ via conda" >&2
        echo "   instead (both provide broader platform support):" >&2
        echo "     conda install -c conda-forge ncbi-datasets-cli" >&2
        echo "     conda install -c bioconda blast" >&2
        echo "unknown"
        ;;
    esac
}

# --- 1b. Binary verification ---
#
# A download that "succeeds" (non-empty file, correct HTTP status) can
# still be unusable — wrong architecture, a Bionic-libc host that can't run
# glibc-linked binaries (e.g. Termux on Android), or a truncated/corrupted
# transfer. Rather than trusting install_tools() blindly, we execute each
# tool with a trivial, side-effect-free command right after installing it
# and fail fast with a clear, cause-specific message if it doesn't run.
# This turns a silent, deferred failure (as happened when the amd64
# datasets binary was run on an ARM64 phone terminal, and again when the
# correct arm64 binary still couldn't run under Termux's Bionic libc) into
# an immediate, readable one at the point of installation.

is_termux() {
    [ -n "${TERMUX_VERSION:-}" ] || [[ "${PREFIX:-}" == *com.termux* ]]
}

verify_binary() {
    local bin_path="$1" label="$2"
    shift 2
    if ! "$bin_path" "$@" &>/dev/null; then
        echo "❌ Critical Error: '$label' was downloaded but failed to run." >&2
        if is_termux; then
            echo "   You're running inside Termux. Termux uses Android's" >&2
            echo "   Bionic libc, not the glibc that NCBI's precompiled" >&2
            echo "   Linux binaries are linked against — so even a binary" >&2
            echo "   matching your CPU architecture (aarch64) cannot run" >&2
            echo "   directly in a plain Termux shell. This is a libc" >&2
            echo "   mismatch, not a download problem." >&2
            echo "" >&2
            echo "   Fix: run OASIS inside a proot-distro Linux environment," >&2
            echo "   which provides a real glibc userland on top of Termux:" >&2
            echo "     pkg install proot-distro -y" >&2
            echo "     proot-distro install ubuntu" >&2
            echo "     proot-distro login ubuntu" >&2
            echo "     # then, inside that Ubuntu shell:" >&2
            echo "     apt update && apt install -y python3 curl tar unzip" >&2
            echo "     # re-run OASIS.sh from there" >&2
        else
            echo "   This usually means the binary is incompatible with this" >&2
            echo "   machine's CPU architecture ($(uname -m)), or the download" >&2
            echo "   was corrupted/incomplete." >&2
            echo "   Try removing '$bin_path' (or its containing folder) and" >&2
            echo "   re-running OASIS so it can attempt a fresh download, or" >&2
            echo "   install '$label' manually for your platform." >&2
        fi
        exit 1
    fi
}

install_tools() {
    local arch
    arch=$(detect_arch)
    [ "$arch" = "unknown" ] && exit 1

    if [ ! -f "$DATASETS_PATH" ]; then
        echo "📦 Installing NCBI Datasets CLI (linux-${arch})..."
        download_file \
            "https://ftp.ncbi.nlm.nih.gov/pub/datasets/command-line/LATEST/linux-${arch}/datasets" \
            "$DATASETS_PATH"
        chmod +x "$DATASETS_PATH"
        verify_binary "$DATASETS_PATH" "NCBI Datasets CLI" --version
    fi

    if [ ! -d "$BLAST_DIR" ]; then
        local blast_tarball
        if [ "$arch" = "arm64" ]; then
            # Naming convention for the pinned 2.13.0 release specifically;
            # NCBI switched to "-aarch64-linux" only in later BLAST+ releases.
            blast_tarball="ncbi-blast-2.13.0+-x64-arm-linux.tar.gz"
        else
            blast_tarball="ncbi-blast-2.13.0+-x64-linux.tar.gz"
        fi

        echo "🛰️  Installing BLAST+ 2.13.0 (static binaries, ${arch})..."
        download_file \
            "https://ftp.ncbi.nlm.nih.gov/blast/executables/blast+/2.13.0/${blast_tarball}" \
            "$HOME/blast.tar.gz"
        tar -xzf "$HOME/blast.tar.gz" -C "$HOME"
        rm "$HOME/blast.tar.gz"
        verify_binary "$BLAST_DIR/blastn" "BLAST+ (blastn)" -version
    fi
}

# --- 2. Accession-type auto-detection ---
#
# Returns one of: protein | nucleotide | gene_id
# protein    → NP_ XP_ WP_  (query with blastp, fetch from protein db)
# nucleotide → NM_ XM_ NG_  (query with blastx, fetch from nuccore db)
# gene_id    → purely numeric strings (treated as NCBI Gene IDs directly)

detect_type() {
    local acc="$1"
    case "$acc" in
    NP_* | XP_* | WP_*) echo "protein" ;;
    NM_* | XM_* | NG_*) echo "nucleotide" ;;
    [A-Z][0-9][A-Z0-9][A-Z0-9][A-Z0-9][0-9]*) echo "uniprot" ;; # Adicione esta linha
    [0-9]*) echo "gene_id" ;;
    *)
        echo "❌ Unrecognised accession format: '$acc'" >&2
        echo "   Supported: NP_ XP_ WP_ NM_ XM_ NG_, UniProt, or numeric Gene ID" >&2
        echo "unknown"
        ;;
    esac
}

# --- 3. Gene ID resolver ---
#
# All accession types are normalised to a numeric NCBI Gene ID here.
# protein    → esearch(protein)  → elink(protein→gene)
# nucleotide → esearch(nuccore) → elink(nuccore→gene)
# gene_id    → passed through unchanged

resolve_gene_id() {
    local accession="$1"
    local acc_type
    acc_type=$(detect_type "$accession")

    case "$acc_type" in

    protein)
        echo "  🔎 Resolving protein accession → Gene ID..." >&2

        local puid
        puid=$(download_text "https://eutils.ncbi.nlm.nih.gov/entrez/eutils/esearch.fcgi?db=protein&term=${accession}%5Baccn%5D&retmode=json" | python3 -c '
import sys, json
try:
    data = json.load(sys.stdin)
    ids = data.get("esearchresult", {}).get("idlist", [])
    if ids:
        print(ids[0])
except Exception:
    pass
')
        
        if [ -z "$puid" ]; then
            puid=$(download_text "https://eutils.ncbi.nlm.nih.gov/entrez/eutils/esearch.fcgi?db=protein&term=${accession}&retmode=json" | python3 -c '
import sys, json
try:
    data = json.load(sys.stdin)
    ids = data.get("esearchresult", {}).get("idlist", [])
    if ids:
        print(ids[0])
except Exception:
    pass
')
        fi

        if [ -z "$puid" ]; then
            echo "  ❌ Failed to resolve protein UID." >&2
            return 1
        fi

        local gene_id
        
        # Strategy 1: elink
        gene_id=$(download_text "https://eutils.ncbi.nlm.nih.gov/entrez/eutils/elink.fcgi?dbfrom=protein&db=gene&id=${puid}" | python3 -c '
import sys
import xml.etree.ElementTree as ET
try:
    root = ET.fromstring(sys.stdin.read())
    accepted = {"protein_gene", "protein_gene_refseq"}
    for db in root.iter("LinkSetDb"):
        if db.findtext("LinkName") in accepted:
            for link in db.findall("Link"):
                gid = link.findtext("Id")
                if gid:
                    print(gid)
                    raise SystemExit
except Exception:
    pass
')

        # Strategy 2: efetch GenPept
        if [ -z "$gene_id" ]; then
            echo "  ↩️  elink gave no result — trying efetch GenPept record..." >&2
            gene_id=$(download_text "https://eutils.ncbi.nlm.nih.gov/entrez/eutils/efetch.fcgi?db=protein&id=${puid}&rettype=gp&retmode=text" | python3 -c '
import sys, re
for line in sys.stdin:
    m = re.search(r"/db_xref=\"GeneID:(\d+)\"", line)
    if m:
        print(m.group(1))
        raise SystemExit
')
        fi

        # Strategy 3: esummary
        if [ -z "$gene_id" ]; then
            echo "  ↩️  Trying esummary for protein UID $puid..." >&2
            gene_id=$(download_text "https://eutils.ncbi.nlm.nih.gov/entrez/eutils/esummary.fcgi?db=protein&id=${puid}&retmode=json" | python3 -c '
import sys, json, re
try:
    uid = sys.argv[1]
    data = json.load(sys.stdin)
    rec = data.get("result", {}).get(uid, {})
    for st, sn in zip(rec.get("subtype", "").split("|"), rec.get("subname", "").split("|")):
        if st.strip().lower() == "gene_id":
            print(sn.strip())
            raise SystemExit
    extra = rec.get("extra", "")
    m = re.search(r"GeneID[=:](\d+)", extra, re.IGNORECASE)
    if m:
        print(m.group(1))
except Exception:
    pass
' "$puid")
        fi

        if [ -z "$gene_id" ]; then
            echo "  ❌ Failed to resolve Gene ID from protein accession." >&2
            return 1
        fi
        echo "$gene_id"
        ;;
        
    uniprot)
        echo "  🔎 Resolving UniProt ID → Gene ID..." >&2
        local gene_id
        # Acessa a API em modo texto e filtra a linha exata que contém o GeneID cruzado
        gene_id=$(download_text "https://rest.uniprot.org/uniprotkb/${accession}.txt" | awk '/^DR   GeneID;/ {print $3; exit}' | tr -d ';')
        
        if [ -z "$gene_id" ]; then
            echo "  ❌ Failed to resolve Gene ID from UniProt accession." >&2
            return 1
        fi
        echo "$gene_id"
        ;;

    nucleotide)
        echo "  🔎 Resolving nucleotide accession → Gene ID..." >&2

        local nuid
        nuid=$(download_text "https://eutils.ncbi.nlm.nih.gov/entrez/eutils/esearch.fcgi?db=nuccore&term=${accession}%5Baccn%5D&retmode=json" | python3 -c '
import sys, json
try:
    data = json.load(sys.stdin)
    ids = data.get("esearchresult", {}).get("idlist", [])
    if ids:
        print(ids[0])
except Exception:
    pass
')
        
        if [ -z "$nuid" ]; then
            nuid=$(download_text "https://eutils.ncbi.nlm.nih.gov/entrez/eutils/esearch.fcgi?db=nuccore&term=${accession}&retmode=json" | python3 -c '
import sys, json
try:
    data = json.load(sys.stdin)
    ids = data.get("esearchresult", {}).get("idlist", [])
    if ids:
        print(ids[0])
except Exception:
    pass
')
        fi

        if [ -z "$nuid" ]; then
            echo "  ❌ Failed to resolve nuccore UID." >&2
            return 1
        fi

        local gene_id
        
        # Strategy 1: elink
        gene_id=$(download_text "https://eutils.ncbi.nlm.nih.gov/entrez/eutils/elink.fcgi?dbfrom=nuccore&db=gene&id=${nuid}" | python3 -c '
import sys
import xml.etree.ElementTree as ET
try:
    root = ET.fromstring(sys.stdin.read())
    accepted = {"nuccore_gene", "nucleotide_gene", "nuccore_gene_refseq"}
    for db in root.iter("LinkSetDb"):
        if db.findtext("LinkName") in accepted:
            for link in db.findall("Link"):
                gid = link.findtext("Id")
                if gid:
                    print(gid)
                    raise SystemExit
except Exception:
    pass
')

        # Strategy 2: efetch GenBank
        if [ -z "$gene_id" ]; then
            echo "  ↩️  elink gave no result — trying efetch GenBank record..." >&2
            gene_id=$(download_text "https://eutils.ncbi.nlm.nih.gov/entrez/eutils/efetch.fcgi?db=nuccore&id=${nuid}&rettype=gb&retmode=text" | python3 -c '
import sys, re
for line in sys.stdin:
    m = re.search(r"/db_xref=\"GeneID:(\d+)\"", line)
    if m:
        print(m.group(1))
        raise SystemExit
')
        fi

        # Strategy 3: esummary
        if [ -z "$gene_id" ]; then
            echo "  ↩️  Trying esummary for nucleotide UID $nuid..." >&2
            gene_id=$(download_text "https://eutils.ncbi.nlm.nih.gov/entrez/eutils/esummary.fcgi?db=nuccore&id=${nuid}&retmode=json" | python3 -c '
import sys, json, re
try:
    uid = sys.argv[1]
    data = json.load(sys.stdin)
    rec = data.get("result", {}).get(uid, {})
    for st, sn in zip(rec.get("subtype", "").split("|"), rec.get("subname", "").split("|")):
        if st.strip().lower() == "gene_id":
            print(sn.strip())
            raise SystemExit
    extra = rec.get("extra", "")
    m = re.search(r"GeneID[=:](\d+)", extra, re.IGNORECASE)
    if m:
        print(m.group(1))
except Exception:
    pass
' "$nuid")
        fi

        if [ -z "$gene_id" ]; then
            echo "  ❌ Failed to resolve Gene ID from nucleotide accession." >&2
            return 1
        fi
        echo "$gene_id"
        ;;

    gene_id)
        echo "$accession"
        ;;

    *)
        return 1
        ;;
    esac
}

# --- 4. Ortholog fetcher ---
#
# Downloads ortholog proteins for a given NCBI Gene ID using the Datasets CLI.
# The orthologs are only available for vertebrates and insects.
#
# Taxonomic scope (TODO: "Taxonomic filter option"):
#   If TAXON_SCOPE is empty, a single request is made with --ortholog all.
#   If TAXON_SCOPE contains one or more comma-separated taxon names/IDs
#   (e.g. "Mammalia" or "Mammalia,Actinopterygii"), OASIS issues one
#   Datasets CLI request PER taxon and merges the results. Splitting a
#   broad request into several taxon-scoped requests is also the strategy
#   used to work around the historical 499-sequence cap (TODO: "Lift the
#   499-sequence cap") when a single "--ortholog all" call would otherwise
#   be truncated by the API.
#
# Deduplication of headers is done with awk after concatenation.

fetch_all_orthologs() {
    local gene_id="$1"
    local output_faa="$2"
    local taxon_scope="${3:-}"

    # Skip if already fetched in this session (shared across queries)
    if [ -s "$output_faa" ]; then
        local cached
        cached=$(grep -c '^>' "$output_faa" 2>/dev/null || echo 0)
        echo "  ♻️  Using cached ortholog FAA ($cached sequences)."
        return 0
    fi

    local -a taxa
    if [ -n "$taxon_scope" ]; then
        IFS=',' read -ra taxa <<<"$taxon_scope"
    else
        taxa=("all")
    fi

    : >"${output_faa}.raw"
    local any_ok=0

    for raw_t in "${taxa[@]}"; do
        local t
        t=$(echo "$raw_t" | xargs) # trim whitespace
        [ -z "$t" ] && continue

        echo "  🌍 Downloading ortholog protein sequences (gene ID: $gene_id, taxon scope: $t)..."

        local safe_t="${t// /_}"
        local ortho_zip="$GLOBAL_TMP/orthologs_${gene_id}_${safe_t}.zip"
        local ortho_dir="$GLOBAL_TMP/orthologs_${gene_id}_${safe_t}"

        "$DATASETS_PATH" download gene gene-id "$gene_id" \
            --ortholog "$t" \
            --include protein \
            --filename "$ortho_zip" >/dev/null 2>&1

        if [ ! -s "$ortho_zip" ]; then
            echo "  ⚠️  No ortholog data returned for taxon scope '$t'." >&2
            continue
        fi

        mkdir -p "$ortho_dir"
        extract_zip "$ortho_zip" "$ortho_dir"

        find "$ortho_dir" -type f \( -name "*.faa" -o -name "*.protein.faa" \) \
            -exec cat {} + >>"${output_faa}.raw"
        any_ok=1
    done

    if [ "$any_ok" -eq 0 ] || [ ! -s "${output_faa}.raw" ]; then
        echo "  ❌ Ortholog download failed for gene ID $gene_id." >&2
        rm -f "${output_faa}.raw"
        return 1
    fi

    mv "${output_faa}.raw" "$output_faa"

    # Deduplicate on header line (keeps first occurrence) — also removes
    # overlap between taxon-scoped requests when TAXON_SCOPE has >1 entry.
    awk '
/^>/ {
    header = $0
    split(header, a, " ")
    id = a[1]

    if (seen[id]++) {
        skip = 1
    } else {
        skip = 0
        print
    }

    next
}

!skip {
    print
}
' "$output_faa" >"${output_faa}.dedup"

    mv "${output_faa}.dedup" "$output_faa"

    local count
    count=$(grep -c '^>' "$output_faa" 2>/dev/null || echo 0)
    echo "  ✅ $count ortholog protein sequences ready."

    # Heuristic truncation notice: a single unscoped call landing suspiciously
    # close to a known API page size may indicate the response was cut off.
    if [ "${#taxa[@]}" -eq 1 ] && [ "${taxa[0]}" = "all" ] && [ "$count" -ge 495 ] && [ "$count" -le 500 ]; then
        echo "  ℹ️  $count sequences retrieved, close to a known API page size." >&2
        echo "      If you suspect truncation, rerun with a taxonomic scope" >&2
        echo "      (e.g. 'Mammalia,Aves,Actinopterygii') to fetch in batches and merge." >&2
    fi
}

# --- 4b. Isoform flagging/removal ---
#
# TODO: "Isoform filtering strategy" — heuristic, best-effort approach.
# NCBI ortholog packages are curated one-gene-model-per-organism in most
# cases, but alternatively spliced isoforms and redundant accessions for
# the same locus/organism can still appear. This is a genuinely hard
# problem given how splicing is annotated in RefSeq, so OASIS uses a
# practical heuristic rather than a definitive solution:
#   - Sequences are grouped by organism (text inside the trailing "[...]"
#     of the FASTA header).
#   - Within each organism group, the LONGEST sequence is kept as the
#     representative; shorter sequences are treated as likely isoforms/
#     redundant accessions of the same locus and are FLAGGED.
#   - A TSV report of flagged accessions is always written.
#   - Depending on ISOFORM_MODE, flagged sequences are either kept (flag
#     only) or physically removed from the ortholog pool before BLAST.
# This will not catch every real-world case (e.g. true paralogs sharing an
# organism, or isoforms from different organisms) — manual curation of the
# report is still recommended for rigorous phylogenetic work.

flag_isoforms() {
    local ortho_faa="$1"
    local report_tsv="$2"
    local mode="$3" # keep | flag | remove

    if [ ! -s "$ortho_faa" ]; then
        return 0
    fi

    echo "  🧬 Screening ortholog set for likely isoforms/redundant accessions ($mode mode)..."

    local flagged_count
    flagged_count=$(python3 - "$ortho_faa" "$mode" "$report_tsv" <<'PYEOF'
import re
import sys

faa_path, mode, report_path = sys.argv[1], sys.argv[2], sys.argv[3]

records = []
header = None
seq_lines = []


def flush():
    if header is not None:
        records.append((header, "".join(seq_lines)))


with open(faa_path) as fh:
    for line in fh:
        line = line.rstrip("\n")
        if line.startswith(">"):
            flush()
            header = line
            seq_lines = []
        else:
            seq_lines.append(line)
    flush()


def organism_of(h):
    m = re.search(r"\[([^\[\]]+)\]\s*$", h)
    return m.group(1) if m else "unknown"


groups = {}
for h, s in records:
    groups.setdefault(organism_of(h), []).append((h, s))

keep_headers = set()
flagged = []

for org, items in groups.items():
    if len(items) == 1:
        keep_headers.add(items[0][0])
        continue
    items.sort(key=lambda x: len(x[1]), reverse=True)
    keep_headers.add(items[0][0])
    rep_acc = items[0][0][1:].split()[0]
    for h, s in items[1:]:
        acc = h[1:].split()[0]
        flagged.append((acc, org, len(s), rep_acc))

with open(report_path, "w") as rf:
    rf.write("flagged_accession\torganism\tlength\tkept_representative\n")
    for acc, org, ln, rep in flagged:
        rf.write(f"{acc}\t{org}\t{ln}\t{rep}\n")

if mode == "remove":
    with open(faa_path, "w") as out:
        for h, s in records:
            if h in keep_headers:
                out.write(h + "\n")
                for i in range(0, len(s), 70):
                    out.write(s[i:i + 70] + "\n")

print(len(flagged))
PYEOF
)

    if [ "${flagged_count:-0}" -gt 0 ]; then
        case "$mode" in
        remove)
            echo "  ⚠️  $flagged_count likely isoform/redundant sequence(s) REMOVED from the ortholog pool."
            ;;
        *)
            echo "  ⚠️  $flagged_count likely isoform/redundant sequence(s) FLAGGED (kept in pool)."
            ;;
        esac
        echo "  📋 Isoform report → $report_tsv"
    else
        echo "  ✅ No obvious isoform/redundant duplicates detected (one sequence per organism)."
    fi
}

# --- 5. Per-query BLAST + filtering ---
#
# Builds a local protein BLAST DB from the ortholog FAA, runs blastp or
# blastx against the query, and filters hits by identity and similarity.

run_blast_filter() {
    local query_fasta="$1" # query sequence file
    local ortho_faa="$2"   # ortholog protein database source
    local blast_prog="$3"  # blastp or blastx
    local min_id="$4"
    local min_sim="$5"
    local db_prefix="$6"  # path prefix for the blast DB files
    local out_list="$7"   # output accession list
    local exclude_id="$8" # accession to exclude (the query itself)

    # Build DB only once per ortholog set (shared across queries of same gene)
    if [ ! -f "${db_prefix}.pin" ] && [ ! -f "${db_prefix}.pdb" ]; then
        echo "  🔨 Building local BLAST database..."
        "$BLAST_DIR/makeblastdb" \
            -in "$ortho_faa" \
            -dbtype prot \
            -out "$db_prefix" \
            -parse_seqids \
            -logfile /dev/null
    else
        echo "  ♻️  Reusing existing BLAST database."
    fi

    echo "  🔬 Running $blast_prog alignment..."
    "$BLAST_DIR/$blast_prog" \
    -query "$query_fasta" \
    -db "$db_prefix" \
    -max_hsps 1 \
    -max_target_seqs 5000 \
    -outfmt "6 saccver pident ppos" \
    -evalue 1e-5 |
    awk -v id_min="$min_id" -v sim_min="$min_sim" '
        ($2+0) >= (id_min+0) && ($3+0) >= (sim_min+0) {
            print $1
        }
    ' |
    awk -v q="$exclude_id" '
        BEGIN {
            sub(/\.[0-9]+$/, "", q)
        }

        {
            x = $0
            sub(/\.[0-9]+$/, "", x)

            if (x != q)
                print $0
        }
    ' |
    sort -u > "$out_list"
}

# --- 5b. Query sequence retrieval via Datasets CLI ---
#
# TODO: "Replace efetch with ncbi-datasets-cli for query sequence retrieval,
# to ensure compatibility with NCBI infrastructure changes in August 2026."
#
# This is now the PRIMARY retrieval path for RefSeq protein/nucleotide
# accessions. `efetch` is kept ONLY as an automatic fallback for cases the
# Datasets CLI can't resolve directly (e.g. accessions it doesn't recognise,
# or transient failures) — full removal of efetch would remove that safety
# net, so OASIS degrades gracefully instead of failing outright.
#
# Returns 0 and writes a single-sequence FASTA to $out_fasta on success;
# returns 1 (leaving $out_fasta untouched/empty) on any failure so the
# caller can fall back to efetch.

fetch_query_via_datasets() {
    local accession="$1"
    local acc_type="$2" # protein | nucleotide
    local out_fasta="$3"

    local safe_acc="${accession//[^A-Za-z0-9]/_}"
    local qzip="$GLOBAL_TMP/query_dl_${safe_acc}.zip"
    local qdir="$GLOBAL_TMP/query_dl_${safe_acc}"

    "$DATASETS_PATH" download gene accession "$accession" \
        --include protein,rna \
        --filename "$qzip" >/dev/null 2>&1

    if [ ! -s "$qzip" ]; then
        return 1
    fi

    mkdir -p "$qdir"
    extract_zip "$qzip" "$qdir" >/dev/null 2>&1

    local src_faa
    if [ "$acc_type" = "protein" ]; then
        src_faa=$(find "$qdir" -type f -iname "*.faa" | head -n1)
    else
        src_faa=$(find "$qdir" -type f -iname "*.fna" | head -n1)
    fi

    if [ -z "$src_faa" ] || [ ! -s "$src_faa" ]; then
        return 1
    fi

    # Isolate the exact accession's record (the gene package may include
    # sibling transcripts/proteins of the same gene alongside it).
    python3 - "$src_faa" "$accession" "$out_fasta" <<'PYEOF'
import sys

src, acc, out = sys.argv[1], sys.argv[2], sys.argv[3]
target = acc.split(".")[0]
keep = []
writing = False

with open(src) as fh:
    for line in fh:
        if line.startswith(">"):
            header_id = line[1:].split()[0].split(".")[0]
            writing = (header_id == target)
        if writing:
            keep.append(line)

with open(out, "w") as fh:
    fh.writelines(keep)
PYEOF

    [ -s "$out_fasta" ] && grep -q '^>' "$out_fasta"
}

# --- 6. Output extractors ---

extract_protein_fasta() {
    local db_prefix="$1"
    local acclist="$2"
    local out_fasta="$3"

    echo "  🚀 Extracting protein sequences from local database..."
    "$BLAST_DIR/blastdbcmd" \
        -db "$db_prefix" \
        -entry_batch "$acclist" \
        -out "$out_fasta" 2>/dev/null

    if [ -s "$out_fasta" ]; then
        local n
        n=$(grep -c '^>' "$out_fasta")
        echo "  ✅ Protein FASTA: $n sequences → $(basename "$out_fasta")"

        # TODO "Accession count mismatch warning": compare the number of
        # sequences actually extracted against the number of accessions
        # requested, and warn only when they genuinely differ (typically
        # because more than one isoform accession maps into the same
        # locus/BLAST hit, or an accession failed to resolve).
        local n_acc
        n_acc=$(grep -c . "$acclist" 2>/dev/null || echo 0)
        if [ "$n" -ne "$n_acc" ]; then
            echo "  ⚠️  MISMATCH: $n_acc accession(s) in the filtered list vs $n sequence(s) in the protein FASTA." >&2
            echo "      This usually indicates multiple isoforms per locus or an accession that failed to resolve." >&2
            echo "      Check isoforms_flagged_*.tsv (if generated) for details, or curate the accession list manually." >&2
        fi
    else
        echo "  ❌ Protein extraction returned empty output." >&2
    fi
}

extract_cds_fasta() {

    local acclist="$1"
    local out_fasta="$2"

    echo "  🚀 Downloading CDS sequences..."

    > "$out_fasta"

    # Otimizado para baixar em lotes de 400 IDs por requisição (EUtils standard)
    local batch_size=400

    # Limpa arquivos temporários de lotes de execuções anteriores
    rm -f "${GLOBAL_TMP}/cds_batch_"*

    split -l $batch_size "$acclist" "${GLOBAL_TMP}/cds_batch_"

    for batch in "${GLOBAL_TMP}"/cds_batch_*; do

        [ -f "$batch" ] || continue

        local ids
        ids=$(paste -sd, "$batch")

        local tmp_fa="${GLOBAL_TMP}/tmp_cds.fa"

        local success=0

        for retry in {1..5}; do

            download_text \
"https://eutils.ncbi.nlm.nih.gov/entrez/eutils/efetch.fcgi?db=protein&id=${ids}&rettype=fasta_cds_na&retmode=text" \
> "$tmp_fa"

            if [[ -s "$tmp_fa" ]]; then
                success=1
                break
            fi

            echo "    ⚠️ Retry $retry/5..."
            sleep 2
        done

        if [[ $success -eq 1 ]]; then

            cat "$tmp_fa" >> "$out_fasta"

            local nseq
            nseq=$(grep -c "^>" "$tmp_fa")

            echo "    → Batch $(basename "$batch"): $nseq CDS sequences"

        else

            echo "    ⚠️ Batch failed."

        fi

        # Respiro extra de 1 segundo entre os lotes para não estourar o limite de 3 req/s da NCBI
        sleep 1

    done

    local total_cds
    total_cds=$(grep -c "^>" "$out_fasta" 2>/dev/null || echo 0)

    if [ "$total_cds" -gt 0 ]; then
        echo "  ✅ CDS FASTA: $total_cds sequences → $(basename "$out_fasta")"
    else
        echo "  ❌ CDS output is empty." >&2
    fi
}

# --- 7. Single-accession pipeline ---
#
# Called once per accession in the batch. All intermediate files go to
# GLOBAL_TMP; final outputs go to OUTPUT_ROOT/<accession>/.

run_single() {
    local acc="$1"
    local min_id="$2"
    local min_sim="$3"
    local want_prot="$4" # y/n
    local want_cds="$5"  # y/n

    echo ""
    echo "╔══════════════════════════════════════════════════════╗"
    echo "║  Processing: $acc"
    echo "╚══════════════════════════════════════════════════════╝"

    # 7a. Detect type
    local acc_type
    acc_type=$(detect_type "$acc")
    if [ "$acc_type" = "unknown" ]; then
        echo "  ⏭️  Skipping '$acc' (unrecognised format)."
        return 1
    fi
    echo "  🔬 Type detected: $acc_type"

    # 7b. Resolve Gene ID
    echo "  🔎 Resolving Gene ID..."
    local gene_id
    gene_id=$(resolve_gene_id "$acc")
    if [ -z "$gene_id" ]; then
        echo "  ❌ Could not resolve Gene ID for '$acc'. Skipping." >&2
        return 1
    fi
    echo "  ✅ Gene ID: $gene_id"

    # 7c. Per-accession output directory
    local out_dir="${OUTPUT_ROOT}/${acc}"
    mkdir -p "$out_dir"

    local final_list="${out_dir}/filtered_accessions_ID${min_id}_SIM${min_sim}_${acc}.txt"

    # 7d. Fetch query sequence
    echo "  📥 Fetching query sequence..."
    local query_fasta="$GLOBAL_TMP/query_${acc}.fasta"
    local blast_prog

    if [ "$acc_type" = "protein" ]; then
        blast_prog="blastp"
        if ! fetch_query_via_datasets "$acc" "protein" "$query_fasta"; then
            echo "  ↩️  Datasets CLI unavailable/failed for '$acc' — falling back to efetch..."
            download_text \
                "https://eutils.ncbi.nlm.nih.gov/entrez/eutils/efetch.fcgi?db=protein&id=${acc}&rettype=fasta&retmode=text" \
                >"$query_fasta"
        fi
    elif [ "$acc_type" = "uniprot" ]; then
        blast_prog="blastp"
        echo "  📥 Fetching sequence from UniProt..."
        download_text "https://rest.uniprot.org/uniprotkb/${acc}.fasta" > "$query_fasta"
    elif [ "$acc_type" = "nucleotide" ]; then
        blast_prog="blastx"
        if ! fetch_query_via_datasets "$acc" "nucleotide" "$query_fasta"; then
            echo "  ↩️  Datasets CLI unavailable/failed for '$acc' — falling back to efetch..."
            download_text \
                "https://eutils.ncbi.nlm.nih.gov/entrez/eutils/efetch.fcgi?db=nuccore&id=${acc}&rettype=fasta&retmode=text" \
                >"$query_fasta"
        fi
    else
        # Numeric gene ID: fetch the representative RefSeq protein via esummary
        blast_prog="blastp"
        echo "  ℹ️  Numeric gene ID — fetching representative protein via esummary..."
        local rep_prot
        rep_prot=$(download_text \
            "https://eutils.ncbi.nlm.nih.gov/entrez/eutils/esummary.fcgi?db=gene&id=${acc}&retmode=json" |
            python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    uid = list(data['result'].keys() - {'uids'})[0]
    prots = data['result'][uid].get('genomicinfo', [{}])
    # Try to get the accession from protein products
    prod = data['result'][uid].get('locationhist', [{}])
    # fallback: just report the gene_id for manual resolution
    print(data['result'][uid].get('name',''))
except: pass
" 2>/dev/null)
        echo "  ℹ️  Gene symbol: $rep_prot — fetching protein FASTA via gene link..."
        # For gene IDs, fetch the protein via elink gene→protein then efetch
        local prot_uid
        prot_uid=$(download_text \
            "https://eutils.ncbi.nlm.nih.gov/entrez/eutils/elink.fcgi?dbfrom=gene&db=protein&id=${acc}&retmode=json" |
            python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    for ls in data.get('linksets', []):
        for db in ls.get('linksetdbs', []):
            if db.get('linkname') == 'gene_protein_refseq':
                lk = db.get('links', [])
                if lk: print(lk[0]); raise SystemExit
except: pass
" 2>/dev/null)
        if [ -n "$prot_uid" ]; then
            download_text \
                "https://eutils.ncbi.nlm.nih.gov/entrez/eutils/efetch.fcgi?db=protein&id=${prot_uid}&rettype=fasta&retmode=text" \
                >"$query_fasta"
        fi
    fi

    if [ ! -s "$query_fasta" ] || ! grep -q '^>' "$query_fasta"; then
        echo "  ❌ Could not fetch query sequence for '$acc'. Skipping." >&2
        return 1
    fi
    echo "  ✅ Query sequence fetched."

    # 7e. Fetch orthologs (shared per gene_id across the whole run)
    local ortho_faa="$GLOBAL_TMP/ortho_${gene_id}.faa"
    local blast_db="$GLOBAL_TMP/blastdb_${gene_id}"

    if ! fetch_all_orthologs "$gene_id" "$ortho_faa" "$TAXON_SCOPE"; then
        echo "  ❌ Ortholog fetch failed for '$acc'. Skipping." >&2
        return 1
    fi

    # 7e-bis. Isoform screening (flag or remove), TODO "Isoform filtering strategy"
    if [ "$ISOFORM_MODE" != "keep" ]; then
        local isoform_report="${out_dir}/isoforms_flagged_${gene_id}.tsv"
        flag_isoforms "$ortho_faa" "$isoform_report" "$ISOFORM_MODE"
    fi

    # 7f. BLAST + filter
    echo "  ⚙️  Running BLAST alignment and filtering..."
    run_blast_filter \
        "$query_fasta" "$ortho_faa" "$blast_prog" \
        "$min_id" "$min_sim" \
        "$blast_db" "$final_list" "$acc"

    local count
    count=$(wc -l <"$final_list" | tr -d '[:space:]')
    echo "  🎯 $count accessions passed filters (Identity ≥ ${min_id}%, Similarity ≥ ${min_sim}%)."
    echo "  📋 Accession list → $final_list"

    if [ "$count" -eq 0 ]; then
        echo "  ⚠️  No hits passed filters — try lowering thresholds."
        return 0
    fi

    # 7g. Protein FASTA (optional)
    if [[ "$want_prot" =~ ^[Yy]$ ]]; then
        local prot_out="${out_dir}/sequences_PROT_OASIS_${acc}.fasta"
        extract_protein_fasta "$blast_db" "$final_list" "$prot_out"
    fi

    # 7h. CDS FASTA (optional)
    if [[ "$want_cds" =~ ^[Yy]$ ]]; then
        local cds_out="${out_dir}/sequences_CDS_OASIS_${acc}.fasta"
        extract_cds_fasta "$final_list" "$cds_out"
    fi

    echo "  ✅ Done → ./${out_dir}/"
}

# =============================================================================
#  MAIN
# =============================================================================

# Fail fast on missing dependencies before printing the banner or asking
# the user anything — see check_dependencies() definition above.
check_dependencies

cat <<'OASIS_BANNER'
=============================================================

     *******         **        ********   **    ********
    **/////**       ****      **//////   /**   **////// 
   **     //**     **//**    /**         /**  /**       
  /**      /**    **  //**   /*********  /**  /*********
  /**      /**   **********  ////////**  /**  ////////**
  //**     **   /**//////**         /**  /**         /**
   //*******    /**     /**   ********   /**   ******** 
    ///////     //      //   ////////    //   //////// 

    ⠀⠀⠉⠓⢦⣄⡀⠀⠉⠙⠲⢼⣧⡉⠙⠲⣤⡀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀
    ⠀⠀⠀⠀⠀⠈⠙⠳⣤⡀⠀⢀⠈⠙⠲⣄⣄⠙⢦⣴⣄⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀
    ⠀⠀⠀⠀⠀⠀⠀⠀⠀⠙⠳⣌⡓⢤⡀⠈⠉⢣⠀⠻⠈⢷⠀⠀⢀⣀⣠⣤⣤⣤⣄⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀
    ⣠⣤⡤⠦⠤⠤⠤⠤⠤⠤⢤⣼⡿⣆⠙⢦⠀⠀⢧⠹⡄⠈⡷⠛⢉⣀⣀⡀⠀⠐⠻⠶⠤⢤⣄⡀⠀⠀⠀⠀⠀⠀⠀
    ⠉⠙⠛⠛⠓⠲⠶⠦⢤⣄⡀⠈⢡⡈⠑⢦⡱⡄⠈⣇⠁⢀⠇⠀⣉⡤⠔⢛⣧⡤⠤⠤⠤⠤⠤⠿⢷⣦⣶⣦⣤⣤⠄
    ⠀⠀⠀⠀⠀⠀⠀⠀⢀⣾⣯⣤⣀⡉⠒⠀⣹⠶⠤⣼⣄⣾⠔⠋⠁⣀⡤⠞⢁⣀⣠⠤⠶⠶⠿⣭⣉⠙⢧⡀⠀⠀⠀
    ⠀⠀⠀⠀⣤⣶⡟⠋⠉⣉⣉⣉⠛⠛⠷⣶⡃⢀⡤⠘⡿⠓⢶⣬⠥⠔⠒⠒⠚⠛⠶⢶⣦⠀⠀⠀⠈⠉⠛⠿⠀⠀⠀
    ⠀⠀⠀⢠⡼⠋⠁⣠⣼⣧⣠⣤⠴⠶⠶⠾⢷⣆⣀⣴⠃⢷⣀⡧⢤⣗⡒⠶⠤⠀⠀⠻⢦⣄⠀⠀⠀⠀⠀⠀⠀⠀⠀
    ⠀⠀⡴⠋⢀⡴⠋⠀⠉⠉⠀⠀⠀⠀⠀⢀⡞⠁⠀⢉⡿⠛⣿⢀⢦⡀⠉⢳⣶⠶⠶⢤⣄⡈⠙⠶⣄⠀⠀⠀⠀⠀⠀
    ⠀⣼⠁⡴⠋⠀⠀⠀⠀⠀⠀⠀⠀⠀⢠⡎⠀⠀⠀⡼⠀⠀⠛⠻⣆⠳⡀⠘⣏⠁⠀⠀⠀⠉⠙⠓⠮⢿⣦⡀⠀⠀⠀
    ⠀⣇⡞⠁⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⡾⠉⠙⠒⢲⡇⠀⠀⠀⠀⠸⡄⢱⠀⢹⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀
    ⠸⣿⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⢸⠇⢤⠀⠀⢸⠁⠀⠀⠀⠀⠀⢻⠀⠃⢸⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀
    ⠀⠁⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⢼⡀⠀⠘⠀⢸⠀⠀⠀⠀⠀⠀⢸⡆⢀⡾⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀
    ⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⣾⠉⠉⠉⠉⠙⡇⠀⠀⠀⠀⠀⣸⣧⠞⠁⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀
    ⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⣿⠤⠀⠀⠀⠀⢷⠀⠀⠀⠀⠀⠿⠋⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀
    ⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⢿⠀⠉⠀⠀⠀⠘⡆⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀
    ⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⢸⡀⠀⠀⣀⣀⣠⠼⡄⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀
    ⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠘⣿⠋⠉⠁⠀⢀⡀⠻⣆⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀
    ⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠹⡄⠀⠀⠀⠈⠉⠀⠘⢦⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀
    ⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⡀⣀⣀⢹⡀⣰⠛⢧⣠⢄⣀⣬⢧⣀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀
    ⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠐⣿⠻⡌⠻⠿⠃⠀⠈⠁⠈⠁⠸⠋⢹⡷⣶⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀
    ⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠈⠛⠲⠶⠒⠒⠚⠛⠛⠛⠛⠓⠓⠛⠛⠋⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀
    ⠀⠀⠀⠀⠀⠀⠘⠚⠛⠚⠛⠻⠟⠛⠃⠟⠻⠓⠐⠚⠛⠛⠀⠀⠀⠀⠀⠃⠟⠓⠺⠛⠻⠗⠃⠀⠀⠀⠀⠀⠀⠀⠀

          Ortholog Alignment & Similarity Screener
    EvoMol - LAboratório de Evolução Molecular e Sistemas
=============================================================
OASIS_BANNER

# ---------- Input parsing ----------
#
# Accepted call signatures:
#   ./OASIS.sh                             → fully interactive
#   ./OASIS.sh ACC 90 95                   → single accession
#   ./OASIS.sh ACC1 ACC2 ... 90 95         → multiple inline accessions
#   ./OASIS.sh file.txt 90 95             → batch file

ACCESSIONS=()
MIN_ID=""
MIN_SIM=""

if [ "$#" -eq 0 ]; then
    # Fully interactive
    echo ""
    echo "You can enter:"
    echo "  • A single accession:           NP_001416352.1"
    echo "  • Multiple accessions (space):  NP_001416352.1 NM_001429423.1"
    echo "  • A path to a batch file:       /path/to/ids.txt"
    echo ""
    read -rp "🧬 Accession(s) or batch file: " INPUT_RAW

    # Check if it's a file
    if [ -f "$INPUT_RAW" ]; then
        mapfile -t ACCESSIONS < <(grep -v '^\s*#' "$INPUT_RAW" | grep -v '^\s*$' | awk '{print $1}')
    else
        read -ra ACCESSIONS <<<"$INPUT_RAW"
    fi

    read -rp "📊 Minimum Identity (e.g. 90): " MIN_ID
    read -rp "📊 Minimum Similarity (e.g. 95): " MIN_SIM

else
    # CLI mode: last two numeric args are MIN_ID and MIN_SIM
    ARGS=("$@")
    N=${#ARGS[@]}

    # Check if last two look numeric
    if [[ "${ARGS[$((N - 1))]}" =~ ^[0-9]+$ ]] && [[ "${ARGS[$((N - 2))]}" =~ ^[0-9]+$ ]]; then
        MIN_SIM="${ARGS[$((N - 1))]}"
        MIN_ID="${ARGS[$((N - 2))]}"
        ARGS=("${ARGS[@]:0:$((N - 2))}")
    fi

    # Remaining args: single file or list of accessions
    if [ "${#ARGS[@]}" -eq 1 ] && [ -f "${ARGS[0]}" ]; then
        mapfile -t ACCESSIONS < <(grep -v '^\s*#' "${ARGS[0]}" | grep -v '^\s*$' | awk '{print $1}')
        echo "📂 Batch file: ${ARGS[0]} (${#ACCESSIONS[@]} accessions)"
    else
        ACCESSIONS=("${ARGS[@]}")
    fi

    # Prompt for missing thresholds
    [ -z "$MIN_ID" ] && read -rp "📊 Minimum Identity (%):    " MIN_ID
    [ -z "$MIN_SIM" ] && read -rp "📊 Minimum Similarity (%): " MIN_SIM
fi

# Validate we have something to process
if [ "${#ACCESSIONS[@]}" -eq 0 ]; then
    echo "❌ No accessions provided. Exiting." >&2
    exit 1
fi
if [ -z "$MIN_ID" ] || [ -z "$MIN_SIM" ]; then
    echo "❌ Identity and Similarity thresholds are required." >&2
    exit 1
fi

echo ""
echo "📋 Accessions to process (${#ACCESSIONS[@]}):"
for a in "${ACCESSIONS[@]}"; do echo "   • $a"; done
echo "📊 Identity ≥ ${MIN_ID}%  |  Similarity ≥ ${MIN_SIM}%"
echo ""

# ---------- Output downloads prompt (asked once for the whole batch) ----------

read -rp "📥 Extract protein FASTA for each result? (y/n): " WANT_PROT
read -rp "🧬 Download CDS FASTA for each result?     (y/n): " WANT_CDS

# TODO "Taxonomic filter option": optional taxonomic scope to reduce dataset
# size and, as a side effect, work around ortholog result truncation by
# splitting the request into taxon-scoped batches (see fetch_all_orthologs).
echo ""
echo "🌍 Optional taxonomic scope (reduces dataset size / relevance)."
echo "   Examples: Mammalia | Actinopterygii | Mammalia,Aves | (leave blank for all)"
read -rp "🌍 Taxonomic scope: " TAXON_SCOPE

# TODO "Isoform filtering strategy": how to handle likely alternatively
# spliced isoforms / redundant accessions detected per organism.
echo ""
echo "🧬 Isoform handling for the ortholog pool:"
echo "   [k]eep all   – no screening"
echo "   [f]lag only  – report likely isoforms/redundant accessions, keep them (default)"
echo "   [r]emove     – drop likely isoforms/redundant accessions before BLAST"
read -rp "🧬 Choice (k/f/r) [f]: " ISOFORM_CHOICE
case "${ISOFORM_CHOICE,,}" in
k | keep) ISOFORM_MODE="keep" ;;
r | remove) ISOFORM_MODE="remove" ;;
*) ISOFORM_MODE="flag" ;;
esac

# ---------- Environment setup ----------

install_tools

# Global output root and shared temp directory
OUTPUT_ROOT="OASIS_results_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$OUTPUT_ROOT"

GLOBAL_TMP="tmp_OASIS_$$"
mkdir -p "$GLOBAL_TMP"
trap 'rm -rf "$GLOBAL_TMP"' EXIT

echo ""
echo "📁 All results will be saved under: ./${OUTPUT_ROOT}/"
echo ""

# ---------- Main batch loop ----------

SUCCESS=()
SKIPPED=()

for ACC in "${ACCESSIONS[@]}"; do
    if run_single "$ACC" "$MIN_ID" "$MIN_SIM" "$WANT_PROT" "$WANT_CDS"; then
        SUCCESS+=("$ACC")
    else
        SKIPPED+=("$ACC")
    fi
done

# ---------- Final summary ----------

echo ""
echo "======================================================"
echo "🏁 OASIS batch run complete."
echo "   Processed : ${#ACCESSIONS[@]} accession(s)"
echo "   Succeeded : ${#SUCCESS[@]}"
echo "   Skipped   : ${#SKIPPED[@]}"
if [ "${#SKIPPED[@]}" -gt 0 ]; then
    echo "   Failed IDs:"
    for s in "${SKIPPED[@]}"; do echo "     • $s"; done
fi
echo "📁 Output root: ./${OUTPUT_ROOT}/"
echo "======================================================"
echo ""
echo "⚠️  IMPORTANT NOTICE:"
echo "   • If a protein FASTA has more sequences than accessions in its filtered"
echo "     list, a per-run MISMATCH warning was already printed above — this"
echo "     usually means multiple isoform accessions map to the same locus."
echo "   • Isoform screening (flag/remove, mode: $ISOFORM_MODE) is heuristic,"
echo "     organism-based, and not a substitute for manual curation before"
echo "     MSA or phylogenetic analysis — check any isoforms_flagged_*.tsv files."
