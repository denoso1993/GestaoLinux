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
MENU_HINT="  Setas: navegar  |  Enter: selecionar  |  Esc: voltar"
STATUS_TS=0
STATUS_LINE1=""
STATUS_LINE2=""
STATUS_LINE3=""
TMP_DIR=""
RUN_OUT=""
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
BATCH_LAST_FILE=/var/log/rhel_admin_manager.last_batch

die() {
  printf 'ERRO: %s\n' "$*" >&2
  exit 1
}

q() {
  printf '%q' "$1"
}

sh_quote() {
  local s=$1
  s=${s//\'/\'\\\'\'}
  printf "'%s'" "$s"
}

cmd_line() {
  local s
  s=$(printf '%q ' "$@")
  printf '%s' "${s% }"
}

log_event() {
  local status=$1 rc=$2 cmd=$3 detail=${4:-} line
  cmd=$(printf '%s' "$cmd" | tr '\n\r' '; ')
  detail=$(printf '%s' "$detail" | tr '\n\r' '  ')
  line=$(printf '%s | user=%s | status=%s | rc=%s | cmd=%s' \
    "$(date '+%Y-%m-%d %H:%M:%S')" "$LOG_USER" "$status" "$rc" "$cmd")
  [[ -n $detail ]] && line+=" | detail=${detail:0:1500}"
  printf '%s\n' "$line" >>"$LOG_FILE"
}

run_cmd() {
  local out rc preview
  preview=$(printf '%q ' "$@")
  out=$("$@" 2>&1)
  rc=$?
  RUN_OUT=$out
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
  ((UI_H < 16)) && UI_H=16
  ((UI_H > l - 1)) && UI_H=$((l - 1))
  UI_W=$((c - 2))
  ((UI_W < 78)) && UI_W=78
  ((UI_W > c - 2)) && UI_W=$((c - 2))
  MENU_ROWS=$((UI_H - 9))
  ((MENU_ROWS < 5)) && MENU_ROWS=5
}

init_theme() {
  export NEWT_COLORS='root=white,black;roottext=white,black;window=white,black;border=white,black;shadow=black,black;title=yellow,black;button=black,lightgray;actbutton=black,cyan;compactbutton=white,black;textbox=white,black;acttextbox=white,black;entry=white,black;label=white,black;listbox=white,black;actlistbox=black,cyan;sellistbox=white,black;actsellistbox=black,cyan;checkbox=white,black;actcheckbox=black,cyan;helpline=white,black;emptyscale=,black;fullscale=,cyan;disentry=gray,black'
}

ui_footer() {
  printf 'operador %s  |  %s' "${LOG_USER:-$(id -un)}" "$(date '+%H:%M')"
}

ui_rule() {
  local n=$((UI_W - 2))
  ((n < 60)) && n=60
  printf '%*s' "$n" '' | tr ' ' '-'
}

refresh_status() {
  local ip up load mem swap kernel rootpct failed vg lv batch selinux fw
  kernel=$(uname -r 2>/dev/null)
  ip=$(ip -4 -o addr show scope global 2>/dev/null | awk 'NR==1 {print $4}')
  [[ -z $ip ]] && ip=$(hostname -I 2>/dev/null | awk '{print $1}')
  [[ -n $ip ]] || ip="sem-ip"
  up=$(uptime 2>/dev/null | sed 's/^ *//;s/.* up //;s/,.*//;s/^ *//')
  [[ -n $up ]] || up="n/d"
  load=$(cut -d' ' -f1-3 /proc/loadavg 2>/dev/null)
  [[ -n $load ]] || load="n/d"
  mem=$(free -m 2>/dev/null | awk '/^Mem:/ {if ($2 > 0) printf "%d%%", ($3 * 100) / $2}')
  [[ -n $mem ]] || mem="n/d"
  swap=$(free -m 2>/dev/null | awk '/^Swap:/ {if ($2 > 0) printf "%d%%", ($3 * 100) / $2; else printf "off"}')
  [[ -n $swap ]] || swap="n/d"
  rootpct=$(timeout 5 df -P / 2>/dev/null | awk 'NR==2 {gsub("%","",$5); print $5}')
  [[ -n $rootpct ]] || rootpct="?"
  failed="n/d"
  if ((RHEL_VER >= 7)); then
    failed=$(timeout 5 systemctl --failed --no-pager --plain 2>/dev/null | grep -c '\.service')
    [[ $failed =~ ^[0-9]+$ ]] || failed="n/d"
  fi
  vg=$(timeout 5 vgs --noheadings 2>/dev/null | wc -l)
  lv=$(timeout 5 lvs --noheadings 2>/dev/null | wc -l)
  batch="inativa"
  if command -v tmux >/dev/null 2>&1 && timeout 2 tmux has-session -t "$BATCH_SESSION" 2>/dev/null; then
    batch="ativa"
  fi
  selinux=$(getenforce 2>/dev/null)
  [[ -n $selinux ]] || selinux="n/d"
  fw="n/d"
  if ((RHEL_VER >= 7)); then
    fw=$(timeout 3 systemctl is-active firewalld 2>/dev/null)
    [[ -n $fw ]] || fw="n/d"
  elif timeout 3 service iptables status >/dev/null 2>&1; then
    fw="ativo"
  else
    fw="inativo"
  fi
  STATUS_LINE1="  HOST  $(hostname -s 2>/dev/null || hostname)  |  $RHEL_LABEL  |  kernel ${kernel%%-*}  |  $ip"
  STATUS_LINE2="  USO   up $up  |  load $load  |  mem $mem  |  swap $swap  |  / $rootpct%"
  STATUS_LINE3="  SEG   SELinux $selinux  |  fw $fw  |  fail $failed  |  LVM $vg/$lv  |  batch $batch"
  STATUS_TS=$(date +%s)
  if [[ -n $TMP_DIR ]]; then
    printf '%s\t%s\t%s\t%s\n' "$STATUS_TS" "$STATUS_LINE1" "$STATUS_LINE2" "$STATUS_LINE3" >"$TMP_DIR/status.cache"
  fi
}

status_block() {
  local now ts l1 l2 l3 cache="$TMP_DIR/status.cache"
  now=$(date +%s)
  if [[ -n $TMP_DIR && -r $cache ]]; then
    IFS=$'\t' read -r ts l1 l2 l3 <"$cache"
    if [[ $ts =~ ^[0-9]+$ ]] && ((now - ts < 30)); then
      printf '%s\n%s\n%s' "$l1" "$l2" "$l3"
      return
    fi
  fi
  refresh_status
  printf '%s\n%s\n%s' "$STATUS_LINE1" "$STATUS_LINE2" "$STATUS_LINE3"
}

show_menu() {
  local title=$1 prompt=$2
  shift 2
  whiptail --backtitle "$BACKTITLE" --title "$title" \
    --fb --notags --ok-button "Selecionar" --cancel-button "Voltar" \
    --menu "$prompt"$'\n'"$(ui_rule)"$'\n'"$(status_block)"$'\n'"$MENU_HINT"$'\n'"  $(ui_footer)" \
    "$UI_H" "$UI_W" "$MENU_ROWS" "$@" </dev/tty 3>&1 1>&2 2>&3
}

action_command_hint() {
  local item=$1
  case $item in
    "Consultar volumes"*) printf 'pvs; vgs; lvs; timeout 10 df -hT' ;;
    "Consultar interfaces"*) printf 'ip -o link show; ip -4 -o addr show; nmcli device status' ;;
    "Testar conectividade"*) printf 'ping -c 2; teste TCP via /dev/tcp' ;;
    "Consultar rotas"*) printf 'ip route; ip neigh; cat /etc/resolv.conf' ;;
    "Consultar servicos essenciais"*) printf 'systemctl is-active/is-enabled (RHEL 7+) ou service/chkconfig (RHEL 6)' ;;
    "Consultar status ("*) printf 'systemctl status <servico> ou service <servico> status' ;;
    "Consultar logs recentes"*) printf 'journalctl -u <servico> ou tail -n 120 /var/log/messages' ;;
    "Consultar servicos com falha"*) printf 'systemctl --failed (RHEL 7+) ou service --status-all (RHEL 6)' ;;
    "Consultar processos"*) printf 'ps -eo pid,user,pcpu,pmem,comm' ;;
    "Consultar cron"*) printf 'crontab -l; ls /etc/cron.d; systemctl list-timers' ;;
    "Consultar repositorios"*) printf 'dnf repolist ou yum repolist' ;;
    "Consultar atualizacoes"*) printf 'dnf check-update ou yum check-update' ;;
    "Consultar historico"*) printf 'dnf history ou yum history' ;;
    "Buscar pacote"*) printf 'dnf search ou yum search' ;;
    "Consultar informacoes"*) printf 'dnf info ou yum info' ;;
    "Consultar Subscription"*) printf 'subscription-manager status; identity; repos --list-enabled' ;;
    "Consultar firewall"*) printf 'firewall-cmd --state/--list-all ou iptables -L -n -v' ;;
    "Consultar SELinux"*) printf 'sestatus; getenforce' ;;
    "Consultar negacoes"*) printf 'ausearch -m AVC,USER_AVC -ts recent' ;;
    "Auditar configuracao do SSH"*) printf 'sshd -T; ss -tlnp' ;;
    "Testar configuracao do SSH"*) printf 'sshd -t' ;;
    "Consultar data"*) printf 'date; timedatectl; hwclock' ;;
    "Consultar NTP"*) printf 'chronyc tracking ou ntpq -p' ;;
    "Consultar sysctl"*) printf 'sysctl <chaves>; ls /etc/sysctl.d' ;;
    "Consultar boot"*) printf 'uname -r; systemctl get-default; grubby --default-kernel' ;;
    "Consultar compatibilidade"*) printf 'Perfil interno do RHEL (sem comando de sistema)' ;;
    "Consultar uso do swap"*) printf 'cat /proc/swaps; free -m' ;;
    "Consultar discos"*) printf 'lsblk; fdisk -l' ;;
    "Consultar multipath"*) printf 'multipath -ll; leitura de /sys/class/fc_host' ;;
    "Uso de filesystems"*) printf 'timeout 10 df -hT; timeout 10 df -i' ;;
    "Consultar usuarios"*) printf 'getent passwd; getent group; who; last' ;;
    "Logs recentes"*) printf 'journalctl -n 120 ou tail -n 120 /var/log/messages' ;;
    "Consultar logs"*) printf 'journalctl -n 120 ou tail -n 120 /var/log/messages' ;;
    "Consultar ultimas"*|"Consultar erros"*|"Consultar status do arquivo"*) printf 'tail/grep em /var/log/rhel_admin_manager.log' ;;
    "Consultar relatorio"*) printf 'Leitura do relatorio e logs do ultimo lote' ;;
    "Ajuda rapida"*|"Compatibilidade da versao"*) printf 'Conteudo interno do painel (sem comando de sistema).' ;;
    *"(modifica"*) printf 'Os comandos exatos serao exibidos na tela de confirmacao, antes de executar.' ;;
    *"(destrutivo"*) printf 'Os comandos exatos serao exibidos; a execucao exige digitar SIM.' ;;
    *"(interativo"*) printf 'Abre uma sessao SSH interativa; nada e executado automaticamente.' ;;
    *"(contem acoes"*|*"(abre menu"*|*"(abre opcoes"*) printf 'A proxima tela lista as acoes e o impacto de cada uma.' ;;
    *"(somente leitura"*) printf 'Somente comandos de leitura; o resultado sera exibido.' ;;
    *) printf 'Consulte a proxima tela para ver os parametros e comandos.' ;;
  esac
}

select_action() {
  local title=$1 prompt=$2
  shift 2
  local -a raw=("$@") display=()
  local i tag item impact hint text
  for ((i = 0; i < ${#raw[@]}; i += 2)); do
    if [[ ${raw[$i]} == 0 ]]; then
      display+=("${raw[$i]}" "${raw[$((i + 1))]}")
    else
      display+=("${raw[$i]}" "${raw[$((i + 1))]}  [detalhes]")
    fi
  done
  MENU_HINT="  Setas: navegar  |  Enter: abrir detalhes e riscos  |  Esc: voltar"
  tag=$(show_menu "$title" "$prompt" "${display[@]}") || return 1
  for ((i = 0; i < ${#raw[@]}; i += 2)); do
    if [[ ${raw[$i]} == "$tag" ]]; then
      item=${raw[$((i + 1))]}
      break
    fi
  done
  [[ -n $item ]] || item=$tag
  case $item in
    *"(destrutivo"*) impact=destrutivo ;;
    *"(modifica"*) impact=modifica ;;
    *"(somente leitura"*) impact=leitura ;;
    *"(interativo"*) impact=interativo ;;
    *"(contem acoes"*|*"(abre menu"*|*"(abre opcoes"*) impact=menu ;;
    *) impact=info ;;
  esac
  hint=$(action_command_hint "$item")
  text=$'== ACAO SELECIONADA ==\n'"$item"
  text+=$'\n\n== O QUE ACONTECE ==\n'
  case $impact in
    leitura) text+="Esta opcao apenas consulta o sistema. Nenhuma alteracao sera feita." ;;
    modifica) text+="Esta opcao inicia uma alteracao. Nada sera executado agora. Voce informara os parametros e revisara os comandos exatos antes de confirmar." ;;
    destrutivo) text+="Esta opcao pode remover dados, interromper servicos ou bloquear acesso. Nada sera executado agora. Voce revisara os comandos e digitara SIM para confirmar." ;;
    interativo) text+="Esta opcao abre uma sessao interativa. Nenhuma alteracao automatica sera feita." ;;
    menu) text+="Esta opcao abre a proxima tela de escolhas. Nenhuma alteracao sera feita agora." ;;
    *) text+="Esta opcao abre a proxima tela do painel." ;;
  esac
  text+=$'\n\n== COMANDOS ==\n'"$hint"
  text+=$'\n\n== RISCOS E CUIDADOS ==\n'
  case $impact in
    leitura) text+="Classificacao: BAIXO (somente leitura)."$'\n'"Sem risco de escrita: apenas leitura de dados do sistema." ;;
    modifica) text+="Classificacao: MEDIO (modifica o sistema)."$'\n'"Pode alterar configuracao do sistema. Backup e confirmacao sao aplicados quando cabivel." ;;
    destrutivo) text+="Classificacao: ALTO (destrutivo)."$'\n'"Risco alto: perda de dados, indisponibilidade ou perda de acesso remoto. Use console/IPMI quando a rede for afetada." ;;
    interativo) text+="Classificacao: VARIAVEL (interativo)."$'\n'"O risco depende do que voce executar na sessao. O painel nao executa nada sozinho." ;;
    menu) text+="Classificacao: BAIXO (navegacao)."$'\n'"Apenas navegacao; nenhuma alteracao agora." ;;
    *) text+="Classificacao: INDEFINIDA."$'\n'"Sem impacto conhecido." ;;
  esac
  text+=$'\n\n== PROXIMO PASSO ==\n'
  case $impact in
    leitura|interativo|menu|info) text+="Feche esta tela para continuar." ;;
    *) text+="Feche esta tela e confirme 'Continuar' para informar os parametros." ;;
  esac
  show_text "Detalhes - $title" "$text" || return 1
  case $impact in
    modifica|destrutivo)
      ui_yesno "Continuar" "Deseja abrir a configuracao desta acao?" || return 1
      ;;
  esac
  printf '%s' "$tag"
}

