#!/bin/bash
#############################################
# Cipi — Tables
#
# Columns as wide as their longest value, so an app name of 32 characters, a
# long domain or a list of destinations does not push the rest of the row out
# of line. Cells may carry colour codes (they do not count); the last column
# is not padded unless it is right-aligned. Two spaces between columns.
#
#   tbl_start
#   tbl_align l r r                        # optional, per column (default l)
#   tbl_head "APP" "FILES" "SIZE"          # printed bold
#   tbl_row  "$app" "$files" "${CYAN}${size}${NC}"
#   tbl_rule                               # ── across the table's width
#   tbl_line "${YELLOW}a note${NC}"        # free text, not measured
#   tbl_print [indent]                     # default indent: 2 spaces
#
# No side effects when sourced, and no global constants: every function can be
# lifted on its own (declare -f), as the regression tests do.
#############################################

tbl_start() { _TBL_ROWS=(); _TBL_ALIGN=(); }
tbl_align() { _TBL_ALIGN=("$@"); }
tbl_head()  { local IFS=$'\x1f'; _TBL_ROWS+=("H${IFS}$*"); }
tbl_row()   { local IFS=$'\x1f'; _TBL_ROWS+=("R${IFS}$*"); }
tbl_line()  { _TBL_ROWS+=("L"$'\x1f'"$1"); }
tbl_rule()  { _TBL_ROWS+=("-"$'\x1f'); }

# Visible length: colour codes removed.
_tbl_vlen() {
    local s="$1" re=$'\e''\[[0-9;]*m'
    while [[ "$s" =~ $re ]]; do s="${s/"${BASH_REMATCH[0]}"/}"; done
    printf '%s' "${#s}"
}

tbl_print() {
    local indent="${1-  }" sep=$'\x1f' row kind i n len pad line total=0 cols=0 rule=""
    local -a w=() cells=()
    for row in "${_TBL_ROWS[@]}"; do
        [[ "${row:0:1}" == "H" || "${row:0:1}" == "R" ]] || continue
        IFS="$sep" read -r -a cells <<< "$row"
        (( ${#cells[@]} - 1 > cols )) && cols=$(( ${#cells[@]} - 1 ))
        for ((i = 1; i < ${#cells[@]}; i++)); do
            len=$(_tbl_vlen "${cells[$i]}")
            (( len > ${w[$i]:-0} )) && w[$i]=$len
        done
    done
    for ((i = 1; i <= cols; i++)); do total=$(( total + ${w[$i]:-0} )); done
    (( cols > 1 )) && total=$(( total + 2 * (cols - 1) ))
    for ((i = 0; i < total; i++)); do rule+="─"; done
    for row in "${_TBL_ROWS[@]}"; do
        kind="${row:0:1}"
        case "$kind" in
            L) printf '%s%b\n' "$indent" "${row:2}"; continue ;;
            -) printf '%s%s\n' "$indent" "$rule"; continue ;;
        esac
        IFS="$sep" read -r -a cells <<< "$row"
        n=${#cells[@]}; line=""
        for ((i = 1; i < n; i++)); do
            pad=$(( ${w[$i]:-0} - $(_tbl_vlen "${cells[$i]}") ))
            if [[ "${_TBL_ALIGN[$((i - 1))]:-l}" == "r" ]]; then
                printf -v line '%s%*s%s' "$line" "$pad" "" "${cells[$i]}"
            elif (( i < n - 1 )); then
                printf -v line '%s%s%*s' "$line" "${cells[$i]}" "$pad" ""
            else
                line+="${cells[$i]}"
            fi
            (( i < n - 1 )) && line+="  "
        done
        if [[ "$kind" == "H" ]]; then
            printf '%s%b%s%b\n' "$indent" "${BOLD:-}" "$line" "${NC:-}"
        else
            printf '%s%s\n' "$indent" "$line"
        fi
    done
    _TBL_ROWS=(); _TBL_ALIGN=()
}
