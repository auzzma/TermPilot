import Foundation

extension Dictionary where Key == String, Value == Any {
  func metric(_ key: String) -> Double? {
    guard let n = self[key] as? NSNumber, n.doubleValue.isFinite else { return nil }
    return n.doubleValue
  }
}
func monitorBytes(_ value: Double?) -> String {
  guard let value, value.isFinite, value >= 0 else { return "--" }
  return ByteCountFormatter.string(fromByteCount: Int64(min(value, Double(Int64.max / 2))), countStyle: .binary)
}
func monitorPercent(_ value: Double?) -> String { value.map { String(format: "%.1f%%", $0) } ?? "--" }

struct MonitorParser {
  private var lastTime: Double?
  private var cpu: [Double] = []
  private var interfaces: [String: [Double]] = [:]
  mutating func parse(_ output: String) throws -> JSON {
    var values: [String: String] = [:]
    var disks: [JSON] = [], tops: [JSON] = [], network: [JSON] = []
    var counters: [String: [Double]] = [:]
    let lines = output.split(separator: "\n").map(String.init)
    for line in lines {
      let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
      if parts.count == 2 { values[String(parts[0])] = String(parts[1]) }
    }
    func n(_ key: String) -> Double? { values[key].flatMap(Double.init).flatMap { $0.isFinite ? $0 : nil } }
    guard let total = n("MEM_TOTAL_MB"), total > 0 else { throw MobileError(message: tr("无法获取监控数据")) }
    let time = n("SAMPLE_TIME"), elapsed = time.flatMap { t in lastTime.map { t - $0 } }
    let timed = elapsed.map { $0 > 0 && $0 < 60 } == true
    let raw = (values["CPU_RAW"] ?? "").split(separator: "|").compactMap { Double($0) }
    var usage = n("CPU"), user = n("CPU_USER"), system = n("CPU_SYS")
    if raw.count == 4 && cpu.count == 4 && raw[0] > cpu[0] && zip(raw,cpu).allSatisfy({ $0 >= $1 }) {
      let delta = raw[0] - cpu[0]
      usage = min(100,max(0,100 * (1 - (raw[1] - cpu[1]) / delta)))
      user = min(100,max(0,100 * (raw[2] - cpu[2]) / delta))
      system = min(100,max(0,100 * (raw[3] - cpu[3]) / delta))
    }
    for line in lines {
      let p = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
      guard p.count == 2 else { continue }
      let v = p[1].split(separator: "|", omittingEmptySubsequences: false).map(String.init)
      if p[0] == "DISK", v.count >= 4 { disks.append(["mount":v[0],"used":(Double(v[1]) ?? 0)*1073741824,"total":(Double(v[2]) ?? 0)*1073741824,"percent":Double(v[3]) ?? 0]) }
      if p[0] == "TOPPROC", v.count >= 3 { tops.append(["pid":Int(v[0]) ?? 0,"memoryPercent":Double(v[1]) ?? 0,"command":v[2]]) }
      if p[0] == "NETIF_BYTES", v.count >= 3, let rx=Double(v[1]), let tx=Double(v[2]) {
        let old=interfaces[v[0]]
        let valid=timed && old != nil && rx >= old![0] && tx >= old![1]
        network.append(["name":v[0],"rxPerSecond":valid ? (rx-old![0])/elapsed! : NSNull(),"txPerSecond":valid ? (tx-old![1])/elapsed! : NSNull()])
        counters[v[0]]=[rx,tx]
      }
    }
    defer { lastTime=time;cpu=raw;interfaces=counters }
    var result: JSON = ["os":values["OS"] ?? "--","kernel":values["KERNEL"] ?? "--","loadAverage":values["LOAD"] ?? "--","swap":values["SWAP"] ?? "--","uptime":trf("{} 天 {} 小时",values["UPTIME_DAYS"] ?? "--",values["UPTIME_HOURS"] ?? "--"),"cpuCoreCount":n("CPU_CORES") ?? 0,"memoryTotal":total*1048576,"memoryUsed":(n("MEM_USED_MB") ?? 0)*1048576,"disks":disks,"networkInterfaces":network,"topMemoryProcesses":tops]
    result["cpuUsage"]=usage;result["cpuUserUsage"]=user;result["cpuSystemUsage"]=system
    let rates=network.compactMap { $0.metric("rxPerSecond") }
    if !rates.isEmpty { result["networkRxPerSecond"]=rates.reduce(0,+);result["networkTxPerSecond"]=network.compactMap { $0.metric("txPerSecond") }.reduce(0,+) }
    return result
  }
  static let processCommand = "LC_ALL=C ps -eo pid= -o user= -o pcpu= -o pmem= -o rss= -o comm="
  static func processes(_ output: String) -> [JSON] {
    output.split(separator: "\n").compactMap { line in
      let c=line.split(maxSplits:5,omittingEmptySubsequences:true,whereSeparator: { $0 == " " || $0 == "\t" })
      guard c.count==6, let pid=Int(c[0]), let cpu=Double(c[2]), let mem=Double(c[3]) else { return nil }
      return ["pid":pid,"user":String(c[1]),"cpuPercent":cpu,"memPercent":mem,"rssKB":Double(c[4]) ?? 0,"command":String(c[5])]
    }
  }
}
