import Foundation

protocol TaskDisplayable {
    var id: String { get }
    var title: String { get }
    var todoState: String? { get }
    var priority: String? { get }
    var tags: [String] { get }
    var inheritedTags: [String] { get }
    var scheduled: OrgTimestamp? { get }
    var deadline: OrgTimestamp? { get }
    var category: String { get }
    var file: String { get }
    var pos: Int { get }
}

extension OrgTask: TaskDisplayable {}
extension AgendaEntry: TaskDisplayable {}
