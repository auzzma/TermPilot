import SwiftUI
import TermPilotDomain
import TermPilotRemote
import TermPilotTerminal

private extension TerminalSidePanelTab {
    var title: LocalizedStringKey {
        switch self {
        case .sftp:
            "SFTP"
        case .system:
            "System"
        case .scripts:
            "Scripts"
        case .history:
            "Command History"
        case .notes:
            "Notes"
        case .forwarding:
            "Forwarding"
        }
    }

    var systemImage: String {
        switch self {
        case .sftp:
            "folder"
        case .system:
            "waveform.path.ecg"
        case .scripts:
            "terminal"
        case .history:
            "clock.arrow.circlepath"
        case .notes:
            "note.text"
        case .forwarding:
            "arrow.left.arrow.right"
        }
    }
}

struct TerminalSessionSidePanel: View {
    @EnvironmentObject private var state: AppState
    let workspaceID: UUID
    let host: TermPilotDomain.Host
    @ObservedObject var runtime: TerminalSessionRuntime
    @ObservedObject var sftpModel: SFTPBrowserModel
    @ObservedObject var commandHistoryModel: CommandHistoryModel
    @State private var hoveredTab: TerminalSidePanelTab?
    @State private var serverToolsUsername: String?
    @State private var serverToolsAccountUnavailable = false

    private var availableTabs: [TerminalSidePanelTab] {
        TerminalSidePanelTab.available(for: runtime.descriptor.kind)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                ForEach(availableTabs) { tab in
                    sidePanelTabButton(tab)
                }

                Spacer(minLength: 8)

                Button {
                    state.closeTerminalSidePanel(in: workspaceID)
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .help("Close")
            }
            .padding(8)
            .background(.bar)
            .zIndex(1)
            Divider()
            accountStatusBar
            Divider()

            switch state.terminalSidePanelTab(in: workspaceID) {
            case .sftp:
                SFTPBrowserView(
                    model: sftpModel,
                    presentation: runtime.descriptor.kind == .local
                        ? .localSidebar
                        : .remoteSidebar,
                    terminalSessionID: runtime.descriptor.id,
                    terminalCurrentDirectory: runtime.currentDirectory,
                    closesOnDisappear: false
                )
                .id(ObjectIdentifier(sftpModel))
                .environmentObject(state)
            case .system:
                SessionSystemMonitorPanel(
                    workspaceID: workspaceID,
                    host: host,
                    runtime: runtime
                )
                    .environmentObject(state)
            case .scripts:
                SessionScriptsPanel(runtime: runtime)
                    .environmentObject(state)
            case .history:
                SessionCommandHistoryPanel(
                    model: commandHistoryModel,
                    runtime: runtime
                )
                .environmentObject(state)
            case .notes:
                SessionHostNotesPanel(
                    host: host,
                    noteHostID: runtime.descriptor.kind == .local
                        ? nil
                        : host.id
                )
                    .environmentObject(state)
            case .forwarding:
                SessionPortForwardingPanel(host: host)
                    .environmentObject(state)
            }
        }
        .task(id: serverToolsAccountProbeID) {
            await probeServerToolsAccount()
        }
    }

    private var accountStatusBar: some View {
        HStack(spacing: 10) {
            accountStatus(
                title: "Terminal Account",
                username: runtime.currentUser
                    ?? runtime.descriptor.username
                    ?? AppLocalization.string("Unknown"),
                isUnavailable: false
            )
            Spacer(minLength: 8)
            accountStatus(
                title: "Server Tools Account",
                username: serverToolsAccountUnavailable
                    ? AppLocalization.string("Unavailable")
                    : serverToolsUsername
                        ?? AppLocalization.string("Unknown"),
                isUnavailable: serverToolsAccountUnavailable
            )
        }
        .padding(.horizontal, 10)
        .frame(height: 26)
        .background(.bar)
    }

    private func accountStatus(
        title: LocalizedStringKey,
        username: String,
        isUnavailable: Bool
    ) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "person.crop.circle")
            Text(title)
            Text(username)
                .font(.caption2.monospaced().weight(.semibold))
        }
        .font(.caption2)
        .foregroundStyle(
            isUnavailable
                ? Color.red
                : (username == "root" ? Color.orange : Color.secondary)
        )
        .lineLimit(1)
    }

    private var serverToolsAccountProbeID: String {
        [
            runtime.descriptor.sshConnectionID?.uuidString ?? "local",
            String(host.serverToolsUseRoot),
            host.serverToolsElevationMethod.rawValue,
            String(describing: runtime.lifecycle),
        ].joined(separator: "-")
    }

    private func probeServerToolsAccount() async {
        guard runtime.descriptor.kind == .ssh else {
            serverToolsUsername = NSUserName()
            serverToolsAccountUnavailable = false
            return
        }
        guard runtime.lifecycle == .connected else {
            serverToolsUsername = nil
            serverToolsAccountUnavailable = false
            return
        }

        let elevatesOperations =
            host.serverToolsUseRoot
            && host.username != "root"
        do {
            let response = try await state.execServerTool(
                in: workspaceID,
                host: host,
                sourceConnectionID: runtime.descriptor.sshConnectionID,
                sourceSessionID: runtime.descriptor.id,
                command: "id -un",
                timeoutMS: 8_000,
                elevated: elevatesOperations
            )
            let username = response.stdout
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard response.code == nil || response.code == 0,
                  !username.isEmpty
            else {
                throw SSH2SFTPBridgeError.remote(
                    response.stderr.trimmingCharacters(
                        in: .whitespacesAndNewlines
                    )
                )
            }
            serverToolsUsername = username
            serverToolsAccountUnavailable = false
        } catch is CancellationError {
        } catch {
            serverToolsUsername = nil
            serverToolsAccountUnavailable = true
        }
    }

    private func sidePanelTabButton(
        _ tab: TerminalSidePanelTab
    ) -> some View {
        let isSelected =
            state.terminalSidePanelTab(in: workspaceID) == tab
        let isHovered = hoveredTab == tab

        return Button {
            state.selectTerminalSidePanelTab(
                tab,
                in: workspaceID
            )
        } label: {
            Image(systemName: tab.systemImage)
                .font(.system(size: 14, weight: .semibold))
                .frame(width: 38, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(isSelected ? Color.white : Color.primary)
        .background(
            isSelected
                ? Color.accentColor
                : (isHovered ? Color.secondary.opacity(0.14) : Color.clear),
            in: RoundedRectangle(cornerRadius: 7, style: .continuous)
        )
        .accessibilityLabel(Text(tab.title))
        .onHover { hovering in
            if hovering {
                hoveredTab = tab
            } else if hoveredTab == tab {
                hoveredTab = nil
            }
        }
        .overlay(alignment: .bottom) {
            if isHovered {
                Text(tab.title)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                    .fixedSize()
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(
                        .regularMaterial,
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(Color.primary.opacity(0.12), lineWidth: 1)
                    }
                    .shadow(color: .black.opacity(0.2), radius: 8, y: 3)
                    .offset(y: 36)
                    .allowsHitTesting(false)
            }
        }
        .zIndex(isHovered ? 2 : 0)
    }
}

private enum SystemMonitorTab: String, CaseIterable, Identifiable {
    case overview
    case processes
    case docker

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .overview:
            "Overview"
        case .processes:
            "Processes"
        case .docker:
            "Docker"
        }
    }
}

enum SessionSystemMonitorRefreshPolicy {
    static func isEnabled(
        sessionKind: SessionKind,
        lifecycle: SessionLifecycle
    ) -> Bool {
        switch sessionKind {
        case .local:
            true
        case .ssh:
            lifecycle == .connected
        }
    }
}

struct SystemNetworkByteCounters: Equatable, Sendable {
    var rxBytes: UInt64
    var txBytes: UInt64
}

struct SystemNetworkByteRates: Equatable, Sendable {
    var rxBps: Double
    var txBps: Double
}

enum SystemNetworkRateCalculator {
    static func rates(
        current: SystemNetworkByteCounters,
        previous: SystemNetworkByteCounters,
        elapsed: TimeInterval
    ) -> SystemNetworkByteRates? {
        guard elapsed > 0,
              current.rxBytes >= previous.rxBytes,
              current.txBytes >= previous.txBytes
        else {
            return nil
        }

        return SystemNetworkByteRates(
            rxBps: Double(current.rxBytes - previous.rxBytes) / elapsed,
            txBps: Double(current.txBytes - previous.txBytes) / elapsed
        )
    }
}

struct SystemCPUCoreJiffyCounters: Equatable, Sendable {
    var id: Int
    var total: UInt64
    var idle: UInt64
}

struct SystemCPUJiffyCounters: Equatable, Sendable {
    var total: UInt64
    var idle: UInt64
    var user: UInt64
    var system: UInt64
    var cores: [SystemCPUCoreJiffyCounters]
}

struct SystemCPUUsagePercentages: Equatable, Sendable {
    var total: Double
    var user: Double
    var system: Double
    var perCore: [Double]
}

enum SystemCPUUsageCalculator {
    static func usage(
        current: SystemCPUJiffyCounters,
        previous: SystemCPUJiffyCounters
    ) -> SystemCPUUsagePercentages? {
        guard current.total > previous.total,
              current.idle >= previous.idle,
              current.user >= previous.user,
              current.system >= previous.system
        else {
            return nil
        }
        let totalDelta = current.total - previous.total
        let idleDelta = current.idle - previous.idle
        guard idleDelta <= totalDelta else {
            return nil
        }

        let total = clamp(
            100 - Double(idleDelta) * 100 / Double(totalDelta)
        ).rounded()
        let user = clamp(
            Double(current.user - previous.user) * 100
                / Double(totalDelta)
        )
        let system = clamp(
            Double(current.system - previous.system) * 100
                / Double(totalDelta)
        )
        let previousCores = Dictionary(
            uniqueKeysWithValues: previous.cores.map { ($0.id, $0) }
        )
        let perCore = current.cores.sorted { $0.id < $1.id }.map { core in
            guard let previousCore = previousCores[core.id],
                  core.total > previousCore.total,
                  core.idle >= previousCore.idle
            else {
                return 0.0
            }
            let coreTotalDelta = core.total - previousCore.total
            let coreIdleDelta = core.idle - previousCore.idle
            guard coreIdleDelta <= coreTotalDelta else {
                return 0.0
            }
            return clamp(
                100 - Double(coreIdleDelta) * 100
                    / Double(coreTotalDelta)
            ).rounded()
        }
        return SystemCPUUsagePercentages(
            total: total,
            user: user,
            system: system,
            perCore: perCore
        )
    }