ask() {
  local title=$1 prompt=$2 default=${3:-} ans
  ans=$(whiptail --backtitle "$BACKTITLE" --title "$title" --fb \
    --ok-button "Confirmar" --cancel-button "Cancelar" --inputbox \
    "$prompt" 12 "$UI_W" "$default" </dev/tty 3>&1 1>&2 2>&3) || return 1
  ans=$(printf '%s' "$ans" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
  printf '%s' "$ans"
}

ui_msg() {
  local h=14
  ((h > UI_H)) && h=$UI_H
  whiptail --backtitle "$BACKTITLE" --title "$1" --fb --ok-button "Entendi" --msgbox "$2" "$h" "$UI_W"
}

ui_error() {
  local title=$1 msg=$2 detail=${3:-} text h=20
  text=$'== ERRO ==\n'"$msg"
  if [[ -n $detail ]]; then
    text+=$'\n\n== SAIDA (ULTIMAS LINHAS) ==\n'"$(printf '%s' "$detail" | tail -n 12)"
  fi
  text+=$'\n\n== AUDITORIA ==\n'"$LOG_FILE"
  ((h > UI_H)) && h=$UI_H
  whiptail --backtitle "$BACKTITLE" --title "ERRO - $title" --fb --ok-button "Entendi" --msgbox "$text" "$h" "$UI_W"
}

ui_ok() {
  local h=14
  ((h > UI_H)) && h=$UI_H
  whiptail --backtitle "$BACKTITLE" --title "$1" --fb --ok-button "OK" --msgbox "$2"$'\n\n== AUDITORIA ==\n'"$LOG_FILE" "$h" "$UI_W"
}

confirm_exec() {
  local title=$1 cmds=$2 extra=${3:-} text
  text=$'== COMANDOS EXATOS ==\n\n'"$cmds"
  [[ -n $extra ]] && text+=$'\n\n== IMPACTO / OBSERVACOES ==\n'"$extra"
  text+=$'\n\n== AUDITORIA ==\n'"$LOG_FILE"
  show_text "CONFIRMAR - $title" "$text" || return 1
  ui_yesno "Executar" "Confirme a execucao dos comandos exibidos."
}

confirm_strong() {
  local title=$1 cmds=$2 ans
  show_text "CONFIRMAR - $title" \
    $'== OPERACAO DESTRUTIVA ==\n\n'"$cmds"$'\n\n== CONFIRMACAO ==\n'"Digite SIM na proxima tela para continuar." || return 1
  ans=$(whiptail --backtitle "$BACKTITLE" --title "CONFIRMAR - $title" --fb \
    --ok-button "Confirmar" --cancel-button "Cancelar" --inputbox \
    "Digite SIM para confirmar:" 10 "$UI_W" "" </dev/tty 3>&1 1>&2 2>&3) || return 1
  [[ $ans == SIM ]]
}

ui_yesno() {
  local h=14
  ((h > UI_H)) && h=$UI_H
  whiptail --backtitle "$BACKTITLE" --title "$1" --fb --defaultno \
    --yes-button "Confirmar" --no-button "Cancelar" --yesno "$2" "$h" "$UI_W" </dev/tty >/dev/tty 2>&1
}

confirm_batch() {
  local title=$1 text=$2 strong=$3 ans
  show_text "CONFIRMAR BATCH - $title" \
    "$text"$'\n\n== MODO ==\n'"$([[ $strong == 1 ]] && printf 'DESTRUTIVO: sera exigido SIM.' || printf 'Paralelo via TMUX.')"$'\n'"Revise os comandos acima antes de confirmar." || return 1
  if ((strong)); then
    ans=$(whiptail --backtitle "$BACKTITLE" --title "CONFIRMAR - $title" --fb \
      --ok-button "Confirmar" --cancel-button "Cancelar" --inputbox \
      "Digite SIM para confirmar:" 10 "$UI_W" "" </dev/tty 3>&1 1>&2 2>&3) || return 1
    [[ $ans == SIM ]]
  else
    ui_yesno "Executar batch" "Executar os comandos exibidos na sessao $BATCH_SESSION?"
  fi
}

show_text() {
  local title=$1 text=$2 f
  f=$(mktemp "$TMP_DIR/text.XXXXXX") || return 1
  printf '%s\n' "$text" >"$f"
  whiptail --backtitle "$BACKTITLE" --title "$title" --fb --ok-button "Fechar" \
    --scrolltext --textbox "$f" "$UI_H" "$UI_W" </dev/tty >/dev/tty 2>&1
  local rc=$?
  rm -f "$f"
  return "$rc"
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
  BACKTITLE="  RHEL Admin Manager  |  $RHEL_LABEL  |  $(hostname -s 2>/dev/null || hostname)  "
}

check_release() {
  if ((RHEL_VER < 6 || RHEL_VER > 10)); then
    ui_error "Release nao suportada" "Release detectada: $RELEASE_NAME"$'\n'"Este script suporta RHEL 6, 7, 8, 9 e 10."
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
  timeout 5 blkid -o value -s TYPE "$1" 2>/dev/null | head -n1
}

mountpoint_of() {
  local dev=$1 real mp=""
  real=$(readlink -f "$dev" 2>/dev/null || printf '%s' "$dev")
  if command -v findmnt >/dev/null 2>&1; then
    mp=$(findmnt -n -o TARGET "$dev" 2>/dev/null | head -n1)
  fi
  if [[ -z $mp ]] && command -v lsblk >/dev/null 2>&1; then
    mp=$(timeout 5 lsblk -no MOUNTPOINT "$dev" 2>/dev/null | awk 'NF {print; exit}')
  fi
  if [[ -z $mp ]]; then
    mp=$(awk -v d="$dev" -v r="$real" '$1==d || $1==r {print $2; exit}' /proc/mounts)
  fi
  printf '%s' "$mp"
}

device_mounted() {
  local dev=$1 mp mm
  mp=$(mountpoint_of "$dev")
  [[ -n $mp ]] && return 0
  if command -v lsblk >/dev/null 2>&1; then
    mm=$(timeout 5 lsblk -dn -o MAJ:MIN "$dev" 2>/dev/null | awk 'NR==1 {print $1}')
    [[ -n $mm ]] && awk -v mm="$mm" '$3==mm {found=1} END {exit !found}' /proc/self/mountinfo && return 0
  fi
  return 1
}

mountpoint_used() {
  local mp=$1
  if command -v findmnt >/dev/null 2>&1 && findmnt -n -o TARGET "$mp" >/dev/null 2>&1; then
    return 0
  fi
  awk -v m="$mp" '$2==m {found=1} END {exit !found}' /proc/mounts
}

in_swap() {
  local dev=$1 real line
  real=$(readlink -f "$dev" 2>/dev/null)
  while read -r line _; do
    [[ $line == Filename ]] && continue
    [[ $line == "$dev" || $line == "$real" ]] && return 0
    [[ $(readlink -f "$line" 2>/dev/null) == "$real" ]] && return 0
  done < /proc/swaps
  return 1
}

vg_free_bytes() {
  local bytes
  bytes=$(timeout 5 vgs --noheadings --units b --nosuffix -o vg_free "$1" 2>/dev/null |
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
  done < <(timeout 10 vgs --noheadings -o vg_name,vg_free 2>/dev/null)
  if ((${#items[@]} == 0)); then
    ui_error "LVM" "Nenhum Volume Group encontrado."
    return 1
  fi
  show_menu "Selecionar VG" "Volume Group:" "${items[@]}"
}

select_lv() {
  need_bin lvs lvm2 || return 1
  local -a items=()
  local vg lv size attr
  while read -r vg lv size attr; do
    [[ -n $vg && -n $lv ]] || continue
    case ${attr:0:1} in
      t|s|V) continue ;;
    esac
    items+=("$vg/$lv" "$vg/$lv | $size")
  done < <(timeout 10 lvs --noheadings -o vg_name,lv_name,lv_size,lv_attr 2>/dev/null)
  if ((${#items[@]} == 0)); then
    ui_error "LVM" "Nenhum Logical Volume simples encontrado (thin/snapshot sao omitidos)."
    return 1
  fi
  show_menu "Selecionar LV" "Logical Volume (thin/snapshot omitidos):" "${items[@]}"
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
  done < <(timeout 10 blkid -o device 2>/dev/null | sort -u)
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
    timeout 10 pvs 2>&1
    printf '\n=== VOLUME GROUPS ===\n'
    timeout 10 vgs 2>&1
    printf '\n=== LOGICAL VOLUMES ===\n'
    timeout 10 lvs 2>&1
    printf '\n=== FILESYSTEMS ===\n'
    timeout 10 df -hT 2>&1
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
    if timeout 5 lvs "$vg/$name" >/dev/null 2>&1; then
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
    size=$(ask "Criar LV" "Tamanho do LV (ex.: 50G, 512M)."$'\n'"Espaco livre em $vg: $((free / 1048576)) MB") || return 1
    size=${size^^}
    valid_size "$size" || {
      ui_error "Tamanho invalido" "Use numero inteiro seguido de K, M, G ou T (ex.: 50G)."
      continue
    }
    bytes=$(size_bytes "$size")
    ((bytes <= free)) && break
    ui_error "Espaco insuficiente" "Solicitado: $size"$'\n'"Livre no VG: $((free / 1048576)) MB"
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
    size=$(ask "Estender LV" "Tamanho a adicionar (ex.: 10G)."$'\n'"Livre em $vg: $((free / 1048576)) MB") || return 1
    size=${size^^}
    valid_size "$size" || {
      ui_error "Tamanho invalido" "Use numero inteiro seguido de K, M, G ou T."
      continue
    }
    bytes=$(size_bytes "$size")
    ((bytes <= free)) && break
    ui_error "Espaco insuficiente" "Solicitado: $size"$'\n'"Livre no VG: $((free / 1048576)) MB"
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
  if device_mounted "$dev"; then
    mp=$(mountpoint_of "$dev")
    ui_error "LV montado" "Desmonte $dev${mp:+ (montado em $mp)} antes de formatar."
    return 1
  fi
  if in_swap "$dev"; then
    ui_error "LV em swap" "$dev esta em uso como swap. Desative antes de formatar."
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
  if device_mounted "$dev"; then
    mp_now=$(mountpoint_of "$dev")
    ui_error "Dispositivo montado" "$dev${mp_now:+ ja esta montado em $mp_now}."
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
  uuid=$(timeout 5 blkid -s UUID -o value "$dev" 2>/dev/null | head -n1)
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
  cmd_show="install -d -m 755 $(q "$mp")"$'\n'"mount $(q "$dev") $(q "$mp")"$'\n'"cp -a /etc/fstab $(q "$backup")"$'\n'"$append"
  if ((RHEL_VER >= 7)); then
    cmd_show+=$'\n'"systemctl daemon-reload"
  fi
  confirm_exec "Montar FS e atualizar fstab" "$cmd_show" \
    "Entrada fstab: $line"$'\n'"Backup: $backup"$'\n'"$(version_mount_note)" || return 0
  if ! run_cmd install -d -m 755 "$mp"; then
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

select_mounted_device() {
  need_bin blkid util-linux || return 1
  local -a items=()
  local dev fs mp
  while read -r dev; do
    [[ -b $dev ]] || continue
    mp=$(mountpoint_of "$dev")
    [[ -n $mp ]] || continue
    fs=$(fs_type "$dev")
    items+=("$dev" "$dev | $fs | $mp")
  done < <(timeout 10 blkid -o device 2>/dev/null | sort -u)
  if ((${#items[@]} == 0)); then
    ui_error "File Systems" "Nenhum filesystem montado detectado."
    return 1
  fi
  show_menu "Selecionar dispositivo montado" "Dispositivo em uso:" "${items[@]}"
}

unmount_fs() {
  local dev mp backup cmd_show remove_cmd awkprog has_fstab=0
  dev=$(select_mounted_device) || return 1
  mp=$(mountpoint_of "$dev")
  if [[ -z $mp ]]; then
    ui_error "File Systems" "$dev nao esta montado."
    return 1
  fi
  case $mp in
    /|/boot|/boot/efi|/usr|/var|/var/log|/var/lib|/etc|/dev|/proc|/sys|/run|/run/*)
      ui_error "Operacao bloqueada" "Desmontar $mp nao e permitido por seguranca."
      return 1
      ;;
  esac
  backup="/etc/fstab.bak.$(date +%Y%m%d%H%M%S)"
  if fstab_has_mp "$mp"; then
    has_fstab=1
  fi
  cmd_show="umount $(q "$mp")"
  if ((has_fstab)); then
    awkprog='$1 !~ /^[[:space:]]*#/ && $2==mp {next} {print}'
    remove_cmd="awk -v mp=$(q "$mp") $(q "$awkprog") /etc/fstab > /etc/fstab.rhel_admin.tmp"$'\n'
    remove_cmd+="chmod --reference=/etc/fstab /etc/fstab.rhel_admin.tmp"$'\n'
    remove_cmd+="mv /etc/fstab.rhel_admin.tmp /etc/fstab"
    cmd_show+=$'\n'"cp -a /etc/fstab $(q "$backup")"$'\n'"$remove_cmd"
    ((RHEL_VER >= 7)) && cmd_show+=$'\n'"systemctl daemon-reload"
  fi
  confirm_strong "Desmontar File System" "$cmd_show" \
    "Dispositivo: $dev"$'\n'"Ponto: $mp"$'\n'"A remocao do fstab usa backup $backup." || return 0
  if ! run_cmd umount "$mp"; then
    ui_error "Falha ao desmontar" "A sequencia foi interrompida; o fstab nao foi alterado." "$RUN_OUT"
    return 1
  fi
  if ((has_fstab)); then
    if ! run_cmd cp -a /etc/fstab "$backup"; then
      if run_cmd mount "$dev" "$mp" >/dev/null 2>&1; then
        ui_error "Falha no backup do fstab" "O FS foi remontado." "$RUN_OUT"
      else
        ui_error "Falha no backup do fstab" "O FS permanece desmontado; monte manualmente." "$RUN_OUT"
      fi
      return 1
    fi
    if ! run_shell "$remove_cmd"; then
      if run_cmd mount "$dev" "$mp" >/dev/null 2>&1; then
        ui_error "Falha ao atualizar fstab" "O FS foi remontado; o backup esta em $backup." "$RUN_OUT"
      else
        ui_error "Falha ao atualizar fstab" "O FS permanece desmontado; monte manualmente. Backup: $backup" "$RUN_OUT"
      fi
      return 1
    fi
    if ((RHEL_VER >= 7)); then
      if ! run_cmd systemctl daemon-reload; then
        ui_error "fstab atualizado" "O FS foi desmontado, mas o daemon-reload falhou." "$RUN_OUT"
        return 1
      fi
    fi
  fi
  ui_ok "File System desmontado" "$dev desmontado de $mp."$'\n'"$( ((has_fstab)) && printf 'Entrada removida do fstab com backup em %s.' "$backup" || printf 'Nao havia entrada no fstab.' )"
}

delete_lv() {
  need_bin lvremove lvm2 || return 1
  local sel dev mp
  sel=$(select_lv) || return 1
  dev="/dev/$sel"
  [[ -b $dev ]] || {
    ui_error "LVM" "Dispositivo nao encontrado: $dev"
    return 1
  }
  if device_mounted "$dev"; then
    mp=$(mountpoint_of "$dev")
    ui_error "LV em uso" "$dev${mp:+ esta montado em $mp}. Desmonte antes de excluir."
    return 1
  fi
  if in_swap "$dev"; then
    ui_error "LV em swap" "$dev esta em uso como swap. Desative antes de excluir."
    return 1
  fi
  confirm_strong "Excluir Logical Volume" "lvremove -f $(q "$dev")" \
    "LV: $dev"$'\n'"Todos os dados e assinaturas deste LV serao removidos." || return 0
  if ! run_cmd lvremove -f "$dev"; then
    ui_error "Falha ao excluir LV" "A operacao foi interrompida." "$RUN_OUT"
    return 1
  fi
  ui_ok "LV excluido" "$dev removido."
}

network_interfaces() {
  need_bin ip iproute || return 1
  local out
  out=$(printf '=== LINK ===\n'; ip -o link show 2>&1; printf '\n=== IPv4 ===\n'; ip -4 -o addr show 2>&1)
  if command -v nmcli >/dev/null 2>&1; then
    out+=$'\n\n=== NETWORKMANAGER ===\n'"$(timeout 5 nmcli device status 2>&1)"
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
  c=$(timeout 5 nmcli -t -f NAME,DEVICE connection show --active 2>/dev/null |
    awk -F: -v d="$d" '$2==d {print $1; exit}')
  [[ -n $c ]] || c=$(timeout 5 nmcli -t -f NAME,DEVICE connection show 2>/dev/null |
    awk -F: -v d="$d" '$2==d {print $1; exit}')
  printf '%s' "$c"
}

nm_profile_is_slave() {
  local conn=$1 master slave
  master=$(timeout 5 nmcli -g connection.master connection show "$conn" 2>/dev/null)
  slave=$(timeout 5 nmcli -g connection.slave-type connection show "$conn" 2>/dev/null)
  [[ -n $master && $master != "--" ]] || [[ -n $slave && $slave != "--" ]]
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
    if [[ $gw == "$NET_IP" ]]; then
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
  if [[ -n $conn ]] && nm_profile_is_slave "$conn"; then
    ui_error "Perfil slave" "$conn e slave de bond/bridge/team. Configure o perfil mestre, nao o slave."
    return 1
  fi
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
  confirm_strong "Configurar rede via nmcli" "$cmds" "$extra" || return 0
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
  confirm_strong "Configurar rede via ifcfg" "$cmds" "$extra" || return 0
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
    cmds+="chmod --reference=/etc/hosts /etc/hosts.rhel_admin.tmp"$'\n'
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
  fq=$(timeout 5 hostname -f 2>/dev/null)
  ui_ok "Hostname atualizado" "Hostname atual: $cur"$'\n'"FQDN resolvido: ${fq:-nao resolvido}"$'\n\n'"$outcome"$'\n'"Reinicie servicos/aplicacoes dependentes do hostname."
}

network_details() {
  need_bin ip iproute || return 1
  local out
  out="=== ENDERECOS IPv4 ==="$'\n'"$(ip -4 -o addr show 2>&1)"$'\n\n'
  out+="=== ROTAS ==="$'\n'"$(ip route show 2>&1)"$'\n\n'
  out+="=== NEIGHBORS / ARP ==="$'\n'"$(ip neigh show 2>&1)"$'\n\n'
  out+="=== RESOLV.CONF ==="$'\n'"$(cat /etc/resolv.conf 2>&1)"
  if command -v nmcli >/dev/null 2>&1; then
    out+=$'\n\n'"=== NETWORKMANAGER DEVICE STATUS ==="$'\n'"$(timeout 5 nmcli device status 2>&1)"
  fi
  show_text "Rede - rotas, DNS e ARP" "$out"
}

dhcp_result() {
  local iface=$1 ip
  sleep 2
  ip=$(ip -4 -o addr show dev "$iface" 2>/dev/null | awk 'NR==1 {print $4}')
  if [[ -n $ip ]]; then
    ui_ok "DHCP configurado" "Interface $iface obteve $ip."
  else
    ui_error "DHCP sem endereco" "A configuracao foi aplicada, mas $iface nao recebeu IPv4."
  fi
}

configure_dhcp() {
  local iface conn file backup content hw uuid cmds cmds_extra
  local -a c_add=() c_mod c_up
  if ((RHEL_VER >= 7)); then
    need_bin nmcli NetworkManager || return 1
    iface=$(select_iface) || return 1
    conn=$(find_nm_conn "$iface")
    if [[ -n $conn ]] && nm_profile_is_slave "$conn"; then
      ui_error "Perfil slave" "$conn e slave de bond/bridge/team. Configure o perfil mestre."
      return 1
    fi
    cmds=""
    if [[ -z $conn ]]; then
      if special_iface "$iface"; then
        ui_error "Interface especial" "$iface nao tem perfil nmcli. Configure manualmente."
        return 1
      fi
      conn="rhel-admin-$iface"
      c_add=(nmcli connection add type ethernet ifname "$iface" con-name "$conn" autoconnect no)
      cmds+=$(cmd_line "${c_add[@]}")$'\n'
    fi
    c_mod=(nmcli connection modify "$conn" ipv4.method auto ipv4.addresses "" ipv4.gateway ""
      ipv4.dns "" ipv4.never-default no ipv4.ignore-auto-dns no connection.autoconnect yes)
    c_up=(nmcli connection up "$conn")
    cmds+=$(cmd_line "${c_mod[@]}")$'\n'$(cmd_line "${c_up[@]}")
    cmds_extra="Interface: $iface | Conexao: $conn | Modo: DHCP"$'\n'"$(version_network_note)"$'\n'
    cmds_extra+="A mudanca pode interromper a sessao SSH. Use console/IPMI."
    confirm_strong "Configurar DHCP via nmcli" "$cmds" "$cmds_extra" || return 0
    if ((${#c_add[@]} > 0)); then
      if ! run_cmd "${c_add[@]}"; then
        ui_error "Falha ao criar conexao" "A sequencia foi interrompida." "$RUN_OUT"
        return 1
      fi
    fi
    if ! run_cmd "${c_mod[@]}"; then
      ui_error "Falha ao configurar DHCP" "A sequencia foi interrompida." "$RUN_OUT"
      return 1
    fi
    if ! run_cmd "${c_up[@]}"; then
      ui_error "Falha ao ativar conexao" "A configuracao foi gravada, mas a conexao nao foi ativada." "$RUN_OUT"
      return 1
    fi
    dhcp_result "$iface"
    return
  fi
  iface=$(select_iface) || return 1
  file="/etc/sysconfig/network-scripts/ifcfg-$iface"
  if special_iface "$iface"; then
    ui_error "Interface especial" "$iface parece bond/bridge/team/VLAN. Operacao abortada."
    return 1
  fi
  if [[ ! -f $file ]]; then
    ui_error "ifcfg ausente" "Arquivo nao encontrado: $file"
    return 1
  fi
  if grep -Eq '^(TYPE=(Bond|Bridge|Vlan|Team)|VLAN=|BRIDGE=|MASTER=|SLAVE=)' "$file"; then
    ui_error "Interface gerenciada" "$file contem bond/bridge/VLAN. Operacao abortada."
    return 1
  fi
  backup="$file.bak.$(date +%Y%m%d%H%M%S)"
  hw=$(sed -n 's/^HWADDR=//p' "$file" 2>/dev/null | head -n1)
  uuid=$(sed -n 's/^UUID=//p' "$file" 2>/dev/null | head -n1)
  content=$(printf 'DEVICE=%s\nBOOTPROTO=dhcp\nONBOOT=yes\nTYPE=Ethernet\n' "$iface")
  content+=$'\n'
  [[ -n $hw ]] && content+="HWADDR=$hw"$'\n'
  [[ -n $uuid ]] && content+="UUID=$uuid"$'\n'
  content+="NM_CONTROLLED=no"
  cmds="cp -a $(q "$file") $(q "$backup")"$'\n'
  cmds+="cat > $(q "$file") <<'__RHEL_IFCFG_DHCP__'"$'\n'"$content"$'\n'"__RHEL_IFCFG_DHCP__"$'\n'
  cmds+="chmod 644 $(q "$file")"$'\n'
  cmds+="service network restart"
  cmds_extra="Interface: $iface | Modo: DHCP | Backup: $backup"$'\n'"$(version_network_note)"$'\n'
  cmds_extra+="A mudanca pode interromper a sessao SSH. Use console/IPMI."
  confirm_strong "Configurar DHCP via ifcfg" "$cmds" "$cmds_extra" || return 0
  if ! run_shell "$cmds"; then
    ui_error "Falha ao configurar DHCP" "A sequencia foi interrompida. Backup: $backup" "$RUN_OUT"
    return 1
  fi
  dhcp_result "$iface"
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
  local model cmds out i model_file
  if [[ ! $BATCH_SSH_USER =~ ^[A-Za-z_][A-Za-z0-9_-]*$ ]]; then
    ui_error "Usuario SSH local invalido" "Valor: ${BATCH_SSH_USER:-vazio}"
    return 1
  fi
  if [[ ! $BATCH_DEFAULT_USER =~ ^[A-Za-z_][A-Za-z0-9_-]*$ ]]; then
    ui_error "Usuario remoto padrao invalido" "Valor: ${BATCH_DEFAULT_USER:-vazio}"
    return 1
  fi
  if [[ -L $BATCH_FILE ]]; then
    ui_error "Inventario inseguro" "$BATCH_FILE e um symlink. Remova antes de continuar."
    return 1
  fi
  if [[ -e $BATCH_FILE && ! -f $BATCH_FILE ]]; then
    ui_error "Inventario invalido" "$BATCH_FILE nao e um arquivo regular."
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
    model_file="$TMP_DIR/hosts.batch.model"
    cmds="cat > $(q "$model_file") <<'__HOSTS_BATCH__'"$'\n'"$model"$'\n'"__HOSTS_BATCH__"$'\n'
    cmds+="chmod 600 $(q "$model_file")"$'\n'
    cmds+="mv -f $(q "$model_file") $(q "$BATCH_FILE")"$'\n'
    cmds+="chown $(q "$BATCH_SSH_USER") $(q "$BATCH_FILE")"$'\n'
    cmds+="chmod 600 $(q "$BATCH_FILE")"
    confirm_exec "Criar inventario" "$cmds" "Arquivo: $BATCH_FILE | dono: $BATCH_SSH_USER" || return 1
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

batch_edit_inventory() {
  batch_path
  if [[ -L $BATCH_FILE ]]; then
    ui_error "Inventario inseguro" "$BATCH_FILE e um symlink. Operacao bloqueada."
    return 1
  fi
  [[ -f $BATCH_FILE ]] || {
    batch_inventory || return 1
  }
  local ed=${EDITOR:-vi}
  [[ $ed =~ ^[A-Za-z0-9_./-]+$ ]] || ed="vi"
  need_bin "$ed" "$ed" || return 1
  "$ed" "$BATCH_FILE"
}

load_inventory() {
  batch_path
  BATCH_TARGETS=()
  BATCH_PORTS=()
  BATCH_NAMES=()
  if [[ -L $BATCH_FILE ]]; then
    ui_error "Inventario inseguro" "$BATCH_FILE e um symlink. Operacao bloqueada."
    return 1
  fi
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
    printf 'sudo -n bash -c %s' "$(sh_quote "$remote")"
  else
    printf '%s' "$remote"
  fi
}

batch_session_check() {
  timeout 2 tmux has-session -t "$BATCH_SESSION" 2>/dev/null || return 0
  local c
  c=$(select_action "Sessao TMUX existente" "A sessao '$BATCH_SESSION' ja existe." \
    attach "Anexar a sessao existente (interativo)" \
    new "! Encerrar a sessao e iniciar novo lote (destrutivo)" \
    0 "Cancelar") || return 1
  case $c in
    attach)
      tmux attach -t "$BATCH_SESSION"
      batch_report
      return 1
      ;;
    new)
      if ! confirm_strong "Encerrar sessao TMUX" "timeout 5 tmux kill-session -t $(q "$BATCH_SESSION")" \
        "Janelas em execucao serao interrompidas."; then
        return 1
      fi
      run_cmd timeout 5 tmux kill-session -t "$BATCH_SESSION" || {
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
      display=$(cmd_line "${BATCH_SSH_PREFIX[@]}" -o BatchMode=yes -o ConnectTimeout=10 -o ServerAliveInterval=30 -o StrictHostKeyChecking=yes \
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
  if [[ ! -L $BATCH_LAST_FILE ]]; then
    printf '%s\n' "$BATCH_DIR" >"$BATCH_LAST_FILE" 2>/dev/null
    chmod 600 "$BATCH_LAST_FILE" 2>/dev/null
  fi
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
  while IFS=$'\t' read -r idx target port _; do
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
  timeout 10 tmux new-session -d -s "$BATCH_SESSION" -n "monitor" "bash $(q "$BATCH_DIR/monitor.sh")" || {
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
      display=$(cmd_line "${BATCH_SSH_PREFIX[@]}" -o BatchMode=yes -o ConnectTimeout=10 -o ServerAliveInterval=30 -o StrictHostKeyChecking=yes \
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
"${sshcmd[@]}" -o BatchMode=yes -o ConnectTimeout=10 -o ServerAliveInterval=30 -o StrictHostKeyChecking=yes -p "$port" "$target" "$remote" 2>&1 | tee "$outfile"
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
    if ! timeout 5 tmux new-window -d -t "$BATCH_SESSION" -n "$win" "bash $(q "$runfile")" 2>/dev/null; then
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
    [[ -r $BATCH_LAST_FILE && ! -L $BATCH_LAST_FILE ]] && dir=$(cat "$BATCH_LAST_FILE")
  fi
  if [[ -z $dir || ! -d $dir || ! -r $dir/manifest.tsv ]]; then
    ui_error "Relatorio" "Nenhum lote encontrado. Execute um batch primeiro."
    return 1
  fi
  local text idx target port status log rc start end st dur
  local total=0 ok=0 fail=0 pending=0
  text="Relatorio batch"$'\n'"Diretorio: $dir"$'\n'"Acao: $(cat "$dir/action.txt" 2>/dev/null)"$'\n\n'
  while IFS=$'\t' read -r idx target port _; do
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
  batch_dispatch "Atualizacao completa" "$remote" 1 1 0 \
    "RHEL 6/7: yum | RHEL 8/9/10: dnf. Kernel novo pode exigir reboot." 
}

batch_security() {
  local remote
  remote='if command -v dnf >/dev/null 2>&1; then dnf -y update --security; elif command -v yum >/dev/null 2>&1; then yum -y update --security; else echo "dnf/yum ausente"; exit 127; fi'
  batch_dispatch "Atualizacao de seguranca" "$remote" 1 1 0 \
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
  remote='echo "=== HOST ==="; hostname; cat /etc/redhat-release 2>/dev/null || cat /etc/os-release 2>/dev/null; echo; uptime; echo; timeout 10 df -hT; echo; free -m; echo; if command -v systemctl >/dev/null 2>&1; then systemctl --failed --no-pager; else echo "systemctl ausente (RHEL6)"; fi; echo; ip -4 -o addr show 2>/dev/null'
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
  if ! timeout 2 tmux has-session -t "$BATCH_SESSION" 2>/dev/null; then
    ui_error "TMUX" "Nao existe sessao $BATCH_SESSION."
    return 1
  fi
  tmux attach -t "$BATCH_SESSION"
  batch_report
}

batch_kill_session() {
  need_bin tmux "tmux (RHEL6: EPEL)" || return 1
  if ! timeout 2 tmux has-session -t "$BATCH_SESSION" 2>/dev/null; then
    ui_msg "TMUX" "Nao existe sessao $BATCH_SESSION."
    return 0
  fi
  confirm_strong "Encerrar sessao TMUX" "timeout 5 tmux kill-session -t $(q "$BATCH_SESSION")" \
    "Todas as janelas e comandos em execucao serao encerrados." || return 0
  if ! run_cmd timeout 5 tmux kill-session -t "$BATCH_SESSION"; then
    ui_error "TMUX" "Nao foi possivel encerrar a sessao." "$RUN_OUT"
    return 1
  fi
  ui_ok "TMUX" "Sessao $BATCH_SESSION encerrada."
}

batch_menu() {
  local c
  while :; do
    c=$(select_action "Operacoes em lote (TMUX)" "Inventario: $BATCH_FILE | SSH local: $BATCH_SSH_USER. Cada opcao abre detalhes." \
      1 "Criar ou validar inventario (modifica arquivo local)" \
      2 "Editar inventario (modifica arquivo local)" \
      3 "Testar SSH e sudo (somente leitura)" \
      4 "! Atualizar todos os hosts (modifica varios hosts)" \
      5 "! Aplicar atualizacoes de seguranca (modifica varios hosts)" \
      6 "! Reiniciar hosts (destrutivo em varios hosts)" \
      7 "Coletar diagnostico (somente leitura)" \
      8 "! Executar comando personalizado (destrutivo em varios hosts)" \
      9 "Abrir SSH interativo em TMUX (interativo)" \
      10 "Anexar sessao TMUX (interativo)" \
      11 "Consultar relatorio do ultimo lote (somente leitura)" \
      12 "! Encerrar sessao TMUX (destrutivo)" \
      0 "Voltar") || return 0
    case $c in
      1) batch_inventory ;;
      2) batch_edit_inventory ;;
      3) batch_test_ssh ;;
      4) batch_patch ;;
      5) batch_security ;;
      6) batch_reboot ;;
      7) batch_diag ;;
      8) batch_custom ;;
      9) batch_interactive ;;
      10) batch_attach ;;
      11) batch_report ;;
      12) batch_kill_session ;;
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
  out=$(timeout 10 lsblk 2>&1)
  out+=$'\n\n=== FDISK -L ===\n'"$(timeout 15 fdisk -l 2>&1)"
  show_text "Discos apos rescan" "$out"
}

list_disks() {
  local out
  out=$(timeout 10 lsblk 2>&1)
  out+=$'\n\n=== FDISK -L ===\n'"$(timeout 15 fdisk -l 2>&1)"
  show_text "Discos e particoes" "$out"
}

filesystem_usage() {
  local out
  out="=== ESPACO EM DISCO ==="$'\n'"$(timeout 10 df -hT 2>&1)"$'\n\n'
  out+="=== INODES ==="$'\n'"$(timeout 10 df -i 2>&1)"
  show_text "Uso de filesystems" "$out"
}

select_swap_device() {
  local -a items=()
  local dev
  while read -r dev; do
    [[ -b $dev ]] || continue
    items+=("$dev" "$dev")
  done < <(timeout 10 blkid -o device -t TYPE=swap 2>/dev/null | sort -u)
  if ((${#items[@]} == 0)); then
    ui_error "Swap" "Nenhum dispositivo swap encontrado. Crie com mkswap/lvcreate primeiro."
    return 1
  fi
  show_menu "Selecionar swap" "Dispositivos swap:" "${items[@]}"
}

swap_status() {
  local out
  out="=== SWAP ATIVO ==="$'\n'"$(cat /proc/swaps 2>&1)"$'\n\n'
  out+="=== MEMORIA ==="$'\n'"$(free -m 2>&1)"
  show_text "Swap" "$out"
}

swap_toggle() {
  local dev action=${1:-}
  local -a c
  dev=$(select_swap_device) || return 1
  [[ -n $action ]] || {
    if in_swap "$dev"; then action="off"; else action="on"; fi
  }
  if [[ $action == on ]]; then
    if in_swap "$dev"; then
      ui_error "Swap ativo" "$dev ja esta ativo."
      return 1
    fi
    c=(swapon "$dev")
    confirm_exec "Ativar swap" "$(cmd_line "${c[@]}")" "Dispositivo: $dev" || return 0
  else
    if ! in_swap "$dev"; then
      ui_error "Swap inativo" "$dev nao esta ativo."
      return 1
    fi
    c=(swapoff "$dev")
    confirm_strong "Desativar swap" "$(cmd_line "${c[@]}")" \
      "Dispositivo: $dev"$'\n'"Desativar swap pode causar pressao de memoria." || return 0
  fi
  run_cmd "${c[@]}" || {
    ui_error "Falha no swap" "A operacao foi interrompida." "$RUN_OUT"
    return 1
  }
  ui_ok "Swap atualizado" "$dev: $action concluido."
}

swap_menu() {
  local c
  while :; do
    c=$(select_action "Swap" "Consultar e ativar memoria de troca. Cada opcao abre detalhes." \
      1 "Consultar uso do swap (somente leitura)" \
      2 "Ativar dispositivo swap (modifica o sistema)" \
      3 "! Desativar dispositivo swap (destrutivo)" \
      0 "Voltar") || return 0
    case $c in
      1) swap_status ;;
      2) swap_toggle on ;;
      3) swap_toggle off ;;
      0) return 0 ;;
    esac
  done
}

storage_root_menu() {
  local c
  while :; do
    c=$(show_menu "Armazenamento" "Escolha uma area. Cada item abre um menu." \
      1 "LVM e filesystems (abre menu)" \
      2 "Discos e barramento (abre menu)" \
      3 "Swap (abre menu)" \
      4 "Uso de filesystems (somente leitura)" \
      0 "Voltar") || return 0
    case $c in
      1) lvm_menu ;;
      2) storage_menu ;;
      3) swap_menu ;;
      4) filesystem_usage ;;
      0) return 0 ;;
    esac
  done
}

storage_health() {
  local out h name state speed
  out="=== MULTIPATH ==="$'\n'
  if command -v multipath >/dev/null 2>&1; then
    out+="$(timeout 10 multipath -ll 2>&1)"
  else
    out+="multipath-tools nao instalado."
  fi
  out+=$'\n\n'"=== FIBRE CHANNEL HBAs ==="$'\n'
  for h in /sys/class/fc_host/host*; do
    [[ -e $h ]] || continue
    name=${h##*/}
    state=$(cat "$h/port_state" 2>/dev/null)
    speed=$(cat "$h/speed" 2>/dev/null)
    out+="$name | state=${state:-?} | speed=${speed:-?} | port=$(cat "$h/port_name" 2>/dev/null)"$'\n'
  done
  out+=$'\n'"=== SCSI HOSTS ==="$'\n'
  for h in /sys/class/scsi_host/host*; do
    [[ -e $h ]] || continue
    out+="${h##*/} | proc=$(cat "$h/proc_name" 2>/dev/null)"$'\n'
  done
  out+=$'\n'"=== BLOCK DEVICES ==="$'\n'"$(timeout 10 lsblk 2>&1)"
  show_text "Multipath e HBAs" "$out"
}

recent_logs() {
  local out=""
  if command -v journalctl >/dev/null 2>&1; then
    out+="=== JOURNAL (ultimas 120) ==="$'\n'"$(timeout 10 journalctl -n 120 --no-pager 2>&1)"$'\n\n'
  fi
  if [[ -r /var/log/messages ]]; then
    out+="=== /var/log/messages (ultimas 120) ==="$'\n'"$(tail -n 120 /var/log/messages 2>&1)"
  fi
  [[ -n $out ]] || out="Nenhum log acessivel."
  show_text "Logs recentes" "$out"
}

hardware_info() {
  local out
  out="=== CPU ==="$'\n'"$(lscpu 2>&1 | head -n 30)"$'\n\n'
  out+="=== MEMORIA ==="$'\n'"$(lsmem 2>&1 | head -n 20)"$'\n\n'
  out+="=== DMI ==="$'\n'"$(dmidecode -t system -t bios 2>&1 | head -n 40)"$'\n\n'
  out+="=== PCI ==="$'\n'"$(lspci 2>&1 | head -n 40)"$'\n\n'
  out+="=== BLOCK DEVICES ==="$'\n'"$(timeout 10 lsblk 2>&1)"
  show_text "Inventario de hardware" "$out"
}

diagnostics() {
  local out cpus
  cpus=$(getconf _NPROCESSORS_ONLN 2>/dev/null || grep -c '^processor' /proc/cpuinfo)
  out="=== HOST ==="$'\n'"$(hostname 2>&1)"$'\n\n'
  out+="=== UPTIME / CARGA ==="$'\n'"$(uptime 2>&1)"$'\n\n'
  out+="=== CPU ==="$'\n'"Nucleos online: $cpus"$'\n\n'
  out+="=== MEMORIA (MB) ==="$'\n'"$(free -m 2>&1)"$'\n\n'
  out+="=== DISCOS ==="$'\n'"$(timeout 10 df -hT 2>&1)"$'\n\n'
  out+="=== TOP CPU ==="$'\n'"$(ps -eo pid,user,pcpu,pmem,comm --sort=-pcpu 2>&1 | head -n 6)"
  show_text "Diagnostico" "$out"
}

service_status() {
  local -a services
  local out s st en line
  out=""
  if ((RHEL_VER >= 7)); then
    services=(sshd NetworkManager crond rsyslog auditd firewalld chronyd)
    out+="=== SYSTEMD FALHAS ==="$'\n'"$(timeout 5 systemctl --failed --no-pager 2>&1)"$'\n\n'
    out+="SERVICO                ATIVO      HABILITADO"$'\n'
    for s in "${services[@]}"; do
      st=$(timeout 3 systemctl is-active "$s" 2>/dev/null)
      [[ -n $st ]] || st=desconhecido
      en=$(timeout 3 systemctl is-enabled "$s" 2>/dev/null)
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

dashboard_text() {
  local host kernel up load mem swap rootpct rootfree vgcount lvcount failed nics batch_count batch_state nm fs net out alerts selinux fw rule
  host=$(hostname 2>/dev/null)
  kernel=$(uname -r 2>/dev/null)
  up=$(uptime 2>/dev/null | sed 's/^ *//;s/.* up //;s/,.*//;s/^ *//')
  load=$(cut -d' ' -f1-3 /proc/loadavg 2>/dev/null)
  mem=$(free -m 2>/dev/null | awk '/^Mem:/ {if ($2 > 0) printf "%s/%s MB (%.0f%%)", $3, $2, ($3 * 100) / $2}')
  swap=$(free -m 2>/dev/null | awk '/^Swap:/ {if ($2 > 0) printf "%s/%s MB", $3, $2; else printf "desativado"}')
  rootpct=$(timeout 5 df -P / 2>/dev/null | awk 'NR==2 {gsub("%","",$5); print $5}')
  rootfree=$(timeout 5 df -h / 2>/dev/null | awk 'NR==2 {print $4}')
  vgcount=$(timeout 5 vgs --noheadings 2>/dev/null | wc -l)
  lvcount=$(timeout 5 lvs --noheadings 2>/dev/null | wc -l)
  if ((RHEL_VER >= 7)); then
    failed=$(timeout 5 systemctl --failed --no-pager --plain 2>/dev/null | grep -c '\.service')
  else
    failed="n/d"
  fi
  nics=0
  for _n in /sys/class/net/*; do
    [[ ${_n##*/} == lo ]] && continue
    nics=$((nics + 1))
  done
  batch_count=0
  [[ -r $BATCH_FILE && ! -L $BATCH_FILE ]] && batch_count=$(grep -vcE '^[[:space:]]*(#|$)' "$BATCH_FILE" 2>/dev/null)
  if command -v tmux >/dev/null 2>&1 && timeout 2 tmux has-session -t "$BATCH_SESSION" 2>/dev/null; then
    batch_state="ativa"
  else
    batch_state="inativa"
  fi
  nm="n/d"
  if command -v nmcli >/dev/null 2>&1; then
    nm=$(timeout 3 nmcli -t -f RUNNING general 2>/dev/null)
    [[ $nm == running ]] && nm="ativo" || nm="${nm:-n/d}"
  fi
  fs=$(version_fs_default)
  net=$(version_network_backend)
  selinux=$(getenforce 2>/dev/null)
  [[ -n $selinux ]] || selinux="n/d"
  fw="n/d"
  if ((RHEL_VER >= 7)); then
    fw=$(timeout 3 systemctl is-active firewalld 2>/dev/null)
    [[ -n $fw ]] || fw="n/d"
  elif timeout 3 service iptables status >/dev/null 2>&1; then
    fw="ativo"
  else
    fw="inativo"
  fi
  alerts=""
  [[ $rootpct =~ ^[0-9]+$ ]] && ((rootpct >= 80)) && alerts+="- Root FS em ${rootpct}%: avaliar espaco."$'\n'
  [[ $failed =~ ^[0-9]+$ ]] && ((failed > 0)) && alerts+="- $failed servico(s) systemd em falha."$'\n'
  [[ $batch_state == ativa ]] && alerts+="- Sessao batch TMUX ativa."$'\n'
  [[ -z $alerts ]] && alerts="- Nenhum alerta critico detectado."$'\n'
  rule=$(ui_rule)
  out="$rule"
  out+=$'\n'"  RHEL ADMIN MANAGER  -  DASHBOARD"
  out+=$'\n'"$rule"
  out+=$'\n'" HOST........: $host"
  out+=$'\n'" RELEASE.....: $RHEL_LABEL | kernel $kernel"
  out+=$'\n'" UPTIME......: $up"
  out+=$'\n'" LOAD........: $load"
  out+=$'\n'" MEMORIA.....: $mem"
  out+=$'\n'" SWAP........: $swap"
  out+=$'\n'" ROOT FS.....: ${rootpct:-?}% usado | ${rootfree:-?} livre"
  out+=$'\n'" INTERFACES..: $nics | NetworkManager: $nm"
  out+=$'\n'" SEGURANCA...: SELinux $selinux | firewall $fw"
  out+=$'\n'" LVM.........: VGs=$vgcount | LVs=$lvcount"
  out+=$'\n'" BATCH.......: $batch_count host(s) | sessao $batch_state"
  out+=$'\n'"$rule"
  out+=$'\n'" PERFIL DA VERSAO"
  out+=$'\n'"   FS padrao..: $fs"
  out+=$'\n'"   Rede.......: $net"
  out+=$'\n'"   Atencao....: $(version_network_note)"
  out+=$'\n'"$rule"
  out+=$'\n'" ALERTAS"
  out+=$'\n'"$alerts"
  out+="$rule"
  out+=$'\n'" INTERACAO...: cada acao interna abre detalhes, comandos e riscos."
  out+=$'\n'" AUDITORIA...: $LOG_FILE"
  out+=$'\n'" BATCH LOGS..: /var/log/rhel_admin_manager.batch.*"
  printf '%s\n' "$out"
}

dashboard() {
  show_text "Dashboard - $RHEL_LABEL" "$(dashboard_text)"
}

log_errors() {
  if [[ ! -r $LOG_FILE ]]; then
    ui_error "Auditoria" "Log nao encontrado: $LOG_FILE"
    return 1
  fi
  local out
  out=$(grep -E 'status=(ERRO|ERRO_|FALHA)' "$LOG_FILE" 2>/dev/null | tail -n 200)
  [[ -n $out ]] || out="Nenhum erro/falha encontrado no log."
  show_text "Auditoria - erros e falhas" "$out"
}

log_recent() {
  if [[ ! -r $LOG_FILE ]]; then
    ui_error "Auditoria" "Log nao encontrado: $LOG_FILE"
    return 1
  fi
  show_text "Auditoria - ultimas 200 linhas" "$(tail -n 200 "$LOG_FILE")"
}

log_status() {
  local out
  if [[ ! -e $LOG_FILE ]]; then
    ui_error "Auditoria" "Log nao encontrado: $LOG_FILE"
    return 1
  fi
  out="Arquivo..: $LOG_FILE"$'\n'"Permissoes: $(stat -c '%A %U:%G' "$LOG_FILE" 2>/dev/null)"$'\n'
  out+="Linhas...: $(wc -l <"$LOG_FILE" 2>/dev/null)"$'\n'
  out+="Tamanho..: $(du -h "$LOG_FILE" 2>/dev/null | awk '{print $1}')"$'\n\n'
  out+="Ultima entrada:"$'\n'"$(tail -n 1 "$LOG_FILE" 2>/dev/null)"
  show_text "Auditoria - status do log" "$out"
}

help_text() {
  printf '%s\n' \
    "RHEL ADMIN MANAGER - AJUDA RAPIDA" \
    "" \
    "EXECUCAO" \
    "  sudo ./rhel_admin_manager.sh" \
    "  Requer root, whiptail/newt, ssh, tmux e sudo para o modulo batch." \
    "" \
    "LEGENDA DAS ACOES" \
    "  Menus de area apenas navegam. Acoes internas abrem detalhes e pedem confirmacao." \
    "  [detalhes]            toda acao abre uma tela com o que sera feito, comandos e riscos." \
    "  !                     destaque visual para acao de risco/destrutiva." \
    "  (somente leitura)     consulta; nao altera o sistema." \
    "  (modifica o sistema)  escrita com confirmacao e backup quando aplicavel." \
    "  (destrutivo)          pode remover dados ou interromper servicos; exige SIM." \
    "" \
    "CONFIRMACAO" \
    "  Toda escrita mostra os comandos exatos em uma tela rolavel." \
    "  Operacoes destrutivas exigem digitar SIM." \
    "  Cada comando e registrado em $LOG_FILE." \
    "" \
    "LVM / FILE SYSTEMS" \
    "  Permite visualizar, criar LV, estender LV+FS, formatar, montar com UUID," \
    "  desmontar/remover fstab e excluir LV. Nao faz shrink nem criacao de PV/VG." \
    "" \
    "REDE" \
    "  RHEL 6 usa ifcfg + service network. RHEL 7+ usa nmcli/NetworkManager." \
    "  Modos: completo (gateway/DNS), heartbeat (sem gateway/DNS) e DHCP." \
    "  Inclui hostname/hosts, rotas, DNS, ARP e teste ping/porta." \
    "  Alterar IP pode derrubar a sessao SSH; use console/IPMI." \
    "" \
    "STORAGE / DIAGNOSTICO" \
    "  LVM/FS, rescan SCSI/FC, discos, multipath/HBAs, swap, uso, hardware e logs." \
    "" \
    "USUARIOS / SERVICOS / PACOTES" \
    "  Cria usuarios/grupos, senha, lock, grupos privilegiados e remocao." \
    "  Gerencia systemctl/service, enable/disable, logs, cron/timers e kill." \
    "  Instala, remove, atualiza, busca pacotes, security e subscription." \
    "" \
    "SEGURANCA / SISTEMA" \
    "  Firewall: status em todas; alteracoes via firewalld no RHEL 7+." \
    "  SELinux (modo/booleanos/AVC) e auditoria SSH sem editar sshd_config." \
    "  Data/hora, timezone, NTP, sysctl, boot e reboot/shutdown." \
    "" \
    "LIMITES DELIBERADOS" \
    "  Nao faz shrink, thin/snapshot, criacao/remocao de PV/VG ou particionamento." \
    "  Nao edita sshd_config, bond/VLAN ou distribui chaves automaticamente." \
    "  Nao cobre NFS, edicao de cron/timers, tuned/kdump, RAID ou registro de subscription." \
    "  Essas operacoes exigem procedimento dedicado e console/IPMI." \
    "" \
    "PRODUCAO" \
    "  ifcfg, fstab e hostname geram backup antes da alteracao." \
    "  XFS nao encolhe e so cresce montado. ext4 cresce online/offline." \
    "  RHEL 9/10 nao leem ifcfg; RHEL 8 usa keyfile via nmcli." \
    "" \
    "BATCH / TMUX" \
    "  Inventario: $BATCH_FILE" \
    "  Formato: [usuario@]host[:porta], um por linha." \
    "  SSH local: $BATCH_SSH_USER. Acoes root remotas usam sudo -n (NOPASSWD)." \
    "  BatchMode exige host key em known_hosts; use Testar SSH + sudo -n." \
    "  O script valida confianca SSH, mas nao distribui chaves automaticamente." \
    "  Nao use batch para alterar o IP da interface de gerencia." \
    "  Relatorios e logs: /var/log/rhel_admin_manager.batch.*" \
    "" \
    "ATALHOS" \
    "  Seta/Tab navegam. Enter seleciona. Cancelar/Voltar retorna." \
    "  Use uma sessao tmux no jump host para sobreviver a quedas de SSH."
}

valid_user_name() {
  [[ $1 =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]
}

valid_group_name() {
  [[ $1 =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]
}

select_user() {
  local -a items=()
  local name uid home shell
  while IFS=: read -r name _ uid _ _ home shell; do
    [[ $name == root || $uid -ge 1000 ]] || continue
    [[ $uid -lt 65534 ]] || continue
    items+=("$name" "$name | uid=$uid | ${home:-?} | ${shell:-?}")
  done < <(timeout 10 getent passwd)
  if ((${#items[@]} == 0)); then
    ui_error "Usuarios" "Nenhum usuario gerenciavel encontrado."
    return 1
  fi
  show_menu "Selecionar usuario" "Usuarios locais (root e UID >= 1000):" "${items[@]}"
}

select_group() {
  local -a items=()
  local name gid members
  while IFS=: read -r name _ gid members; do
    items+=("$name" "$name | gid=$gid | membros=${members:-nenhum}")
  done < <(timeout 10 getent group)
  if ((${#items[@]} == 0)); then
    ui_error "Grupos" "Nenhum grupo encontrado."
    return 1
  fi
  show_menu "Selecionar grupo" "Grupos locais:" "${items[@]}"
}

users_overview() {
  local out
  out="=== USUARIOS (root + UID >= 1000) ==="$'\n'
  out+="$(timeout 10 getent passwd | awk -F: '$1=="root" || ($3>=1000 && $3<65534) {printf "%-20s uid=%-6s home=%-24s shell=%s\n",$1,$3,$6,$7}' 2>&1)"$'\n\n'
  out+="=== GRUPOS COM MEMBROS ==="$'\n'
  out+="$(timeout 10 getent group | awk -F: '$4!="" {printf "%-20s gid=%-6s %s\n",$1,$3,$4}' 2>&1)"$'\n\n'
  out+="=== USUARIOS LOGADOS ==="$'\n'"$(timeout 5 who 2>&1)"$'\n\n'
  out+="=== ULTIMOS LOGINS ==="$'\n'"$(timeout 5 last -n 10 2>&1)"
  show_text "Usuarios e grupos" "$out"
}

create_user() {
  need_bin useradd shadow-utils || return 1
  local user shell groups g gcsv
  local -a gl=()
  while :; do
    user=$(ask "Criar usuario" "Nome do usuario (minusculo, sem espacos):") || return 1
    valid_user_name "$user" && ! timeout 5 getent passwd "$user" >/dev/null && break
    ui_error "Usuario invalido" "Use letras minusculas, numeros, _ ou -; o usuario nao pode existir."
  done
  shell=$(ask "Criar usuario" "Shell:" "/bin/bash") || return 1
  [[ -n $shell ]] || shell="/bin/bash"
  if [[ $shell != /* || ! -x $shell ]]; then
    ui_error "Shell invalido" "Informe um shell absoluto e executavel."
    return 1
  fi
  groups=$(ask "Criar usuario" "Grupos adicionais (virgula, opcional):") || return 1
  groups=${groups//,/ }
  for g in $groups; do
    if ! valid_group_name "$g" || ! timeout 5 getent group "$g" >/dev/null; then
      ui_error "Grupo invalido" "Grupo nao encontrado: $g"
      return 1
    fi
    gl+=("$g")
  done
  gcsv=""
  ((${#gl[@]} > 0)) && gcsv=$(IFS=,; printf '%s' "${gl[*]}")
  local -a cmd=(useradd -m -s "$shell")
  [[ -n $gcsv ]] && cmd+=(-G "$gcsv")
  cmd+=("$user")
  confirm_exec "Criar usuario" "$(cmd_line "${cmd[@]}")" \
    "Usuario: $user | Home: /home/$user | Shell: $shell${gcsv:+ | Grupos: $gcsv}"$'\n'"A senha deve ser definida depois em Usuarios > Definir senha." || return 0
  if ! run_cmd "${cmd[@]}"; then
    ui_error "Falha ao criar usuario" "A operacao foi interrompida." "$RUN_OUT"
    return 1
  fi
  ui_ok "Usuario criado" "Usuario $user criado."$'\n'"Defina a senha no menu Usuarios."
}

run_tty_cmd() {
  local preview rc
  preview=$(printf '%q ' "$@")
  clear
  printf 'Executando: %s\n\n' "$preview"
  log_event INICIO 0 "$preview"
  "$@"
  rc=$?
  if ((rc == 0)); then
    log_event SUCESSO 0 "$preview"
  else
    log_event ERRO "$rc" "$preview"
  fi
  printf '\nPressione Enter para voltar ao painel...'
  read -r
  return "$rc"
}

user_set_password() {
  need_bin passwd shadow-utils || return 1
  local user
  user=$(select_user) || return 1
  [[ $user == root ]] && {
    ui_error "Operacao bloqueada" "Alterar a senha de root nao e permitido por este menu."
    return 1
  }
  confirm_exec "Definir senha" "passwd $(q "$user")" \
    "A senha sera solicitada no terminal. Ela nao sera registrada no log." || return 0
  if ! run_tty_cmd passwd "$user"; then
    ui_error "Falha ao definir senha" "A operacao foi interrompida." "Veja a saida no terminal."
    return 1
  fi
  ui_ok "Senha atualizada" "Senha de $user atualizada."
}

user_expire_password() {
  need_bin chage shadow-utils || return 1
  local user
  user=$(select_user) || return 1
  [[ $user == root ]] && {
    ui_error "Operacao bloqueada" "Forcar troca de senha de root nao e permitido."
    return 1
  }
  confirm_exec "Forcar troca de senha" "chage -d 0 $(q "$user")" \
    "O usuario $user devera trocar a senha no proximo login." || return 0
  run_cmd chage -d 0 "$user" || {
    ui_error "Falha" "Nao foi possivel forcar a troca de senha." "$RUN_OUT"
    return 1
  }
  ui_ok "Troca forcada" "Proximo login de $user exigira nova senha."
}

user_lock_toggle() {
  need_bin passwd shadow-utils || return 1
  local user action cmd
  user=$(select_user) || return 1
  [[ $user == root ]] && {
    ui_error "Operacao bloqueada" "Bloquear/desbloquear root nao e permitido."
    return 1
  }
  action=$(select_action "Conta de $user" "Selecione a acao:" \
    lock "Bloquear conta (modifica o sistema)" \
    unlock "Desbloquear conta (modifica o sistema)") || return 1
  if [[ $action == lock ]]; then
    cmd=(passwd -l "$user")
  else
    cmd=(passwd -u "$user")
  fi
  confirm_exec "Conta de usuario" "$(cmd_line "${cmd[@]}")" "Usuario: $user" || return 0
  run_cmd "${cmd[@]}" || {
    ui_error "Falha na conta" "A operacao foi interrompida." "$RUN_OUT"
    return 1
  }
  ui_ok "Conta atualizada" "Acao '$action' aplicada em $user."
}

user_add_group() {
  need_bin usermod shadow-utils || return 1
  local user group extra
  user=$(select_user) || return 1
  group=$(select_group) || return 1
  extra="Usuario: $user | Grupo: $group"$'\n'"O usuario deve relogar para o novo grupo valer."
  case $group in
    root|wheel|sudo|adm)
      extra+=$'\n'"ATENCAO: grupo privilegiado; isso pode conceder acesso administrativo."
      confirm_strong "Adicionar a grupo privilegiado" "usermod -aG $(q "$group") $(q "$user")" "$extra" || return 0
      ;;
    *)
      confirm_exec "Adicionar usuario a grupo" "usermod -aG $(q "$group") $(q "$user")" "$extra" || return 0
      ;;
  esac
  run_cmd usermod -aG "$group" "$user" || {
    ui_error "Falha ao adicionar grupo" "A operacao foi interrompida." "$RUN_OUT"
    return 1
  }
  ui_ok "Grupo adicionado" "$user agora pertence a $group (efetivo no proximo login)."
}

delete_user() {
  need_bin userdel shadow-utils || return 1
  local user
  user=$(select_user) || return 1
  if [[ $user == root ]]; then
    ui_error "Operacao bloqueada" "Excluir root nao e permitido."
    return 1
  fi
  if pgrep -u "$user" >/dev/null 2>&1; then
    ui_error "Usuario em uso" "Existem processos ativos de $user. Encerre-os antes de excluir."
    return 1
  fi
  confirm_strong "Excluir usuario" "userdel -r $(q "$user")" \
    "Usuario: $user"$'\n'"O home, mail spool e arquivos do usuario serao removidos." || return 0
  run_cmd userdel -r "$user" || {
    ui_error "Falha ao excluir usuario" "A operacao foi interrompida." "$RUN_OUT"
    return 1
  }
  ui_ok "Usuario excluido" "$user removido."
}

create_group() {
  need_bin groupadd shadow-utils || return 1
  local group
  while :; do
    group=$(ask "Criar grupo" "Nome do grupo:") || return 1
    valid_group_name "$group" && ! timeout 5 getent group "$group" >/dev/null && break
    ui_error "Grupo invalido" "Use letras minusculas, numeros, _ ou -; o grupo nao pode existir."
  done
  confirm_exec "Criar grupo" "groupadd $(q "$group")" "Grupo: $group" || return 0
  run_cmd groupadd "$group" || {
    ui_error "Falha ao criar grupo" "A operacao foi interrompida." "$RUN_OUT"
    return 1
  }
  ui_ok "Grupo criado" "Grupo $group criado."
}

delete_group() {
  need_bin groupdel shadow-utils || return 1
  local group gid
  group=$(select_group) || return 1
  gid=$(timeout 5 getent group "$group" 2>/dev/null | cut -d: -f3)
  if [[ $group == root || ${gid:-0} -lt 1000 ]]; then
    ui_error "Operacao bloqueada" "Excluir grupo de sistema nao e permitido."
    return 1
  fi
  confirm_strong "Excluir grupo" "groupdel $(q "$group")" \
    "Grupo: $group"$'\n'"O grupo deve estar sem usuarios associados como grupo primario." || return 0
  run_cmd groupdel "$group" || {
    ui_error "Falha ao excluir grupo" "A operacao foi interrompida." "$RUN_OUT"
    return 1
  }
  ui_ok "Grupo excluido" "Grupo $group removido."
}

users_menu() {
  local c
  while :; do
    c=$(select_action "Usuarios e grupos" "Gerencie contas locais. Cada opcao abre detalhes antes de executar." \
      1 "Consultar usuarios e grupos (somente leitura)" \
      2 "Criar usuario (modifica o sistema)" \
      3 "Definir senha interativamente (modifica o sistema)" \
      4 "Forcar troca de senha (modifica o sistema)" \
      5 "Adicionar usuario a grupo (modifica o sistema)" \
      6 "Abrir opcoes de bloqueio de conta (abre opcoes)" \
      7 "Criar grupo (modifica o sistema)" \
      8 "! Excluir usuario (destrutivo)" \
      9 "! Excluir grupo (destrutivo)" \
      0 "Voltar") || return 0
    case $c in
      1) users_overview ;;
      2) create_user ;;
      3) user_set_password ;;
      4) user_expire_password ;;
      5) user_add_group ;;
      6) user_lock_toggle ;;
      7) create_group ;;
      8) delete_user ;;
      9) delete_group ;;
      0) return 0 ;;
    esac
  done
}

service_backend() {
  if ((RHEL_VER >= 7)); then
    printf 'systemctl'
  else
    printf 'service/chkconfig'
  fi
}

select_service() {
  local -a items=()
  local svc
  if ((RHEL_VER >= 7)); then
    while read -r svc; do
      [[ $svc =~ ^[A-Za-z0-9@_.:-]+$ ]] && items+=("$svc" "$svc")
    done < <(timeout 10 systemctl list-unit-files --type=service --no-legend --no-pager 2>/dev/null | awk '{print $1}' | sed 's/\.service$//' | sort -u)
  else
    while read -r svc; do
      [[ $svc =~ ^[A-Za-z0-9@_.:-]+$ ]] && items+=("$svc" "$svc")
    done < <({ chkconfig --list 2>/dev/null | awk '{print $1}'; ls /etc/init.d 2>/dev/null; } | sort -u)
  fi
  if ((${#items[@]} == 0)); then
    ui_error "Servicos" "Nenhum servico encontrado."
    return 1
  fi
  show_menu "Selecionar servico" "Backend: $(service_backend)" "${items[@]}"
}

service_failed() {
  local out
  if ((RHEL_VER >= 7)); then
    out=$(timeout 5 systemctl --failed --no-pager 2>&1)
  else
    out=$(timeout 15 service --status-all 2>&1 | grep -iE 'stopped|failed|dead' || true)
    [[ -n $out ]] || out="Nenhum servico parado/falho detectado."
  fi
  show_text "Servicos com falha" "$out"
}

manage_service() {
  local svc action cmd extra
  local -a c
  svc=$(select_service) || return 1
  action=$(select_action "Gerenciar $svc" "Backend: $(service_backend)" \
    status "Consultar status (somente leitura)" \
    logs "Consultar logs recentes (somente leitura)" \
    start "Iniciar servico (modifica o sistema)" \
    stop "! Parar servico (destrutivo)" \
    restart "! Reiniciar servico (destrutivo)" \
    reload "Recarregar configuracao (modifica o sistema)" \
    enable "Habilitar no boot (modifica o sistema)" \
    disable "! Desabilitar no boot (destrutivo)") || return 1
  if [[ $action == status ]]; then
    if ((RHEL_VER >= 7)); then
      show_text "Status - $svc" "$(timeout 10 systemctl status "$svc" --no-pager 2>&1)"
    else
      show_text "Status - $svc" "$(timeout 10 service "$svc" status 2>&1)"
    fi
    return 0
  fi
  if [[ $action == logs ]]; then
    if ((RHEL_VER >= 7)); then
      show_text "Logs - $svc" "$(timeout 10 journalctl -u "$svc" -n 120 --no-pager 2>&1)"
    else
      show_text "Logs - $svc" "$(timeout 10 grep -i "$svc" /var/log/messages 2>/dev/null | tail -n 120)"
    fi
    return 0
  fi
  if ((RHEL_VER >= 7)); then
    c=(systemctl "$action" "$svc")
  elif [[ $action == enable || $action == disable ]]; then
    c=(chkconfig "$svc" "$([[ $action == enable ]] && printf on || printf off)")
  else
    c=(service "$svc" "$action")
  fi
  extra="Servico: $svc | Acao: $action"
  case $svc in
    sshd|sshd.service|network|NetworkManager|firewalld)
      extra+=$'\n'"ATENCAO: este servico pode afetar acesso remoto ou conectividade."
      ;;
  esac
  if [[ $action == stop || $action == restart || $action == disable ]]; then
    confirm_strong "Servico $svc" "$(cmd_line "${c[@]}")" "$extra" || return 0
  else
    confirm_exec "Servico $svc" "$(cmd_line "${c[@]}")" "$extra" || return 0
  fi
  run_cmd "${c[@]}" || {
    ui_error "Falha no servico" "A operacao foi interrompida." "$RUN_OUT"
    return 1
  }
  ui_ok "Servico atualizado" "$svc: $action concluido."
}

select_process() {
  local -a items=()
  local pid user cpu mem comm
  while read -r pid user cpu mem comm; do
    [[ $pid =~ ^[0-9]+$ ]] || continue
    items+=("$pid" "$pid | $user | cpu=${cpu}% | mem=${mem}% | $comm")
  done < <(ps -eo pid,user,pcpu,pmem,comm 2>/dev/null | tail -n +2 | sort -k3 -nr | head -n 40)
  if ((${#items[@]} == 0)); then
    ui_error "Processos" "Nenhum processo encontrado."
    return 1
  fi
  items+=("manual" "Informar PID manualmente")
  show_menu "Selecionar processo" "Top processos por CPU:" "${items[@]}"
}

top_processes() {
  local out
  out="=== TOP CPU ==="$'\n'"$(ps -eo pid,user,pcpu,pmem,etime,comm 2>/dev/null | tail -n +2 | sort -k3 -nr | head -n 20)"$'\n\n'
  out+="=== TOP MEMORIA ==="$'\n'"$(ps -eo pid,user,pcpu,pmem,etime,comm 2>/dev/null | tail -n +2 | sort -k4 -nr | head -n 20)"
  show_text "Processos" "$out"
}

kill_process() {
  local pid sig
  local -a c
  pid=$(select_process) || return 1
  if [[ $pid == manual ]]; then
    pid=$(ask "PID manual" "Informe o PID:") || return 1
  fi
  [[ $pid =~ ^[0-9]+$ ]] || {
    ui_error "PID invalido" "PID: $pid"
    return 1
  }
  if ((pid == 1)); then
    ui_error "Operacao bloqueada" "Encerrar PID 1 nao e permitido."
    return 1
  fi
  if ! kill -0 "$pid" 2>/dev/null; then
    ui_error "Processo ausente" "PID $pid nao existe mais."
    return 1
  fi
  sig=$(select_action "Sinal para PID $pid" "Escolha como encerrar o processo." \
    TERM "SIGTERM - encerramento gracioso (modifica o sistema)" \
    KILL "! SIGKILL - forcar encerramento (destrutivo)") || return 1
  c=(kill -"$sig" "$pid")
  confirm_strong "Encerrar processo" "$(cmd_line "${c[@]}")" \
    "PID: $pid"$'\n'"SIGKILL pode causar perda de dados no processo." || return 0
  run_cmd "${c[@]}" || {
    ui_error "Falha ao encerrar processo" "A operacao foi interrompida." "$RUN_OUT"
    return 1
  }
  ui_ok "Processo sinalizado" "PID $pid recebeu SIG$sig."
}

scheduled_jobs() {
  local out
  out="=== CRONTAB ROOT ==="$'\n'"$(crontab -l 2>&1)"$'\n\n'
  out+="=== /etc/cron.d ==="$'\n'"$(ls -l /etc/cron.d 2>&1)"$'\n\n'
  if ((RHEL_VER >= 7)); then
    out+="=== SYSTEMD TIMERS ==="$'\n'"$(timeout 5 systemctl list-timers --all --no-pager 2>&1)"
  else
    out+="=== CRON ==="$'\n'"$(service crond status 2>&1)"
  fi
  show_text "Cron e timers" "$out"
}

services_menu() {
  local c
  while :; do
    c=$(select_action "Servicos e processos" "Backend: $(service_backend). Cada opcao abre detalhes antes de executar." \
      1 "Consultar servicos essenciais (somente leitura)" \
      2 "Consultar servicos com falha (somente leitura)" \
      3 "Abrir gerenciamento de servico (abre opcoes)" \
      4 "Consultar processos por CPU e memoria (somente leitura)" \
      5 "! Encerrar processo (destrutivo)" \
      6 "Consultar cron e timers (somente leitura)" \
      0 "Voltar") || return 0
    case $c in
      1) service_status ;;
      2) service_failed ;;
      3) manage_service ;;
      4) top_processes ;;
      5) kill_process ;;
      6) scheduled_jobs ;;
      0) return 0 ;;
    esac
  done
}

pkg_backend() {
  if command -v dnf >/dev/null 2>&1; then
    printf 'dnf'
  elif command -v yum >/dev/null 2>&1; then
    printf 'yum'
  else
    return 1
  fi
}

pkg_repos() {
  local pkg
  pkg=$(pkg_backend) || {
    ui_error "Pacotes" "dnf/yum nao encontrado."
    return 1
  }
  show_text "Repositorios - $pkg" "$(timeout 60 "$pkg" repolist 2>&1)"
}

pkg_updates() {
  local pkg out rc
  pkg=$(pkg_backend) || {
    ui_error "Pacotes" "dnf/yum nao encontrado."
    return 1
  }
  out=$(timeout 120 "$pkg" check-update 2>&1)
  rc=$?
  if ((rc == 0)); then
    out="Nenhuma atualizacao disponivel."
  elif ((rc == 100)); then
    :
  else
    out="Falha ao consultar atualizacoes (rc=$rc):"$'\n'"$out"
  fi
  show_text "Atualizacoes disponiveis" "$out"
}

pkg_update_all() {
  local pkg
  local -a c
  pkg=$(pkg_backend) || return 1
  c=("$pkg" -y update)
  confirm_strong "Atualizar todos os pacotes" "$(cmd_line "${c[@]}")" \
    "Pode atualizar kernel e exigir reboot. Valide janela de manutencao." || return 0
  run_cmd "${c[@]}" || {
    ui_error "Falha na atualizacao" "A operacao foi interrompida." "$RUN_OUT"
    return 1
  }
  ui_ok "Atualizacao concluida" "Pacotes atualizados. Verifique se ha kernel novo e reboot pendente."
}

pkg_security() {
  local pkg
  local -a c
  pkg=$(pkg_backend) || return 1
  c=("$pkg" -y update --security)
  confirm_strong "Atualizacoes de seguranca" "$(cmd_line "${c[@]}")" \
    "Requer suporte a --security no gerenciador. RHEL 6/7 pode exigir yum-plugin-security." || return 0
  run_cmd "${c[@]}" || {
    ui_error "Falha no security update" "A operacao foi interrompida." "$RUN_OUT"
    return 1
  }
  ui_ok "Security update concluido" "Atualizacoes de seguranca aplicadas."
}

pkg_install() {
  local pkg name
  local -a c
  pkg=$(pkg_backend) || return 1
  while :; do
    name=$(ask "Instalar pacote" "Nome do pacote (ou grupo @nome):") || return 1
    [[ $name =~ ^@?[A-Za-z0-9][A-Za-z0-9._+:-]*$ ]] && break
    ui_error "Nome invalido" "Informe um nome de pacote valido."
  done
  c=("$pkg" -y install "$name")
  confirm_exec "Instalar pacote" "$(cmd_line "${c[@]}")" "Pacote: $name" || return 0
  run_cmd "${c[@]}" || {
    ui_error "Falha ao instalar" "A operacao foi interrompida." "$RUN_OUT"
    return 1
  }
  ui_ok "Pacote instalado" "$name instalado."
}

pkg_remove() {
  local pkg name extra
  local -a c
  pkg=$(pkg_backend) || return 1
  while :; do
    name=$(ask "Remover pacote" "Nome do pacote:") || return 1
    [[ $name =~ ^[A-Za-z0-9][A-Za-z0-9._+:-]*$ ]] && break
    ui_error "Nome invalido" "Informe um nome de pacote valido."
  done
  c=("$pkg" -y remove "$name")
  extra="Pacote: $name"
  case $name in
    kernel*|glibc*|systemd*|openssl*|grub*|shim*)
      extra+=$'\n'"ATENCAO: remover este pacote pode impedir boot ou quebrar o sistema."
      ;;
  esac
  confirm_strong "Remover pacote" "$(cmd_line "${c[@]}")" "$extra" || return 0
  run_cmd "${c[@]}" || {
    ui_error "Falha ao remover" "A operacao foi interrompida." "$RUN_OUT"
    return 1
  }
  ui_ok "Pacote removido" "$name removido."
}

pkg_search() {
  local pkg term
  pkg=$(pkg_backend) || return 1
  term=$(ask "Buscar pacote" "Termo de busca:") || return 1
  [[ $term =~ ^[A-Za-z0-9] ]] || {
    ui_error "Busca invalida" "O termo deve iniciar com letra ou numero."
    return 1
  }
  show_text "Busca - $term" "$(timeout 30 "$pkg" search "$term" 2>&1)"
}

pkg_info() {
  local pkg name
  pkg=$(pkg_backend) || return 1
  name=$(ask "Informacoes do pacote" "Nome do pacote:") || return 1
  [[ $name =~ ^[A-Za-z0-9][A-Za-z0-9._+:-]*$ ]] || {
    ui_error "Nome invalido" "Informe um nome de pacote valido."
    return 1
  }
  show_text "Pacote - $name" "$(timeout 30 "$pkg" info "$name" 2>&1)"
}

pkg_history() {
  local pkg
  pkg=$(pkg_backend) || return 1
  show_text "Historico de pacotes" "$(timeout 30 "$pkg" history 2>&1)"
}

pkg_subscription() {
  local out
  if ! command -v subscription-manager >/dev/null 2>&1; then
    ui_error "Subscription Manager" "subscription-manager nao instalado."
    return 1
  fi
  out="=== STATUS ==="$'\n'"$(timeout 30 subscription-manager status 2>&1)"$'\n\n'
  out+="=== IDENTIDADE ==="$'\n'"$(timeout 30 subscription-manager identity 2>&1)"$'\n\n'
  out+="=== REPOSITORIOS HABILITADOS ==="$'\n'"$(timeout 30 subscription-manager repos --list-enabled 2>&1)"
  show_text "Subscription Manager" "$out"
}

packages_menu() {
  local c pkg
  pkg=$(pkg_backend 2>/dev/null || printf 'n/d')
  while :; do
    c=$(select_action "Pacotes e atualizacoes" "Backend: $pkg. Cada opcao abre detalhes antes de executar." \
      1 "Consultar repositorios (somente leitura)" \
      2 "Consultar atualizacoes disponiveis (somente leitura)" \
      3 "Consultar historico de transacoes (somente leitura)" \
      4 "Buscar pacote (somente leitura)" \
      5 "Consultar informacoes de pacote (somente leitura)" \
      6 "Instalar pacote (modifica o sistema)" \
      7 "! Remover pacote (destrutivo)" \
      8 "! Atualizar todos (modifica o sistema; pode exigir reboot)" \
      9 "! Aplicar atualizacoes de seguranca (modifica o sistema)" \
      10 "Consultar Subscription Manager (somente leitura)" \
      0 "Voltar") || return 0
    case $c in
      1) pkg_repos ;;
      2) pkg_updates ;;
      3) pkg_history ;;
      4) pkg_search ;;
      5) pkg_info ;;
      6) pkg_install ;;
      7) pkg_remove ;;
      8) pkg_update_all ;;
      9) pkg_security ;;
      10) pkg_subscription ;;
      0) return 0 ;;
    esac
  done
}

firewall_status() {
  local out
  if command -v firewall-cmd >/dev/null 2>&1; then
    out="=== FIREWALLD ==="$'\n'"$(timeout 5 firewall-cmd --state 2>&1)"$'\n\n'
    out+="=== ZONAS ATIVAS ==="$'\n'"$(timeout 5 firewall-cmd --get-active-zones 2>&1)"$'\n\n'
    out+="=== CONFIGURACAO DA ZONA PADRAO ==="$'\n'"$(timeout 5 firewall-cmd --list-all 2>&1)"
  elif command -v iptables >/dev/null 2>&1; then
    out="=== IPTABLES ==="$'\n'"$(iptables -L -n -v 2>&1)"
  else
    out="Nenhum backend de firewall encontrado."
  fi
  show_text "Firewall" "$out"
}

firewall_change() {
  local action svc port p proto extra
  local -a c1 c2
  if ((RHEL_VER < 7)); then
    ui_error "Firewall" "Alteracoes automaticas de firewall sao suportadas apenas no RHEL 7+ (firewalld)."
    return 1
  fi
  need_bin firewall-cmd firewalld || return 1
  if ! timeout 5 firewall-cmd --state >/dev/null 2>&1; then
    ui_error "Firewall" "firewalld nao esta em execucao."
    return 1
  fi
  action=$(select_action "Alterar firewall" "As regras serao permanentes e aplicadas com reload." \
    add-service "Adicionar servico (modifica a rede)" \
    remove-service "! Remover servico (destrutivo)" \
    add-port "Adicionar porta (modifica a rede)" \
    remove-port "! Remover porta (destrutivo)" \
    reload "Recarregar regras (modifica a rede)") || return 1
  extra=""
  case $action in
    add-service|remove-service)
      svc=$(ask "Firewall" "Nome do servico (ex.: http, https, ssh):") || return 1
      [[ $svc =~ ^[A-Za-z0-9_-]+$ ]] || {
        ui_error "Servico invalido" "Informe um nome de servico valido."
        return 1
      }
      c1=(firewall-cmd --permanent --"$action=$svc")
      c2=(firewall-cmd --reload)
      extra="Servico: $svc"
      [[ $svc == ssh && $action == remove-service ]] && extra+=$'\n'"ATENCAO: remover ssh pode bloquear o acesso remoto."
      ;;
    add-port|remove-port)
      port=$(ask "Firewall" "Porta/protocolo (ex.: 8080/tcp):") || return 1
      [[ $port =~ ^([0-9]{1,5})/(tcp|udp)$ ]] || {
        ui_error "Porta invalida" "Use o formato porta/tcp ou porta/udp."
        return 1
      }
      p=$((10#${BASH_REMATCH[1]}))
      proto=${BASH_REMATCH[2]}
      ((p >= 1 && p <= 65535)) || {
        ui_error "Porta invalida" "A porta deve estar entre 1 e 65535."
        return 1
      }
      c1=(firewall-cmd --permanent --"$action=$p/$proto")
      c2=(firewall-cmd --reload)
      extra="Porta: $p/$proto"
      ;;
    reload)
      c1=(firewall-cmd --reload)
      ;;
  esac
  local cmds
  cmds=$(cmd_line "${c1[@]}")
  ((${#c2[@]} > 0)) && cmds+=$'\n'$(cmd_line "${c2[@]}")
  extra+=$'\n'"Pode interromper SSH se a regra afetar a porta 22. Use console/IPMI."
  confirm_strong "Firewall" "$cmds" "$extra" || return 0
  if ! run_cmd "${c1[@]}"; then
    ui_error "Falha no firewall" "A sequencia foi interrompida." "$RUN_OUT"
    return 1
  fi
  if ((${#c2[@]} > 0)) && ! run_cmd "${c2[@]}"; then
    ui_error "Falha no reload" "A regra permanente foi gravada, mas o reload falhou." "$RUN_OUT"
    return 1
  fi
  ui_ok "Firewall atualizado" "Acao $action concluida."
}

selinux_status() {
  local out
  out="=== GETENFORCE ==="$'\n'"$(getenforce 2>&1)"$'\n\n'
  if command -v sestatus >/dev/null 2>&1; then
    out+="=== SESTATUS ==="$'\n'"$(sestatus 2>&1)"
  fi
  show_text "SELinux" "$out"
}

selinux_mode() {
  local target current backup conf
  local -a c1 c2
  need_bin getenforce libselinux-utils || return 1
  need_bin setenforce libselinux-utils || return 1
  current=$(getenforce 2>/dev/null)
  target=$(select_action "Modo SELinux" "Modo atual: ${current:-desconhecido}" \
    enforcing "! Enforcing - aplicar agora e persistir (destrutivo)" \
    permissive "! Permissive - aplicar agora e persistir (destrutivo)" \
    disabled "! Disabled - persistir e exigir reboot (destrutivo)") || return 1
  conf="/etc/selinux/config"
  backup="$conf.bak.$(date +%Y%m%d%H%M%S)"
  c1=()
  if [[ $current != Disabled && $target != disabled ]]; then
    if [[ $target == enforcing ]]; then
      c1=(setenforce 1)
    else
      c1=(setenforce 0)
    fi
  elif [[ $current != Disabled && $target == disabled ]]; then
    c1=(setenforce 0)
  fi
  c2=(cp -a "$conf" "$backup")
  local cmds extra
  cmds=""
  ((${#c1[@]} > 0)) && cmds+=$(cmd_line "${c1[@]}")$'\n'
  cmds+=$(cmd_line "${c2[@]}")$'\n'
  cmds+="sed -i $(q "s/^SELINUX=.*/SELINUX=$target/") $(q "$conf")"
  extra="Modo atual: ${current:-?} | Novo modo: $target"$'\n'"Backup: $backup"
  [[ $target == disabled ]] && extra+=$'\n'"O modo Disabled so tera efeito completo apos reboot."
  [[ $current == Disabled && $target != disabled ]] && extra+=$'\n'"SELinux esta desabilitado; habilitar exige reboot."
  confirm_strong "Alterar SELinux" "$cmds" "$extra" || return 0
  if ((${#c1[@]} > 0)); then
    if ! run_cmd "${c1[@]}"; then
      ui_error "Falha no SELinux" "A sequencia foi interrompida." "$RUN_OUT"
      return 1
    fi
  fi
  if ! run_cmd "${c2[@]}"; then
    ui_error "Falha no backup" "A sequencia foi interrompida." "$RUN_OUT"
    return 1
  fi
  if ! run_cmd sed -i "s/^SELINUX=.*/SELINUX=$target/" "$conf"; then
    ui_error "Falha ao persistir SELinux" "O modo runtime pode ter sido alterado." "$RUN_OUT"
    return 1
  fi
  ui_ok "SELinux atualizado" "Modo alvo: $target."$'\n'"Reboot pode ser necessario para Disabled/Enforcing."
}

selinux_booleans() {
  local bo onoff
  local -a c
  need_bin getsebool policycoreutils || return 1
  need_bin setsebool policycoreutils || return 1
  bo=$(ask "SELinux boolean" "Nome do booleano (ex.: httpd_can_network_connect):") || return 1
  [[ $bo =~ ^[A-Za-z0-9_]+$ ]] || {
    ui_error "Booleano invalido" "Informe um nome valido."
    return 1
  }
  getsebool "$bo" >/dev/null 2>&1 || {
    ui_error "Booleano ausente" "Booleano nao encontrado: $bo"
    return 1
  }
  onoff=$(select_action "Booleano $bo" "Valor:" \
    on "Ativar booleano (modifica o sistema)" \
    off "! Desativar booleano (destrutivo)") || return 1
  c=(setsebool -P "$bo" "$onoff")
  if [[ $onoff == off ]]; then
    confirm_strong "SELinux boolean" "$(cmd_line "${c[@]}")" \
      "Booleano: $bo | Valor: $onoff"$'\n'"Desativar um booleano pode reduzir a seguranca ou quebrar servicos." || return 0
  else
    confirm_exec "SELinux boolean" "$(cmd_line "${c[@]}")" \
      "Booleano: $bo | Valor: $onoff"$'\n'"Alteracao persistente." || return 0
  fi
  run_cmd "${c[@]}" || {
    ui_error "Falha no booleano" "A operacao foi interrompida." "$RUN_OUT"
    return 1
  }
  ui_ok "SELinux boolean" "$bo definido como $onoff."
}

selinux_denials() {
  local out
  if command -v ausearch >/dev/null 2>&1; then
    out=$(timeout 15 ausearch -m AVC,USER_AVC -ts recent 2>&1 | tail -n 200)
  elif [[ -r /var/log/audit/audit.log ]]; then
    out=$(grep -i 'avc:' /var/log/audit/audit.log 2>/dev/null | tail -n 200)
  else
    out="ausearch/audit.log nao disponivel."
  fi
  [[ -n $out ]] || out="Nenhuma negacao AVC recente."
  show_text "SELinux - negacoes recentes" "$out"
}

ssh_audit() {
  local out status
  if ((RHEL_VER >= 7)); then
    status=$(timeout 5 systemctl status sshd --no-pager 2>&1)
  else
    status=$(timeout 5 service sshd status 2>&1)
  fi
  out="=== SSHD STATUS ==="$'\n'"$status"$'\n\n'
  out+="=== CONFIGURACAO EFETIVA (FILTRADA) ==="$'\n'
  if ((RHEL_VER >= 7)); then
    out+="$(timeout 5 sshd -T 2>/dev/null | grep -Ei '^(port|permitrootlogin|passwordauthentication|pubkeyauthentication|maxauthtries|x11forwarding|allowtcpforwarding|logingracetime|usepam)' 2>&1)"$'\n\n'
  else
    out+="$(grep -Ei '^(Port|PermitRootLogin|PasswordAuthentication|PubkeyAuthentication|MaxAuthTries|X11Forwarding|AllowTcpForwarding|LoginGraceTime|UsePAM)' /etc/ssh/sshd_config 2>&1)"$'\n\n'
  fi
  out+="=== LISTEN ==="$'\n'"$(ss -tlnp 2>/dev/null | grep -E ':(22|2222)[[:space:]]' 2>&1)"
  show_text "SSH - auditoria" "$out"
}

ssh_test_config() {
  need_bin sshd openssh-server || return 1
  show_text "SSH - teste de configuracao" "$(timeout 5 sshd -t 2>&1; printf '\nrc=%s\n' "$?")"
}

security_menu() {
  local c
  while :; do
    c=$(select_action "Seguranca do sistema" "Firewall, SELinux e SSH. Cada opcao abre detalhes antes de executar." \
      1 "Consultar firewall (somente leitura)" \
      2 "Abrir opcoes de firewall (abre opcoes)" \
      3 "Consultar SELinux (somente leitura)" \
      4 "Abrir opcoes do SELinux (abre opcoes)" \
      5 "Alterar booleano do SELinux (modifica o sistema)" \
      6 "Consultar negacoes do SELinux (somente leitura)" \
      7 "Auditar configuracao do SSH (somente leitura)" \
      8 "Testar configuracao do SSH (somente leitura)" \
      0 "Voltar") || return 0
    case $c in
      1) firewall_status ;;
      2) firewall_change ;;
      3) selinux_status ;;
      4) selinux_mode ;;
      5) selinux_booleans ;;
      6) selinux_denials ;;
      7) ssh_audit ;;
      8) ssh_test_config ;;
      0) return 0 ;;
    esac
  done
}

time_status() {
  local out
  out="=== DATA/HORA ==="$'\n'"$(date 2>&1)"$'\n\n'
  if command -v timedatectl >/dev/null 2>&1; then
    out+="=== TIMEDATECTL ==="$'\n'"$(timedatectl 2>&1)"$'\n\n'
  fi
  out+="=== HWCLOCK ==="$'\n'"$(timeout 5 hwclock --show 2>&1)"$'\n\n'
  if command -v chronyc >/dev/null 2>&1; then
    out+="=== CHRONY ==="$'\n'"$(timeout 5 chronyc tracking 2>&1)"
  elif command -v ntpq >/dev/null 2>&1; then
    out+="=== NTPQ ==="$'\n'"$(timeout 5 ntpq -p 2>&1)"
  fi
  show_text "Data, hora e timezone" "$out"
}

timezone_change() {
  local tz backup cmds
  while :; do
    tz=$(ask "Timezone" "Timezone (ex.: America/Sao_Paulo):") || return 1
    if [[ $tz =~ ^[A-Za-z0-9_+/-]+$ && $tz != *..* && -f /usr/share/zoneinfo/$tz ]]; then
      break
    fi
    ui_error "Timezone invalido" "Informe um timezone existente em /usr/share/zoneinfo."
  done
  if ((RHEL_VER >= 7)); then
    need_bin timedatectl systemd || return 1
    cmds="timedatectl set-timezone $(q "$tz")"
    confirm_exec "Alterar timezone" "$cmds" "Novo timezone: $tz" || return 0
    run_cmd timedatectl set-timezone "$tz" || {
      ui_error "Falha no timezone" "A operacao foi interrompida." "$RUN_OUT"
      return 1
    }
  else
    backup="/etc/sysconfig/clock.bak.$(date +%Y%m%d%H%M%S)"
    cmds="cp -a /etc/sysconfig/clock $(q "$backup")"$'\n'
    cmds+="if grep -q '^ZONE=' /etc/sysconfig/clock; then sed -i $(q "s|^ZONE=.*|ZONE=\"$tz\"|") /etc/sysconfig/clock; else printf 'ZONE=\"%s\"\\n' $(q "$tz") >> /etc/sysconfig/clock; fi"$'\n'
    cmds+="ln -sf $(q "/usr/share/zoneinfo/$tz") /etc/localtime"$'\n'
    cmds+="timeout 10 hwclock --systohc"
    confirm_exec "Alterar timezone" "$cmds" "Novo timezone: $tz | Backup: $backup" || return 0
    if ! run_shell "$cmds"; then
      ui_error "Falha no timezone" "A sequencia foi interrompida. Backup: $backup" "$RUN_OUT"
      return 1
    fi
  fi
  ui_ok "Timezone atualizado" "Timezone definido para $tz."
}

ntp_status() {
  local out
  out="=== SERVICO ==="$'\n'
  if ((RHEL_VER >= 7)); then
    out+="$(timeout 5 systemctl status chronyd --no-pager 2>&1 | head -n 15)"
  else
    out+="$(timeout 5 service ntpd status 2>&1 | head -n 15)"
  fi
  out+=$'\n\n'"=== SINCRONIZACAO ==="$'\n'
  if command -v chronyc >/dev/null 2>&1; then
    out+="$(timeout 5 chronyc tracking 2>&1)"
  elif command -v ntpq >/dev/null 2>&1; then
    out+="$(timeout 5 ntpq -p 2>&1)"
  else
    out+="chronyc/ntpq nao disponivel."
  fi
  show_text "NTP / Chrony" "$out"
}

ntp_toggle() {
  local action cmds
  local -a c1 c2
  action=$(select_action "NTP" "Sincronizacao de horario do servidor." \
    on "Habilitar sincronizacao NTP (modifica o sistema)" \
    off "! Desabilitar sincronizacao NTP (destrutivo)") || return 1
  if ((RHEL_VER >= 7)); then
    need_bin timedatectl systemd || return 1
    if [[ $action == on ]]; then
      c1=(timedatectl set-ntp true)
    else
      c1=(timedatectl set-ntp false)
    fi
  else
    if [[ $action == on ]]; then
      c1=(chkconfig ntpd on)
      c2=(service ntpd start)
    else
      c1=(service ntpd stop)
      c2=(chkconfig ntpd off)
    fi
  fi
  cmds=$(cmd_line "${c1[@]}")
  ((${#c2[@]} > 0)) && cmds+=$'\n'$(cmd_line "${c2[@]}")
  if [[ $action == on ]]; then
    confirm_exec "Habilitar NTP" "$cmds" "Requer chronyd/ntpd instalado e repositorio de tempo acessivel." || return 0
  else
    confirm_strong "Desabilitar NTP" "$cmds" "O relogio pode perder sincronizacao." || return 0
  fi
  run_cmd "${c1[@]}" || {
    ui_error "Falha no NTP" "A sequencia foi interrompida." "$RUN_OUT"
    return 1
  }
  if ((${#c2[@]} > 0)); then
    run_cmd "${c2[@]}" || {
      ui_error "Falha no NTP" "A sequencia foi interrompida." "$RUN_OUT"
      return 1
    }
  fi
  ui_ok "NTP atualizado" "Acao $action concluida."
}

sysctl_view() {
  local out
  out="=== VALORES PRINCIPAIS ==="$'\n'
  out+="$(sysctl kernel.hostname kernel.pid_max fs.file-max vm.swappiness net.ipv4.ip_forward net.ipv4.tcp_syncookies 2>&1)"$'\n\n'
  out+="=== ARQUIVOS DE CONFIGURACAO ==="$'\n'
  out+="$(ls -l /etc/sysctl.conf /etc/sysctl.d/*.conf 2>&1)"
  show_text "Sysctl" "$out"
}

sysctl_set() {
  local key value mode current file backup cmds re
  local -a c
  re='^[A-Za-z0-9 _.,:/-]+$'
  while :; do
    key=$(ask "Sysctl" "Chave (ex.: net.ipv4.ip_forward):") || return 1
    [[ $key =~ ^[A-Za-z0-9_.-]+$ ]] && sysctl -n "$key" >/dev/null 2>&1 && break
    ui_error "Chave invalida" "Informe uma chave sysctl existente."
  done
  current=$(sysctl -n "$key" 2>/dev/null)
  while :; do
    value=$(ask "Sysctl" "Novo valor para $key (atual: ${current:-?}):") || return 1
    [[ $value =~ $re ]] && break
    ui_error "Valor invalido" "Use letras, numeros, espaco, ponto, virgula, dois-pontos, barra ou hifen."
  done
  mode=$(select_action "Aplicar sysctl" "Escolha o escopo da alteracao." \
    runtime "Aplicar temporariamente (modifica o sistema; volta ao reboot)" \
    persistent "! Aplicar permanentemente (destrutivo; sobrevive ao reboot)") || return 1
  if [[ $mode == runtime ]]; then
    c=(sysctl -w "$key=$value")
    confirm_exec "Sysctl temporario" "$(cmd_line "${c[@]}")" "$key: $current -> $value" || return 0
    run_cmd "${c[@]}" || {
      ui_error "Falha no sysctl" "A operacao foi interrompida." "$RUN_OUT"
      return 1
    }
  else
    file="/etc/sysctl.d/99-rhel-admin.conf"
    backup="$file.bak.$(date +%Y%m%d%H%M%S)"
    cmds="if [ -f $(q "$file") ]; then cp -a $(q "$file") $(q "$backup"); awk -v k=$(q "$key") 'index(\$0, k \"=\") != 1 {print}' $(q "$file") > $(q "$file.rhel_admin.tmp"); chmod --reference=$(q "$file") $(q "$file.rhel_admin.tmp"); else : > $(q "$file.rhel_admin.tmp"); chmod 644 $(q "$file.rhel_admin.tmp"); fi"$'\n'
    cmds+="mv $(q "$file.rhel_admin.tmp") $(q "$file")"$'\n'
    cmds+="printf '%s=%s\\n' $(q "$key") $(q "$value") >> $(q "$file")"$'\n'
    cmds+="sysctl -w $(q "$key=$value")"
    confirm_strong "Sysctl persistente" "$cmds" \
      "$key: $current -> $value"$'\n'"Arquivo: $file | Backup: $backup" || return 0
    if ! run_shell "$cmds"; then
      ui_error "Falha no sysctl" "A sequencia foi interrompida." "$RUN_OUT"
      return 1
    fi
  fi
  ui_ok "Sysctl aplicado" "$key = $value."
}

boot_info() {
  local out
  out="=== KERNEL ATUAL ==="$'\n'"$(uname -r 2>&1)"$'\n\n'
  if ((RHEL_VER >= 7)); then
    out+="=== DEFAULT TARGET ==="$'\n'"$(systemctl get-default 2>&1)"$'\n\n'
    if command -v grubby >/dev/null 2>&1; then
      out+="=== KERNEL PADRAO ==="$'\n'"$(grubby --default-kernel 2>&1)"$'\n\n'
    fi
  else
    out+="=== RUNLEVEL PADRAO ==="$'\n'"$(grep -E '^id:' /etc/inittab 2>&1)"$'\n\n'
  fi
  out+="=== KERNELS INSTALADOS ==="$'\n'"$(ls -1 /boot/vmlinuz-* 2>&1)"
  show_text "Boot e kernel" "$out"
}

reboot_system() {
  local -a c=(shutdown -r now "Reboot solicitado por RHEL Admin Manager")
  confirm_strong "Reiniciar servidor" "$(cmd_line "${c[@]}")" \
    "Todos os servicos e sessoes serao encerrados." || return 0
  log_event INICIO 0 "$(cmd_line "${c[@]}")"
  run_cmd "${c[@]}"
}

shutdown_system() {
  local -a c=(shutdown -h now "Desligamento solicitado por RHEL Admin Manager")
  confirm_strong "Desligar servidor" "$(cmd_line "${c[@]}")" \
    "O servidor sera desligado e precisara de intervencao para voltar." || return 0
  log_event INICIO 0 "$(cmd_line "${c[@]}")"
  run_cmd "${c[@]}"
}

cancel_shutdown() {
  local -a c=(shutdown -c)
  confirm_exec "Cancelar shutdown" "$(cmd_line "${c[@]}")" "Cancela agendamentos de shutdown pendentes." || return 0
  run_cmd "${c[@]}" || {
    ui_error "Falha ao cancelar" "Nao havia shutdown agendado ou a operacao falhou." "$RUN_OUT"
    return 1
  }
  ui_ok "Shutdown cancelado" "Agendamentos pendentes foram cancelados."
}

system_menu() {
  local c
  while :; do
    c=$(select_action "Sistema e energia" "Data/hora, NTP, kernel e energia. Cada opcao abre detalhes antes de executar." \
      1 "Consultar data, hora e timezone (somente leitura)" \
      2 "Alterar timezone (modifica o sistema)" \
      3 "Consultar NTP/chrony (somente leitura)" \
      4 "Abrir opcoes de NTP (abre opcoes)" \
      5 "Consultar sysctl (somente leitura)" \
      6 "! Aplicar sysctl (modifica o sistema)" \
      7 "Consultar boot e kernel (somente leitura)" \
      8 "! Reiniciar servidor (destrutivo)" \
      9 "! Desligar servidor (destrutivo)" \
      10 "Cancelar shutdown (modifica o sistema)" \
      0 "Voltar") || return 0
    case $c in
      1) time_status ;;
      2) timezone_change ;;
      3) ntp_status ;;
      4) ntp_toggle ;;
      5) sysctl_view ;;
      6) sysctl_set ;;
      7) boot_info ;;
      8) reboot_system ;;
      9) shutdown_system ;;
      10) cancel_shutdown ;;
      0) return 0 ;;
    esac
  done
}

help_menu() {
  local c
  while :; do
    c=$(select_action "Ajuda e compatibilidade" "Consulte instrucoes e diferencas entre versoes. Cada opcao abre detalhes." \
      1 "Ajuda rapida (somente leitura)" \
      2 "Compatibilidade da versao (somente leitura)" \
      0 "Voltar") || return 0
    case $c in
      1) show_text "Ajuda rapida" "$(help_text)" ;;
      2) show_text "Compatibilidade $RHEL_LABEL" "$(version_profile_text)" ;;
      0) return 0 ;;
    esac
  done
}

audit_menu() {
  local c
  while :; do
    c=$(select_action "Auditoria e logs" "Somente leitura. Cada opcao abre detalhes. Arquivo: $LOG_FILE" \
      1 "Consultar ultimas 200 linhas (somente leitura)" \
      2 "Consultar erros e falhas (somente leitura)" \
      3 "Consultar status do arquivo de log (somente leitura)" \
      0 "Voltar") || return 0
    case $c in
      1) log_recent ;;
      2) log_errors ;;
      3) log_status ;;
      0) return 0 ;;
    esac
  done
}

