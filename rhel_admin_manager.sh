#!/usr/bin/env bash

export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export LC_ALL=C
umask 077

SELF=${0##*/}
LOG_FILE=/var/log/rhel_admin_manager.log
RHEL_VER=0
RELEASE_NAME=desconhecida
RHEL_LABEL=RHEL
BACKTITLE="RHEL Admin Manager"
UI_H=22
UI_W=78
MENU_ROWS=12
TMP_DIR=""
RUN_OUT=""
RUN_RC=0
LOG_USER=""
NET_IFACE=""
NET_IP=""
NET_PREFIX=""
NET_GW=""
NET_DNS=""
NET_MODE="full"
SCRIPT_DIR=""
BATCH_FILE=""
BATCH_SESSION="rhel-admin-batch"
BATCH_DIR=""
BATCH_TARGETS=()
BATCH_PORTS=()
BATCH_NAMES=()
BATCH_DEFAULT_USER=${BATCH_DEFAULT_USER:-}
BATCH_SSH_USER=${BATCH_SSH_USER:-}
BATCH_SSH_PREFIX=()
BATCH_LAST_FILE=/var/tmp/rhel_admin_manager.last_batch

die() {
  printf 'ERRO: %s\n' "$*" >&2
  exit 1
}

q() {
  printf '%q' "$1"
}

cmd_line() {
  local s
  s=$(printf '%q ' "$@")
  printf '%s' "${s% }"
}

log_event() {
  local status=$1 rc=$2 cmd=$3 detail=${4:-}
  cmd=$(printf '%s' "$cmd" | tr '\n\r' '; ')
  detail=$(printf '%s' "$detail" | tr '\n\r' '  ')
  printf '%s | user=%s | status=%s | rc=%s | cmd=%s' \
    "$(date '+%Y-%m-%d %H:%M:%S')" "$LOG_USER" "$status" "$rc" "$cmd" >>"$LOG_FILE"
  if [[ -n $detail ]]; then
    printf ' | detail=%s' "${detail:0:1500}" >>"$LOG_FILE"
  fi
  printf '\n' >>"$LOG_FILE"
}

run_cmd() {
  local out rc preview
  preview=$(printf '%q ' "$@")
  out=$("$@" 2>&1)
  rc=$?
  RUN_OUT=$out
  RUN_RC=$rc
  if ((rc == 0)); then
    log_event SUCESSO 0 "$preview"
  else
    log_event ERRO "$rc" "$preview" "$out"
  fi
  return "$rc"
}

run_shell() {
  local script=$1 out rc f
  f=$(mktemp "$TMP_DIR/cmd.XXXXXX") || return 1
  printf 'set -e\n%s\n' "$script" >"$f"
  out=$(bash "$f" 2>&1)
  rc=$?
  rm -f "$f"
  RUN_OUT=$out
  RUN_RC=$rc
  if ((rc == 0)); then
    log_event SUCESSO 0 "$script"
  else
    log_event ERRO "$rc" "$script" "$out"
  fi
  return "$rc"
}

set_ui() {
  local l c
  l=$(tput lines 2>/dev/null | head -n1)
  c=$(tput cols 2>/dev/null | head -n1)
  [[ $l =~ ^[0-9]+$ ]] || l=24
  [[ $c =~ ^[0-9]+$ ]] || c=80
  UI_H=$((l - 2))
  ((UI_H > 24)) && UI_H=24
  ((UI_H < 12)) && UI_H=12
  UI_W=$((c - 4))
  ((UI_W > 100)) && UI_W=100
  ((UI_W < 50)) && UI_W=50
  ((UI_W > c - 2)) && UI_W=$((c - 2))
  MENU_ROWS=$((UI_H - 8))
  ((MENU_ROWS < 4)) && MENU_ROWS=4
}

show_menu() {
  local title=$1 prompt=$2
  shift 2
  whiptail --backtitle "$BACKTITLE" --title "$title" \
    --menu "$prompt" "$UI_H" "$UI_W" "$MENU_ROWS" "$@" 3>&1 1>&2 2>&3
}

ask() {
  local title=$1 prompt=$2 default=${3:-} ans
  ans=$(whiptail --backtitle "$BACKTITLE" --title "$title" --inputbox \
    "$prompt" 12 "$UI_W" "$default" 3>&1 1>&2 2>&3) || return 1
  ans=$(printf '%s' "$ans" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
  printf '%s' "$ans"
}

ui_msg() {
  whiptail --backtitle "$BACKTITLE" --title "$1" --msgbox "$2" "$UI_H" "$UI_W"
}

ui_error() {
  local title=$1 msg=$2 detail=${3:-} text
  text=$msg
  if [[ -n $detail ]]; then
    text+=$'\n\nSaida (ultimas linhas):\n'"$(printf '%s' "$detail" | tail -n 12)"
  fi
  text+=$'\n\nAuditoria: '"$LOG_FILE"
  whiptail --backtitle "$BACKTITLE" --title "ERRO - $title" --msgbox "$text" "$UI_H" "$UI_W"
}

ui_ok() {
  whiptail --backtitle "$BACKTITLE" --title "$1" --msgbox "$2" "$UI_H" "$UI_W"
}

confirm_exec() {
  local title=$1 cmds=$2 extra=${3:-} text
  text=$'Comandos que serao executados:\n\n'"$cmds"
  [[ -n $extra ]] && text+=$'\n\n'"$extra"
  show_text "CONFIRMAR - $title" "$text" || return 1
  ui_yesno "Executar" "Confirme a execucao dos comandos exibidos."
}

confirm_strong() {
  local title=$1 cmds=$2 ans
  show_text "CONFIRMAR - $title" \
    "$cmds"$'\n\n'"ATENCAO: operacao destrutiva."$'\n'"Digite SIM na proxima tela para continuar." || return 1
  ans=$(whiptail --backtitle "$BACKTITLE" --title "CONFIRMAR - $title" --inputbox \
    "Digite SIM para confirmar:" 10 "$UI_W" "" 3>&1 1>&2 2>&3) || return 1
  [[ $ans == SIM ]]
}

ui_yesno() {
  whiptail --backtitle "$BACKTITLE" --title "$1" --defaultno \
    --yesno "$2" "$UI_H" "$UI_W"
}

confirm_batch() {
  local title=$1 text=$2 strong=$3 ans
  show_text "CONFIRMAR - $title" "$text"$'\n\n'"Revise os comandos acima."$'\n'"$([[ $strong == 1 ]] && printf 'Operacao destrutiva: sera exigido SIM.' || printf 'A execucao sera paralela via TMUX.')" || return 1
  if ((strong)); then
    ans=$(whiptail --backtitle "$BACKTITLE" --title "CONFIRMAR - $title" --inputbox \
      "Digite SIM para confirmar:" 10 "$UI_W" "" 3>&1 1>&2 2>&3) || return 1
    [[ $ans == SIM ]]
  else
    ui_yesno "Executar batch" "Executar os comandos exibidos na sessao $BATCH_SESSION?"
  fi
}

show_text() {
  local title=$1 text=$2 f
  f=$(mktemp "$TMP_DIR/text.XXXXXX") || return 1
  printf '%s\n' "$text" >"$f"
  whiptail --backtitle "$BACKTITLE" --title "$title" --scrolltext \
    --textbox "$f" "$UI_H" "$UI_W"
  rm -f "$f"
}

need_bin() {
  local bin=$1 pkg=${2:-}
  command -v "$bin" >/dev/null 2>&1 && return 0
  ui_error "Dependencia ausente" "Comando '$bin' nao encontrado.${pkg:+ Verifique o pacote: $pkg.}"
  return 1
}

is_ipv4() {
  local ip=$1 o x
  [[ $ip =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
  IFS=. read -r -a o <<<"$ip"
  for x in "${o[@]}"; do
    [[ $x =~ ^(0|[1-9][0-9]{0,2})$ ]] || return 1
    ((10#$x <= 255)) || return 1
  done
}

ip2int() {
  local a b c d
  IFS=. read -r a b c d <<<"$1"
  printf '%s' $(( (10#$a << 24) | (10#$b << 16) | (10#$c << 8) | 10#$d ))
}

prefix_to_mask() {
  local p=$1 v
  v=$(( (0xFFFFFFFF << (32 - p)) & 0xFFFFFFFF ))
  printf '%d.%d.%d.%d' $(( (v >> 24) & 255 )) $(( (v >> 16) & 255 )) $(( (v >> 8) & 255 )) $(( v & 255 ))
}

mask_to_prefix() {
  local int prefix=0 seen0=0 i bit
  is_ipv4 "$1" || return 1
  int=$(ip2int "$1")
  for ((i = 31; i >= 0; i--)); do
    bit=$(( (int >> i) & 1 ))
    if ((bit)); then
      ((seen0)) && return 1
      prefix=$((prefix + 1))
    else
      seen0=1
    fi
  done
  ((prefix > 0)) || return 1
  printf '%s' "$prefix"
}

same_subnet() {
  local ip=$1 gw=$2 prefix=$3 mask
  mask=$(( (0xFFFFFFFF << (32 - prefix)) & 0xFFFFFFFF ))
  (( ( $(ip2int "$ip") & mask ) == ( $(ip2int "$gw") & mask ) ))
}

valid_lvm_name() {
  [[ $1 =~ ^[A-Za-z0-9][A-Za-z0-9+_.-]*$ && ${#1} -le 127 ]]
}

valid_size() {
  [[ $1 =~ ^[1-9][0-9]*[KMGT]$ ]]
}

size_bytes() {
  local s=${1^^} n u m
  n=${s%?}
  u=${s: -1}
  case $u in
    K) m=1024 ;;
    M) m=1048576 ;;
    G) m=1073741824 ;;
    T) m=1099511627776 ;;
    *) return 1 ;;
  esac
  printf '%s' $((n * m))
}

valid_host() {
  is_ipv4 "$1" && return 0
  [[ $1 =~ ^[0-9.]+$ ]] && return 1
  valid_fqdn "$1"
}

ask_ipv4() {
  local title=$1 prompt=$2 v
  while :; do
    v=$(ask "$title" "$prompt") || return 1
    if is_ipv4 "$v"; then
      printf '%s' "$v"
      return 0
    fi
    ui_error "IPv4 invalido" "Informe um endereco IPv4 valido (ex.: 192.168.1.10)."
  done
}

ask_mask() {
  local v p
  while :; do
    v=$(ask "Mascara de rede" "Prefixo (1-32) ou mascara (ex.: 255.255.255.0):") || return 1
    if [[ $v =~ ^[0-9]{1,2}$ ]]; then
      p=$((10#$v))
      if ((p >= 1 && p <= 32)); then
        printf '%s' "$p"
        return 0
      fi
    elif is_ipv4 "$v"; then
      if p=$(mask_to_prefix "$v"); then
        printf '%s' "$p"
        return 0
      fi
    fi
    ui_error "Mascara invalida" "Use prefixo de 1 a 32 ou mascara contigua (ex.: 255.255.255.0)."
  done
}

ask_dns() {
  local raw d out n
  while :; do
    raw=$(ask "Servidores DNS" "DNS (separados por espaco ou virgula, max. 4):") || return 1
    raw=${raw//,/ }
    out=""
    n=0
    for d in $raw; do
      if ! is_ipv4 "$d"; then
        n=-1
        break
      fi
      out+="${out:+,}$d"
      n=$((n + 1))
    done
    if ((n >= 1 && n <= 4)); then
      printf '%s' "$out"
      return 0
    fi
    ui_error "DNS invalido" "Informe de 1 a 4 enderecos IPv4 validos."
  done
}

detect_release() {
  RHEL_VER=0
  RELEASE_NAME=desconhecida
  if [[ -r /etc/redhat-release ]]; then
    RELEASE_NAME=$(head -n1 /etc/redhat-release)
    RHEL_VER=$(sed -n 's/.*release[[:space:]]*\([0-9][0-9]*\).*/\1/p' /etc/redhat-release | head -n1)
  fi
  [[ $RHEL_VER =~ ^[0-9]+$ ]] || RHEL_VER=0
  if ((RHEL_VER >= 6 && RHEL_VER <= 10)); then
    RHEL_LABEL="RHEL $RHEL_VER"
  else
    RHEL_LABEL="RHEL desconhecido"
  fi
  BACKTITLE="RHEL Admin Manager | $RHEL_LABEL | $(hostname -s 2>/dev/null || hostname)"
}

check_release() {
  if ((RHEL_VER < 6 || RHEL_VER > 10)); then
    ui_error "Release nao suportada" "Release detectada: $RELEASE_NAME\nEste script suporta RHEL 6, 7, 8, 9 e 10."
    return 1
  fi
}

version_fs_default() {
  if ((RHEL_VER >= 7)); then
    printf 'xfs'
  else
    printf 'ext4'
  fi
}

version_network_backend() {
  case $RHEL_VER in
    6) printf 'ifcfg-* + service network' ;;
    7) printf 'nmcli / NetworkManager (ifcfg legado ainda existe)' ;;
    8) printf 'nmcli / NetworkManager keyfile (ifcfg obsoleto)' ;;
    9) printf 'nmcli / NetworkManager keyfile (ifcfg removido)' ;;
    10) printf 'nmcli / NetworkManager keyfile (ifcfg removido)' ;;
  esac
}

version_profile_text() {
  case $RHEL_VER in
    6)
      printf '%s\n' \
        "RHEL 6 - perfil operacional" \
        "FS padrao: ext4 (xfs somente com xfsprogs)" \
        "Rede: $(version_network_backend)" \
        "Servicos: service/chkconfig | firewall: iptables" \
        "Hostname: /etc/sysconfig/network (sem hostnamectl)" \
        "Pacotes: yum; security update depende de yum-plugin-security" \
        "" \
        "ATENCAO / OUTCOMES:" \
        "- service network restart reinicia TODAS as interfaces; risco de queda de SSH." \
        "- XFS nao encolhe; crescer XFS exige montado e xfs_growfs." \
        "- ifcfg e reescrito com backup; opcoes nao preservadas devem ser revalidadas." \
        "- NetworkManager pode nao ser o gerenciador padrao." \
        "- Servicos systemd nao existem; use service/chkconfig." \
        "- Batch TMUX: tmux pode vir de EPEL; SSH local usa o usuario de sudo."
      ;;
    7)
      printf '%s\n' \
        "RHEL 7 - perfil operacional" \
        "FS padrao: xfs (ext4 disponivel)" \
        "Rede: $(version_network_backend)" \
        "Servicos: systemd | firewall: firewalld" \
        "Hostname: hostnamectl" \
        "Pacotes: yum; security update depende de yum-plugin-security" \
        "" \
        "ATENCAO / OUTCOMES:" \
        "- nmcli connection up reativa apenas o perfil alterado; ainda pode derrubar SSH." \
        "- XFS nao encolhe; crescer XFS exige montado e xfs_growfs." \
        "- ifcfg existe, mas o caminho suportado neste script e nmcli." \
        "- Apos alterar fstab, systemd gera unidades de mount."
      ;;
    8)
      printf '%s\n' \
        "RHEL 8 - perfil operacional" \
        "FS padrao: xfs (ext4 disponivel)" \
        "Rede: $(version_network_backend)" \
        "Servicos: systemd | firewall: firewalld/nftables" \
        "Hostname: hostnamectl" \
        "Pacotes: dnf (yum e alias)" \
        "" \
        "ATENCAO / OUTCOMES:" \
        "- network-scripts esta obsoleto; nao edite ifcfg manualmente." \
        "- nmcli connection up reativa o perfil; risco de queda de SSH." \
        "- XFS nao encolhe; crescer XFS exige montado e xfs_growfs." \
        "- Security update usa dnf --security (repositorios configurados)." \
        "- Apos alterar fstab, systemd gera unidades de mount."
      ;;
    9)
      printf '%s\n' \
        "RHEL 9 - perfil operacional" \
        "FS padrao: xfs (ext4 disponivel)" \
        "Rede: $(version_network_backend)" \
        "Servicos: systemd | firewall: firewalld/nftables" \
        "Hostname: hostnamectl" \
        "Pacotes: dnf" \
        "" \
        "ATENCAO / OUTCOMES:" \
        "- network-scripts foi removido; ifcfg nao e lido pelo sistema." \
        "- nmcli connection up reativa o perfil; risco de queda de SSH." \
        "- XFS nao encolhe; crescer XFS exige montado e xfs_growfs." \
        "- Security update usa dnf --security." \
        "- Apos alterar fstab, systemd gera unidades de mount."
      ;;
    10)
      printf '%s\n' \
        "RHEL 10 - perfil operacional" \
        "FS padrao: xfs (ext4 disponivel)" \
        "Rede: $(version_network_backend)" \
        "Servicos: systemd | firewall: firewalld/nftables" \
        "Hostname: hostnamectl" \
        "Pacotes: dnf5" \
        "" \
        "ATENCAO / OUTCOMES:" \
        "- network-scripts nao existe; use exclusivamente nmcli." \
        "- nmcli connection up reativa o perfil; risco de queda de SSH." \
        "- XFS nao encolhe; crescer XFS exige montado e xfs_growfs." \
        "- Security update usa dnf5 --security; valide compatibilidade da aplicacao." \
        "- Apos alterar fstab, systemd gera unidades de mount."
      ;;
  esac
}