    private static func clamp(_ value: Double) -> Double {
        min(100, max(0, value))
    }
}

enum SystemOverviewCommand {
    static var command: String {
        """
        ostype=$(uname -s 2>/dev/null || echo "Unknown")
        if [ "$ostype" = "Darwin" ]; then
        \(macOSScript)
        else
        \(linuxScript)
        fi
        """
    }

    static let macOSScript = """
    set +e
    cores=$(sysctl -n hw.logicalcpu 2>/dev/null || echo "1")
    pagesize=$(sysctl -n hw.pagesize 2>/dev/null || echo "4096")
    memsize=$(sysctl -n hw.memsize 2>/dev/null || echo "0")
    memtotal=$(printf "%s" "$memsize" | awk '{printf "%.0f",$1/1024/1024}')
    printf "CPU_CORES=%s\\n" "$cores"
    ps -A -o %cpu= 2>/dev/null | awk -v c="$cores" '{s+=$1} END{if(c<=0)c=1;s=s/c;if(s<0)s=0;if(s>100)s=100;printf "CPU=%.1f\\n",s}'
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
        printf "MEM_USED_MB=%.0f\\nMEM_TOTAL_MB=%.0f\\nMEM_PERCENT=%.1f\\n",mused,mt,percent
    }'
    sysctl vm.swapusage 2>/dev/null | awk '{
        for(i=1;i<=NF;i++){
            if($i=="total"&&$(i+1)=="="){v=$(i+2);m=1;if(v~/[Gg]/)m=1024;gsub(/[MmGg]/,"",v);st=v*m}
            if($i=="used"&&$(i+1)=="="){v=$(i+2);m=1;if(v~/[Gg]/)m=1024;gsub(/[MmGg]/,"",v);su=v*m}
        }
        printf "SWAP=%.0f MB / %.0f MB\\n",su+0,st+0
    }'
    mounts=$(mount 2>/dev/null || true)
    diskrows=$({ printf "%s\\n" "$mounts"; printf "__TERMPILOT_DF__\\n"; df -kP 2>/dev/null; } | awk '
    $0=="__TERMPILOT_DF__"{in_df=1;next}
    !in_df{
        if($1~/^\\/dev\\/disk/&&(index($0,"(apfs,")||index($0,"(apfs)"))){
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
            printf "DISK=%s|%.6f|%.6f|%s\\n",m,u,t,p
        }
    }')
    printf "%s\\n" "$diskrows"
    printf "%s\\n" "$diskrows" | awk -F'[=|]' '$1=="DISK"&&$2=="/"{printf "DISK_USED_GB=%s\\nDISK_TOTAL_GB=%s\\nDISK_PERCENT=%s\\n",$3,$4,$5;exit}'
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
            printf "NETIF_BYTES=%s|%.0f|%.0f\\n",name,rxByName[name],txByName[name]
        }
        printf "NET_RX_BYTES=%.0f\\nNET_TX_BYTES=%.0f\\n",rx,tx
    }'
    sysctl -n vm.loadavg 2>/dev/null | tr -d '{}' | awk 'NF>=3{printf "LOAD=%s / %s / %s\\n",$1,$2,$3}'
    bootsec=$(sysctl -n kern.boottime 2>/dev/null | awk -F'[ ,]+' '{for(i=1;i<=NF;i++){if($i=="sec"){print $(i+2);exit}}}')
    nowsec=$(date +%s 2>/dev/null || echo "0")
    awk -v n="$nowsec" -v b="$bootsec" 'BEGIN{if(n>0&&b>0){u=n-b;printf "UPTIME_DAYS=%d\\nUPTIME_HOURS=%d\\n",u/86400,(u%86400)/3600}}'
    ps -A -o pid= -o pmem= -o comm= 2>/dev/null | sort -k2 -nr | head -5 | awk '{printf "TOPPROC=%s|%.1f|%s\\n",$1,$2,$3}'
    osname=$(printf "%s %s" "$(sw_vers -productName 2>/dev/null)" "$(sw_vers -productVersion 2>/dev/null)" | sed 's/[[:space:]]*$//')
    printf "OS=%s\\nKERNEL=%s\\n" "${osname:-Darwin}" "$(uname -r 2>/dev/null)"
    """

    private static let linuxScript = """
    set +e
    awk '/^cpu /{total=0;for(i=2;i<=NF;i++)total+=$i;printf "CPU_RAW=%.0f|%.0f|%.0f|%.0f\\n",total,$5,$2+$3,$4+$7+$8}' /proc/stat 2>/dev/null
    awk '/^cpu[0-9]+ /{total=0;for(i=2;i<=NF;i++)total+=$i;printf "CPU_CORE_RAW=%s|%.0f|%.0f\\n",substr($1,4),total,$5}' /proc/stat 2>/dev/null
    awk 'BEGIN{count=0}/^cpu[0-9]+ /{count++}END{if(count>0)printf "CPU_CORES=%d\\n",count}' /proc/stat 2>/dev/null
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
        if(mt>0)printf "MEM_USED_MB=%.0f\\nMEM_TOTAL_MB=%.0f\\nMEM_PERCENT=%.1f\\n",used/1024,mt/1024,used*100/mt
        if(st>0)printf "SWAP=%.0f MB / %.0f MB\\n",(st-sf)/1024,st/1024
        else print "SWAP=0 MB / 0 MB"
    }' /proc/meminfo 2>/dev/null
    df -kP 2>/dev/null | awk '
    NR>1 && $1 !~ /^\\/dev\\/loop/ && ($6=="/" || ($1~/^\\/dev\\// && $6!~/^\\/(etc|proc|sys|dev)(\\/|$)/)){
        total=$2/1048576
        used=$3/1048576
        percent=$5
        gsub(/%/,"",percent)
        printf "DISK=%s|%.6f|%.6f|%s\\n",$6,used,total,percent
        if($6=="/")printf "DISK_USED_GB=%.6f\\nDISK_TOTAL_GB=%.6f\\nDISK_PERCENT=%s\\n",used,total,percent
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
            printf "NETIF_BYTES=%s|%.0f|%.0f\\n",name,fields[1],fields[9]
        }
    }
    END{printf "NET_RX_BYTES=%.0f\\nNET_TX_BYTES=%.0f\\n",rx,tx}' /proc/net/dev 2>/dev/null
    awk '{print "LOAD="$1" / "$2" / "$3}' /proc/loadavg 2>/dev/null
    awk '{printf "UPTIME_DAYS=%d\\nUPTIME_HOURS=%d\\n",$1/86400,($1%86400)/3600}' /proc/uptime 2>/dev/null
    if procraw=$(ps -eo pid,%mem,comm --sort=-%mem 2>/dev/null); then
        printf "%s\\n" "$procraw" | awk 'NR>1 && NR<=6{printf "TOPPROC=%s|%.1f|%s\\n",$1,$2,$3}'
    elif topraw=$(top -b -n 1 2>/dev/null); then
        printf "%s\\n" "$topraw" | awk '
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
        }' | sort -t '|' -k1,1rn | head -5 | awk -F'|' '{printf "TOPPROC=%s|%.1f|%s\\n",$2,$1,$3}'
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
        }' | sort -t '|' -k1,1rn | head -5 | awk -F'|' '{printf "TOPPROC=%s|%.1f|%s\\n",$2,$1,$3}'
    fi
    if [ -r /etc/os-release ]; then . /etc/os-release; fi
    printf "OS=%s\\nKERNEL=%s\\n" "${PRETTY_NAME:-$(uname -s 2>/dev/null)}" "$(uname -r 2>/dev/null)"
    """
}

private struct TimedSystemNetworkCounters {
    var date: Date
    var total: SystemNetworkByteCounters?
    var interfaces: [String: SystemNetworkByteCounters]
}

private struct SystemCommandResult {
    var stdout: String
    var stderr: String
    var code: Int?
}

private enum DockerPanelError: LocalizedError {
    case commandFailed(String)
    case invalidInspectOutput

    var errorDescription: String? {
        switch self {
        case let .commandFailed(message):
            message
        case .invalidInspectOutput:
            AppLocalization.string("Unable to parse Docker inspect output.")
        }
    }
}

private struct SystemOverviewSnapshot {
    var cpuPercent: Double?
    var cpuUserPercent: Double?
    var cpuSystemPercent: Double?
    var cpuPerCore: [Double]
    var cpuCoreCount: Int?
    var cpuJiffyCounters: SystemCPUJiffyCounters?
    var memoryPercent: Double?
    var memoryUsedMB: Double?
    var memoryTotalMB: Double?
    var diskPercent: Double?
    var diskUsedGB: Double?
    var diskTotalGB: Double?
    var disks: [SystemDiskRow]
    var netRxBps: Double?
    var netTxBps: Double?
    var networkInterfaces: [SystemNetworkRow]
    var networkByteCounters: SystemNetworkByteCounters?
    var networkInterfaceByteCounters: [String: SystemNetworkByteCounters]
    var load: String?
    var uptime: String?
    var osName: String?
    var kernel: String?
    var swap: String?
    var latencyMS: Double?
    var topMemoryProcesses: [SystemProcessRow]
}

private struct SystemOverviewSample: Identifiable {
    let id = UUID()
    var date: Date
    var cpuPercent: Double
}

private struct SystemDiskRow: Identifiable {
    var id: String { mount }
    var mount: String
    var usedGB: Double
    var totalGB: Double
    var percent: Double
}

private struct SystemNetworkRow: Identifiable {
    var id: String { name }
    var name: String
    var rxBps: Double?
    var txBps: Double?
}

private struct SystemProcessRow: Identifiable {
    var id: Int { pid }
    var pid: Int
    var ppid: Int
    var user: String
    var stat: String
    var cpuPercent: Double
    var memPercent: Double
    var rssKB: Int
    var vszKB: Int
    var elapsed: String
    var command: String
}

private enum ProcessFilter: String, CaseIterable, Identifiable {
    case all
    case running

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .all:
            "System Filter All"
        case .running:
            "System Filter Running"
        }
    }
}

private enum ProcessSortKey: String, CaseIterable, Identifiable {
    case cpu
    case memory
    case pid
    case command
    case user

    var id: String { rawValue }
}

private enum DockerSection: String, CaseIterable, Identifiable {
    case containers
    case images