lvm_menu() {
  local c
  while :; do
    c=$(select_action "LVM e File Systems" "Escolha a tarefa. Cada opcao abre detalhes e mostra o impacto." \
      1 "Consultar volumes e filesystems (somente leitura)" \
      2 "Criar volume logico (modifica o sistema)" \
      3 "Ampliar volume logico e filesystem (modifica o sistema)" \
      4 "! Formatar volume logico (destrutivo)" \
      5 "Montar filesystem e gravar no fstab (modifica o sistema)" \
      6 "! Desmontar filesystem e remover do fstab (destrutivo)" \
      7 "! Excluir volume logico (destrutivo)" \
      0 "Voltar") || return 0
    case $c in
      1) lvm_overview ;;
      2) create_lv ;;
      3) extend_lv ;;
      4) create_fs_lv ;;
      5) mount_fs ;;
      6) unmount_fs ;;
      7) delete_lv ;;
      0) return 0 ;;
    esac
  done
}

network_menu() {
  local c
  while :; do
    c=$(select_action "Rede e conectividade" "Backend: $(version_network_backend). Alteracoes podem interromper o SSH; cada opcao abre detalhes." \
      1 "Consultar interfaces e enderecos (somente leitura)" \
      2 "! Alterar IPv4 (modifica a rede; pode afetar SSH)" \
      3 "! Configurar heartbeat (modifica a rede; pode afetar SSH)" \
      4 "! Alterar para DHCP (modifica a rede; pode afetar SSH)" \
      5 "Testar conectividade (somente leitura)" \
      6 "Consultar rotas, DNS e ARP (somente leitura)" \
      7 "Definir hostname e /etc/hosts (modifica o sistema)" \
      0 "Voltar") || return 0
    case $c in
      1) network_interfaces ;;
      2) configure_network full ;;
      3) configure_network heartbeat ;;
      4) configure_dhcp ;;
      5) test_connectivity ;;
      6) network_details ;;
      7) configure_hostname ;;
      0) return 0 ;;
    esac
  done
}

