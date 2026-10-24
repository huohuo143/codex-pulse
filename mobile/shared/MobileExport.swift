import Foundation

public enum MobileExport {
  /// RFC 4180 quoting plus spreadsheet-formula neutralization for externally sourced labels.
  public static func csvCell(_ value:String) -> String {
    let safe = ["=","+","-","@","\t","\r"].contains(where:value.hasPrefix) ? "'"+value : value
    return "\""+safe.replacingOccurrences(of:"\"",with:"\"\"")+"\""
  }
  public static func csv(_ detail:MobileDetailSnapshot) -> String {
    var rows:[[String]]=[["section","id_or_time","label","value","secondary","tertiary","source_time","note"],
      ["metadata","","source_timezone",detail.sourceTimeZone,"","",detail.publishedAt.ISO8601Format(),"Anonymous Mac log aggregates; not an official account bill. History is downsampled."]]
    let usageTime=detail.usageSampledAt?.ISO8601Format() ?? ""
    func number(_ value:Double?) -> String { value.map(String.init(describing:)) ?? "" }
    if let u=detail.usage {
      for (name,points) in [("hourly",u.hourly),("daily",u.daily),("monthly",u.monthly)] {
        rows += points.map { [name,$0.key,$0.label,String($0.tokens),String($0.input),String($0.output),usageTime,"cached_input="+String($0.cached)] }
      }
      for (name,metrics) in [("projects",u.projects),("budgets",u.budgets),("models",u.models),("analysis",u.analysis),("costs_usd",u.costs),("devices",u.devices)] {
        rows += metrics.map { [name,$0.id,$0.label,number($0.value),number($0.secondary),number($0.tertiary),usageTime,$0.note] }
      }
    }
    rows += detail.history.map { ["quota_history",$0.date.ISO8601Format(),"remaining_percent",String($0.remaining),$0.resetAt.ISO8601Format(),String($0.segment),$0.date.ISO8601Format(),"sampled history"] }
    rows += detail.calendar.map { ["public_calendar",$0.day,$0.title,$0.kind,$0.confirmation,$0.precision,detail.calendarReadAt?.ISO8601Format() ?? "",$0.summary] }
    return "\u{FEFF}"+rows.map { $0.map(csvCell).joined(separator:",") }.joined(separator:"\r\n")+"\r\n"
  }
}
