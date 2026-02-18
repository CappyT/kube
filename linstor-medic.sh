#!/bin/bash

# ==============================================================================
# LINSTOR MEDIC DASHBOARD v3.6 (Final Polish)
# ==============================================================================
# Un'interfaccia TUI avanzata per la gestione e riparazione del cluster.
#
# REQUISITI: kubectl, jq, fzf (OBBLIGATORIO per la TUI)
# ==============================================================================

# --- CONFIGURAZIONE ---
NAMESPACE="piraeus-datastore"
LABEL_SELECTOR="app.kubernetes.io/component=linstor-satellite"
# NODES sarà popolato dinamicamente

# Cartelle e File Temporanei
TEMP_DIR=$(mktemp -d)
ISSUES_DB="$TEMP_DIR/issues.tsv"
LINSTOR_DB="$TEMP_DIR/linstor_full.json"
K8S_DB="$TEMP_DIR/k8s_pvs.txt"
LAST_SCAN_FILE="$TEMP_DIR/last_scan_info"
LIVE_PREVIEW_FLAG="$TEMP_DIR/live_preview_enabled"
PREVIEW_SCRIPT="$TEMP_DIR/preview_helper.sh"

# --- COLORI & STILE ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# Trap per pulizia all'uscita
trap "rm -rf $TEMP_DIR" EXIT

# Init flag live preview (0 = Disabled)
echo "0" > "$LIVE_PREVIEW_FLAG"

# ==============================================================================
# UTILITÀ DI SISTEMA
# ==============================================================================

check_deps() {
    local missing=0
    for cmd in kubectl jq awk fzf; do
        if ! command -v $cmd &> /dev/null; then
            echo -e "${RED}[ERROR] Manca il comando: $cmd${NC}"
            if [ "$cmd" == "fzf" ]; then
                echo -e "Questa versione richiede 'fzf' per la Dashboard. Installalo con 'apt install fzf'."
            fi
            missing=1
        fi
    done
    if [ $missing -eq 1 ]; then exit 1; fi
}

header() {
    clear
    echo -e "${PURPLE}"
    echo "  _     ___ _   _ ____  _____ ___  ____  "
    echo " | |   |_ _| \ | / ___||_   _/ _ \|  _ \ "
    echo " | |    | ||  \| \___ \  | || | | | |_) |"
    echo " | |___ | || |\  |___) | | || |_| |  _ < "
    echo " |_____|___|_| \_|____/  |_| \___/|_| \_\\"
    echo -e "${NC}"
    echo -e "  ${CYAN}CLUSTER MEDIC DASHBOARD v3.6${NC} :: Namespace: ${BOLD}$NAMESPACE${NC}"
    echo " ─────────────────────────────────────────────────────────────────"
}