    var id: String { rawValue }
}

private enum DockerFilter: String, CaseIterable, Identifiable {
    case all
    case running
    case stopped
    case paused

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .all:
            "System Filter All"
        case .running:
            "System Filter Running"
        case .stopped:
            "System Filter Stopped"
        case .paused:
            "System Filter Paused"
        }
    }
}

private enum DockerSheet: Identifiable {
    case confirmContainer(DockerContainerRow, DockerContainerAction)
    case confirmImageRemoval(DockerImageRow)
    case confirmImagePrune(all: Bool)
    case renameContainer(DockerContainerRow)
    case tagImage(DockerImageRow)

    var id: String {
        switch self {
        case let .confirmContainer(container, action):
            "container-\(container.id)-\(action.rawValue)"
        case let .confirmImageRemoval(image):
            "image-remove-\(image.id)"
        case let .confirmImagePrune(all):
            "image-prune-\(all)"
        case let .renameContainer(container):
            "container-rename-\(container.id)"
        case let .tagImage(image):
            "image-tag-\(image.id)"
        }
    }
}

private struct SessionSystemMonitorPanel: View {
    @EnvironmentObject private var state: AppState
    let workspaceID: UUID
    let host: TermPilotDomain.Host
    @ObservedObject var runtime: TerminalSessionRuntime

    @AppStorage(AppPreferences.overviewRefreshInterval)
    private var overviewRefreshInterval =
        AppPreferences.defaultOverviewRefreshInterval
    @AppStorage(AppPreferences.processesRefreshInterval)
    private var processesRefreshInterval =
        AppPreferences.defaultProcessesRefreshInterval
    @AppStorage(AppPreferences.dockerRefreshInterval)
    private var dockerRefreshInterval =
        AppPreferences.defaultDockerRefreshInterval

    @State private var overview: SystemOverviewSnapshot?
    @State private var overviewSamples: [SystemOverviewSample] = []
    @State private var processes: [SystemProcessRow] = []
    @State private var containers: [DockerContainerRow] = []
    @State private var images: [DockerImageRow] = []
    @State private var query = ""
    @State private var processFilter = ProcessFilter.all
    @State private var processSort = ProcessSortKey.cpu
    @State private var processSortAscending = false
    @State private var dockerSection = DockerSection.containers
    @State private var dockerFilter = DockerFilter.all
    @State private var selectedContainerID: String?
    @State private var selectedImageID: String?
    @State private var dockerInspectKey: String?
    @State private var dockerInspect: DockerInspectDetails?
    @State private var dockerInspectLoading = false
    @State private var pendingDockerActionID: String?
    @State private var pendingDockerAction: DockerContainerAction?
    @State private var dockerImageActionInProgress = false
    @State private var dockerSheet: DockerSheet?
    @State private var previousCPUCounters: SystemCPUJiffyCounters?
    @State private var previousNetworkCounters: TimedSystemNetworkCounters?
    @State private var loading = false
    @State private var errorMessage: String?

    private let overviewMetricCardHeight: CGFloat = 82

    private var overviewInfoColumns: [GridItem] {
        fixedOverviewColumns
    }

    private var fixedOverviewColumns: [GridItem] {
        [
            GridItem(.flexible(minimum: 0), spacing: 8, alignment: .top),
            GridItem(.flexible(minimum: 0), spacing: 8, alignment: .top),
        ]
    }

    private var tab: SystemMonitorTab {
        SystemMonitorTab(
            rawValue: state.terminalSystemMonitorTab(
                in: workspaceID
            )
        ) ?? .overview
    }

    private var tabBinding: Binding<SystemMonitorTab> {
        Binding(
            get: { tab },
            set: {
                state.selectTerminalSystemMonitorTab(
                    $0.rawValue,
                    in: workspaceID
                )
            }
        )
    }