version_network_note() {
  case $RHEL_VER in
    6) printf 'RHEL 6: grava ifcfg e executa service network restart (todas as interfaces).' ;;
    7) printf 'RHEL 7: usa nmcli; o perfil sera reativado e a sessao SSH pode cair.' ;;
    8) printf 'RHEL 8: usa nmcli; ifcfg/network-scripts e obsoleto.' ;;
    9) printf 'RHEL 9: usa nmcli keyfile; ifcfg nao e suportado.' ;;
    10) printf 'RHEL 10: usa nmcli keyfile; ifcfg nao e suportado.' ;;
  esac
}

version_fs_note() {
  if ((RHEL_VER >= 7)); then
    printf 'RHEL %s: padrao xfs; XFS nao encolhe e cresce apenas montado; ext4 continua disponivel.' "$RHEL_VER"
  else
    printf 'RHEL 6: padrao ext4; XFS exige xfsprogs e nao pode encolher.'
  fi
}

version_mount_note() {
  if ((RHEL_VER >= 7)); then
    printf 'RHEL %s: systemd gera unidades a partir do fstab; daemon-reload sera executado.' "$RHEL_VER"
  else
    printf 'RHEL 6: fstab e lido pelo SysV; UUID evita alteracao de nome do dispositivo.'
  fi
}

init_log() {
  [[ -L $LOG_FILE ]] && die "O arquivo de log nao pode ser symlink: $LOG_FILE"
  if [[ -e $LOG_FILE && ! -f $LOG_FILE ]]; then
    die "Caminho de log invalido: $LOG_FILE"
  fi
  if [[ ! -e $LOG_FILE ]]; then
    (umask 077; : >"$LOG_FILE") || die "Nao foi possivel criar $LOG_FILE"
  fi
  chmod 600 "$LOG_FILE" 2>/dev/null || die "Nao foi possivel ajustar permissoes de $LOG_FILE"
  [[ -w $LOG_FILE ]] || die "Sem permissao de escrita em $LOG_FILE"
}

fs_type() {
  blkid -o value -s TYPE "$1" 2>/dev/null | head -n1
}

mountpoint_of() {
  local dev=$1 real mp=""
  real=$(readlink -f "$dev" 2>/dev/null || printf '%s' "$dev")
  if command -v findmnt >/dev/null 2>&1; then
    mp=$(findmnt -n -o TARGET "$dev" 2>/dev/null | head -n1)
  fi
  if [[ -z $mp ]]; then
    mp=$(awk -v d="$dev" -v r="$real" '$1==d || $1==r {print $2; exit}' /proc/mounts)
  fi
  printf '%s' "$mp"
}

mountpoint_used() {
  local mp=$1
  if command -v findmnt >/dev/null 2>&1 && findmnt -n -o TARGET "$mp" >/dev/null 2>&1; then
    return 0
  fi
  awk -v m="$mp" '$2==m {found=1} END {exit !found}' /proc/mounts
}

vg_free_bytes() {
  local bytes
  bytes=$(vgs --noheadings --units b --nosuffix -o vg_free "$1" 2>/dev/null |
    awk 'NR==1 {gsub(/[<>]/,"",$1); printf "%.0f",$1}')
  [[ $bytes =~ ^[0-9]+$ ]] || return 1
  printf '%s' "$bytes"
}

fstab_has_mp() {
  [[ -r /etc/fstab ]] || return 1
  awk -v mp="$1" '$1 !~ /^[[:space:]]*#/ && $2==mp {found=1} END {exit !found}' /etc/fstab
}

fstab_has_uuid() {
  [[ -r /etc/fstab ]] || return 1
  awk -v u="UUID=$1" '$1==u {found=1} END {exit !found}' /etc/fstab
}