# ==============================================================================
# PREVIEW HELPER (Lo script esterno che gestisce la grafica a lato)
# ==============================================================================
generate_preview_script() {
cat << 'EOF' > "$PREVIEW_SCRIPT"
#!/bin/bash
# Script generato automaticamente per gestire la preview di FZF senza errori di quoting
TITLE="$1"
FLAG_FILE="$2"
SCAN_FILE="$3"
PROB="$4"
RES="$5"
NODE="$6"
DETAILS="$7"

# Ridefinizione colori (perché siamo in una sub-shell)
BOLD="\033[1m"
NC="\033[0m"
CYAN="\033[0;36m"
GREEN="\033[0;32m"
RED="\033[0;31m"
BLUE="\033[0;34m"

# Header Stats
if [ -f "$SCAN_FILE" ]; then
    IFS='|' read -r time k8s linstor issues < "$SCAN_FILE"
    echo -e "${BLUE}STATS:${NC} K8s PVs: ${BOLD}$k8s${NC} | Linstor Res: ${BOLD}$linstor${NC} | Issues: ${RED}${BOLD}$issues${NC}"
fi

echo -e "${BOLD}$TITLE${NC}"
echo -e "${CYAN}──────────────────────────────${NC}"
echo -e "${BOLD}Problema:${NC} $PROB"
echo -e "${BOLD}Risorsa:${NC}  $RES"
echo -e "${BOLD}Nodo:${NC}     $NODE"
echo ""

# Live Check Logic
if [ -f "$FLAG_FILE" ] && [ $(cat "$FLAG_FILE") -eq 1 ]; then
    echo -ne "${BOLD}Status Live K8s:${NC} "
    # Controllo silenzioso su K8s
    if kubectl get pv "$RES" >/dev/null 2>&1; then
        echo -e "${GREEN}✔ TROVATO${NC}"
    else
        echo -e "${RED}✖ NON TROVATO${NC}"
    fi
else
    echo -e "${CYAN}(Live Check: CTRL-P)${NC}"
fi

echo ""
# Split Description ### Action
# Usiamo variabili per evitare problemi con caratteri speciali in awk
ANALYSIS="${DETAILS%###*}"
ACTION="${DETAILS#*###}"

echo -e "${BOLD}[ 🔍 ANALISI ]${NC}"
echo -e "$ANALYSIS"
echo ""
echo -e "${BOLD}[ 🛠️  AZIONE CONSIGLIATA ]${NC}"
echo -e "$ACTION"
EOF
chmod +x "$PREVIEW_SCRIPT"
}

# ==============================================================================
# MOTORE DI SCANSIONE
# ==============================================================================