    private var automaticRefreshEnabled: Bool {
        SessionSystemMonitorRefreshPolicy.isEnabled(
            sessionKind: runtime.descriptor.kind,
            lifecycle: runtime.lifecycle
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("System", selection: tabBinding) {
                    ForEach(SystemMonitorTab.allCases) { tab in
                        Text(tab.title).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize(horizontal: true, vertical: false)

                Spacer(minLength: 0)
            }
            .padding(8)
            Divider()

            Group {
                switch tab {
                case .overview:
                    overviewView
                case .processes:
                    processesView
                case .docker:
                    dockerView
                }
            }
            .overlay {
                if loading {
                    ProgressView()
                        .controlSize(.small)
                        .padding(12)
                        .background(.regularMaterial)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }
            }
        }
        .task(id: refreshLoopID) {
            await refreshLoop(for: tab)
        }
        .onChange(of: tab) { oldTab, newTab in
            if oldTab == .overview, newTab != .overview {
                previousCPUCounters = nil
                previousNetworkCounters = nil
            }
        }
        .onChange(of: dockerSection) {
            query = ""
            resetDockerSelection()
        }
        .onChange(of: host.id) {
            previousCPUCounters = nil
            previousNetworkCounters = nil
            resetDockerSelection()
            dockerSheet = nil
        }
        .sheet(item: $dockerSheet) { sheet in
            dockerSheetView(sheet)
        }
    }

    private var refreshLoopID: String {
        [
            host.id.uuidString,
            runtime.descriptor.sshConnectionID?.uuidString ?? "local",
            tab.rawValue,
            dockerSection.rawValue,
            String(AppPreferences.clampedSystemMonitorRefreshInterval(overviewRefreshInterval)),
            String(AppPreferences.clampedSystemMonitorRefreshInterval(processesRefreshInterval)),
            String(AppPreferences.clampedSystemMonitorRefreshInterval(dockerRefreshInterval)),
            String(automaticRefreshEnabled),
        ].joined(separator: "-")
    }

    private var overviewView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                if let errorMessage {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                if let overview {
                    overviewHostCard(overview)

                    overviewMetricGrid(overview)

                    cpuTrendCard

                    overviewSectionTitle("Disk Partitions", systemImage: "externaldrive", color: .orange)
                    overviewCard {
                        if overview.disks.isEmpty {
                            Text("No Data")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(overview.disks) { disk in
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack(spacing: 8) {
                                        Text(disk.mount)
                                            .font(.caption)
                                            .foregroundStyle(.primary)
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                        Text("\(gigabyteText(disk.usedGB)) / \(gigabyteText(disk.totalGB))")
                                            .font(.caption2)
                                            .monospacedDigit()
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                            .minimumScaleFactor(0.82)
                                            .frame(width: 138, alignment: .trailing)
                                    }
                                    accentProgressBar(
                                        value: disk.percent,
                                        color: .orange,
                                        height: 6
                                    )
                                }
                                if disk.id != overview.disks.last?.id {
                                    Divider().opacity(0.25)
                                }
                            }
                        }
                    }

                    overviewSectionTitle("Network Interfaces", systemImage: "wifi", color: .green)
                    VStack(spacing: 6) {
                        if overview.networkInterfaces.isEmpty {
                            overviewCard {
                                Text("No Data")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        } else {
                            ForEach(overview.networkInterfaces) { item in
                                overviewCard {
                                    overviewNetworkRow(item)
                                }
                            }
                        }
                    }

                    LazyVGrid(columns: overviewInfoColumns, alignment: .leading, spacing: 6) {
                        infoPill("Load", overview.load)
                        infoPill("System", overview.osName)
                        infoPill("Kernel", overview.kernel)
                        infoPill("Swap", overview.swap)
                    }

                    if !overview.topMemoryProcesses.isEmpty {
                        overviewSectionTitle("Top Memory Processes", systemImage: "memorychip", color: .red)
                        overviewCard {
                            ForEach(overview.topMemoryProcesses.prefix(5)) { process in
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack(spacing: 8) {
                                        Text(process.command)
                                            .font(.caption.weight(.medium))
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                        Text("PID \(process.pid)")
                                            .font(.caption2)
                                            .monospacedDigit()
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                            .frame(width: 64, alignment: .trailing)
                                    }
                                    resourceBar("MEM", value: process.memPercent)
                                }
                            }
                        }
                    }
                } else if !loading {
                    ContentUnavailableView("No Data", systemImage: "waveform.path.ecg")
                        .frame(minHeight: 220)
                }
            }
            .padding(12)
            .lineLimit(1)
            .truncationMode(.tail)
        }
    }

    private func overviewHostCard(_ overview: SystemOverviewSnapshot) -> some View {
        overviewCard {
            HStack(spacing: 12) {
                HostIconView(host: host, size: 42)
                    .frame(width: 42)

                VStack(alignment: .leading, spacing: 8) {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 8) {
                            Text(host.label)
                                .font(.headline.weight(.semibold))
                                .lineLimit(1)
                                .truncationMode(.middle)
                            hostAddressBadge
                        }
                        hostAddressBadge
                    }
                    .layoutPriority(3)

                    HStack(spacing: 8) {
                        Text(host.username)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.purple)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.purple.opacity(0.14))
                            .clipShape(RoundedRectangle(cornerRadius: 7))
                        Text("•")
                            .foregroundStyle(.secondary)
                        Text(
                            "\(overview.osName ?? AppLocalization.string("Unknown")) \(overview.kernel ?? "")"
                        )
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .layoutPriority(1)

                Spacer(minLength: 8)

                VStack(alignment: .trailing, spacing: 4) {
                    Text("Uptime")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(overview.uptime ?? "--")
                        .font(.title3.monospacedDigit().weight(.bold))
                        .foregroundStyle(.green)
                        .lineLimit(1)
                        .minimumScaleFactor(0.78)
                }
                .frame(width: 96, alignment: .trailing)
            }
        }
    }

    private var hostAddressBadge: some View {
        Text(host.hostname)
            .font(.caption.monospacedDigit().weight(.medium))
            .foregroundStyle(.cyan)
            .lineLimit(1)
            .truncationMode(.middle)
            .minimumScaleFactor(0.78)
            .frame(maxWidth: 160, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.cyan.opacity(0.14))
            .clipShape(RoundedRectangle(cornerRadius: 7))
            .help(host.hostname)
    }

    private func overviewMetricGrid(_ overview: SystemOverviewSnapshot) -> some View {
        LazyVGrid(
            columns: fixedOverviewColumns,
            alignment: .leading,
            spacing: 6
        ) {
            overviewMetricCard(
                "CPU",
                systemImage: "cpu",
                value: percentText(overview.cpuPercent),
                accent: .cyan,
                progress: overview.cpuPercent ?? 0,
                titleAccessory: cpuCoreText(overview.cpuCoreCount),
                footerLeading: "\(AppLocalization.string("User:")) \(percentText(overview.cpuUserPercent, digits: 1))",
                footerTrailing: "\(AppLocalization.string("Sys:")) \(percentText(overview.cpuSystemPercent, digits: 1))"
            )

            overviewMetricCard(
                "Memory",
                systemImage: "memorychip",
                value: percentText(overview.memoryPercent),
                accent: .purple,
                progress: overview.memoryPercent ?? 0,
                footerLeading: gigabyteText((overview.memoryUsedMB ?? 0) / 1024),
                footerTrailing: gigabyteText((overview.memoryTotalMB ?? 0) / 1024)
            )

            overviewMetricCard(
                "Disk",
                systemImage: "externaldrive",
                value: percentText(overview.diskPercent),
                accent: .orange,
                progress: overview.diskPercent ?? 0,
                footerLeading: gigabyteText(overview.diskUsedGB),
                footerTrailing: gigabyteText(overview.diskTotalGB)
            )

            overviewMetricCard(
                "Network",
                systemImage: "wifi",
                value: "\(bytesText(totalNetworkRate(overview)))/s",
                accent: .green,
                progress: min(log10((totalNetworkRate(overview) ?? 0) + 1) * 14, 100),
                footerLeading: "↓ \(bytesText(overview.netRxBps))/s",
                footerTrailing: "↑ \(bytesText(overview.netTxBps))/s"
            )
        }
    }

    private func overviewMetricCard(
        _ title: LocalizedStringKey,
        systemImage: String,
        value: String,
        accent: Color,
        progress: Double,
        titleAccessory: String? = nil,
        footerLeading: String,
        footerTrailing: String
    ) -> some View {
        overviewCard {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: systemImage)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(accent)
                        .frame(width: 22, alignment: .leading)
                    Text(title)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                        .layoutPriority(2)
                    if let titleAccessory {
                        Text(titleAccessory)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                    Text(value)
                        .font(
                            .system(
                                size: 12,
                                weight: .bold,
                                design: .monospaced
                            )
                        )
                        .foregroundStyle(accent)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(
                            minWidth: 0,
                            maxWidth: .infinity,
                            alignment: .trailing
                        )
                        .layoutPriority(3)
                }

                accentProgressBar(value: progress, color: accent, height: 7)

                HStack(spacing: 8) {
                    Text(footerLeading)
                        .lineLimit(1)
                        .frame(
                            minWidth: 0,
                            maxWidth: .infinity,
                            alignment: .leading
                        )
                    Text(footerTrailing)
                        .lineLimit(1)
                        .frame(
                            minWidth: 0,
                            maxWidth: .infinity,
                            alignment: .trailing
                        )
                }
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            }
        }
        .frame(height: overviewMetricCardHeight)
    }

    private func totalNetworkRate(_ overview: SystemOverviewSnapshot) -> Double? {
        guard let rxBps = overview.netRxBps,
              let txBps = overview.netTxBps
        else {
            return nil
        }
        return rxBps + txBps
    }

    private func cpuCoreText(_ count: Int?) -> String? {
        guard let count, count > 0 else {
            return nil
        }
        return String(
            format: AppLocalization.string("CPU Cores Format"),
            count
        )
    }

    private func overviewNetworkRow(_ item: SystemNetworkRow) -> some View {
        HStack(spacing: 8) {
            Text(item.name)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("↓ \(bytesText(item.rxBps))/s")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.green)
                .lineLimit(1)
                .minimumScaleFactor(0.78)
                .frame(width: 92, alignment: .trailing)
            Text("↑ \(bytesText(item.txBps))/s")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.blue)
                .lineLimit(1)
                .minimumScaleFactor(0.78)
                .frame(width: 92, alignment: .trailing)
        }
    }

    private var cpuTrendCard: some View {
        overviewCard {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "waveform.path.ecg")
                        .foregroundStyle(.cyan)
                    Text("CPU Load Trend")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                GeometryReader { proxy in
                    ZStack {
                        VStack(spacing: 0) {
                            ForEach(0..<4, id: \.self) { _ in
                                Rectangle()
                                    .fill(Color.secondary.opacity(0.18))
                                    .frame(height: 1)
                                Spacer()
                            }
                        }
                        Path { path in
                            let size = proxy.size
                            let samples = overviewSamples
                            guard samples.count > 1 else {
                                return
                            }
                            for index in samples.indices {
                                let x = size.width * CGFloat(index) / CGFloat(max(samples.count - 1, 1))
                                let clamped = min(max(samples[index].cpuPercent, 0), 100)
                                let y = size.height - (size.height * CGFloat(clamped) / 100)
                                if index == samples.startIndex {
                                    path.move(to: CGPoint(x: x, y: y))
                                } else {
                                    path.addLine(to: CGPoint(x: x, y: y))
                                }
                            }
                        }
                        .stroke(.cyan, style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
                    }
                }
                .frame(height: 96)

                HStack {
                    Text(overviewSamples.first?.date.formatted(date: .omitted, time: .standard) ?? "--")
                    Spacer()
                    Text(overviewSamples.last?.date.formatted(date: .omitted, time: .standard) ?? "--")
                }
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
            }
        }
    }

    private func overviewSectionTitle(
        _ title: LocalizedStringKey,
        systemImage: String,
        color: Color
    ) -> some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
                .foregroundStyle(color)
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private func overviewCard<Content: View>(
        @ViewBuilder content: () -> Content
    ) -> some View {
        content()
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.72))
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    private func accentProgressBar(
        value: Double,
        color: Color,
        height: CGFloat
    ) -> some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.black.opacity(0.22))
                Capsule()
                    .fill(color)
                    .frame(width: max(4, proxy.size.width * CGFloat(min(max(value, 0), 100)) / 100))
            }
        }
        .frame(height: height)
    }

    private var processesView: some View {
        VStack(spacing: 0) {
            HStack {
                TextField("Search processes...", text: $query)
                    .textFieldStyle(.roundedBorder)
                Button {
                    Task { await refreshProcesses() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
            }
            .padding(8)
            Divider()
            HStack {
                Picker("", selection: $processFilter) {
                    ForEach(ProcessFilter.allCases) { filter in
                        Text(filter.title).tag(filter)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize(horizontal: true, vertical: false)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            HStack(spacing: 4) {
                ForEach(ProcessSortKey.allCases) { key in
                    Button(sortTitle(key)) {
                        if processSort == key {
                            processSortAscending.toggle()
                        } else {
                            processSort = key
                            processSortAscending = key == .command || key == .user
                        }
                    }
                    .font(.caption2)
                }
            }
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            Divider()
            List(filteredProcesses) { process in
                VStack(alignment: .leading, spacing: 5) {
                    Text(process.command)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Text("\(process.user) · PID \(process.pid) · CPU \(percentText(process.cpuPercent)) · MEM \(percentText(process.memPercent))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack {
                        Button("Sleep") {
                            Task { await signal(process.pid, "STOP") }
                        }
                        Button("Resume") {
                            Task { await signal(process.pid, "CONT") }
                        }
                        Button("Term") {
                            Task { await signal(process.pid, "TERM") }
                        }
                        Button("Kill", role: .destructive) {
                            Task { await signal(process.pid, "KILL") }
                        }
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                }
                .padding(.vertical, 4)
            }
        }
    }

    private var dockerView: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("", selection: $dockerSection) {
                    Label("Containers", systemImage: "shippingbox")
                        .tag(DockerSection.containers)
                    Label("Images", systemImage: "square.stack.3d.up")
                        .tag(DockerSection.images)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize(horizontal: true, vertical: false)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            Divider()

            HStack(spacing: 8) {
                TextField(dockerSearchPrompt, text: $query)
                    .textFieldStyle(.roundedBorder)
                if dockerSection == .images {
                    Button("Prune") {
                        dockerSheet = .confirmImagePrune(all: false)
                    }
                    Button("Prune All") {
                        dockerSheet = .confirmImagePrune(all: true)
                    }
                    .foregroundStyle(.red)
                }
                Button {
                    Task { await refreshDocker() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .accessibilityLabel("Refresh")
            }
            .buttonStyle(.borderless)
            .font(.caption)
            .disabled(dockerImageActionInProgress)
            .padding(8)
            Divider()

            if dockerSection == .containers {
                HStack {
                    Picker("", selection: $dockerFilter) {
                        ForEach(DockerFilter.allCases) { filter in
                            Text(filter.title).tag(filter)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize(horizontal: true, vertical: false)

                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                Divider()
                dockerCountBar(
                    count: filteredContainers.count,
                    title: "Containers"
                )
                Divider()
                ScrollView {
                    LazyVStack(spacing: 0) {
                        if let errorMessage {
                            dockerErrorRow(errorMessage)
                        }
                        if filteredContainers.isEmpty,
                           errorMessage == nil
                        {
                            ContentUnavailableView(
                                "No Containers Found",
                                systemImage: "shippingbox"
                            )
                            .padding(.vertical, 32)
                        }
                        ForEach(filteredContainers) { container in
                            DockerContainerManagementRow(
                                container: container,
                                selected:
                                    selectedContainerID == container.id,
                                pendingAction:
                                    pendingDockerActionID == container.id
                                        ? pendingDockerAction
                                        : nil,
                                onSelect: {
                                    selectDockerContainer(container)
                                },
                                onShell: {
                                    openDockerShell(container)
                                },
                                onLogs: {
                                    openDockerLogs(container)
                                },
                                onAction: { action in
                                    requestDockerContainerAction(
                                        container,
                                        action: action
                                    )
                                }
                            )
                            if selectedContainerID == container.id {
                                DockerContainerDetailView(
                                    container: container,
                                    inspect: dockerInspectKey
                                        == dockerInspectKeyForContainer(
                                            container
                                        )
                                        ? dockerInspect
                                        : nil,
                                    inspectLoading:
                                        dockerInspectLoading
                                            && dockerInspectKey
                                                == dockerInspectKeyForContainer(
                                                    container
                                                ),
                                    pendingAction:
                                        pendingDockerActionID == container.id
                                            ? pendingDockerAction
                                            : nil,
                                    onRename: {
                                        dockerSheet =
                                            .renameContainer(container)
                                    },
                                    onAction: { action in
                                        requestDockerContainerAction(
                                            container,
                                            action: action
                                        )
                                    },
                                    onClose: {
                                        resetDockerSelection()
                                    }
                                )
                            }
                            Divider()
                        }
                    }
                }
            } else {
                dockerCountBar(
                    count: filteredImages.count,
                    title: "Images"
                )
                Divider()
                ScrollView {
                    LazyVStack(spacing: 0) {
                        if let errorMessage {
                            dockerErrorRow(errorMessage)
                        }
                        if filteredImages.isEmpty,
                           errorMessage == nil
                        {
                            ContentUnavailableView(
                                "No Images Found",
                                systemImage: "square.stack.3d.up"
                            )
                            .padding(.vertical, 32)
                        }
                        ForEach(filteredImages) { image in
                            DockerImageManagementRow(
                                image: image,
                                selected: selectedImageID == image.id,
                                busy: dockerImageActionInProgress,
                                onSelect: {
                                    selectDockerImage(image)
                                },
                                onTag: {
                                    dockerSheet = .tagImage(image)
                                },
                                onRemove: {
                                    dockerSheet =
                                        .confirmImageRemoval(image)
                                }
                            )
                            if selectedImageID == image.id {
                                DockerImageDetailView(
                                    inspect: dockerInspectKey
                                        == dockerInspectKeyForImage(image)
                                        ? dockerInspect
                                        : nil,
                                    loading:
                                        dockerInspectLoading
                                            && dockerInspectKey
                                                == dockerInspectKeyForImage(
                                                    image
                                                ),
                                    onClose: {
                                        resetDockerSelection()
                                    }
                                )
                            }
                            Divider()
                        }
                    }
                }
            }
        }
    }

    private func dockerCountBar(
        count: Int,
        title: LocalizedStringKey
    ) -> some View {
        HStack(spacing: 4) {
            Text("\(count)")
                .monospacedDigit()
            Text(title)
            Spacer()
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .frame(height: 30)
    }

    private func dockerErrorRow(_ message: String) -> some View {
        Text(message)
            .font(.caption)
            .foregroundStyle(.red)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
    }

    @ViewBuilder
    private func dockerSheetView(_ sheet: DockerSheet) -> some View {
        switch sheet {
        case let .confirmContainer(container, action):
            let isKill = action == .kill
            DockerConfirmationSheet(
                title: isKill ? "Kill Container" : "Remove Container",
                message: String(
                    format: AppLocalization.string(
                        isKill
                            ? "Force kill container \"%@\"?"
                            : "Remove container \"%@\"?"
                    ),
                    container.name.isEmpty
                        ? String(container.id.prefix(12))
                        : container.name
                ),
                confirmTitle: isKill ? "Kill" : "Remove",
                onCancel: {
                    dockerSheet = nil
                },
                onConfirm: {
                    dockerSheet = nil
                    Task {
                        await performDockerContainerAction(
                            container,
                            action: action
                        )
                    }
                }
            )
        case let .confirmImageRemoval(image):
            DockerConfirmationSheet(
                title: "Remove Image",
                message: String(
                    format: AppLocalization.string(
                        "Remove image \"%@\"?"
                    ),
                    image.displayName
                ),
                confirmTitle: "Remove",
                onCancel: {
                    dockerSheet = nil
                },
                onConfirm: {
                    dockerSheet = nil
                    Task {
                        await removeDockerImage(image)
                    }
                }
            )
        case let .confirmImagePrune(all):
            DockerConfirmationSheet(
                title: all ? "Prune All" : "Prune",
                message: AppLocalization.string(
                    all
                        ? "Remove all unused images?"
                        : "Remove dangling images?"
                ),
                confirmTitle: all ? "Prune All" : "Prune",
                onCancel: {
                    dockerSheet = nil
                },
                onConfirm: {
                    dockerSheet = nil
                    Task {
                        await pruneDockerImages(all: all)
                    }
                }
            )
        case let .renameContainer(container):
            DockerRenameSheet(
                initialName: container.name,
                onCancel: {
                    dockerSheet = nil
                },
                onSave: { name in
                    dockerSheet = nil
                    Task {
                        await performDockerContainerAction(
                            container,
                            action: .rename,
                            newName: name
                        )
                    }
                }
            )
        case let .tagImage(image):
            DockerTagSheet(
                image: image,
                onCancel: {
                    dockerSheet = nil
                },
                onSave: { repository, tag in
                    dockerSheet = nil
                    Task {
                        await tagDockerImage(
                            image,
                            repository: repository,
                            tag: tag
                        )
                    }
                }
            )
        }
    }

    private var dockerSearchPrompt: LocalizedStringKey {
        dockerSection == .containers ? "Search containers..." : "Search images..."
    }

    private var filteredProcesses: [SystemProcessRow] {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let filtered = processes.filter {
            if processFilter == .running, !$0.stat.localizedCaseInsensitiveContains("R") {
                return false
            }
            guard !text.isEmpty else { return true }
            return $0.command.lowercased().contains(text)
                || $0.user.lowercased().contains(text)
                || String($0.pid).contains(text)
        }
        return filtered.sorted(by: processSortComparator)
    }

    private var filteredContainers: [DockerContainerRow] {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return containers.filter {
            switch dockerFilter {
            case .all:
                break
            case .running:
                guard $0.isRunning else { return false }
            case .stopped:
                guard !$0.isRunning && !$0.isPaused else {
                    return false
                }
            case .paused:
                guard $0.isPaused else { return false }
            }
            guard !text.isEmpty else { return true }
            return $0.name.lowercased().contains(text)
                || $0.image.lowercased().contains(text)
                || $0.status.lowercased().contains(text)
        }
    }

    private var filteredImages: [DockerImageRow] {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let sorted = images.sorted {
            $0.displayName.localizedCaseInsensitiveCompare(
                $1.displayName
            ) == .orderedAscending
        }
        guard !text.isEmpty else { return sorted }
        return sorted.filter {
            $0.displayName.lowercased().contains(text)
                || $0.imageID.lowercased().contains(text)
                || $0.repository.lowercased().contains(text)
        }
    }

    private func header(_ title: LocalizedStringKey, refresh: @escaping () -> Void) -> some View {
        HStack {
            Text(title)
                .font(.headline)
            Spacer()
            Button(action: refresh) {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
        }
    }

    private func sectionCard<Content: View>(
        _ title: LocalizedStringKey,
        systemImage: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                    .foregroundStyle(.secondary)
                Text(title)
                    .font(.caption.weight(.semibold))
            }
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
        }
    }

    private func resourceBar(_ label: String, value: Double) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(width: 36, alignment: .leading)
            ProgressView(value: min(max(value / 100, 0), 1))
            Text(percentText(value))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 42, alignment: .trailing)
        }
    }

    private func metricCard(
        _ title: LocalizedStringKey,
        value: String,
        detail: String,
        color: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title3.weight(.semibold))
            ProgressView(value: min(max(percentNumber(value) / 100, 0), 1))
                .tint(color)
            if !detail.isEmpty {
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
        }
    }

    private func infoPill(_ title: LocalizedStringKey, _ value: String?) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value?.isEmpty == false ? value! : "--")
                .font(.caption.weight(.medium))
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
        }
    }

    private func sortTitle(_ key: ProcessSortKey) -> String {
        let suffix = processSort == key ? (processSortAscending ? " ↑" : " ↓") : ""
        switch key {
        case .cpu:
            return "CPU\(suffix)"
        case .memory:
            return "MEM\(suffix)"
        case .pid:
            return "PID\(suffix)"
        case .command:
            return "\(AppLocalization.string("Command"))\(suffix)"
        case .user:
            return "\(AppLocalization.string("User"))\(suffix)"
        }
    }

    private func processSortComparator(
        _ lhs: SystemProcessRow,
        _ rhs: SystemProcessRow
    ) -> Bool {
        let result: ComparisonResult
        switch processSort {
        case .cpu:
            result = lhs.cpuPercent == rhs.cpuPercent
                ? .orderedSame
                : (lhs.cpuPercent < rhs.cpuPercent ? .orderedAscending : .orderedDescending)
        case .memory:
            result = lhs.memPercent == rhs.memPercent
                ? .orderedSame
                : (lhs.memPercent < rhs.memPercent ? .orderedAscending : .orderedDescending)
        case .pid:
            result = lhs.pid == rhs.pid
                ? .orderedSame
                : (lhs.pid < rhs.pid ? .orderedAscending : .orderedDescending)
        case .command:
            result = lhs.command.localizedCaseInsensitiveCompare(rhs.command)
        case .user:
            result = lhs.user.localizedCaseInsensitiveCompare(rhs.user)
        }
        if result == .orderedSame {
            return lhs.pid < rhs.pid
        }
        return processSortAscending
            ? result == .orderedAscending
            : result == .orderedDescending
    }

    private func refreshLoop(for tab: SystemMonitorTab) async {
        guard automaticRefreshEnabled else {
            previousCPUCounters = nil
            previousNetworkCounters = nil
            return
        }
        await refreshCurrentTab()
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(refreshInterval(for: tab)))
            if Task.isCancelled {
                return
            }
            await refreshCurrentTab()
        }
    }

    private func refreshInterval(for tab: SystemMonitorTab) -> Int {
        switch tab {
        case .overview:
            AppPreferences.clampedSystemMonitorRefreshInterval(
                overviewRefreshInterval
            )
        case .processes:
            AppPreferences.clampedSystemMonitorRefreshInterval(
                processesRefreshInterval
            )
        case .docker:
            AppPreferences.clampedSystemMonitorRefreshInterval(
                dockerRefreshInterval
            )
        }
    }

    private func refreshCurrentTab() async {
        switch tab {
        case .overview:
            await refreshOverview()
        case .processes:
            await refreshProcesses()
        case .docker:
            await refreshDocker()
        }
    }

    private func refreshOverview() async {
        await runRefresh {
            let started = Date()
            let output = try await exec(
                SystemOverviewCommand.command,
                timeoutMS: 12_000
            )
            try Task.checkCancellation()
            let sampledAt = Date()
            var snapshot = Self.parseOverview(
                output.stdout,
                latencyMS: sampledAt.timeIntervalSince(started) * 1000
            )
            applyCPUUsage(
                to: &snapshot,
                previous: previousCPUCounters
            )
            previousCPUCounters = snapshot.cpuJiffyCounters
            let currentCounters = TimedSystemNetworkCounters(
                date: sampledAt,
                total: snapshot.networkByteCounters,
                interfaces: snapshot.networkInterfaceByteCounters
            )
            applyNetworkRates(
                to: &snapshot,
                current: currentCounters,
                previous: previousNetworkCounters
            )
            previousNetworkCounters = currentCounters
            overview = snapshot
            recordOverviewSample(snapshot)
        }
    }

    private func applyCPUUsage(
        to snapshot: inout SystemOverviewSnapshot,
        previous: SystemCPUJiffyCounters?
    ) {
        guard let current = snapshot.cpuJiffyCounters else {
            return
        }
        guard let previous,
              let usage = SystemCPUUsageCalculator.usage(
                  current: current,
                  previous: previous
              )
        else {
            snapshot.cpuPercent = nil
            snapshot.cpuUserPercent = nil
            snapshot.cpuSystemPercent = nil
            snapshot.cpuPerCore = current.cores.map { _ in 0 }
            return
        }
        snapshot.cpuPercent = usage.total
        snapshot.cpuUserPercent = usage.user
        snapshot.cpuSystemPercent = usage.system
        snapshot.cpuPerCore = usage.perCore
    }

    private func applyNetworkRates(
        to snapshot: inout SystemOverviewSnapshot,
        current: TimedSystemNetworkCounters,
        previous: TimedSystemNetworkCounters?
    ) {
        let elapsed = previous.map { current.date.timeIntervalSince($0.date) }
        if let currentTotal = current.total,
           let previousTotal = previous?.total,
           let elapsed,
           let rates = SystemNetworkRateCalculator.rates(
               current: currentTotal,
               previous: previousTotal,
               elapsed: elapsed
           ) {
            snapshot.netRxBps = rates.rxBps
            snapshot.netTxBps = rates.txBps
        } else {
            snapshot.netRxBps = nil
            snapshot.netTxBps = nil
        }

        snapshot.networkInterfaces = current.interfaces.keys.sorted().map { name in
            let rates: SystemNetworkByteRates?
            if let currentCounters = current.interfaces[name],
               let previousCounters = previous?.interfaces[name],
               let elapsed {
                rates = SystemNetworkRateCalculator.rates(
                    current: currentCounters,
                    previous: previousCounters,
                    elapsed: elapsed
                )
            } else {
                rates = nil
            }
            return SystemNetworkRow(
                name: name,
                rxBps: rates?.rxBps,
                txBps: rates?.txBps
            )
        }
    }

    private func recordOverviewSample(_ snapshot: SystemOverviewSnapshot) {
        guard let cpuPercent = snapshot.cpuPercent else {
            return
        }
        overviewSamples.append(
            SystemOverviewSample(date: Date(), cpuPercent: cpuPercent)
        )
        if overviewSamples.count > 24 {
            overviewSamples.removeFirst(overviewSamples.count - 24)
        }
    }

    private func refreshProcesses() async {
        await runRefresh {
            let output = try await exec(Self.processCommand, timeoutMS: 12_000)
            processes = Self.parseProcesses(output.stdout)
        }
    }

    private func refreshDocker() async {
        await runRefresh {
            switch dockerSection {
            case .containers:
                let output = try await exec(Self.dockerListCommand, timeoutMS: 12_000)
                containers = Self.parseDockerContainers(output.stdout)
            case .images:
                let output = try await exec(Self.dockerImagesCommand, timeoutMS: 12_000)
                images = Self.parseDockerImages(output.stdout)
            }
        }
    }

    private func signal(_ pid: Int, _ signal: String) async {
        await runLoading {
            _ = try await exec("kill -s \(signal) \(pid)", timeoutMS: 5_000)
            await refreshProcesses()
        }
    }

    private func resetDockerSelection() {
        selectedContainerID = nil
        selectedImageID = nil
        dockerInspectKey = nil
        dockerInspect = nil
        dockerInspectLoading = false
    }

    private func dockerInspectKeyForContainer(
        _ container: DockerContainerRow
    ) -> String {
        "container:\(container.id)"
    }

    private func dockerInspectKeyForImage(
        _ image: DockerImageRow
    ) -> String {
        "image:\(image.id)"
    }

    private func selectDockerContainer(
        _ container: DockerContainerRow
    ) {
        let key = dockerInspectKeyForContainer(container)
        if selectedContainerID == container.id {
            resetDockerSelection()
            return
        }
        selectedContainerID = container.id
        selectedImageID = nil
        dockerInspectKey = key
        dockerInspect = nil
        Task {
            await loadDockerInspect(
                id: container.id,
                kind: .container,
                key: key
            )
        }
    }

    private func selectDockerImage(_ image: DockerImageRow) {
        let key = dockerInspectKeyForImage(image)
        if selectedImageID == image.id {
            resetDockerSelection()
            return
        }
        selectedImageID = image.id
        selectedContainerID = nil
        dockerInspectKey = key
        dockerInspect = nil
        Task {
            await loadDockerInspect(
                id: image.imageID,
                kind: .image,
                key: key
            )
        }
    }

    private func loadDockerInspect(
        id: String,
        kind: DockerInspectKind,
        key: String
    ) async {
        guard let command = DockerManagement.inspectCommand(
            id: id,
            kind: kind
        ) else {
            return
        }
        dockerInspectLoading = true
        do {
            let result = try await runDockerCommand(
                command,
                timeoutMS: 12_000
            )
            guard dockerInspectKey == key else {
                return
            }
            guard let details = DockerManagement.parseInspect(
                result.stdout,
                kind: kind
            ) else {
                throw DockerPanelError.invalidInspectOutput
            }
            dockerInspect = details
        } catch is CancellationError {
            return
        } catch {
            guard dockerInspectKey == key else {
                return
            }
            errorMessage = AppLocalization.errorDescription(error)
        }
        if dockerInspectKey == key {
            dockerInspectLoading = false
        }
    }

    private func requestDockerContainerAction(
        _ container: DockerContainerRow,
        action: DockerContainerAction
    ) {
        if action == .remove || action == .kill {
            dockerSheet = .confirmContainer(container, action)
            return
        }
        Task {
            await performDockerContainerAction(
                container,
                action: action
            )
        }
    }

    private func performDockerContainerAction(
        _ container: DockerContainerRow,
        action: DockerContainerAction,
        newName: String? = nil
    ) async {
        guard let command = DockerManagement.containerCommand(
            id: container.id,
            action: action,
            newName: newName
        ) else {
            errorMessage = AppLocalization.string(
                "Invalid Docker container action."
            )
            return
        }
        pendingDockerActionID = container.id
        pendingDockerAction = action
        errorMessage = nil
        do {
            _ = try await runDockerCommand(
                command,
                timeoutMS: 30_000
            )
            if action == .remove {
                resetDockerSelection()
            }
            await refreshDocker()
            if action != .remove,
               selectedContainerID == container.id
            {
                let key = dockerInspectKeyForContainer(container)
                dockerInspectKey = key
                await loadDockerInspect(
                    id: container.id,
                    kind: .container,
                    key: key
                )
            }
        } catch is CancellationError {
            pendingDockerActionID = nil
            pendingDockerAction = nil
            return
        } catch {
            errorMessage = AppLocalization.errorDescription(error)
        }
        pendingDockerActionID = nil
        pendingDockerAction = nil
    }

    private func openDockerShell(
        _ container: DockerContainerRow
    ) {
        let elevationMethod =
            host.serverToolsUseRoot && host.username != "root"
                ? host.serverToolsElevationMethod
                : nil
        guard let command = DockerManagement.interactiveShellCommand(
                  containerID: container.id,
                  elevationMethod: elevationMethod
              ),
              let workspaceID = dockerWorkspaceID
        else {
            return
        }
        Task {
            await state.openTerminalTabAndRun(
                from: runtime.descriptor.id,
                in: workspaceID,
                title: "docker: \(container.name)",
                command: command,
                automaticElevationPassword: elevationMethod != nil
            )
        }
    }

    private func openDockerLogs(
        _ container: DockerContainerRow
    ) {
        let elevationMethod =
            host.serverToolsUseRoot && host.username != "root"
                ? host.serverToolsElevationMethod
                : nil
        guard let command = DockerManagement.logsCommand(
                  containerID: container.id,
                  elevationMethod: elevationMethod
              ),
              let workspaceID = dockerWorkspaceID
        else {
            return
        }
        Task {
            await state.openTerminalTabAndRun(
                from: runtime.descriptor.id,
                in: workspaceID,
                title: "logs: \(container.name)",
                command: command,
                automaticElevationPassword: elevationMethod != nil
            )
        }
    }

    private var dockerWorkspaceID: UUID? {
        state.workspaces.first {
            $0.root.sessionIDs.contains(runtime.descriptor.id)
        }?.id
    }

    private func removeDockerImage(
        _ image: DockerImageRow
    ) async {
        guard let command = DockerManagement.imageRemoveCommand(
            id: image.imageID,
            force: image.isDangling
        ) else {
            return
        }
        dockerImageActionInProgress = true
        errorMessage = nil
        do {
            _ = try await runDockerCommand(
                command,
                timeoutMS: 60_000
            )
            if selectedImageID == image.id {
                resetDockerSelection()
            }
            await refreshDocker()
        } catch is CancellationError {
            dockerImageActionInProgress = false
            return
        } catch {
            errorMessage = AppLocalization.errorDescription(error)
        }
        dockerImageActionInProgress = false
    }

    private func tagDockerImage(
        _ image: DockerImageRow,
        repository: String,
        tag: String
    ) async {
        guard let command = DockerManagement.imageTagCommand(
            id: image.imageID,
            repository: repository,
            tag: tag
        ) else {
            errorMessage = AppLocalization.string(
                "Repository and tag are invalid."
            )
            return
        }
        dockerImageActionInProgress = true
        errorMessage = nil
        do {
            _ = try await runDockerCommand(
                command,
                timeoutMS: 30_000
            )
            await refreshDocker()
        } catch is CancellationError {
            dockerImageActionInProgress = false
            return
        } catch {
            errorMessage = AppLocalization.errorDescription(error)
        }
        dockerImageActionInProgress = false
    }

    private func pruneDockerImages(all: Bool) async {
        dockerImageActionInProgress = true
        errorMessage = nil
        do {
            _ = try await runDockerCommand(
                DockerManagement.imagePruneCommand(all: all),
                timeoutMS: 120_000
            )
            resetDockerSelection()
            await refreshDocker()
        } catch is CancellationError {
            dockerImageActionInProgress = false
            return
        } catch {
            errorMessage = AppLocalization.errorDescription(error)
        }
        dockerImageActionInProgress = false
    }

    private func runDockerCommand(
        _ command: String,
        timeoutMS: Int
    ) async throws -> SystemCommandResult {
        let result = try await exec(command, timeoutMS: timeoutMS)
        guard result.code == nil || result.code == 0 else {
            let message = result.stderr
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw DockerPanelError.commandFailed(
                message.isEmpty
                    ? String(
                        format: AppLocalization.string(
                            "Docker exited with code %@."
                        ),
                        String(result.code ?? -1)
                    )
                    : message
            )
        }
        return result
    }

    private func runLoading(_ operation: () async throws -> Void) async {
        loading = true
        errorMessage = nil
        do {
            try await operation()
        } catch is CancellationError {
            loading = false
            return
        } catch {
            errorMessage = AppLocalization.errorDescription(error)
        }
        loading = false
    }

    private func runRefresh(_ operation: () async throws -> Void) async {
        errorMessage = nil
        do {
            try await operation()
        } catch is CancellationError {
            return
        } catch {
            errorMessage = AppLocalization.errorDescription(error)
        }
    }

    private func exec(
        _ command: String,
        timeoutMS: Int
    ) async throws -> SystemCommandResult {
        if runtime.descriptor.kind == .local {
            let response = try await LocalCommandExecutor.run(
                command: command,
                shell: runtime.descriptor.shell
                    ?? ProcessInfo.processInfo.environment["SHELL"]
                    ?? "/bin/zsh",
                workingDirectory: runtime.currentDirectory
                    ?? runtime.descriptor.workingDirectory,
                timeoutMS: timeoutMS
            )
            return SystemCommandResult(
                stdout: response.stdout,
                stderr: response.stderr,
                code: Int(response.code)
            )
        }

        let elevatesOperations =
            host.serverToolsUseRoot
            && host.username != "root"
        let response = try await state.execServerTool(
            in: workspaceID,
            host: host,
            sourceConnectionID: runtime.descriptor.sshConnectionID,
            sourceSessionID: runtime.descriptor.id,
            command: command,
            timeoutMS: timeoutMS,
            elevated: elevatesOperations
        )
        return SystemCommandResult(
            stdout: response.stdout,
            stderr: response.stderr,
            code: response.code
        )
    }

    private static let processCommand = "ps -eo pid= -o ppid= -o user= -o stat= -o pcpu= -o pmem= -o rss= -o vsz= -o etime= -o args= 2>/dev/null || top -b -n 1 2>/dev/null || ps ww 2>/dev/null || ps 2>/dev/null"

    private static let dockerListCommand = "docker ps -a --format '{{.ID}}\\t{{.Names}}\\t{{.Image}}\\t{{.Status}}\\t{{.State}}\\t{{.Ports}}' 2>/dev/null"

    private static let dockerImagesCommand = "docker images --format '{{.ID}}\\t{{.Repository}}\\t{{.Tag}}\\t{{.Size}}\\t{{.CreatedSince}}' 2>/dev/null"

    private static func parseOverview(_ output: String, latencyMS: Double) -> SystemOverviewSnapshot {
        let lines = output.split(separator: "\n").map(String.init)
        var values: [String: String] = [:]
        for line in lines {
            guard let index = line.firstIndex(of: "=") else {
                continue
            }
            let key = String(line[..<index])
            if key == "DISK"
                || key == "NETIF_BYTES"
                || key == "TOPPROC"
                || key == "CPU_CORE_RAW"
            {
                continue
            }
            values[key] = String(line[line.index(after: index)...])
        }
        let cpuCores = lines.compactMap {
            line -> SystemCPUCoreJiffyCounters? in
            guard line.hasPrefix("CPU_CORE_RAW=") else {
                return nil
            }
            let parts = line.dropFirst(13).split(
                separator: "|",
                omittingEmptySubsequences: false
            )
            guard parts.count >= 3,
                  let id = Int(parts[0]),
                  let total = UInt64(parts[1]),
                  let idle = UInt64(parts[2])
            else {
                return nil
            }
            return SystemCPUCoreJiffyCounters(
                id: id,
                total: total,
                idle: idle
            )
        }
        let cpuJiffyCounters: SystemCPUJiffyCounters?
        if let raw = values["CPU_RAW"] {
            let parts = raw.split(
                separator: "|",
                omittingEmptySubsequences: false
            )
            if parts.count >= 4,
               let total = UInt64(parts[0]),
               let idle = UInt64(parts[1]),
               let user = UInt64(parts[2]),
               let system = UInt64(parts[3])
            {
                cpuJiffyCounters = SystemCPUJiffyCounters(
                    total: total,
                    idle: idle,
                    user: user,
                    system: system,
                    cores: cpuCores
                )
            } else {
                cpuJiffyCounters = nil
            }
        } else {
            cpuJiffyCounters = nil
        }
        let disks = lines.compactMap { line -> SystemDiskRow? in
            guard line.hasPrefix("DISK=") else { return nil }
            let parts = line.dropFirst(5).split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            guard parts.count >= 4 else { return nil }
            return SystemDiskRow(
                mount: parts[0],
                usedGB: Double(parts[1]) ?? 0,
                totalGB: Double(parts[2]) ?? 0,
                percent: Double(parts[3]) ?? 0
            )
        }
        let networkInterfaceByteCounters = Dictionary(
            uniqueKeysWithValues: lines.compactMap { line -> (String, SystemNetworkByteCounters)? in
            guard line.hasPrefix("NETIF_BYTES=") else { return nil }
            let parts = line.dropFirst(12).split(
                separator: "|",
                omittingEmptySubsequences: false
            ).map(String.init)
            guard parts.count >= 3 else { return nil }
            guard let rxBytes = UInt64(parts[1]),
                  let txBytes = UInt64(parts[2])
            else {
                return nil
            }
            return (
                parts[0],
                SystemNetworkByteCounters(
                    rxBytes: rxBytes,
                    txBytes: txBytes
                )
            )
        })
        let networkByteCounters: SystemNetworkByteCounters?
        if let rxBytes = values["NET_RX_BYTES"].flatMap(UInt64.init),
           let txBytes = values["NET_TX_BYTES"].flatMap(UInt64.init) {
            networkByteCounters = SystemNetworkByteCounters(
                rxBytes: rxBytes,
                txBytes: txBytes
            )
        } else {
            networkByteCounters = nil
        }
        let topProcesses = lines.compactMap { line -> SystemProcessRow? in
            guard line.hasPrefix("TOPPROC=") else { return nil }
            let parts = line.dropFirst(8).split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            guard parts.count >= 3 else { return nil }
            return SystemProcessRow(
                pid: Int(parts[0]) ?? 0,
                ppid: 0,
                user: "",
                stat: "",
                cpuPercent: 0,
                memPercent: Double(parts[1]) ?? 0,
                rssKB: 0,
                vszKB: 0,
                elapsed: "",
                command: parts[2]
            )
        }
        return SystemOverviewSnapshot(
            cpuPercent: double(values["CPU"]),
            cpuUserPercent: double(values["CPU_USER"]),
            cpuSystemPercent: double(values["CPU_SYS"]),
            cpuPerCore: [],
            cpuCoreCount: values["CPU_CORES"].flatMap(Int.init)
                ?? (cpuCores.isEmpty ? nil : cpuCores.count),
            cpuJiffyCounters: cpuJiffyCounters,
            memoryPercent: double(values["MEM_PERCENT"]),
            memoryUsedMB: double(values["MEM_USED_MB"]),
            memoryTotalMB: double(values["MEM_TOTAL_MB"]),
            diskPercent: double(values["DISK_PERCENT"]),
            diskUsedGB: double(values["DISK_USED_GB"]),
            diskTotalGB: double(values["DISK_TOTAL_GB"]),
            disks: disks,
            netRxBps: nil,
            netTxBps: nil,
            networkInterfaces: [],
            networkByteCounters: networkByteCounters,
            networkInterfaceByteCounters: networkInterfaceByteCounters,
            load: values["LOAD"],
            uptime: formattedUptime(days: values["UPTIME_DAYS"], hours: values["UPTIME_HOURS"]),
            osName: values["OS"],
            kernel: values["KERNEL"],
            swap: values["SWAP"],
            latencyMS: latencyMS,
            topMemoryProcesses: topProcesses
        )
    }

    private static func parseProcesses(_ output: String) -> [SystemProcessRow] {
        output.split(separator: "\n").compactMap { rawLine in
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            let pattern = #"^(\d+)\s+(\d+)\s+(\S+)\s+(\S+)\s+([\d.]+)\s+([\d.]+)\s+(\d+)\s+(\d+)\s+(\S+)\s+(.+)$"#
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..<line.endIndex, in: line)),
                  match.numberOfRanges == 11
            else {
                return nil
            }
            func group(_ index: Int) -> String {
                guard let range = Range(match.range(at: index), in: line) else { return "" }
                return String(line[range])
            }
            return SystemProcessRow(
                pid: Int(group(1)) ?? 0,
                ppid: Int(group(2)) ?? 0,
                user: group(3),
                stat: group(4),
                cpuPercent: Double(group(5)) ?? 0,
                memPercent: Double(group(6)) ?? 0,
                rssKB: Int(group(7)) ?? 0,
                vszKB: Int(group(8)) ?? 0,
                elapsed: group(9),
                command: group(10)
            )
        }
    }

    private static func parseDockerContainers(_ output: String) -> [DockerContainerRow] {
        output.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard parts.count >= 6 else { return nil }
            return DockerContainerRow(
                id: parts[0],
                name: parts[1],
                image: parts[2],
                status: parts[3],
                state: parts[4],
                ports: parts[5]
            )
        }
    }

    private static func parseDockerImages(_ output: String) -> [DockerImageRow] {
        output.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard parts.count >= 5 else { return nil }
            let repository = parts[1]
            let tag = parts[2]
            return DockerImageRow(
                imageID: parts[0],
                repository: repository,
                tag: tag,
                size: parts[3],
                createdAt: parts[4],
                name: repository.isEmpty ? parts[0] : "\(repository):\(tag)"
            )
        }
    }

    private static func double(_ value: String?) -> Double? {
        guard let value else { return nil }
        return Double(value)
    }

    private static func formattedUptime(days: String?, hours: String?) -> String? {
        guard let days, let hours else {
            return nil
        }
        return String(
            format: AppLocalization.string("Uptime %@ days %@ hours"),
            days,
            hours
        )
    }

    private func percentText(_ value: Double?) -> String {
        guard let value else { return "--" }
        return "\(Int(value.rounded()))%"
    }

    private func percentText(_ value: Double?, digits: Int) -> String {
        guard let value else { return "--" }
        return String(format: "%.\(digits)f%%", value)
    }

    private func percentText(_ value: Double) -> String {
        "\(Int(value.rounded()))%"
    }

    private func percentNumber(_ value: String) -> Double {
        Double(value.replacingOccurrences(of: "%", with: "")) ?? 0
    }

    private func megabyteText(_ value: Double?) -> String {
        guard let value else { return "--" }
        return value >= 1024 ? String(format: "%.1f GB", value / 1024) : "\(Int(value)) MB"
    }

    private func gigabyteText(_ value: Double?) -> String {
        guard let value else { return "--" }
        return String(format: "%.1f GB", value)
    }

    private func bytesText(_ value: Double?) -> String {
        guard let value else { return "--" }
        if value >= 1024 * 1024 { return String(format: "%.1f MB", value / 1024 / 1024) }
        if value >= 1024 { return String(format: "%.1f KB", value / 1024) }
        if value > 0, value < 1 { return "<1 B" }
        return "\(Int(value)) B"
    }
}

