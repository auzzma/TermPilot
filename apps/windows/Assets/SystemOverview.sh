# Copied from the independent macOS presentation adapter; no runtime dependency.
export LC_ALL=C
if [ "$(uname -s)" = "Darwin" ]; then
set +e
cores=$(sysctl -n hw.logicalcpu 2>/dev/null || echo "1")
pagesize=$(sysctl -n hw.pagesize 2>/dev/null || echo "4096")
memsize=$(sysctl -n hw.memsize 2>/dev/null || echo "0")
memtotal=$(printf "%s" "$memsize" | awk '{printf "%.0f",$1/1024/1024}')
printf "CPU_CORES=%s\n" "$cores"
ps -A -o %cpu= 2>/dev/null | awk -v c="$cores" '{s+=$1} END{if(c<=0)c=1;s=s/c;if(s<0)s=0;if(s>100)s=100;printf "CPU=%.1f\n",s}'
vm_stat 2>/dev/null | awk -v ps="$pagesize" -v mt="$memtotal" '
/^Pages free:/{gsub(/[^0-9]/,"",$NF);free=$NF+0}
/^Pages speculative:/{gsub(/[^0-9]/,"",$NF);spec=$NF+0}
/^Pages inactive:/{gsub(/[^0-9]/,"",$NF);inact=$NF+0}
/^Pages purgeable:/{gsub(/[^0-9]/,"",$NF);purg=$NF+0}
END{
    mfree=(free+spec)*ps/1024/1024
    mcached=(inact+purg)*ps/1024/1024
    mused=mt-mfree-mcached
    if(mused<0)mused=0
    percent=mt>0?mused*100/mt:0
    printf "MEM_USED_MB=%.0f\nMEM_TOTAL_MB=%.0f\nMEM_PERCENT=%.1f\n",mused,mt,percent
}'
sysctl vm.swapusage 2>/dev/null | awk '{
    for(i=1;i<=NF;i++){
        if($i=="total"&&$(i+1)=="="){v=$(i+2);m=1;if(v~/[Gg]/)m=1024;gsub(/[MmGg]/,"",v);st=v*m}
        if($i=="used"&&$(i+1)=="="){v=$(i+2);m=1;if(v~/[Gg]/)m=1024;gsub(/[MmGg]/,"",v);su=v*m}
    }
    printf "SWAP=%.0f MB / %.0f MB\n",su+0,st+0
}'
mounts=$(mount 2>/dev/null || true)
diskrows=$({ printf "%s\n" "$mounts"; printf "__TERMPILOT_DF__\n"; df -kP 2>/dev/null; } | awk '
$0=="__TERMPILOT_DF__"{in_df=1;next}
!in_df{
    if($1~/^\/dev\/disk/&&(index($0,"(apfs,")||index($0,"(apfs)"))){
        key=$1
        sub(/s[0-9].*$/,"",key)
        capacity[$1]="apfs:" key
    }
    next
}
$1=="Filesystem"{next}
index($1,"/dev/")==1{
    m=$6
    if(m=="/"||index(m,"/Volumes/")==1){
        t=$2/1048576
        key=(($1 in capacity)?capacity[$1]:$1)
        if(key~/^apfs:/){
            u=($2-$4)/1048576
            p=(t>0?int(u*100/t+0.5):0)
        }else{
            u=$3/1048576
            p=$5
            gsub(/%/,"",p)
        }
        printf "DISK=%s|%.6f|%.6f|%s\n",m,u,t,p
    }
}')
printf "%s\n" "$diskrows"
printf "%s\n" "$diskrows" | awk -F'[=|]' '$1=="DISK"&&$2=="/"{printf "DISK_USED_GB=%s\nDISK_TOTAL_GB=%s\nDISK_PERCENT=%s\n",$3,$4,$5;exit}'
netstat -ibn 2>/dev/null | awk '
NR==1{
    for(i=1;i<=NF;i++){
        if($i=="Ibytes")ib=i
        if($i=="Obytes")ob=i
    }
    next
}
ib&&ob&&$1~/^[[:alpha:]]/&&$1!~/^lo/&&$0~/<Link#/{
    name=$1
    gsub(/[*]/,"",name)
    rxByName[name]=$(ib)+0
    txByName[name]=$(ob)+0
}
END{
    for(name in rxByName){
        rx+=rxByName[name]
        tx+=txByName[name]
        printf "NETIF_BYTES=%s|%.0f|%.0f\n",name,rxByName[name],txByName[name]
    }
    printf "NET_RX_BYTES=%.0f\nNET_TX_BYTES=%.0f\n",rx,tx
}'
sysctl -n vm.loadavg 2>/dev/null | tr -d '{}' | awk 'NF>=3{printf "LOAD=%s / %s / %s\n",$1,$2,$3}'
bootsec=$(sysctl -n kern.boottime 2>/dev/null | awk -F'[ ,]+' '{for(i=1;i<=NF;i++){if($i=="sec"){print $(i+2);exit}}}')
nowsec=$(date +%s 2>/dev/null || echo "0")
awk -v n="$nowsec" -v b="$bootsec" 'BEGIN{if(n>0&&b>0){u=n-b;printf "UPTIME_DAYS=%d\nUPTIME_HOURS=%d\n",u/86400,(u%86400)/3600}}'
ps -A -o pid= -o pmem= -o comm= 2>/dev/null | sort -k2 -nr | head -5 | awk '{printf "TOPPROC=%s|%.1f|%s\n",$1,$2,$3}'
osname=$(printf "%s %s" "$(sw_vers -productName 2>/dev/null)" "$(sw_vers -productVersion 2>/dev/null)" | sed 's/[[:space:]]*$//')
printf "OS=%s\nKERNEL=%s\n" "${osname:-Darwin}" "$(uname -r 2>/dev/null)"
else
set +e
awk '/^cpu /{total=0;for(i=2;i<=NF;i++)total+=$i;printf "CPU_RAW=%.0f|%.0f|%.0f|%.0f\n",total,$5,$2+$3,$4+$7+$8}' /proc/stat 2>/dev/null
awk '/^cpu[0-9]+ /{total=0;for(i=2;i<=NF;i++)total+=$i;printf "CPU_CORE_RAW=%s|%.0f|%.0f\n",substr($1,4),total,$5}' /proc/stat 2>/dev/null
awk 'BEGIN{count=0}/^cpu[0-9]+ /{count++}END{if(count>0)printf "CPU_CORES=%d\n",count}' /proc/stat 2>/dev/null
awk '
/^MemTotal:/{mt=$2}
/^MemFree:/{mf=$2}
/^Buffers:/{mb=$2}
/^Cached:/{mc=$2}
/^SReclaimable:/{ms=$2}
/^SwapTotal:/{st=$2}
/^SwapFree:/{sf=$2}
END{
    cached=mc+ms
    used=mt-mf-mb-cached
    if(used<0)used=0
    if(mt>0)printf "MEM_USED_MB=%.0f\nMEM_TOTAL_MB=%.0f\nMEM_PERCENT=%.1f\n",used/1024,mt/1024,used*100/mt
    if(st>0)printf "SWAP=%.0f MB / %.0f MB\n",(st-sf)/1024,st/1024
    else print "SWAP=0 MB / 0 MB"
}' /proc/meminfo 2>/dev/null
df -kP 2>/dev/null | awk '
NR>1 && $1 !~ /^\/dev\/loop/ && ($6=="/" || ($1~/^\/dev\// && $6!~/^\/(etc|proc|sys|dev)(\/|$)/)){
    total=$2/1048576
    used=$3/1048576
    percent=$5
    gsub(/%/,"",percent)
    printf "DISK=%s|%.6f|%.6f|%s\n",$6,used,total,percent
    if($6=="/")printf "DISK_USED_GB=%.6f\nDISK_TOTAL_GB=%.6f\nDISK_PERCENT=%s\n",used,total,percent
}'
awk -F":" '
NR>2{
    name=$1
    gsub(/^[[:space:]]+|[[:space:]]+$/,"",name)
    if(name!="lo" && name!~/^veth/ && name!~/^docker/ && name!~/^br-/){
        data=$2
        sub(/^[[:space:]]+/,"",data)
        split(data,fields,/[[:space:]]+/)
        rx+=fields[1]
        tx+=fields[9]
        printf "NETIF_BYTES=%s|%.0f|%.0f\n",name,fields[1],fields[9]
    }
}
END{printf "NET_RX_BYTES=%.0f\nNET_TX_BYTES=%.0f\n",rx,tx}' /proc/net/dev 2>/dev/null
awk '{print "LOAD="$1" / "$2" / "$3}' /proc/loadavg 2>/dev/null
awk '{printf "UPTIME_DAYS=%d\nUPTIME_HOURS=%d\n",$1/86400,($1%86400)/3600}' /proc/uptime 2>/dev/null
if procraw=$(ps -eo pid,%mem,comm --sort=-%mem 2>/dev/null); then
    printf "%s\n" "$procraw" | awk 'NR>1 && NR<=6{printf "TOPPROC=%s|%.1f|%s\n",$1,$2,$3}'
elif topraw=$(top -b -n 1 2>/dev/null); then
    printf "%s\n" "$topraw" | awk '
    $1=="PID"{
        for(i=1;i<=NF;i++){
            if($i=="%VSZ" || $i=="%MEM")mem_col=i
            else if($i=="COMMAND")cmd_col=i
        }
        next
    }
    $1~/^[0-9]+$/ && mem_col && cmd_col{
        pct=$(mem_col)
        gsub(/%/,"",pct)
        print pct "|" $1 "|" $(cmd_col)
    }' | sort -t '|' -k1,1rn | head -5 | awk -F'|' '{printf "TOPPROC=%s|%.1f|%s\n",$2,$1,$3}'
else
    memtotal=$(awk '/^MemTotal:/{print $2}' /proc/meminfo 2>/dev/null)
    ps ww 2>/dev/null | awk -v total="$memtotal" '
    $1~/^[0-9]+$/{
        value=$3
        unit=substr(value,length(value),1)
        multiplier=1
        if(unit=="m" || unit=="M")multiplier=1024
        else if(unit=="g" || unit=="G")multiplier=1048576
        sub(/[mMgG]$/,"",value)
        percent=total>0?value*multiplier*100/total:0
        print percent "|" $1 "|" $5
    }' | sort -t '|' -k1,1rn | head -5 | awk -F'|' '{printf "TOPPROC=%s|%.1f|%s\n",$2,$1,$3}'
fi
if [ -r /etc/os-release ]; then . /etc/os-release; fi
printf "OS=%s\nKERNEL=%s\n" "${PRETTY_NAME:-$(uname -s 2>/dev/null)}" "$(uname -r 2>/dev/null)"
fi