scan_cluster() {
    echo -ne "${BLUE}[SCAN] Mappatura Nodi e Pods...${NC}\r"
    
    declare -A POD_MAP
    NODES=()
    
    while read -r node pod; do
        if [ ! -z "$node" ] && [ ! -z "$pod" ]; then
            POD_MAP["$node"]="$pod"
            NODES+=("$node")
        fi
    done < <(kubectl get pods -n "$NAMESPACE" -l "$LABEL_SELECTOR" -o jsonpath='{range .items[*]}{.spec.nodeName}{" "}{.metadata.name}{"\n"}{end}')

    if [ ${#NODES[@]} -eq 0 ]; then
        echo -e "${RED}[ERROR] Nessun nodo Linstor Satellite trovato nel namespace $NAMESPACE.${NC}"
        exit 1
    fi

    echo -ne "${BLUE}[SCAN] Download Database Linstor...${NC}\r"
    kubectl linstor -m r list > "$LINSTOR_DB"
    
    echo -ne "${BLUE}[SCAN] Download Database Kubernetes...${NC}\r"
    kubectl get pv -o jsonpath='{range .items[*]}{.metadata.name}{"|"}{.spec.storageClassName}{"|"}{.metadata.deletionTimestamp}{"\n"}{end}' | \
    awk -F"|" '{
        name=$1; sc=$2; del=$3
        if (sc == "") sc = "-"
        status = "ACTIVE"
        if (del != "") status = "TERMINATING"
        print name " " sc " " status
    }' | sort > "$K8S_DB"

    > "$ISSUES_DB"

    # Analisi per nodo
    for NODE in "${NODES[@]}"; do
        echo -ne "${CYAN}[SCAN] Analisi $NODE...           ${NC}\r"
        POD="${POD_MAP[$NODE]}"
        
        cat "$LINSTOR_DB" | jq -r --arg N "$NODE" 'flatten | .[] | select(.node_name == $N) | .name' | sort > "$TEMP_DIR/${NODE}_linstor.txt"
        
        kubectl exec -n "$NAMESPACE" "$POD" -- lvs --noheadings -o lv_name 2>/dev/null < /dev/null \
            | grep "pvc-" | awk '{$1=$1;print}' | sed 's/_00000$//' | sort > "$TEMP_DIR/${NODE}_disk.txt"

        SEP="###"

        # Check Orfani
        comm -13 "$TEMP_DIR/${NODE}_linstor.txt" "$TEMP_DIR/${NODE}_disk.txt" | while read vol; do
            issue_type="ORPHAN"
            desc="Spazio occupato inutilmente. Nessun PV K8s, nessuna risorsa Linstor."
            
            if [[ "$vol" == *"snapshot"* ]] || [[ "$vol" == *"snap"* ]]; then
                issue_type="ORPHAN SNAP"
                desc="Snapshot orfano su disco (LVM)."
            fi

            k8s_entry=$(grep "^$vol " "$K8S_DB")
            
            if [ -z "$k8s_entry" ]; then
                echo -e "${issue_type}\t$vol\t$NODE\t${desc}${SEP}Rimozione volume LVM." >> "$ISSUES_DB"
            else
                echo -e "CRITICAL\t$vol\t$NODE\tDisallineamento: K8s usa questo volume, esiste su Disco, ma Linstor NON lo trova.${SEP}Richiede debug Linstor (Restore DB)." >> "$ISSUES_DB"
            fi
        done

        # Check Zombie/Stuck
        comm -12 "$TEMP_DIR/${NODE}_linstor.txt" "$TEMP_DIR/${NODE}_disk.txt" | while read vol; do
            k8s_entry=$(grep "^$vol " "$K8S_DB")
            
            if [ -z "$k8s_entry" ]; then
                echo -e "ZOMBIE\t$vol\t$NODE\tVolume presente in Linstor e Disco, ma PVC non esiste in K8s.${SEP}Rimozione risorsa Linstor." >> "$ISSUES_DB"
            elif echo "$k8s_entry" | grep -q "TERMINATING"; then
                echo -e "STUCK\t$vol\t$NODE\tK8s sta provando a cancellarlo ma e bloccato (PV Terminating).${SEP}Unlock DRBD & Force Delete." >> "$ISSUES_DB"
            fi
        done
    done
    
    cnt_k8s=$(wc -l < "$K8S_DB")
    cnt_linstor=$(jq -r 'flatten | .[].name' "$LINSTOR_DB" | sort -u | wc -l)
    cnt_issues=$(wc -l < "$ISSUES_DB")
    scan_time=$(date +"%H:%M:%S")
    
    echo "$scan_time|$cnt_k8s|$cnt_linstor|$cnt_issues" > "$LAST_SCAN_FILE"
}

# ==============================================================================
# LOGICHE DI FIX
# ==============================================================================

perform_fix() {
    local type=$1
    local vol=$2
    local node=$3
    local skip_confirm=${4:-0} # 0=Ask, 1=Skip

    local pod=$(kubectl get pods -n "$NAMESPACE" -l "$LABEL_SELECTOR" --field-selector spec.nodeName=$node -o jsonpath='{.items[0].metadata.name}')
    
    if [ "$skip_confirm" -eq 0 ]; then
        echo -e "\n${BOLD}--- PREPARAZIONE FIX ---${NC}"
        echo -e "Analisi contesto per: $vol su $node..."
    else
        echo -ne "${CYAN}Fixing $vol on $node... ${NC}"
    fi

    case "$type" in
        "ORPHAN"|"ORPHAN SNAP")
            local lvm_out=$(kubectl exec -n "$NAMESPACE" "$pod" -- lvs --noheadings -o vg_name,lv_name 2>/dev/null < /dev/null)
            local vg_name=$(echo "$lvm_out" | awk -v v="${vol}_00000" '$2 == v {print $1}' | head -n 1)
            local suffix="_00000"

            if [ -z "$vg_name" ]; then
                 vg_name=$(echo "$lvm_out" | awk -v v="${vol}" '$2 == v {print $1}' | head -n 1)
                 suffix=""
            fi
            
            if [ -z "$vg_name" ]; then
                 local fuzzy_match=$(echo "$lvm_out" | grep "$vol" | head -n 1)
                 if [ ! -z "$fuzzy_match" ]; then
                    vg_name=$(echo "$fuzzy_match" | awk '{print $1}')
                    local lv_real_name=$(echo "$fuzzy_match" | awk '{print $2}')
                    suffix=""
                    vol=$lv_real_name
                 fi
            fi

            if [ -z "$vg_name" ]; then
                if [ "$skip_confirm" -eq 0 ]; then echo -e "${RED}✖ VG non trovato.${NC}"; fi
                if [ "$skip_confirm" -eq 1 ]; then echo -e "${RED}Failed (VG not found)${NC}"; fi
                return 1
            fi
            
            local full_path="/dev/${vg_name}/${vol}${suffix}"
            local cmd_str="kubectl exec -n $NAMESPACE $pod -- lvremove -f $full_path"

            if [ "$skip_confirm" -eq 0 ]; then
                echo -e "\n${YELLOW}${BOLD}COMANDO:${NC} ${CYAN}$cmd_str${NC}"
                echo ""
                read -p "Procedere? [y/N] " -n 1 -r
                echo ""
                if [[ ! $REPLY =~ ^[Yy]$ ]]; then echo "Annullato."; return 0; fi
                echo -e "${YELLOW}> Esecuzione...${NC}"
            fi

            # Silenziamo l'output per evitare messaggi brutti in bulk
            if eval "$cmd_str" < /dev/null > /dev/null 2>&1; then
                if [ "$skip_confirm" -eq 0 ]; then echo -e "${GREEN}✔ Successo.${NC}"; fi
                if [ "$skip_confirm" -eq 1 ]; then echo -e "${GREEN}Done${NC}"; fi
                return 0
            else
                if [ "$skip_confirm" -eq 0 ]; then echo -e "${YELLOW}! Busy. Unlock & Retry...${NC}"; fi
                
                kubectl exec -n "$NAMESPACE" "$pod" -- fuser -mk "$full_path" >/dev/null 2>&1 < /dev/null
                kubectl exec -n "$NAMESPACE" "$pod" -- drbdsetup down "$vol" >/dev/null 2>&1 < /dev/null
                sleep 1
                
                if eval "$cmd_str" < /dev/null > /dev/null 2>&1; then
                    if [ "$skip_confirm" -eq 0 ]; then echo -e "${GREEN}✔ Successo (Unlocked).${NC}"; fi
                    if [ "$skip_confirm" -eq 1 ]; then echo -e "${GREEN}Done (Unlocked)${NC}"; fi
                    return 0
                else
                    if [ "$skip_confirm" -eq 0 ]; then echo -e "${RED}✖ Errore persistente.${NC}"; fi
                    if [ "$skip_confirm" -eq 1 ]; then echo -e "${RED}Error${NC}"; fi
                    return 1
                fi
            fi
            ;;

        "ZOMBIE"|"STUCK")
            if [ "$skip_confirm" -eq 0 ]; then
                echo -e "\n${YELLOW}${BOLD}PIANO:${NC} Force Secondary -> Kill Process -> Delete Resource"
                read -p "Procedere? [y/N] " -n 1 -r
                echo ""
                if [[ ! $REPLY =~ ^[Yy]$ ]]; then echo "Annullato."; return 0; fi
                echo -e "${YELLOW}> 1. Force Secondary...${NC}"
            fi

            kubectl exec -n "$NAMESPACE" "$pod" -- drbdadm secondary "$vol" 2>/dev/null < /dev/null
            if [ $? -ne 0 ]; then
                local drbd_dev=$(kubectl exec -n "$NAMESPACE" "$pod" -- drbdadm sh-dev "$vol" < /dev/null)
                if [ ! -z "$drbd_dev" ]; then
                     kubectl exec -n "$NAMESPACE" "$pod" -- fuser -mk "$drbd_dev" >/dev/null 2>&1 < /dev/null
                     sleep 1
                     kubectl exec -n "$NAMESPACE" "$pod" -- drbdadm secondary "$vol" >/dev/null 2>&1 < /dev/null
                fi
            fi
            
            if [ "$skip_confirm" -eq 0 ]; then echo -e "${YELLOW}> 2. Delete Resource...${NC}"; fi
            
            # Qui è il trucco: catturiamo stderr e lo scartiamo se stiamo in bulk
            # Se il comando fallisce (exit code != 0), procediamo al fallback
            if kubectl linstor resource delete "$node" "$vol" >/dev/null 2>&1 < /dev/null; then
                if [ "$skip_confirm" -eq 0 ]; then echo -e "${GREEN}✔ Successo.${NC}"; fi
                if [ "$skip_confirm" -eq 1 ]; then echo -e "${GREEN}Done${NC}"; fi
                return 0
            else
                 # Fallback
                 kubectl linstor resource-definition delete "$vol" >/dev/null 2>&1 < /dev/null
                 if [ "$skip_confirm" -eq 0 ]; then echo -e "${YELLOW}✔ Def Delete Fallback.${NC}"; fi
                 if [ "$skip_confirm" -eq 1 ]; then echo -e "${GREEN}Done (Fallback)${NC}"; fi
                 return 0 
            fi
            ;;
        *)
            return 1
            ;;
    esac
}