private struct SessionScriptsPanel: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject var runtime: TerminalSessionRuntime

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text("Scripts")
                    .font(.headline)
                Text("Run a saved shell script in this terminal session.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if state.automationScripts.isEmpty {
                    ContentUnavailableView(
                        "No Scripts",
                        systemImage: "curlybraces.square"
                    )
                    .frame(maxWidth: .infinity, minHeight: 180)
                } else {
                    ForEach(state.automationScripts) { script in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(script.title)
                                .font(.subheadline.weight(.semibold))
                            Text(script.body)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .lineLimit(3)
                            HStack {
                                Spacer()
                                Button("Run") {
                                    Task {
                                        await state.runAutomationScript(
                                            script,
                                            in: runtime.descriptor.id
                                        )
                                    }
                                }
                            }
                        }
                        .padding(10)
                        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
        }
                    }
                }
            }
            .padding(12)
        }
    }
}

private struct SessionHostNotesPanel: View {
    @EnvironmentObject private var state: AppState
    let host: TermPilotDomain.Host
    let noteHostID: UUID?
    @State private var selectedNoteID: UUID?
    @State private var title = ""
    @State private var bodyText = ""

    private var notes: [HostNote] {
        state.hostNotes.filter { $0.hostID == noteHostID }
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("Host Notes")
                            .font(.headline)
                        Spacer()
                        Button("New Note") {
                            beginNewNote()
                        }
                    }