select_vg() {
  need_bin vgs lvm2 || return 1
  local -a items=()
  local name free
  while read -r name free; do
    [[ -n $name ]] || continue
    items+=("$name" "$name | livre: ${free:-?}")
  done < <(vgs --noheadings -o vg_name,vg_free 2>/dev/null)
  if ((${#items[@]} == 0)); then
    ui_error "LVM" "Nenhum Volume Group encontrado."
    return 1
  fi
  show_menu "Selecionar VG" "Volume Group:" "${items[@]}"
}

select_lv() {
  need_bin lvs lvm2 || return 1
  local -a items=()
  local vg lv size
  while read -r vg lv size; do
    [[ -n $vg && -n $lv ]] || continue
    items+=("$vg/$lv" "$vg/$lv | $size")
  done < <(lvs --noheadings -o vg_name,lv_name,lv_size 2>/dev/null)
  if ((${#items[@]} == 0)); then
    ui_error "LVM" "Nenhum Logical Volume encontrado."
    return 1
  fi
  show_menu "Selecionar LV" "Logical Volume:" "${items[@]}"
}

select_device() {
  need_bin blkid util-linux || return 1
  local -a items=()
  local dev fs mp
  while read -r dev; do
    [[ -b $dev ]] || continue
    fs=$(fs_type "$dev")
    case $fs in
      ext2|ext3|ext4|xfs|btrfs|vfat|ntfs|reiserfs) ;;
      *) continue ;;
    esac
    mp=$(mountpoint_of "$dev")
    items+=("$dev" "$dev | $fs | ${mp:-nao montado}")
  done < <(blkid -o device 2>/dev/null | sort -u)
  if ((${#items[@]} == 0)); then
    ui_error "File Systems" "Nenhum dispositivo com filesystem detectado."
    return 1
  fi
  show_menu "Selecionar dispositivo" "Dispositivo com filesystem:" "${items[@]}"
}

select_fs() {
  local -a items
  if ((RHEL_VER >= 7)); then
    items=(xfs "xfs (padrao RHEL 7+)" ext4 "ext4" none "Nao formatar")
  else
    items=(ext4 "ext4 (padrao RHEL 6)" xfs "xfs" none "Nao formatar")
  fi
  show_menu "Tipo de File System" "Selecione:" "${items[@]}"
}

lvm_overview() {
  need_bin lvs lvm2 || return 1
  local out
  out=$(
    printf '=== PHYSICAL VOLUMES ===\n'
    pvs 2>&1
    printf '\n=== VOLUME GROUPS ===\n'
    vgs 2>&1
    printf '\n=== LOGICAL VOLUMES ===\n'
    lvs 2>&1
    printf '\n=== FILESYSTEMS ===\n'
    df -hT 2>&1
  )
  show_text "LVM e File Systems" "$out"
}

create_lv() {
  need_bin lvcreate lvm2 || return 1
  local vg name size fstype free bytes dev
  local -a c1 c2
  local cmds extra
  vg=$(select_vg) || return 1
  while :; do
    name=$(ask "Criar LV" "Nome do novo LV:") || return 1
    if ! valid_lvm_name "$name"; then
      ui_error "Nome invalido" "Use letras, numeros, ponto, hifen, underline ou mais; nao inicie com hifen."
      continue
    fi
    if lvs "$vg/$name" >/dev/null 2>&1; then
      ui_error "LV existente" "O LV $vg/$name ja existe. Escolha outro nome."
      continue
    fi
    break
  done
  free=$(vg_free_bytes "$vg") || {
    ui_error "LVM" "Nao foi possivel ler o espaco livre do VG $vg."
    return 1
  }
  while :; do
    size=$(ask "Criar LV" "Tamanho do LV (ex.: 50G, 512M).\nEspaco livre em $vg: $((free / 1048576)) MB") || return 1
    size=${size^^}
    valid_size "$size" || {
      ui_error "Tamanho invalido" "Use numero inteiro seguido de K, M, G ou T (ex.: 50G)."
      continue
    }
    bytes=$(size_bytes "$size")
    ((bytes <= free)) && break
    ui_error "Espaco insuficiente" "Solicitado: $size\nLivre no VG: $((free / 1048576)) MB"
  done
  fstype=$(select_fs) || return 1
  c1=(lvcreate -y -n "$name" -L "$size" "$vg")
  cmds=$(cmd_line "${c1[@]}")
  extra="VG: $vg | LV: $name | Tamanho: $size"
  dev="/dev/$vg/$name"
  if [[ $fstype != none ]]; then
    case $fstype in
      xfs)
        need_bin mkfs.xfs xfsprogs || return 1
        c2=(mkfs.xfs -f "$dev")
        ;;
      ext4)
        need_bin mkfs.ext4 e2fsprogs || return 1
        c2=(mkfs.ext4 -F "$dev")
        ;;
    esac
    cmds+=$'\n'$(cmd_line "${c2[@]}")
    extra+=" | FS: $fstype (formatacao)"
  fi
  extra+=$'\n'"$(version_fs_note)"
  confirm_exec "Criar LV" "$cmds" "$extra" || return 0
  if ! run_cmd "${c1[@]}"; then
    ui_error "Falha ao criar LV" "A sequencia foi interrompida." "$RUN_OUT"
    return 1
  fi
  if ((${#c2[@]} > 0)); then
    if ! run_cmd "${c2[@]}"; then
      ui_error "Falha ao criar FS" "O LV $dev foi criado, mas o filesystem nao foi formatado." "$RUN_OUT"
      return 1
    fi
  fi
  ui_ok "LV criado" "LV criado com sucesso: $dev${fstype:+ | FS: $fstype}"
}

extend_lv() {
  need_bin lvextend lvm2 || return 1
  local sel vg name dev size free bytes fstype mp cmds extra
  local -a c1 grow
  sel=$(select_lv) || return 1
  vg=${sel%%/*}
  name=${sel#*/}
  dev="/dev/$vg/$name"
  [[ -b $dev ]] || {
    ui_error "LVM" "Dispositivo nao encontrado: $dev"
    return 1
  }
  free=$(vg_free_bytes "$vg") || {
    ui_error "LVM" "Nao foi possivel ler o espaco livre do VG $vg."
    return 1
  }
  while :; do
    size=$(ask "Estender LV" "Tamanho a adicionar (ex.: 10G).\nLivre em $vg: $((free / 1048576)) MB") || return 1
    size=${size^^}
    valid_size "$size" || {
      ui_error "Tamanho invalido" "Use numero inteiro seguido de K, M, G ou T."
      continue
    }
    bytes=$(size_bytes "$size")
    ((bytes <= free)) && break
    ui_error "Espaco insuficiente" "Solicitado: $size\nLivre no VG: $((free / 1048576)) MB"
  done
  fstype=$(fs_type "$dev")
  mp=$(mountpoint_of "$dev")
  c1=(lvextend -L +"$size" "$dev")
  cmds=$(cmd_line "${c1[@]}")
  extra="LV: $dev | Acrescimo: $size | FS: ${fstype:-nao detectado}"
  case $fstype in
    xfs)
      if [[ -z $mp ]]; then
        ui_error "XFS nao montado" "Para crescer XFS online, monte $dev antes de estender."
        return 1
      fi
      need_bin xfs_growfs xfsprogs || return 1
      grow=(xfs_growfs "$mp")
      cmds+=$'\n'$(cmd_line "${grow[@]}")
      extra+=" | Montado em: $mp"
      ;;
    ext4)
      need_bin resize2fs e2fsprogs || return 1
      grow=(resize2fs "$dev")
      cmds+=$'\n'$(cmd_line "${grow[@]}")
      [[ -n $mp ]] && extra+=" | Montado em: $mp"
      ;;
    *)
      extra+=" | FS sem resize automatico; somente o LV sera estendido."
      ;;
  esac
  extra+=$'\n'"$(version_fs_note)"
  confirm_exec "Estender LV" "$cmds" "$extra" || return 0
  if ! run_cmd "${c1[@]}"; then
    ui_error "Falha ao estender LV" "A sequencia foi interrompida." "$RUN_OUT"
    return 1
  fi
  if ((${#grow[@]} > 0)); then
    if ! run_cmd "${grow[@]}"; then
      ui_error "Falha ao crescer FS" "O LV foi estendido, mas o filesystem nao foi redimensionado." "$RUN_OUT"
      return 1
    fi
  fi
  ui_ok "LV estendido" "LV estendido: $dev${fstype:+ | FS: $fstype}"
}

create_fs_lv() {
  need_bin blkid util-linux || return 1
  local sel dev mp old fs cmds
  local -a cmd
  sel=$(select_lv) || return 1
  dev="/dev/$sel"
  [[ -b $dev ]] || {
    ui_error "LVM" "Dispositivo nao encontrado: $dev"
    return 1
  }
  mp=$(mountpoint_of "$dev")
  if [[ -n $mp ]]; then
    ui_error "LV montado" "Desmonte $dev (montado em $mp) antes de formatar."
    return 1
  fi
  old=$(fs_type "$dev")
  fs=$(show_menu "Criar File System" "Novo filesystem para $dev:" \
    ext4 "ext4" xfs "xfs") || return 1
  case $fs in
    ext4)
      need_bin mkfs.ext4 e2fsprogs || return 1
      cmd=(mkfs.ext4 -F "$dev")
      ;;
    xfs)
      need_bin mkfs.xfs xfsprogs || return 1
      cmd=(mkfs.xfs -f "$dev")
      ;;
  esac
  cmds=$(cmd_line "${cmd[@]}")
  confirm_strong "Formatar LV" "$cmds"$'\n\n'"FS atual: ${old:-nenhum}"$'\n'"$(version_fs_note)" || return 0
  if ! run_cmd "${cmd[@]}"; then
    ui_error "Falha ao criar FS" "A operacao foi interrompida." "$RUN_OUT"
    return 1
  fi
  ui_ok "File System criado" "Filesystem $fs criado em $dev."
}

mount_fs() {
  need_bin blkid util-linux || return 1
  local dev fstype uuid mp mp_now backup line append cmd_show
  dev=$(select_device) || return 1
  fstype=$(fs_type "$dev")
  [[ -n $fstype ]] || {
    ui_error "File System" "Nenhum filesystem detectado em $dev."
    return 1
  }
  mp_now=$(mountpoint_of "$dev")
  if [[ -n $mp_now ]]; then
    ui_error "Dispositivo montado" "$dev ja esta montado em $mp_now."
    return 1
  fi
  while :; do
    mp=$(ask "Montar File System" "Ponto de montagem (ex.: /dados):") || return 1
    mp=${mp%/}
    if [[ -z $mp || $mp == "/" || $mp != /* || $mp =~ [[:space:]] || $mp == *"//"* || $mp =~ (^|/)\.\.?(/|$) ]]; then
      ui_error "Ponto invalido" "Informe um caminho absoluto, sem espacos (ex.: /dados)."
      continue
    fi
    if fstab_has_mp "$mp"; then
      ui_error "Ponto em uso" "$mp ja possui entrada no /etc/fstab."
      continue
    fi
    if mountpoint_used "$mp"; then
      ui_error "Ponto montado" "$mp ja esta em uso por outro dispositivo."
      continue
    fi
    if [[ -d $mp && -n $(ls -A "$mp" 2>/dev/null) ]]; then
      ui_error "Diretorio nao vazio" "$mp contem arquivos. Use um diretorio vazio para evitar ocultar dados."
      continue
    fi
    break
  done
  uuid=$(blkid -s UUID -o value "$dev" 2>/dev/null | head -n1)
  if [[ ! $uuid =~ ^[A-Fa-f0-9-]+$ ]]; then
    ui_error "UUID ausente" "Nao foi possivel obter UUID de $dev."
    return 1
  fi
  if fstab_has_uuid "$uuid"; then
    ui_error "UUID em uso" "O UUID $uuid ja possui entrada no /etc/fstab."
    return 1
  fi
  backup="/etc/fstab.bak.$(date +%Y%m%d%H%M%S)"
  line="UUID=$uuid $mp $fstype defaults 0 0"
  append="printf '%s\\n' $(q "$line") >> /etc/fstab"
  cmd_show="mkdir -p $(q "$mp")"$'\n'"mount $(q "$dev") $(q "$mp")"$'\n'"cp -a /etc/fstab $(q "$backup")"$'\n'"$append"
  if ((RHEL_VER >= 7)); then
    cmd_show+=$'\n'"systemctl daemon-reload"
  fi
  confirm_exec "Montar FS e atualizar fstab" "$cmd_show" \
    "Entrada fstab: $line"$'\n'"Backup: $backup"$'\n'"$(version_mount_note)" || return 0
  if ! run_cmd mkdir -p "$mp"; then
    ui_error "Falha ao criar ponto" "A sequencia foi interrompida." "$RUN_OUT"
    return 1
  fi
  if ! run_cmd mount "$dev" "$mp"; then
    ui_error "Falha ao montar" "A sequencia foi interrompida." "$RUN_OUT"
    return 1
  fi
  if ! run_cmd cp -a /etc/fstab "$backup"; then
    run_cmd umount "$mp" >/dev/null 2>&1
    ui_error "Falha no backup do fstab" "A montagem foi revertida." "$RUN_OUT"
    return 1
  fi
  if ! run_shell "$append"; then
    run_cmd umount "$mp" >/dev/null 2>&1
    ui_error "Falha ao atualizar fstab" "A montagem foi revertida." "$RUN_OUT"
    return 1
  fi
  if ((RHEL_VER >= 7)); then
    if ! run_cmd systemctl daemon-reload; then
      ui_error "fstab atualizado" "A entrada foi gravada e o FS esta montado, mas systemctl daemon-reload falhou." "$RUN_OUT"
      return 1
    fi
  fi
  ui_ok "File System montado" "$dev montado em $mp."$'\n'"fstab: $line"
}

network_interfaces() {
  need_bin ip iproute || return 1
  local out
  out=$(printf '=== LINK ===\n'; ip -o link show 2>&1; printf '\n=== IPv4 ===\n'; ip -4 -o addr show 2>&1)
  if command -v nmcli >/dev/null 2>&1; then
    out+=$'\n\n=== NETWORKMANAGER ===\n'"$(nmcli device status 2>&1)"
  fi
  show_text "Interfaces de rede" "$out"
}

select_iface() {
  need_bin ip iproute || return 1
  local -a items=()
  local d name state ip
  for d in /sys/class/net/*; do
    [[ -e $d ]] || continue
    name=${d##*/}
    [[ $name == lo ]] && continue
    state=$(cat "$d/operstate" 2>/dev/null || printf 'unknown')
    ip=$(ip -4 -o addr show dev "$name" 2>/dev/null | awk '{print $4}' | paste -sd, -)
    items+=("$name" "$name | $state | ${ip:-sem IPv4}")
  done
  if ((${#items[@]} == 0)); then
    ui_error "Rede" "Nenhuma interface de rede encontrada."
    return 1
  fi
  show_menu "Interface de rede" "Selecione a interface:" "${items[@]}"
}

find_nm_conn() {
  local d=$1 c
  c=$(nmcli -t -f NAME,DEVICE connection show --active 2>/dev/null |
    awk -F: -v d="$d" '$2==d {print $1; exit}')
  [[ -n $c ]] || c=$(nmcli -t -f NAME,DEVICE connection show 2>/dev/null |
    awk -F: -v d="$d" '$2==d {print $1; exit}')
  printf '%s' "$c"
}

read_network_form() {
  local mode=$1 gw
  NET_MODE=$mode
  NET_IFACE=$(select_iface) || return 1
  NET_IP=$(ask_ipv4 "Configuracao IPv4" "Endereco IP estatico para $NET_IFACE:") || return 1
  NET_PREFIX=$(ask_mask) || return 1
  NET_GW=""
  NET_DNS=""
  if [[ $mode == full ]]; then
    while :; do
      gw=$(ask "Configuracao IPv4" "Gateway padrao:") || return 1
      if ! is_ipv4 "$gw"; then
        ui_error "Gateway invalido" "Informe um endereco IPv4 valido."
        continue
      fi
    if [[ $gw == $NET_IP ]]; then
      ui_error "Gateway invalido" "O gateway nao pode ser igual ao IP da interface."
      continue
    fi
    if ! same_subnet "$NET_IP" "$gw" "$NET_PREFIX"; then
      ui_error "Gateway fora da sub-rede" "$gw nao pertence a $NET_IP/$NET_PREFIX."
      continue
    fi
    NET_GW=$gw
      break
    done
    NET_DNS=$(ask_dns) || return 1
  fi
}

network_mode_label() {
  if [[ $NET_MODE == heartbeat ]]; then
    printf 'heartbeat/isolado (sem gateway e sem DNS)'
  else
    printf 'LAN (gateway + DNS)'
  fi
}

network_result() {
  local out
  sleep 2
  if [[ $NET_MODE == heartbeat ]]; then
    out=$(ip -4 -o addr show dev "$NET_IFACE" 2>&1)
    if printf '%s\n' "$out" | awk '{print $4}' | grep -Fxq "$NET_IP/$NET_PREFIX"; then
      ui_ok "Rede configurada" "IP $NET_IP/$NET_PREFIX aplicado em $NET_IFACE."$'\n'"Perfil heartbeat: sem gateway e sem DNS."
    else
      ui_error "IP nao confirmado" "A configuracao foi gravada, mas $NET_IP/$NET_PREFIX nao aparece em $NET_IFACE." "$out"
    fi
  else
    if out=$(ping -c 2 -W 2 "$NET_GW" 2>&1); then
      ui_ok "Rede configurada" "IP $NET_IP/$NET_PREFIX aplicado em $NET_IFACE."$'\n'"Gateway $NET_GW respondeu ao ping."
    else
      ui_error "Rede configurada sem resposta" "A configuracao foi aplicada, mas o gateway $NET_GW nao respondeu." "$out"
    fi
  fi
}

special_iface() {
  [[ $1 == *.* || $1 =~ ^(bond|br|team|vlan)[0-9] ]]
}

configure_nm() {
  need_bin nmcli NetworkManager || return 1
  local conn cmds extra
  local -a c_add=() c_mod c_up
  conn=$(find_nm_conn "$NET_IFACE")
  cmds=""
  if [[ -z $conn ]]; then
    if special_iface "$NET_IFACE"; then
      ui_error "Interface especial" "$NET_IFACE parece bond/bridge/team/VLAN e nao tem perfil nmcli. Configure manualmente."
      return 1
    fi
    conn="rhel-admin-$NET_IFACE"
    c_add=(nmcli connection add type ethernet ifname "$NET_IFACE" con-name "$conn" autoconnect no)
    cmds+=$(cmd_line "${c_add[@]}")$'\n'
  fi
  if [[ $NET_MODE == heartbeat ]]; then
    c_mod=(nmcli connection modify "$conn" ipv4.method manual
      ipv4.addresses "$NET_IP/$NET_PREFIX" ipv4.gateway "" ipv4.dns ""
      ipv4.ignore-auto-dns yes ipv4.never-default yes connection.autoconnect yes)
  else
    c_mod=(nmcli connection modify "$conn" ipv4.method manual
      ipv4.addresses "$NET_IP/$NET_PREFIX" ipv4.gateway "$NET_GW"
      ipv4.dns "$NET_DNS" ipv4.ignore-auto-dns yes ipv4.never-default no
      connection.autoconnect yes)
  fi
  c_up=(nmcli connection up "$conn")
  cmds+=$(cmd_line "${c_mod[@]}")$'\n'$(cmd_line "${c_up[@]}")
  extra="Interface: $NET_IFACE | Conexao: $conn | Modo: $(network_mode_label)"$'\n'
  extra+="$(version_network_note)"$'\n'
  extra+="Uma mudanca de IP pode interromper a sessao SSH. Use console/IPMI."
  confirm_exec "Configurar rede via nmcli" "$cmds" "$extra" || return 0
  if ((${#c_add[@]} > 0)); then
    if ! run_cmd "${c_add[@]}"; then
      ui_error "Falha ao criar conexao" "A sequencia foi interrompida." "$RUN_OUT"
      return 1
    fi
  fi
  if ! run_cmd "${c_mod[@]}"; then
    ui_error "Falha ao configurar IP" "A sequencia foi interrompida." "$RUN_OUT"
    return 1
  fi
  if ! run_cmd "${c_up[@]}"; then
    ui_error "Falha ao ativar conexao" "A configuracao foi gravada, mas a conexao nao foi ativada." "$RUN_OUT"
    return 1
  fi
  network_result
}

configure_ifcfg() {
  local file backup netmask content d i hw uuid cmds extra
  local -a dns=()
  file="/etc/sysconfig/network-scripts/ifcfg-$NET_IFACE"
  if special_iface "$NET_IFACE"; then
    ui_error "Interface especial" "$NET_IFACE parece bond/bridge/team/VLAN. O script nao reescreve esse ifcfg."
    return 1
  fi
  if [[ -f $file ]] && grep -Eq '^(TYPE=(Bond|Bridge|Vlan|Team)|VLAN=|BRIDGE=|MASTER=|SLAVE=)' "$file"; then
    ui_error "Interface gerenciada" "$file contem bond/bridge/VLAN. Operacao abortada para evitar quebra."
    return 1
  fi
  backup="$file.bak.$(date +%Y%m%d%H%M%S)"
  netmask=$(prefix_to_mask "$NET_PREFIX")
  hw=$(sed -n 's/^HWADDR=//p' "$file" 2>/dev/null | head -n1)
  uuid=$(sed -n 's/^UUID=//p' "$file" 2>/dev/null | head -n1)
  if [[ $NET_MODE == heartbeat ]]; then
    content=$(printf 'DEVICE=%s\nBOOTPROTO=none\nONBOOT=yes\nTYPE=Ethernet\nIPADDR=%s\nNETMASK=%s\nDEFROUTE=no\n' \
      "$NET_IFACE" "$NET_IP" "$netmask")
  else
    IFS=, read -r -a dns <<<"$NET_DNS"
    content=$(printf 'DEVICE=%s\nBOOTPROTO=none\nONBOOT=yes\nTYPE=Ethernet\nIPADDR=%s\nNETMASK=%s\nGATEWAY=%s\nDEFROUTE=yes\n' \
      "$NET_IFACE" "$NET_IP" "$netmask" "$NET_GW")
  fi
  content+=$'\n'
  if [[ $NET_MODE != heartbeat ]]; then
    i=1
    for d in "${dns[@]}"; do
      content+="DNS$i=$d"$'\n'
      i=$((i + 1))
    done
  fi
  [[ -n $hw ]] && content+="HWADDR=$hw"$'\n'
  [[ -n $uuid ]] && content+="UUID=$uuid"$'\n'
  content+="NM_CONTROLLED=no"
  cmds="if [ -f $(q "$file") ]; then cp -a $(q "$file") $(q "$backup"); fi"$'\n'
  cmds+="cat > $(q "$file") <<'__RHEL_IFCFG__'"$'\n'"$content"$'\n'"__RHEL_IFCFG__"$'\n'
  cmds+="chmod 644 $(q "$file")"$'\n'
  cmds+="service network restart"
  extra="Interface: $NET_IFACE | IP: $NET_IP/$NET_PREFIX | Modo: $(network_mode_label)"$'\n'
  extra+="Backup: $backup"$'\n'"$(version_network_note)"$'\n'
  extra+="Uma mudanca de IP pode interromper a sessao SSH. Use console/IPMI."
  confirm_exec "Configurar rede via ifcfg" "$cmds" "$extra" || return 0
  if ! run_shell "$cmds"; then
    ui_error "Falha ao configurar rede" "A sequencia foi interrompida. Verifique console/IPMI e o backup $backup." "$RUN_OUT"
    return 1
  fi
  network_result
}

configure_network() {
  local mode=${1:-full}
  read_network_form "$mode" || return 1
  if ((RHEL_VER >= 7)); then
    configure_nm
  else
    configure_ifcfg
  fi
}

valid_fqdn() {
  [[ $1 =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)*$ && ${#1} -le 253 ]]
}

configure_hostname() {
  local fqdn short ip ts net_backup hosts_backup cmds awkprog outcome cur fq
  while :; do
    fqdn=$(ask "Hostname" "Novo hostname/FQDN (ex.: dboa2palbr009-priv.dcbr01.corp):") || return 1
    valid_fqdn "$fqdn" && break
    ui_error "Hostname invalido" "Use letras, numeros, hifen e pontos; nao inicie/termine com hifen."
  done
  while :; do
    ip=$(ask "Hostname" "IP para /etc/hosts (opcional, Enter para ignorar):") || return 1
    [[ -z $ip ]] && break
    is_ipv4 "$ip" && break
    ui_error "IPv4 invalido" "Informe um IPv4 valido ou deixe vazio."
  done
  short=${fqdn%%.*}
  ts=$(date +%Y%m%d%H%M%S)
  net_backup="/etc/sysconfig/network.bak.$ts"
  hosts_backup="/etc/hosts.bak.$ts"
  cmds=""
  outcome=""
  if ((RHEL_VER >= 7)); then
    need_bin hostnamectl systemd || return 1
    cmds="hostnamectl set-hostname $(q "$fqdn")"
    outcome="RHEL $RHEL_VER: hostnamectl aplica em runtime e persiste. Nao requer reboot."
  else
    cmds="cp -a /etc/sysconfig/network $(q "$net_backup")"$'\n'
    cmds+="if grep -q '^HOSTNAME=' /etc/sysconfig/network; then sed -i $(q "s/^HOSTNAME=.*/HOSTNAME=$fqdn/") /etc/sysconfig/network; else printf 'HOSTNAME=%s\\n' $(q "$fqdn") >> /etc/sysconfig/network; fi"$'\n'
    cmds+="hostname $(q "$fqdn")"
    outcome="RHEL 6: hostname em runtime e persistido em /etc/sysconfig/network. Nao requer reboot."
  fi
  if [[ -n $ip ]]; then
    awkprog='BEGIN{done=0} $1 !~ /^#/ && ($2==fqdn || $2==short || $3==fqdn || $3==short) {if(!done){print ip, fqdn, short; done=1}; next} {print} END{if(!done) print ip, fqdn, short}'
    cmds+=$'\n'"cp -a /etc/hosts $(q "$hosts_backup")"$'\n'
    cmds+="awk -v ip=$(q "$ip") -v fqdn=$(q "$fqdn") -v short=$(q "$short") $(q "$awkprog") /etc/hosts > /etc/hosts.rhel_admin.tmp"$'\n'
    cmds+="mv /etc/hosts.rhel_admin.tmp /etc/hosts"
    outcome+=" /etc/hosts atualizado com $ip $fqdn $short."
  fi
  confirm_exec "Hostname / /etc/hosts" "$cmds" \
    "Atual: $(hostname 2>/dev/null) | Novo: $fqdn"$'\n'"$outcome"$'\n'"Aplicacoes que dependem do hostname podem precisar de restart." || return 0
  if ! run_shell "$cmds"; then
    ui_error "Falha ao alterar hostname" "A sequencia foi interrompida." "$RUN_OUT"
    return 1
  fi
  cur=$(hostname 2>/dev/null)
  fq=$(hostname -f 2>/dev/null)
  ui_ok "Hostname atualizado" "Hostname atual: $cur"$'\n'"FQDN resolvido: ${fq:-nao resolvido}"$'\n\n'"$outcome"$'\n'"Reinicie servicos/aplicacoes dependentes do hostname."
}

batch_path() {
  BATCH_FILE="$SCRIPT_DIR/hosts.batch"
}

batch_local_ready() {
  if [[ ! $BATCH_SSH_USER =~ ^[A-Za-z_][A-Za-z0-9_-]*$ ]]; then
    ui_error "Usuario SSH local invalido" "Valor: ${BATCH_SSH_USER:-vazio}"
    return 1
  fi
  need_bin ssh openssh-clients || return 1
  if [[ $BATCH_SSH_USER != root ]]; then
    need_bin sudo sudo || return 1
  fi
  BATCH_SSH_PREFIX=(ssh)
  if [[ $BATCH_SSH_USER != root ]] && [[ $BATCH_SSH_USER != $(id -un) ]]; then
    BATCH_SSH_PREFIX=(sudo -u "$BATCH_SSH_USER" -H ssh)
    if [[ -n ${SSH_AUTH_SOCK:-} ]] && [[ $(stat -c %U "$SSH_AUTH_SOCK" 2>/dev/null) == "$BATCH_SSH_USER" ]]; then
      BATCH_SSH_PREFIX=(sudo -u "$BATCH_SSH_USER" -H env SSH_AUTH_SOCK="$SSH_AUTH_SOCK" ssh)
    fi
  fi
}

batch_inventory() {
  batch_path
  local model cmds out i
  if [[ ! $BATCH_SSH_USER =~ ^[A-Za-z_][A-Za-z0-9_-]*$ ]]; then
    ui_error "Usuario SSH local invalido" "Valor: ${BATCH_SSH_USER:-vazio}"
    return 1
  fi
  if [[ ! -f $BATCH_FILE ]]; then
    model=$(printf '%s\n' \
      "# Inventario batch - um alvo por linha" \
      "# Formato: [usuario@]host[:porta]" \
      "# Usuario padrao: $BATCH_DEFAULT_USER" \
      "# Exemplos:" \
      "# $BATCH_DEFAULT_USER@10.0.0.10" \
      "# oracle@db02:2222")
    cmds="cat > $(q "$BATCH_FILE") <<'__HOSTS_BATCH__'"$'\n'"$model"$'\n'"__HOSTS_BATCH__"$'\n'
    cmds+="chown $(q "$BATCH_SSH_USER") $(q "$BATCH_FILE")"$'\n'
    cmds+="chmod 600 $(q "$BATCH_FILE")"
    confirm_exec "Criar inventario" "$cmds" "Arquivo: $BATCH_FILE | dono: $BATCH_SSH_USER" || return 0
    if ! run_shell "$cmds"; then
      ui_error "Falha ao criar inventario" "A operacao foi interrompida." "$RUN_OUT"
      return 1
    fi
    ui_ok "Inventario criado" "Edite $BATCH_FILE e adicione um host por linha."$'\n'"Depois use Batch > Testar SSH/sudo." 
    return 0
  fi
  load_inventory || return 1
  out="Arquivo: $BATCH_FILE"$'\n'"Usuario padrao: $BATCH_DEFAULT_USER"$'\n'"Hosts: ${#BATCH_TARGETS[@]}"$'\n\n'
  for ((i = 0; i < ${#BATCH_TARGETS[@]}; i++)); do
    out+=$(printf '%2d  %-32s porta %s' "$((i + 1))" "${BATCH_TARGETS[$i]}" "${BATCH_PORTS[$i]}")$'\n'
  done
  show_text "Inventario batch" "$out"
}

load_inventory() {
  batch_path
  BATCH_TARGETS=()
  BATCH_PORTS=()
  BATCH_NAMES=()
  if [[ ! -r $BATCH_FILE ]]; then
    ui_error "Inventario ausente" "Arquivo nao encontrado: $BATCH_FILE"
    return 1
  fi
  if [[ ! $BATCH_DEFAULT_USER =~ ^[A-Za-z_][A-Za-z0-9_-]*$ ]]; then
    ui_error "Usuario padrao invalido" "Usuario local: $BATCH_DEFAULT_USER"
    return 1
  fi
  local line n=0 user host rest port target errors=""
  local -A seen=()
  while IFS= read -r line || [[ -n $line ]]; do
    n=$((n + 1))
    line=${line//$'\r'/}
    line=${line%%#*}
    line=$(printf '%s' "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    [[ -z $line ]] && continue
    user=$BATCH_DEFAULT_USER
    rest=$line
    if [[ $line =~ ^([A-Za-z_][A-Za-z0-9_-]*)@(.+)$ ]]; then
      user=${BASH_REMATCH[1]}
      rest=${BASH_REMATCH[2]}
    fi
    host=$rest
    port=22
    if [[ $rest =~ ^(.+):([0-9]+)$ ]]; then
      host=${BASH_REMATCH[1]}
      port=$((10#${BASH_REMATCH[2]}))
    fi
    if [[ $host == *:* ]] || ! valid_host "$host"; then
      errors+="linha $n: host invalido '$host' (IPv6 nao suportado)"$'\n'
      continue
    fi
    if ((port < 1 || port > 65535)); then
      errors+="linha $n: porta invalida '$port'"$'\n'
      continue
    fi
    target="$user@$host"
    if [[ -n ${seen["$target:$port"]:-} ]]; then
      errors+="linha $n: alvo duplicado '$target:$port'"$'\n'
      continue
    fi
    seen["$target:$port"]=1
    BATCH_TARGETS+=("$target")
    BATCH_PORTS+=("$port")
    BATCH_NAMES+=("$host")
  done <"$BATCH_FILE"
  if [[ -n $errors ]]; then
    show_text "Inventario invalido" "$errors"
    return 1
  fi
  if ((${#BATCH_TARGETS[@]} == 0)); then
    ui_error "Inventario vazio" "Adicione alvos em $BATCH_FILE"
    return 1
  fi
}

batch_test_ssh() {
  need_bin ssh openssh-clients || return 1
  batch_local_ready || return 1
  load_inventory || return 1
  local i target port out rc st text ok=0 fail=0
  local remote='if [ "$(id -u)" -ne 0 ]; then sudo -n true || exit 42; fi'
  text="SSH local como: $BATCH_SSH_USER"$'\n'
  text+="Teste SSH BatchMode + sudo -n (host key deve estar em known_hosts)"$'\n\n'
  for ((i = 0; i < ${#BATCH_TARGETS[@]}; i++)); do
    target=${BATCH_TARGETS[$i]}
    port=${BATCH_PORTS[$i]}
    if out=$(timeout 12 "${BATCH_SSH_PREFIX[@]}" -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=yes \
      -p "$port" "$target" "$remote" 2>&1); then
      st=OK
      ok=$((ok + 1))
    else
      rc=$?
      if ((rc == 124)); then
        st="TIMEOUT"
      elif ((rc == 255)); then
        st="FALHA SSH/CHAVE"
      elif ((rc == 42)); then
        st="SSH OK | SUDO FALHOU"
      else
        st="FALHA CMD rc=$rc"
      fi
      fail=$((fail + 1))
      st+=" | $(printf '%s' "$out" | tail -n1)"
    fi
    text+=$(printf '%-32s %s' "$target:$port" "$st")$'\n'
  done
  text+=$'\n'"Resumo: ok=$ok falha=$fail"
  show_text "Teste SSH / sudo" "$text"
}

batch_wrap_remote() {
  local remote=$1 need_root=$2 target=$3 user
  user=${target%%@*}
  if ((need_root)) && [[ $user != root ]]; then
    printf 'sudo -n bash -c %s' "$(q "$remote")"
  else
    printf '%s' "$remote"
  fi
}

batch_session_check() {
  tmux has-session -t "$BATCH_SESSION" 2>/dev/null || return 0
  local c
  c=$(show_menu "Sessao TMUX existente" "A sessao '$BATCH_SESSION' ja existe." \
    attach "Anexar a sessao existente" \
    new "Encerrar a sessao e iniciar novo lote" \
    0 "Cancelar") || return 1
  case $c in
    attach)
      tmux attach -t "$BATCH_SESSION"
      batch_report
      return 1
      ;;
    new)
      if ! confirm_exec "Encerrar sessao TMUX" "tmux kill-session -t $(q "$BATCH_SESSION")" \
        "Janelas em execucao serao interrompidas."; then
        return 1
      fi
      run_cmd tmux kill-session -t "$BATCH_SESSION" || {
        ui_error "TMUX" "Nao foi possivel encerrar a sessao $BATCH_SESSION." "$RUN_OUT"
        return 1
      }
      ;;
    0)
      return 1
      ;;
  esac
}

batch_dispatch() {
  local title=$1 remote=$2 need_root=$3 strong=$4 interactive=$5 notes=$6
  need_bin tmux "tmux (RHEL6: EPEL)" || return 1
  batch_local_ready || return 1
  batch_session_check || return 1
  load_inventory || return 1
  local n=${#BATCH_TARGETS[@]}
  local i target port wrapped display all_cmds preview
  local -a spawn_errors=()
  all_cmds=""
  for ((i = 0; i < n; i++)); do
    if ((interactive)); then
      display=$(cmd_line "${BATCH_SSH_PREFIX[@]}" -o ServerAliveInterval=30 -p "${BATCH_PORTS[$i]}" "${BATCH_TARGETS[$i]}")
    else
      wrapped=$(batch_wrap_remote "$remote" "$need_root" "${BATCH_TARGETS[$i]}")
      display=$(cmd_line "${BATCH_SSH_PREFIX[@]}" -o BatchMode=yes -o ConnectTimeout=10 -o ServerAliveInterval=30 \
        -p "${BATCH_PORTS[$i]}" "${BATCH_TARGETS[$i]}" "$wrapped")
    fi
    all_cmds+="$display"$'\n'
  done
  preview="Arquivo: $BATCH_FILE"$'\n'"Hosts: $n | SSH local: $BATCH_SSH_USER"$'\n\n'"Comandos exatos por host:"$'\n'"$all_cmds"
  [[ -n $notes ]] && preview+=$'\n'"$notes"
  if ((interactive)); then
    preview+=$'\n'"SSH interativo como $BATCH_SSH_USER; senha/host key podem ser tratados na janela."
  else
    preview+=$'\n'"SSH local usa chaves de $BATCH_SSH_USER; BatchMode exige host key em known_hosts."
  fi
  ((need_root)) && preview+=$'\n'"Alvos com usuario remoto diferente de root usam sudo -n (NOPASSWD)."
  confirm_batch "$title" "$preview" "$strong" || return 0
  BATCH_DIR=$(mktemp -d "/var/log/rhel_admin_manager.batch.$(date +%Y%m%d-%H%M%S).XXXXXX") || {
    ui_error "Batch" "Nao foi possivel criar diretorio de logs."
    return 1
  }
  chmod 700 "$BATCH_DIR"
  printf '%s\n' "$BATCH_DIR" >"$BATCH_LAST_FILE" 2>/dev/null
  chmod 600 "$BATCH_LAST_FILE" 2>/dev/null
  printf '%s\n' "$title" >"$BATCH_DIR/action.txt"
  : >"$BATCH_DIR/manifest.tsv"
  for ((i = 0; i < n; i++)); do
    printf '%s\t%s\t%s\t%s\n' "$i" "${BATCH_TARGETS[$i]}" "${BATCH_PORTS[$i]}" "${BATCH_NAMES[$i]}" >>"$BATCH_DIR/manifest.tsv"
  done
  cat >"$BATCH_DIR/monitor.sh" <<'MON'
#!/usr/bin/env bash
dir=$(cd "$(dirname "$0")" && pwd)
manifest="$dir/manifest.tsv"
action=$(cat "$dir/action.txt" 2>/dev/null)
while :; do
  clear
  printf 'RHEL Admin Manager - Batch TMUX\nAcao: %s\nDiretorio: %s\n\n' "$action" "$dir"
  printf '%-32s %-20s %s\n' 'ALVO' 'STATUS' 'LOG'
  printf '%s\n' '-------------------------------------------------------------------------------'
  ok=0; fail=0; wait=0; total=0
  while IFS=$'\t' read -r idx target port label; do
    total=$((total + 1))
    status="$dir/status-$idx"
    log="$dir/host-$idx.log"
    if [ -f "$status" ]; then
      IFS=$'\t' read -r rc start end <"$status"
      if [ "$rc" -eq 0 ]; then st="OK"; ok=$((ok + 1))
      elif [ "$rc" -eq 255 ]; then st="FALHA SSH"; fail=$((fail + 1))
      elif [ "$rc" -eq 254 ]; then st="NAO INICIADO"; fail=$((fail + 1))
      elif [ "$rc" -eq 124 ]; then st="TIMEOUT"; fail=$((fail + 1))
      else st="FALHA rc=$rc"; fail=$((fail + 1)); fi
    else
      st="EXECUTANDO"; wait=$((wait + 1))
    fi
    printf '%-32s %-20s %s\n' "$target" "$st" "$log"
  done <"$manifest"
  printf '\nResumo: total=%s ok=%s falha=%s em_execucao=%s\n' "$total" "$ok" "$fail" "$wait"
  printf 'Atualizado: %s | Ctrl+C fecha o monitor\n' "$(date '+%F %T')"
  sleep 3
done
MON
  chmod 700 "$BATCH_DIR/monitor.sh"
  tmux new-session -d -s "$BATCH_SESSION" -n "monitor" "bash $(q "$BATCH_DIR/monitor.sh")" || {
    ui_error "TMUX" "Nao foi possivel criar a sessao $BATCH_SESSION."
    return 1
  }
  tmux set-option -t "$BATCH_SESSION" remain-on-exit on 2>/dev/null
  tmux set-option -t "$BATCH_SESSION" history-limit 50000 2>/dev/null
  for ((i = 0; i < n; i++)); do
    target=${BATCH_TARGETS[$i]}
    port=${BATCH_PORTS[$i]}
    local runfile="$BATCH_DIR/run-$i.sh"
    local outfile="$BATCH_DIR/host-$i.log"
    local statusfile="$BATCH_DIR/status-$i"
    if ((interactive)); then
      wrapped=""
      display=$(cmd_line "${BATCH_SSH_PREFIX[@]}" -o ServerAliveInterval=30 -p "$port" "$target")
    else
      wrapped=$(batch_wrap_remote "$remote" "$need_root" "$target")
      display=$(cmd_line "${BATCH_SSH_PREFIX[@]}" -o BatchMode=yes -o ConnectTimeout=10 -o ServerAliveInterval=30 \
        -p "$port" "$target" "$wrapped")
    fi
    {
      printf '#!/usr/bin/env bash\n'
      printf 'target=%s\n' "$(q "$target")"
      printf 'port=%s\n' "$(q "$port")"
      printf 'remote=%s\n' "$(q "$wrapped")"
      printf 'display=%s\n' "$(q "$display")"
      printf 'outfile=%s\n' "$(q "$outfile")"
      printf 'statusfile=%s\n' "$(q "$statusfile")"
      printf 'logfile=%s\n' "$(q "$LOG_FILE")"
      printf 'loguser=%s\n' "$(q "$LOG_USER")"
      printf 'sshcmd=(%s)\n' "$(cmd_line "${BATCH_SSH_PREFIX[@]}")"
      cat <<'BODY'
start=$(date +%s)
printf '%s | user=%s | status=INICIO | rc=- | cmd=%s\n' "$(date '+%F %T')" "$loguser" "$display" >>"$logfile"
BODY
      if ((interactive)); then
        cat <<'BODY'
"${sshcmd[@]}" -o ServerAliveInterval=30 -p "$port" "$target" 2>&1 | tee "$outfile"
BODY
      else
        cat <<'BODY'
"${sshcmd[@]}" -o BatchMode=yes -o ConnectTimeout=10 -o ServerAliveInterval=30 -p "$port" "$target" "$remote" 2>&1 | tee "$outfile"
BODY
      fi
      cat <<'BODY'
rc=${PIPESTATUS[0]}
end=$(date +%s)
printf '%s\t%s\t%s\n' "$rc" "$start" "$end" >"$statusfile.tmp"
mv "$statusfile.tmp" "$statusfile"
if [ "$rc" -eq 0 ]; then st=SUCESSO; elif [ "$rc" -eq 255 ]; then st=ERRO_SSH; elif [ "$rc" -eq 124 ]; then st=ERRO_TIMEOUT; else st=ERRO_CMD; fi
printf '%s | user=%s | status=%s | rc=%s | cmd=%s\n' "$(date '+%F %T')" "$loguser" "$st" "$rc" "$display" >>"$logfile"
echo
if [ "$rc" -eq 255 ]; then echo "[BATCH] $target FALHA DE SSH/CONEXAO (rc=255)"
elif [ "$rc" -eq 124 ]; then echo "[BATCH] $target TIMEOUT"
elif [ "$rc" -ne 0 ]; then echo "[BATCH] $target FALHA DE EXECUCAO (rc=$rc)"
else echo "[BATCH] $target OK"; fi
echo "[BATCH] log: $outfile"
exit "$rc"
BODY
    } >"$runfile"
    chmod 700 "$runfile"
    local win
    win=$(printf '%s' "${BATCH_NAMES[$i]}" | tr -c 'A-Za-z0-9_.-' '_' | cut -c1-24)
    [[ -n $win ]] || win="host-$i"
    win="$i-$win"
    if ! tmux new-window -d -t "$BATCH_SESSION" -n "$win" "bash $(q "$runfile")" 2>/dev/null; then
      printf '254\t%s\t%s\n' "$(date +%s)" "$(date +%s)" >"$statusfile"
      printf 'Falha ao iniciar a janela tmux para %s\n' "$target" >"$outfile"
      log_event ERRO 254 "batch spawn target=$target session=$BATCH_SESSION"
      spawn_errors+=("$target")
    else
      tmux set-option -t "$BATCH_SESSION:$win" remain-on-exit on 2>/dev/null
    fi
  done
  log_event INICIO 0 "batch tmux=$BATCH_SESSION action=$title hosts=$n dir=$BATCH_DIR remote=$remote"
  tmux select-window -t "$BATCH_SESSION:monitor" 2>/dev/null
  if ((${#spawn_errors[@]} > 0)); then
    ui_error "Batch parcial" "Nao foi possivel abrir janela para: ${spawn_errors[*]}"$'\n'"As demais estao em execucao."
  fi
  if ui_yesno "Batch iniciado" "Sessao TMUX: $BATCH_SESSION"$'\n'"Janelas: $n + monitor"$'\n\n'"Abrir a sessao agora?"; then
    tmux attach -t "$BATCH_SESSION"
    batch_report
  else
    ui_msg "Batch iniciado" "Acompanhe em Batch > Anexar sessao TMUX ($BATCH_SESSION)."$'\n'"Relatorio: Batch > Relatorio do ultimo lote"$'\n\n'"Logs: $BATCH_DIR"
  fi
}

batch_report() {
  local dir=${BATCH_DIR:-}
  if [[ -z $dir || ! -d $dir ]]; then
    [[ -r $BATCH_LAST_FILE ]] && dir=$(cat "$BATCH_LAST_FILE")
  fi
  if [[ -z $dir || ! -d $dir || ! -r $dir/manifest.tsv ]]; then
    ui_error "Relatorio" "Nenhum lote encontrado. Execute um batch primeiro."
    return 1
  fi
  local text idx target port label status log rc start end st dur
  local total=0 ok=0 fail=0 pending=0
  text="Relatorio batch"$'\n'"Diretorio: $dir"$'\n'"Acao: $(cat "$dir/action.txt" 2>/dev/null)"$'\n\n'
  while IFS=$'\t' read -r idx target port label; do
    total=$((total + 1))
    status="$dir/status-$idx"
    log="$dir/host-$idx.log"
    if [[ ! -f $status ]]; then
      st="SEM STATUS (nao iniciou ou ainda executa)"
      pending=$((pending + 1))
      dur="-"
    else
      IFS=$'\t' read -r rc start end <"$status"
      if [[ ! $rc =~ ^[0-9]+$ ]]; then
        st="STATUS INVALIDO"
        dur="-"
        fail=$((fail + 1))
      else
        [[ $start =~ ^[0-9]+$ && $end =~ ^[0-9]+$ ]] && dur=$((end - start))"s" || dur="-"
        if ((rc == 0)); then
          st="OK"
          ok=$((ok + 1))
        elif ((rc == 255)); then
          st="FALHA SSH/CONEXAO"
          fail=$((fail + 1))
        elif ((rc == 254)); then
          st="NAO INICIADO (TMUX)"
          fail=$((fail + 1))
        elif ((rc == 124)); then
          st="TIMEOUT"
          fail=$((fail + 1))
        else
          st="FALHA EXECUCAO rc=$rc"
          fail=$((fail + 1))
        fi
      fi
    fi
    text+=$(printf '%-30s %-28s %-7s %s' "$target:$port" "$st" "$dur" "$log")$'\n'
    if [[ $st == FALHA* || $st == TIMEOUT* || $st == NAO* || $st == STATUS* ]] && [[ -f $log ]]; then
      text+="    $(tail -n 2 "$log" | tr '\n' ' ' | cut -c1-240)"$'\n'
    fi
  done <"$dir/manifest.tsv"
  text+=$'\n'"Resumo: total=$total OK=$ok FALHA=$fail SEM_STATUS=$pending"$'\n'
  text+="Log de auditoria: $LOG_FILE"$'\n'
  text+="Relatorio salvo: $dir/report.txt"
  printf '%s\n' "$text" >"$dir/report.txt"
  chmod 600 "$dir/report.txt" 2>/dev/null
  show_text "Relatorio batch" "$text"
}

batch_patch() {
  local remote
  remote='if command -v dnf >/dev/null 2>&1; then dnf -y update; elif command -v yum >/dev/null 2>&1; then yum -y update; else echo "dnf/yum ausente"; exit 127; fi'
  batch_dispatch "Atualizacao completa" "$remote" 1 0 0 \
    "RHEL 6/7: yum | RHEL 8/9/10: dnf. Kernel novo pode exigir reboot." 
}

batch_security() {
  local remote
  remote='if command -v dnf >/dev/null 2>&1; then dnf -y update --security; elif command -v yum >/dev/null 2>&1; then yum -y update --security; else echo "dnf/yum ausente"; exit 127; fi'
  batch_dispatch "Atualizacao de seguranca" "$remote" 1 0 0 \
    "Requer suporte a --security no gerenciador remoto; RHEL6/7 pode exigir yum-plugin-security."
}

batch_reboot() {
  local remote
  remote='shutdown -r +1 "Reboot agendado por RHEL Admin Manager"'
  batch_dispatch "Reiniciar hosts" "$remote" 1 1 0 \
    "O reboot sera agendado para +1 minuto em cada host. Conexoes serao encerradas."
}

batch_diag() {
  local remote
  remote='echo "=== HOST ==="; hostname; cat /etc/redhat-release 2>/dev/null || cat /etc/os-release 2>/dev/null; echo; uptime; echo; df -hT; echo; free -m; echo; if command -v systemctl >/dev/null 2>&1; then systemctl --failed --no-pager; else echo "systemctl ausente (RHEL6)"; fi; echo; ip -4 -o addr show 2>/dev/null'
  batch_dispatch "Coletar diagnostico" "$remote" 0 0 0 \
    "Coleta somente leitura. Saida individual em host-N.log." 
}

batch_custom() {
  local cmd priv need_root=0
  cmd=$(ask "Comando personalizado" "Comando remoto (sera executado em todos os hosts):") || return 1
  [[ -n $cmd ]] || {
    ui_error "Comando vazio" "Informe um comando."
    return 1
  }
  priv=$(show_menu "Privilegio remoto" "Como executar o comando?" \
    user "Usuario SSH remoto (sem sudo)" \
    sudo "sudo -n (root no host remoto)") || return 1
  [[ $priv == sudo ]] && need_root=1
  batch_dispatch "Comando personalizado" "$cmd" "$need_root" 1 0 \
    "Comando literal exibido acima. Nao inclua senhas: o comando e auditado no log."
}

batch_interactive() {
  batch_dispatch "Sessoes SSH interativas" "" 0 0 1 \
    "Cada janela abre um SSH interativo. Sudo/password podem ser digitados na janela."
}

batch_attach() {
  need_bin tmux "tmux (RHEL6: EPEL)" || return 1
  if ! tmux has-session -t "$BATCH_SESSION" 2>/dev/null; then
    ui_error "TMUX" "Nao existe sessao $BATCH_SESSION."
    return 1
  fi
  tmux attach -t "$BATCH_SESSION"
  batch_report
}

batch_kill_session() {
  need_bin tmux "tmux (RHEL6: EPEL)" || return 1
  if ! tmux has-session -t "$BATCH_SESSION" 2>/dev/null; then
    ui_msg "TMUX" "Nao existe sessao $BATCH_SESSION."
    return 0
  fi
  confirm_exec "Encerrar sessao TMUX" "tmux kill-session -t $(q "$BATCH_SESSION")" \
    "Todas as janelas e comandos em execucao serao encerrados." || return 0
  if ! run_cmd tmux kill-session -t "$BATCH_SESSION"; then
    ui_error "TMUX" "Nao foi possivel encerrar a sessao." "$RUN_OUT"
    return 1
  fi
  ui_ok "TMUX" "Sessao $BATCH_SESSION encerrada."
}

batch_menu() {
  local c
  while :; do
    c=$(show_menu "Batch / Frota (TMUX)" "Arquivo: $BATCH_FILE | SSH local: $BATCH_SSH_USER" \
      1 "Inventario: criar / validar" \
      2 "Testar SSH + sudo -n" \
      3 "Atualizacao completa (yum/dnf)" \
      4 "Atualizacao de seguranca" \
      5 "Reiniciar hosts" \
      6 "Coletar diagnostico" \
      7 "Comando personalizado" \
      8 "Abrir SSH interativo em TMUX" \
      9 "Anexar sessao TMUX" \
      10 "Relatorio do ultimo lote" \
      11 "Encerrar sessao TMUX" \
      0 "Voltar") || return 0
    case $c in
      1) batch_inventory ;;
      2) batch_test_ssh ;;
      3) batch_patch ;;
      4) batch_security ;;
      5) batch_reboot ;;
      6) batch_diag ;;
      7) batch_custom ;;
      8) batch_interactive ;;
      9) batch_attach ;;
      10) batch_report ;;
      11) batch_kill_session ;;
      0) return 0 ;;
    esac
  done
}

test_connectivity() {
  need_bin ping iputils || return 1
  local host port out pout prc tcp_out tcp_rc
  while :; do
    host=$(ask "Teste de conectividade" "Host ou IPv4 de destino:") || return 1
    valid_host "$host" && break
    ui_error "Destino invalido" "Informe um IPv4 ou hostname valido."
  done
  port=$(ask "Teste de conectividade" "Porta TCP (opcional, 1-65535):") || return 1
  if [[ -n $port ]]; then
    if [[ ! $port =~ ^[0-9]+$ ]] || ((10#$port < 1 || 10#$port > 65535)); then
      ui_error "Porta invalida" "Informe uma porta entre 1 e 65535."
      return 1
    fi
  fi
  pout=$(ping -c 2 -W 2 "$host" 2>&1)
  prc=$?
  out="Ping para $host: $([[ $prc -eq 0 ]] && printf 'OK' || printf 'FALHOU')"$'\n'"$pout"
  if [[ -n $port ]]; then
    tcp_out=$(timeout 5 bash -c "echo > /dev/tcp/$host/$port" 2>&1)
    tcp_rc=$?
    out+=$'\n\nTCP '"$host:$port"': '"$([[ $tcp_rc -eq 0 ]] && printf 'OK' || printf 'FALHOU')"$'\n'"${tcp_out:-sem mensagem}"
  fi
  show_text "Teste de conectividade" "$out"
}

rescan_storage() {
  need_bin fdisk util-linux || return 1
  local script cmd out
  script=$(command -v rescan-scsi-bus.sh 2>/dev/null || true)
  if [[ -n $script ]]; then
    cmd="$(q "$script") -l -w"
  else
    cmd='for h in /sys/class/scsi_host/host*/scan; do if [ -e "$h" ]; then echo "- - -" > "$h"; fi; done'
    cmd+=$'\n''for f in /sys/class/fc_host/host*/issue_lip; do if [ -e "$f" ]; then echo 1 > "$f"; fi; done'
  fi
  confirm_exec "Rescan SCSI/FC" "$cmd" \
    "O rescan pode levar alguns segundos e nao requer reboot."$'\n'"RHEL 6-10: usa rescan-scsi-bus.sh (sg3_utils) ou fallback sysfs; valide multipath com multipath -ll." || return 0
  if ! run_shell "$cmd"; then
    ui_error "Falha no rescan" "A operacao foi interrompida." "$RUN_OUT"
    return 1
  fi
  sleep 3
  out=$(lsblk 2>&1)
  out+=$'\n\n=== FDISK -L ===\n'"$(fdisk -l 2>&1)"
  show_text "Discos apos rescan" "$out"
}

list_disks() {
  local out
  out=$(lsblk 2>&1)
  out+=$'\n\n=== FDISK -L ===\n'"$(fdisk -l 2>&1)"
  show_text "Discos e particoes" "$out"
}

diagnostics() {
  local out cpus
  cpus=$(getconf _NPROCESSORS_ONLN 2>/dev/null || grep -c '^processor' /proc/cpuinfo)
  out="=== HOST ===\n$(hostname 2>&1)"$'\n\n'
  out+="=== UPTIME / CARGA ===\n$(uptime 2>&1)"$'\n\n'
  out+="=== CPU ===\nNucleos online: $cpus"$'\n\n'
  out+="=== MEMORIA (MB) ===\n$(free -m 2>&1)"$'\n\n'
  out+="=== DISCOS ===\n$(df -hT 2>&1)"$'\n\n'
  out+="=== TOP CPU ===\n$(ps -eo pid,user,pcpu,pmem,comm --sort=-pcpu 2>&1 | head -n 6)"
  show_text "Diagnostico" "$out"
}

service_status() {
  local -a services
  local out s st en line
  out=""
  if ((RHEL_VER >= 7)); then
    services=(sshd NetworkManager crond rsyslog auditd firewalld chronyd)
    out+="=== SYSTEMD FALHAS ==="$'\n'"$(systemctl --failed --no-pager 2>&1)"$'\n\n'
    out+="SERVICO                ATIVO      HABILITADO"$'\n'
    for s in "${services[@]}"; do
      st=$(systemctl is-active "$s" 2>/dev/null)
      [[ -n $st ]] || st=desconhecido
      en=$(systemctl is-enabled "$s" 2>/dev/null)
      [[ -n $en ]] || en=desconhecido
      printf -v line '%-22s %-10s %s' "$s" "$st" "$en"
      out+="$line"$'\n'
    done
  else
    services=(sshd network crond rsyslog auditd iptables)
    out+="SERVICO                ATIVO      RUNLEVEL 3"$'\n'
    for s in "${services[@]}"; do
      if timeout 5 service "$s" status >/dev/null 2>&1; then
        st=rodando
      else
        st=parado
      fi
      en=$(chkconfig --list "$s" 2>/dev/null |
        awk '{for (i=1; i<=NF; i++) if ($i ~ /^3:/) {split($i,a,":"); print a[2]; exit}}')
      [[ -n $en ]] || en=desconhecido
      printf -v line '%-22s %-10s %s' "$s" "$st" "$en"
      out+="$line"$'\n'
    done
  fi
  show_text "Servicos essenciais" "$out"
}

lvm_menu() {
  local c
  while :; do
    c=$(show_menu "LVM e File Systems" "Operacoes de LVM e filesystems:" \
      1 "Visao geral (PV / VG / LV / FS)" \
      2 "Criar LV (com FS opcional)" \
      3 "Estender LV e FS online" \
      4 "Criar FS em LV existente" \
      5 "Montar FS com UUID no fstab" \
      0 "Voltar") || return 0
    case $c in
      1) lvm_overview ;;
      2) create_lv ;;
      3) extend_lv ;;
      4) create_fs_lv ;;
      5) mount_fs ;;
      0) return 0 ;;
    esac
  done
}

network_menu() {
  local c
  while :; do
    c=$(show_menu "Rede" "RHEL $RHEL_VER | Backend: $(version_network_backend)" \
      1 "Listar interfaces ativas e inativas" \
      2 "IPv4 completo (IP + mascara + gateway + DNS)" \
      3 "IPv4 heartbeat/isolado (sem gateway/DNS)" \
      4 "Testar conectividade (ping / porta)" \
      5 "Definir hostname / /etc/hosts" \
      0 "Voltar") || return 0
    case $c in
      1) network_interfaces ;;
      2) configure_network full ;;
      3) configure_network heartbeat ;;
      4) test_connectivity ;;
      5) configure_hostname ;;
      0) return 0 ;;
    esac
  done
}

storage_menu() {
  local c
  while :; do
    c=$(show_menu "Storage / Discos" "Operacoes de armazenamento:" \
      1 "Rescan SCSI/FC sem reboot" \
      2 "Listar discos e particoes" \
      0 "Voltar") || return 0
    case $c in
      1) rescan_storage ;;
      2) list_disks ;;
      0) return 0 ;;
    esac
  done
}

diag_menu() {
  local c
  while :; do
    c=$(show_menu "Diagnostico" "Monitoramento e servicos:" \
      1 "Resumo (disco, memoria, CPU, uptime)" \
      2 "Status de servicos essenciais" \
      0 "Voltar") || return 0
    case $c in
      1) diagnostics ;;
      2) service_status ;;
      0) return 0 ;;
    esac
  done
}

main_menu() {
  local c
  while :; do
    c=$(show_menu "Menu principal" "$RHEL_LABEL | $(hostname -s 2>/dev/null || hostname) | $(date '+%Y-%m-%d %H:%M')" \
      1 "LVM e File Systems" \
      2 "Rede" \
      3 "Storage / Discos" \
      4 "Diagnostico" \
      5 "Compatibilidade / Riscos da versao" \
      6 "Batch / Frota (TMUX)" \
      7 "Sair") || return 0
    case $c in
      1) lvm_menu ;;
      2) network_menu ;;
      3) storage_menu ;;
      4) diag_menu ;;
      5) show_text "Compatibilidade $RHEL_LABEL" "$(version_profile_text)" ;;
      6) batch_menu ;;
      7) return 0 ;;
    esac
  done
}