# ==============================================================================
# INTERFACCE UTENTE (UI)
# ==============================================================================

fzf_preview_cmd() {
    local title="$1"
    # Chiamiamo lo script esterno per evitare quoting hell
    echo "$PREVIEW_SCRIPT '$title' '$LIVE_PREVIEW_FLAG' '$LAST_SCAN_FILE' {1} {2} {3} \"{4}\""
}

TOGGLE_CMD="execute(bash -c \"val=\\\$(cat $LIVE_PREVIEW_FLAG); echo \$((1-val)) > $LIVE_PREVIEW_FLAG\")+refresh-preview"

ui_diagnostics() {
    while true; do
        header
        echo -e "${BLUE} > MODALITÀ DIAGNOSTICA (Sola Lettura)${NC}"
        echo " Usa le frecce per scorrere. ESC per tornare indietro."
        echo ""

        if [ ! -s "$ISSUES_DB" ]; then
             echo -e "\n   ${GREEN}✔ Nessun problema rilevato.${NC}"
             read -n 1 -s -r -p "   Premi un tasto per tornare..."
             return
        fi

        cat "$ISSUES_DB" | fzf \
            --header "CTRL-P: Toggle Live Check" \
            --prompt "Dettagli > " \
            --color=fg:188,bg:235,hl:103,fg+:222,bg+:236,hl+:104 \
            --color=info:183,prompt:110,spinner:107,pointer:167,marker:215 \
            --delimiter="\t" \
            --with-nth=1,2,3 \
            --preview "$(fzf_preview_cmd 'SCHEDA DIAGNOSTICA')" \
            --preview-window=right:50%:wrap \
            --bind "enter:deselect-all" \
            --bind "ctrl-p:$TOGGLE_CMD" \
            --bind "esc:execute(echo 'BACK')+abort" \
            > /dev/null
        
        return
    done
}