                    ForEach(notes) { note in
                        Button {
                            load(note)
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(note.title)
                                        .font(.subheadline.weight(.semibold))
                                    Text(note.body)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                Spacer()
                            }
                            .padding(8)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(
                                        selectedNoteID == note.id
                                            ? Color.accentColor.opacity(0.14)
                                            : Color.secondary.opacity(0.06)
                                    )
                            )
                        }
                        .buttonStyle(.plain)
                    }

                    Divider()

                    TextField("Title", text: $title)
                    TextEditor(text: $bodyText)
                        .frame(minHeight: 180)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color.secondary.opacity(0.2))
                        )
                }
                .textFieldStyle(.roundedBorder)
                .padding(12)
            }

            Divider()
            HStack {
                if let selectedNoteID,
                   let note = notes.first(where: { $0.id == selectedNoteID })
                {
                    Button("Delete", role: .destructive) {
                        beginNewNote()
                        Task { await state.deleteHostNote(note) }
                    }
                }
                Spacer()
                Button("Save") {
                    saveNote()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(10)
            .background(.bar)
        }
        .onAppear {
            if selectedNoteID == nil, let first = notes.first {
                load(first)
            }
        }
        .onChange(of: host.id) { _, _ in
            beginNewNote()
        }
    }

    private func beginNewNote() {
        selectedNoteID = nil
        title = ""
        bodyText = ""
    }

    private func load(_ note: HostNote) {
        selectedNoteID = note.id
        title = note.title
        bodyText = note.body
    }

    private func saveNote() {
        let existing = selectedNoteID.flatMap { id in
            notes.first { $0.id == id }
        }
        let note = HostNote(
            id: existing?.id ?? UUID(),
            hostID: noteHostID,
            title: title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? AppLocalization.string("New Note")
                : title,
            body: bodyText,
            createdAt: existing?.createdAt ?? Date(),
            updatedAt: existing?.updatedAt ?? Date()
        )
        selectedNoteID = note.id
        Task { await state.saveHostNote(note) }
    }
}