main() {
  [[ ${EUID:-$(id -u)} -eq 0 ]] || die "Execute como root: sudo ./$SELF"
  command -v whiptail >/dev/null 2>&1 || die "whiptail nao encontrado. Instale o pacote newt."
  TMP_DIR=$(mktemp -d /tmp/rhel_admin_manager.XXXXXX) || die "Nao foi possivel criar diretorio temporario."
  trap 'rm -rf "$TMP_DIR"' EXIT
  SCRIPT_DIR=$(cd "$(dirname "$(readlink -f "$0" 2>/dev/null || printf '%s' "$0")")" && pwd)
  BATCH_FILE="$SCRIPT_DIR/hosts.batch"
  BATCH_SSH_USER=${BATCH_SSH_USER:-${SUDO_USER:-$(id -un)}}
  BATCH_DEFAULT_USER=${BATCH_DEFAULT_USER:-$BATCH_SSH_USER}
  detect_release
  set_ui
  if ! check_release; then
    return 1
  fi
  LOG_USER=${SUDO_USER:-$(id -un)}
  init_log
  log_event INICIO 0 "inicio da sessao | release=$RELEASE_NAME"
  show_text "Perfil $RHEL_LABEL" "$(version_profile_text)"
  main_menu
  log_event FIM 0 "fim da sessao"
  printf 'Log de auditoria: %s\n' "$LOG_FILE"
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  main "$@"
fi