ui_repair() {
    while true; do
        header
        echo -e "${RED} > MODALITÀ RIPARAZIONE (Action)${NC}"
        echo -e " ${BOLD}TAB${NC}: Seleziona Multiplo | ${BOLD}Alt-a${NC}: Seleziona Tutto | ${BOLD}INVIO${NC}: Ripara"
        echo ""

        if [ ! -s "$ISSUES_DB" ]; then
             echo -e "\n   ${GREEN}✔ Nessun problema da risolvere.${NC}"
             read -n 1 -s -r -p "   Premi un tasto per tornare..."
             return
        fi

        selection=$(cat "$ISSUES_DB" | fzf -m \
            --header "CTRL-P: Live Check | TAB: Select/Deselect | Alt-a: Select All" \
            --prompt "Fix > " \
            --color=fg:188,bg:235,hl:103,fg+:222,bg+:236,hl+:104 \
            --color=info:183,prompt:110,spinner:107,pointer:167,marker:215 \
            --delimiter="\t" \
            --with-nth=1,2,3 \
            --preview "$(fzf_preview_cmd 'ANTEPRIMA INTERVENTO')" \
            --preview-window=right:50%:wrap \
            --bind "ctrl-p:$TOGGLE_CMD" \
            --bind "alt-a:select-all" \
            --expect=esc)

        key=$(head -1 <<< "$selection")
        data_lines=$(tail -n +2 <<< "$selection")

        if [ "$key" == "esc" ] || [ -z "$data_lines" ]; then
            return
        fi

        count=$(echo "$data_lines" | wc -l)
        echo -e "\nHai selezionato ${BOLD}$count${NC} elementi."
        
        skip_confirm=0
        if [ "$count" -gt 1 ]; then
            echo -e "${RED}ATTENZIONE:${NC} Stai per avviare una riparazione di massa."
            read -p "Sei sicuro di voler procedere per TUTTI i $count elementi? [y/N] " -n 1 -r
            echo ""
            if [[ ! $REPLY =~ ^[Yy]$ ]]; then continue; fi
            skip_confirm=1
        fi

        while IFS= read -r line <&3; do
            type=$(echo "$line" | awk -F"\t" '{print $1}')
            res=$(echo "$line" | awk -F"\t" '{print $2}')
            node=$(echo "$line" | awk -F"\t" '{print $3}')

            if [ "$type" == "CRITICAL" ]; then
                echo -e "${RED}Skip CRITICAL: $res su $node${NC}"
                continue
            fi

            perform_fix "$type" "$res" "$node" "$skip_confirm"
            
            if [ $? -eq 0 ]; then
                 awk -F"\t" -v target_res="$res" -v target_node="$node" \
                    '$2 != target_res || $3 != target_node' "$ISSUES_DB" > "$ISSUES_DB.tmp" \
                    && mv "$ISSUES_DB.tmp" "$ISSUES_DB"
            fi
        done 3<<< "$data_lines"

        if [ "$count" -gt 1 ]; then
            read -p "Bulk action completata. Premi enter..."
        fi
    done
}