storage_menu() {
  local c
  while :; do
    c=$(select_action "Discos e barramento" "Consultas e reescaneamento. Cada opcao abre detalhes antes de executar." \
      1 "Reescanear barramento SCSI/FC (modifica o sistema)" \
      2 "Consultar discos e particoes (somente leitura)" \
      3 "Consultar multipath e HBAs (somente leitura)" \
      0 "Voltar") || return 0
    case $c in
      1) rescan_storage ;;
      2) list_disks ;;
      3) storage_health ;;
      0) return 0 ;;
    esac
  done
}

diag_menu() {
  local c
  while :; do
    c=$(select_action "Diagnostico e logs" "Somente leitura. Cada opcao abre detalhes e nao altera o sistema." \
      1 "Resumo de CPU, memoria, disco e uptime (somente leitura)" \
      2 "Status dos servicos essenciais (somente leitura)" \
      3 "Rede: rotas, DNS e ARP (somente leitura)" \
      4 "Logs recentes do sistema (somente leitura)" \
      5 "Inventario de hardware (somente leitura)" \
      6 "Auditoria do painel (somente leitura)" \
      0 "Voltar") || return 0
    case $c in
      1) diagnostics ;;
      2) service_status ;;
      3) network_details ;;
      4) recent_logs ;;
      5) hardware_info ;;
      6) audit_menu ;;
      0) return 0 ;;
    esac
  done
}