private struct SessionPortForwardingPanel: View {
    @EnvironmentObject private var state: AppState
    let host: TermPilotDomain.Host

    @State private var editingRuleID: UUID?
    @State private var name = ""
    @State private var kind = PortForwardKind.local
    @State private var localEndpointText = "127.0.0.1:8080"
    @State private var remoteEndpointText = "127.0.0.1:80"
    @State private var autoStart = false
    @State private var validationMessage: String?

    private var rules: [PortForwardRule] {
        state.portForwardRules.filter { $0.hostID == host.id }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Port Forwarding")
                        .font(.headline)
                    Spacer()
                    Button("New Forward") {
                        resetForm()
                    }
                }

                ForEach(rules) { rule in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(rule.name)
                            .font(.subheadline.weight(.semibold))
                        Text(ruleDetail(rule))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        HStack {
                            Text(rule.status.appLocalizedTitle)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Spacer()
                            if rule.status == .active || rule.status == .connecting {
                                Button("Stop") {
                                    Task { await state.stopPortForward(rule) }
                                }
                            } else {
                                Button("Start") {
                                    Task { await state.startPortForward(rule, host: host) }
                                }
                            }
                            Button("Edit") {
                                load(rule)
                            }
                            Button("Delete", role: .destructive) {
                                Task { await state.deletePortForwardRule(rule) }
                            }
                        }
                        if rule.status == .error,
                           let error = rule.error,
                           !error.isEmpty
                        {
                            Text(error)
                                .font(.caption2)
                                .foregroundStyle(.red)
                                .fixedSize(horizontal: false, vertical: true)
                                .textSelection(.enabled)
                        }
                    }
                    .padding(10)
                    .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
        }
                }

                Divider()

                TextField("Name", text: $name)
                Picker("Kind", selection: $kind) {
                    ForEach(PortForwardKind.allCases, id: \.self) { item in
                        Text(item.appLocalizedTitleKey).tag(item)
                    }
                }
                .pickerStyle(.segmented)
                Text(kind.appLocalizedDescriptionKey)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Toggle("Auto Start", isOn: $autoStart)
                endpointField(
                    "Local IP:Port",
                    text: $localEndpointText
                )
                if kind != .dynamic {
                    endpointField(
                        "Remote IP:Port",
                        text: $remoteEndpointText
                    )
                }
                if let validationMessage {
                    Text(validationMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                Button("Save") {
                    saveRule()
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .textFieldStyle(.roundedBorder)
            .padding(12)
        }
        .onAppear {
            if editingRuleID == nil {
                resetForm()
            }
        }
        .onChange(of: host.id) { _, _ in
            resetForm()
        }
    }

    private func resetForm() {
        editingRuleID = nil
        name = AppLocalization.string("Local Forward")
        kind = .local
        localEndpointText = "127.0.0.1:8080"
        remoteEndpointText = "127.0.0.1:80"
        autoStart = false
        validationMessage = nil
    }

    private func load(_ rule: PortForwardRule) {
        editingRuleID = rule.id
        name = rule.name
        kind = rule.kind
        localEndpointText = PortForwardEndpoint(
            host: rule.bindAddress,
            port: rule.localPort
        ).text
        remoteEndpointText = PortForwardEndpoint(
            host: rule.remoteHost,
            port: rule.remotePort ?? rule.localPort
        ).text
        autoStart = rule.autoStart
        validationMessage = nil
    }

    private func saveRule() {
        guard let localEndpoint = PortForwardEndpoint.parse(localEndpointText) else {
            validationMessage = AppLocalization.string("Enter a valid local IP:port.")
            return
        }
        let remoteEndpoint: PortForwardEndpoint?
        if kind == .dynamic {
            remoteEndpoint = nil
        } else {
            guard let parsedRemoteEndpoint = PortForwardEndpoint.parse(remoteEndpointText) else {
                validationMessage = AppLocalization.string("Enter a valid remote IP:port.")
                return
            }
            remoteEndpoint = parsedRemoteEndpoint
        }

        let existing = editingRuleID.flatMap { id in
            rules.first { $0.id == id }
        }
        let rule = PortForwardRule(
            id: existing?.id ?? UUID(),
            hostID: host.id,
            name: name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? AppLocalization.string("Local Forward")
                : name,
            order: existing?.order,
            kind: kind,
            bindAddress: localEndpoint.host,
            localPort: localEndpoint.port,
            remoteHost: remoteEndpoint?.host ?? "127.0.0.1",
            remotePort: remoteEndpoint?.port,
            autoStart: autoStart,
            status: existing?.status ?? .inactive,
            error: existing?.error,
            createdAt: existing?.createdAt ?? Date(),
            updatedAt: existing?.updatedAt ?? Date(),
            lastUsedAt: existing?.lastUsedAt
        )
        editingRuleID = rule.id
        validationMessage = nil
        Task { await state.savePortForwardRule(rule) }
    }

    private func endpointField(
        _ title: LocalizedStringKey,
        text: Binding<String>
    ) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 90, alignment: .leading)
            TextField("", text: text)
                .textFieldStyle(.roundedBorder)
        }
    }

    private func ruleDetail(_ rule: PortForwardRule) -> String {
        let local = "\(rule.bindAddress):\(rule.localPort)"
        switch rule.kind {
        case .dynamic:
            return "\(rule.kind.rawValue) \(local)"
        case .local:
            return "\(rule.kind.rawValue) \(local) -> \(rule.remoteHost):\(rule.remotePort ?? rule.localPort)"
        case .remote:
            return "\(rule.kind.rawValue) \(rule.remoteHost):\(rule.remotePort ?? rule.localPort) -> \(local)"
        }
    }
}