ui_main_menu() {
    while true; do
        header
        
        last_scan="Mai"
        cnt_k8s="?"
        cnt_linstor="?"
        issue_count="?"
        
        if [ -f "$LAST_SCAN_FILE" ]; then 
            IFS='|' read -r last_scan cnt_k8s cnt_linstor issue_count < "$LAST_SCAN_FILE"
        fi
        
        status_color=$GREEN
        if [ "$issue_count" != "?" ] && [ "$issue_count" -gt 0 ]; then status_color=$RED; fi

        echo -e " ${BOLD}CLUSTER STATUS${NC} (Scan: $last_scan)"
        echo -e " ┌────────────────┬───────────────────┬────────────────┐"
        echo -e " │ K8s PVs (Tot)  │ Linstor Resources │ Issues Found   │"
        echo -e " ├────────────────┼───────────────────┼────────────────┤"
        printf " │ %-14s │ %-17s │ ${status_color}%-14s${NC} │\n" "$cnt_k8s" "$cnt_linstor" "$issue_count"
        echo -e " └────────────────┴───────────────────┴────────────────┘"
        echo ""
        echo " Scegli un'operazione:"
        echo ""

        choice=$(echo -e "1. 🔍 Diagnostica (Vedi Problemi)\n2. 💊 Centro Riparazioni (Fix Problemi)\n3. 🔄 Rescan Cluster\n0. 👋 Esci" | \
            fzf --prompt="Dashboard > " --height=10 --layout=reverse --border=rounded --info=hidden)

        case "$choice" in
            *"1."*) ui_diagnostics ;;
            *"2."*) ui_repair ;;
            *"3."*) scan_cluster ;;
            *"0."*) exit 0 ;;
            *) exit 0 ;;
        esac
    done
}

# --- AVVIO ---
check_deps
generate_preview_script
if [ ! -f "$ISSUES_DB" ]; then
    scan_cluster
fi

ui_main_menu