main_menu() {
  local c
  while :; do
    c=$(show_menu "Painel do administrador" "Escolha uma area. As acoes internas abrem detalhes e informam o impacto antes de executar." \
      1 "Visao geral do servidor (somente leitura)" \
      2 "Armazenamento: LVM, discos e swap (abre menu)" \
      3 "Rede e conectividade (abre menu)" \
      4 "Usuarios e grupos (abre menu)" \
      5 "Servicos e processos (abre menu)" \
      6 "Pacotes e atualizacoes (abre menu)" \
      7 "Seguranca: firewall, SELinux e SSH (abre menu)" \
      8 "Sistema: hora, NTP, kernel e energia (abre menu)" \
      9 "Diagnostico e logs (abre menu)" \
      10 "Operacoes em lote (TMUX) (abre menu)" \
      11 "Ajuda e compatibilidade (abre menu)" \
      0 "Sair do painel") || return 0
    case $c in
      1) dashboard ;;
      2) storage_root_menu ;;
      3) network_menu ;;
      4) users_menu ;;
      5) services_menu ;;
      6) packages_menu ;;
      7) security_menu ;;
      8) system_menu ;;
      9) diag_menu ;;
      10) batch_menu ;;
      11) help_menu ;;
      0) return 0 ;;
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
  [[ $BATCH_SSH_USER =~ ^[A-Za-z_][A-Za-z0-9_-]*$ ]] || BATCH_SSH_USER=$(id -un)
  BATCH_DEFAULT_USER=${BATCH_DEFAULT_USER:-$BATCH_SSH_USER}
  [[ $BATCH_DEFAULT_USER =~ ^[A-Za-z_][A-Za-z0-9_-]*$ ]] || BATCH_DEFAULT_USER=$BATCH_SSH_USER
  detect_release
  set_ui
  init_theme
  if ! check_release; then
    return 1
  fi
  LOG_USER=${SUDO_USER:-$(id -un)}
  init_log
  log_event INICIO 0 "inicio da sessao | release=$RELEASE_NAME"
  show_text "Dashboard - $RHEL_LABEL" "$(dashboard_text)"
  main_menu
  log_event FIM 0 "fim da sessao"
  printf 'Log de auditoria: %s\n' "$LOG_FILE"
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  main "$@"
fi
